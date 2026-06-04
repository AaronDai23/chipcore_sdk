package com.chipcore.sdk.flutter

import java.io.IOException
import java.io.OutputStreamWriter
import java.math.BigInteger
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONArray
import org.json.JSONObject

// ─── Chain HTTP helpers ───────────────────────────────────────────────────────

internal object ChainClient {

    private const val BTC_MAIN_API = "https://mempool.space/api"
    private const val BTC_TEST_API = "https://mempool.space/testnet4/api"
    private const val ETH_MAIN_RPC = "https://ethereum.publicnode.com"
    private const val ETH_TEST_RPC = "https://ethereum-sepolia.publicnode.com"
    private const val BSC_MAIN_RPC = "https://bsc-dataseed.bnbchain.org"
    private const val BSC_TEST_RPC = "https://bsc-testnet-dataseed.bnbchain.org"
    private const val POLYGON_MAIN_RPC = "https://polygon-rpc.com"
    private const val POLYGON_TEST_RPC = "https://rpc-amoy.polygon.technology"
    // RTAP / RTBP：ERC20 合约部署在 Ethereum Sepolia 测试网，强制使用 Sepolia RPC
    private const val SEPOLIA_RPC = "https://ethereum-sepolia.publicnode.com"
    // 按 symbol 识别需要固定走 Sepolia 的代币（networkId 在后端可能错误返回 "eth"+testnet=false）
    private val SEPOLIA_SYMBOLS = setOf("RTAP", "RTBP")

    fun ethRpc(isTest: Boolean) = if (isTest) ETH_TEST_RPC else ETH_MAIN_RPC

    /** 根据 networkId 路由到正确的 EVM RPC（ETH / BSC / Polygon） */
    fun evmRpc(networkId: String, isTest: Boolean): String {
        val net = networkId.lowercase()
        return when {
            net.contains("binance") || net.contains("bsc") || net.contains("bnb") ->
                if (isTest) BSC_TEST_RPC else BSC_MAIN_RPC
            net.contains("polygon") || net.contains("matic") || net.contains("pol") ->
                if (isTest) POLYGON_TEST_RPC else POLYGON_MAIN_RPC
            else -> if (isTest) ETH_TEST_RPC else ETH_MAIN_RPC
        }
    }

    /**
     * 按 symbol + networkId 联合路由。
     * 对于后端 testnet 字段配置错误（如 RTAP/RTBP 返回 testnet=false 但实际在 Sepolia）
     * 直接按 symbol 强制选正确 RPC，避免交易广播到错误网络。
     */
    fun evmRpcBySymbol(networkId: String, symbol: String, isTest: Boolean): String {
        if (symbol.uppercase() in SEPOLIA_SYMBOLS) return SEPOLIA_RPC
        return evmRpc(networkId, isTest)
    }

    fun fetchBtcFees(isTest: Boolean): List<Messages.FeeResponse> {
        val api = if (isTest) BTC_TEST_API else BTC_MAIN_API
        val json = httpGet("$api/v1/fees/recommended")
        val obj = JSONObject(json)
        val low = obj.getLong("economyFee")
        val normal = obj.getLong("halfHourFee")
        val priority = obj.getLong("fastestFee")
        return listOf(
            feeResponse(Messages.FeeType.LOW, low.toString()),
            feeResponse(Messages.FeeType.NORMAL, normal.toString()),
            feeResponse(Messages.FeeType.PRIORITY, priority.toString()),
        )
    }

    fun fetchBtcFeeRate(isTest: Boolean): Long {
        val api = if (isTest) BTC_TEST_API else BTC_MAIN_API
        val json = httpGet("$api/v1/fees/recommended")
        return JSONObject(json).getLong("halfHourFee")
    }

    fun fetchEthFees(isTest: Boolean): List<Messages.FeeResponse> = fetchEVMNativeFees(ethRpc(isTest))

    /** EVM 原生代币手续费（支持任意 RPC 端点：ETH/BSC/Polygon）*/
    fun fetchEVMNativeFees(rpc: String): List<Messages.FeeResponse> {
        val gasPriceWei = ethGasPrice(rpc)
        val gasLimit = BigInteger.valueOf(100000)
        fun feeEth(factor: Long): String {
            val adjusted = gasPriceWei.multiply(BigInteger.valueOf(factor)).divide(BigInteger.valueOf(100))
            return EthEncoder.weiToEthString(adjusted.multiply(gasLimit))
        }
        fun gasPrice(factor: Long): String =
            "0x" + gasPriceWei.multiply(BigInteger.valueOf(factor)).divide(BigInteger.valueOf(100)).toString(16)
        return listOf(
            feeResponseEth(Messages.FeeType.LOW, feeEth(100), gasLimit.toString(), gasPrice(100)),
            feeResponseEth(Messages.FeeType.NORMAL, feeEth(120), gasLimit.toString(), gasPrice(120)),
            feeResponseEth(Messages.FeeType.PRIORITY, feeEth(150), gasLimit.toString(), gasPrice(150)),
        )
    }

    /** ERC20 代币手续费：eth_estimateGas 估算 +20% buffer */
    fun fetchEVMTokenFees(rpc: String, contractAddress: String, fromAddress: String, toAddress: String): List<Messages.FeeResponse> {
        val gasPriceWei = ethGasPrice(rpc)
        val dummyData = "0x" + EthEncoder.encodeERC20Transfer(toAddress, BigInteger.ONE).toHex()
        val estimatedGas: BigInteger = try {
            val params = """[{"from":"$fromAddress","to":"$contractAddress","data":"$dummyData"},"latest"]"""
            val result = rpcCall(rpc, "eth_estimateGas", params)
            val hex = result.removePrefix("\"").removeSuffix("\"").removePrefix("0x")
            BigInteger(hex, 16).multiply(BigInteger.valueOf(120)).divide(BigInteger.valueOf(100))
        } catch (e: Exception) {
            BigInteger.valueOf(80000)
        }
        fun feeEth(factor: Long): String {
            val adjusted = gasPriceWei.multiply(BigInteger.valueOf(factor)).divide(BigInteger.valueOf(100))
            return EthEncoder.weiToEthString(adjusted.multiply(estimatedGas))
        }
        fun gasPrice(factor: Long): String =
            "0x" + gasPriceWei.multiply(BigInteger.valueOf(factor)).divide(BigInteger.valueOf(100)).toString(16)
        return listOf(
            feeResponseEth(Messages.FeeType.LOW, feeEth(100), estimatedGas.toString(), gasPrice(100)),
            feeResponseEth(Messages.FeeType.NORMAL, feeEth(120), estimatedGas.toString(), gasPrice(120)),
            feeResponseEth(Messages.FeeType.PRIORITY, feeEth(150), estimatedGas.toString(), gasPrice(150)),
        )
    }

    fun ethGasPrice(rpc: String): BigInteger {
        val result = rpcCall(rpc, "eth_gasPrice", "[]")
        val hex = result.removePrefix("\"").removeSuffix("\"").removePrefix("0x")
        return BigInteger(hex, 16)
    }

    fun ethNonce(rpc: String, address: String): BigInteger {
        val result = rpcCall(rpc, "eth_getTransactionCount", "[\"$address\",\"pending\"]")
        val hex = result.removePrefix("\"").removeSuffix("\"").removePrefix("0x")
        return BigInteger(hex, 16)
    }

    fun ethChainId(rpc: String): BigInteger {
        val result = rpcCall(rpc, "eth_chainId", "[]")
        val hex = result.removePrefix("\"").removeSuffix("\"").removePrefix("0x")
        return BigInteger(hex, 16)
    }

    fun ethBroadcast(rawTx: ByteArray, rpc: String): String {
        val hex = "0x" + rawTx.toHex()
        val result = rpcCall(rpc, "eth_sendRawTransaction", "[\"$hex\"]")
        return result.removePrefix("\"").removeSuffix("\"")
    }

    fun fetchBtcUtxos(address: String, isTest: Boolean): List<BtcEncoder.Utxo> {
        val api = if (isTest) BTC_TEST_API else BTC_MAIN_API
        val json = httpGet("$api/address/$address/utxo")
        val arr = JSONArray(json)
        return (0 until arr.length()).map { i ->
            val obj = arr.getJSONObject(i)
            val status = obj.optJSONObject("status")
            val confirmed = status?.optBoolean("confirmed", false) ?: false
            BtcEncoder.Utxo(
                txid = obj.getString("txid"),
                vout = obj.getInt("vout"),
                value = obj.getLong("value"),
                confirmed = confirmed,
            )
        }.filter { it.confirmed }
    }

    fun btcBroadcast(rawTx: ByteArray, isTest: Boolean): String {
        val api = if (isTest) BTC_TEST_API else BTC_MAIN_API
        val hex = rawTx.toHex()
        return httpPost("$api/tx", hex, "text/plain")
    }

    /** BTC 余额：汇总已确认 UTXO 中的 satoshi，转换为 BTC 字符串 */
    fun fetchBtcBalance(address: String, isTest: Boolean): String {
        val utxos = fetchBtcUtxos(address, isTest)
        val satoshis = utxos.sumOf { it.value }
        return java.math.BigDecimal(satoshis)
            .divide(java.math.BigDecimal("100000000"))
            .toPlainString()
    }

    /** ETH 余额：通过 eth_getBalance RPC 查询，转换为 ETH 字符串 */
    fun fetchEthBalance(address: String, isTest: Boolean): String = fetchEthBalance(address, ethRpc(isTest))

    fun fetchEthBalance(address: String, rpc: String): String {
        val result = rpcCall(rpc, "eth_getBalance", "[\"$address\",\"latest\"]")
        val hex = result.removePrefix("\"").removeSuffix("\"").removePrefix("0x")
        val wei = BigInteger(hex, 16)
        return EthEncoder.weiToEthString(wei)
    }

    /** ERC20 代币余额：eth_call balanceOf(address) */
    fun fetchERC20Balance(address: String, contractAddress: String, rpc: String, decimals: Int): String {
        val data = "0x" + EthEncoder.encodeERC20BalanceOf(address).toHex()
        val params = """[{"to":"$contractAddress","data":"$data"},"latest"]"""
        val result = rpcCall(rpc, "eth_call", params)
        val hex = result.removePrefix("\"").removeSuffix("\"").removePrefix("0x")
        val raw = if (hex.isEmpty()) BigInteger.ZERO else BigInteger(hex, 16)
        return EthEncoder.formatTokenAmount(raw, decimals)
    }

    /** TRC20 代币余额：TronGrid triggerConstantContract */
    fun fetchTRC20Balance(address: String, contractAddress: String, isTest: Boolean, decimals: Int): String {
        val api = if (isTest) "https://nile.trongrid.io" else TRON_MAIN_API
        val hexAddr = try {
            val decoded = Base58Check.decode(address)
            decoded.copyOfRange(1, decoded.size).toHex()
        } catch (e: Exception) { address.removePrefix("0x") }
        val paddedAddr = hexAddr.padStart(64, '0')
        val body = """{"owner_address":"$address","contract_address":"$contractAddress","function_selector":"balanceOf(address)","parameter":"$paddedAddr","visible":true}"""
        val resp = trxPost("$api/wallet/triggerconstantcontract", body)
        val json = JSONObject(resp)
        val constantResult = json.optJSONArray("constant_result")?.optString(0) ?: return "0"
        val raw = if (constantResult.isEmpty()) BigInteger.ZERO else BigInteger(constantResult, 16)
        return EthEncoder.formatTokenAmount(raw, decimals)
    }

    // ── TRX 相关 ──────────────────────────────────────────────────────────────

    private const val TRON_MAIN_API = "https://api.trongrid.io"

    /** TRX 余额：通过 TronGrid v1 查询，单位 TRX */
    fun fetchTrxBalance(address: String): String {
        val json = httpGet("$TRON_MAIN_API/v1/accounts/$address")
        val obj = JSONObject(json)
        val dataArr = obj.optJSONArray("data")
        val sunBalance = if (dataArr != null && dataArr.length() > 0) {
            dataArr.getJSONObject(0).optLong("balance", 0L)
        } else {
            0L
        }
        // 1 TRX = 1,000,000 SUN
        return java.math.BigDecimal(sunBalance)
            .divide(java.math.BigDecimal("1000000"))
            .toPlainString()
    }

    /** TRX 固定手续费（基于带宽/能量，普通转账约 1 TRX，此处返回固定三档） */
    fun fetchTrxFees(): List<Messages.FeeResponse> {
        return listOf(
            feeResponse(Messages.FeeType.LOW, "1"),
            feeResponse(Messages.FeeType.NORMAL, "1"),
            feeResponse(Messages.FeeType.PRIORITY, "3"),
        )
    }

    /** POST JSON 请求给 TronGrid */
    fun trxPost(urlStr: String, body: String): String {
        return httpPost(urlStr, body, "application/json")
    }

    // ── DOGE 相关 ─────────────────────────────────────────────────────────────
    // BlockCypher 免费 API（无需 Key，3 req/s，200 req/h）

    private fun dogeNet(isTest: Boolean) = if (isTest) "doge/test3" else "doge/main"
    private fun dogeCypherBase(isTest: Boolean) = "https://api.blockcypher.com/v1/${dogeNet(isTest)}"

    /** DOGE 余额：Blockchair，单位 DOGE（主网），测试网 fallback 到 BlockCypher */
    fun fetchDogeBalance(address: String, isTest: Boolean): String {
        if (isTest) {
            val json = httpGet("${dogeCypherBase(true)}/addrs/$address/balance")
            val satoshis = JSONObject(json).optLong("balance", 0L)
            return java.math.BigDecimal(satoshis)
                .divide(java.math.BigDecimal("100000000"))
                .stripTrailingZeros().toPlainString()
        }
        // BlockCypher mainnet balance（与 UTXO/广播同域名，不增加额外连接）
        val json = httpGet("${dogeCypherBase(false)}/addrs/$address/balance")
        val satoshis = JSONObject(json).optLong("balance", 0L)
        return java.math.BigDecimal(satoshis)
            .divide(java.math.BigDecimal("100000000"))
            .stripTrailingZeros().toPlainString()
    }

    /** DOGE 手续费：BlockCypher chain info，sat/byte 三档 */
    fun fetchDogeFees(isTest: Boolean): List<Messages.FeeResponse> {
        val defaultPerKb = 100_000_000L // 1 DOGE/kB 兜底
        val triple: Triple<Long, Long, Long> = try {
            val json = httpGet(dogeCypherBase(isTest))
            val obj = JSONObject(json)
            Triple(
                obj.optLong("low_fee_per_kb", defaultPerKb).coerceAtLeast(1L),
                obj.optLong("medium_fee_per_kb", defaultPerKb).coerceAtLeast(1L),
                obj.optLong("high_fee_per_kb", defaultPerKb).coerceAtLeast(1L),
            )
        } catch (e: Exception) {
            Triple(defaultPerKb, defaultPerKb * 2, defaultPerKb * 4)
        }
        val (lowPerKb, midPerKb, highPerKb) = triple
        val txBytes = 226L // 标准 P2PKH 单输入估算
        fun satToDoge(sat: Long): String =
            java.math.BigDecimal(sat)
                .divide(java.math.BigDecimal("100000000"))
                .toPlainString()
        fun dogeResponse(type: Messages.FeeType, perKb: Long): Messages.FeeResponse {
            val satPerByte = (perKb / 1000L).coerceAtLeast(1L)
            return Messages.FeeResponse.Builder()
                .setType(type)
                .setValue(satToDoge(satPerByte * txBytes))
                .setGasPrice(satPerByte.toString())
                .build()
        }
        return listOf(
            dogeResponse(Messages.FeeType.LOW,      lowPerKb),
            dogeResponse(Messages.FeeType.NORMAL,   midPerKb),
            dogeResponse(Messages.FeeType.PRIORITY, highPerKb),
        )
    }

    /** DOGE UTXO：Blockchair（主网），测试网 fallback 到 BlockCypher */
    fun fetchDogeUtxos(address: String, isTest: Boolean): List<DogeEncoder.DogeUtxo> {
        if (isTest) {
            val json = httpGet("${dogeCypherBase(true)}/addrs/$address?unspentOnly=true&includeScript=true")
            val obj = JSONObject(json)
            fun parseRefs(key: String): List<DogeEncoder.DogeUtxo> {
                val arr = obj.optJSONArray(key) ?: return emptyList()
                return (0 until arr.length()).mapNotNull { i ->
                    val u = arr.getJSONObject(i)
                    if (u.optBoolean("spent", false)) null
                    else DogeEncoder.DogeUtxo(txid = u.getString("tx_hash"), vout = u.getInt("tx_output_n"), value = u.getLong("value"))
                }
            }
            return parseRefs("txrefs") + parseRefs("unconfirmed_txrefs")
        }
        // BlockCypher mainnet UTXO（仅发交易时调用，不频繁，不易触发 429）
        val json = httpGet("${dogeCypherBase(false)}/addrs/$address?unspentOnly=true&includeScript=true")
        val obj = JSONObject(json)
        fun parseMainnetRefs(key: String): List<DogeEncoder.DogeUtxo> {
            val arr = obj.optJSONArray(key) ?: return emptyList()
            return (0 until arr.length()).mapNotNull { i ->
                val u = arr.getJSONObject(i)
                if (u.optBoolean("spent", false)) null
                else DogeEncoder.DogeUtxo(txid = u.getString("tx_hash"), vout = u.getInt("tx_output_n"), value = u.getLong("value"))
            }
        }
        val utxos = parseMainnetRefs("txrefs") + parseMainnetRefs("unconfirmed_txrefs")
        android.util.Log.d("ChainClient", "[DOGE UTXO] total=${utxos.size} totalSat=${utxos.sumOf { it.value }}")
        return utxos
    }

    /** DOGE 广播：Blockchair（主网），测试网 fallback 到 BlockCypher */
    fun dogeBroadcast(rawTx: ByteArray, isTest: Boolean): String {
        val hex = rawTx.toHex()
        if (isTest) {
            val resp = httpPost("${dogeCypherBase(true)}/txs/push", "{\"tx\":\"$hex\"}", "application/json")
            return JSONObject(resp).optJSONObject("tx")?.optString("hash")
                ?: throw IOException("DOGE broadcast failed: $resp")
        }
        // BlockCypher mainnet broadcast（发交易一次性调用，不会触发频率限制）
        val resp = httpPost("${dogeCypherBase(false)}/txs/push", "{\"tx\":\"$hex\"}", "application/json")
        return JSONObject(resp).optJSONObject("tx")?.optString("hash")
            ?: throw IOException("DOGE broadcast failed: $resp")
    }

    private fun rpcCall(endpoint: String, method: String, params: String): String {
        val body = """{"jsonrpc":"2.0","method":"$method","params":$params,"id":1}"""
        val response = httpPost(endpoint, body, "application/json")
        val obj = JSONObject(response)
        if (obj.has("error")) {
            val err = obj.getJSONObject("error")
            throw IOException("RPC error: ${err.optString("message")}")
        }
        return obj.get("result").toString()
    }

    private fun httpGet(urlStr: String): String {
        val conn = URL(urlStr).openConnection() as HttpURLConnection
        conn.requestMethod = "GET"
        conn.setRequestProperty("Accept", "application/json")
        conn.connectTimeout = 15_000
        conn.readTimeout = 15_000
        return if (conn.responseCode in 200..299) {
            conn.inputStream.bufferedReader().readText()
        } else {
            val errBody = runCatching { conn.errorStream?.bufferedReader()?.readText() }.getOrNull()
            throw IOException("HTTP ${conn.responseCode} $urlStr: $errBody")
        }
    }

    private fun httpPost(urlStr: String, body: String, contentType: String): String {
        val conn = URL(urlStr).openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", contentType)
        conn.setRequestProperty("Accept", "application/json, text/plain")
        conn.connectTimeout = 15_000
        conn.readTimeout = 15_000
        OutputStreamWriter(conn.outputStream, "UTF-8").use { it.write(body) }
        return if (conn.responseCode in 200..299) {
            conn.inputStream.bufferedReader().readText()
        } else {
            val errBody = runCatching { conn.errorStream?.bufferedReader()?.readText() }.getOrNull()
            throw IOException("HTTP ${conn.responseCode}: $errBody")
        }
    }

    private fun feeResponse(type: Messages.FeeType, value: String) =
        Messages.FeeResponse.Builder().setType(type).setValue(value).build()

    private fun feeResponseEth(type: Messages.FeeType, value: String, gasLimit: String, gasPrice: String) =
        Messages.FeeResponse.Builder()
            .setType(type)
            .setValue(value)
            .setGasLimit(gasLimit)
            .setGasPrice(gasPrice)
            .build()

    // ── 交易历史 ───────────────────────────────────────────────────────────────

    /** BTC 交易历史：mempool.space /address/{addr}/txs */
    fun fetchBtcTxHistory(address: String, isTest: Boolean): List<Messages.TransactionsHistory> {
        val api = if (isTest) BTC_TEST_API else BTC_MAIN_API
        val json = httpGet("$api/address/$address/txs")
        val arr = JSONArray(json)
        val result = mutableListOf<Messages.TransactionsHistory>()
        for (i in 0 until arr.length()) {
            val tx = arr.getJSONObject(i)
            val txid = tx.optString("txid")
            val status = tx.optJSONObject("status")
            val confirmed = status?.optBoolean("confirmed", false) ?: false
            val blockTime = status?.optLong("block_time", 0L) ?: 0L

            // 判断方向：是否有 vin 中包含我方地址
            val vin = tx.optJSONArray("vin") ?: JSONArray()
            val vout = tx.optJSONArray("vout") ?: JSONArray()
            var isOutgoing = false
            var fromAddr = ""
            for (j in 0 until vin.length()) {
                val prevout = vin.getJSONObject(j).optJSONObject("prevout")
                val addr = prevout?.optString("scriptpubkey_address") ?: ""
                if (j == 0 && addr.isNotEmpty()) fromAddr = addr
                if (addr.equals(address, ignoreCase = true)) { isOutgoing = true; break }
            }
            // 金额：收入=我方 vout 之和，支出=非我方 vout 之和
            var satAmount = 0L
            var toAddr = ""
            for (j in 0 until vout.length()) {
                val out = vout.getJSONObject(j)
                val outAddr = out.optString("scriptpubkey_address")
                val outVal = out.optLong("value", 0L)
                if (isOutgoing) {
                    if (!outAddr.equals(address, ignoreCase = true)) {
                        satAmount += outVal
                        if (toAddr.isEmpty()) toAddr = outAddr
                    }
                } else {
                    if (outAddr.equals(address, ignoreCase = true)) satAmount += outVal
                    if (toAddr.isEmpty()) toAddr = outAddr
                }
            }
            result.add(
                Messages.TransactionsHistory.Builder()
                    .setTime(blockTime)
                    .setDirection(if (isOutgoing) 0L else 1L)
                    .setStatus(if (confirmed) 1L else 0L)
                    .setType(0L)
                    .setValue(satAmount.toDouble() / 1e8)
                    .setDecimals(8L)
                    .setTxHash(txid)
                    .setFromAddress(fromAddr)
                    .setToAddress(toAddr)
                    .build()
            )
        }
        return result
    }

    /** ETH 交易历史：Blockscout /api/v2/addresses/{addr}/transactions */
    fun fetchEthTxHistory(address: String, isTest: Boolean): List<Messages.TransactionsHistory> {
        // BlockCypher 仅支持 ETH mainnet；国内可访问，无需 API key
        val json = httpGet("https://api.blockcypher.com/v1/eth/main/addrs/$address/full?limit=25")
        val txs = JSONObject(json).optJSONArray("txs") ?: JSONArray()
        val result = mutableListOf<Messages.TransactionsHistory>()
        val addrLower = address.lowercase()
        for (i in 0 until txs.length()) {
            val tx = txs.getJSONObject(i)
            val hash = tx.optString("hash")
            // inputs[0].addresses[0] = 发送方
            val inputs = tx.optJSONArray("inputs") ?: JSONArray()
            val fromAddr = inputs.optJSONObject(0)?.optJSONArray("addresses")?.optString(0) ?: ""
            // 取第一个非自身地址的 output 作为接收方
            val outputs = tx.optJSONArray("outputs") ?: JSONArray()
            var toAddr = ""
            var valueWei = java.math.BigDecimal.ZERO
            for (j in 0 until outputs.length()) {
                val out = outputs.getJSONObject(j)
                val outAddrs = out.optJSONArray("addresses") ?: continue
                val addr0 = outAddrs.optString(0, "")
                if (addr0.lowercase() != addrLower) {
                    toAddr = addr0
                    valueWei = try {
                        java.math.BigDecimal(out.optString("value", "0"))
                    } catch (_: Exception) { java.math.BigDecimal.ZERO }
                    break
                }
            }
            // 自转账：fallback 到第一个 output
            if (toAddr.isEmpty() && outputs.length() > 0) {
                val out = outputs.getJSONObject(0)
                toAddr = out.optJSONArray("addresses")?.optString(0) ?: ""
                valueWei = try {
                    java.math.BigDecimal(out.optString("value", "0"))
                } catch (_: Exception) { java.math.BigDecimal.ZERO }
            }
            val isOutgoing = fromAddr.lowercase() == addrLower
            val valueEth = valueWei
                .divide(java.math.BigDecimal.TEN.pow(18), 18, java.math.RoundingMode.HALF_UP)
                .toDouble()
            val confirmedStr = tx.optString("confirmed", "")
            val epochSec = if (confirmedStr.isNotEmpty()) {
                try { java.time.Instant.parse(confirmedStr).epochSecond } catch (_: Exception) { 0L }
            } else 0L
            val confirmations = tx.optLong("confirmations", 0L)
            val statusCode = if (confirmations > 0L) 1L else 0L
            result.add(
                Messages.TransactionsHistory.Builder()
                    .setTime(epochSec)
                    .setDirection(if (isOutgoing) 0L else 1L)
                    .setStatus(statusCode)
                    .setType(0L)
                    .setValue(valueEth)
                    .setDecimals(18L)
                    .setTxHash(hash)
                    .setFromAddress(fromAddr)
                    .setToAddress(toAddr)
                    .build()
            )
        }
        return result
    }

    /** TRX 交易历史：TronGrid /v1/accounts/{addr}/transactions?limit=25&visible=true */
    fun fetchTrxTxHistory(address: String): List<Messages.TransactionsHistory> {
        val json = httpGet("$TRON_MAIN_API/v1/accounts/$address/transactions?limit=25&only_confirmed=false&visible=true")
        val data = JSONObject(json).optJSONArray("data") ?: JSONArray()
        val result = mutableListOf<Messages.TransactionsHistory>()
        for (i in 0 until data.length()) {
            val tx = data.getJSONObject(i)
            val txId = tx.optString("txID")
            val blockTs = tx.optLong("block_timestamp", 0L) / 1000L // ms → s
            val contracts = tx.optJSONObject("raw_data")?.optJSONArray("contract") ?: continue
            val contract = contracts.optJSONObject(0) ?: continue
            if (contract.optString("type") != "TransferContract") continue
            val paramVal = contract.optJSONObject("parameter")?.optJSONObject("value") ?: continue
            val ownerAddr = paramVal.optString("owner_address")
            val toAddr = paramVal.optString("to_address")
            val amountSun = paramVal.optLong("amount", 0L)
            val isOutgoing = ownerAddr.equals(address, ignoreCase = true)
            val retArr = tx.optJSONArray("ret")
            val contractRet = retArr?.optJSONObject(0)?.optString("contractRet") ?: ""
            val statusCode = if (contractRet == "SUCCESS") 1L else if (contractRet.isNotEmpty()) -1L else 0L
            result.add(
                Messages.TransactionsHistory.Builder()
                    .setTime(blockTs)
                    .setDirection(if (isOutgoing) 0L else 1L)
                    .setStatus(statusCode)
                    .setType(0L)
                    .setValue(amountSun.toDouble() / 1e6)
                    .setDecimals(6L)
                    .setTxHash(txId)
                    .setFromAddress(ownerAddr)
                    .setToAddress(toAddr)
                    .build()
            )
        }
        return result
    }

    /** DOGE 交易历史：BlockCypher /addrs/{addr}/full?limit=25 */
    fun fetchDogeTxHistory(address: String, isTest: Boolean): List<Messages.TransactionsHistory> {
        val json = httpGet("${dogeCypherBase(isTest)}/addrs/$address/full?limit=25")
        val txs = JSONObject(json).optJSONArray("txs") ?: JSONArray()
        val result = mutableListOf<Messages.TransactionsHistory>()
        for (i in 0 until txs.length()) {
            val tx = txs.getJSONObject(i)
            val hash = tx.optString("hash")
            val confirmedStr = tx.optString("confirmed", "")
            val receivedStr = tx.optString("received", "")
            val tsStr = if (confirmedStr.isNotEmpty()) confirmedStr else receivedStr
            val epochSec = try {
                java.time.Instant.parse(tsStr).epochSecond
            } catch (_: Exception) { 0L }
            val isConfirmed = confirmedStr.isNotEmpty()

            val inputs = tx.optJSONArray("inputs") ?: JSONArray()
            val outputs = tx.optJSONArray("outputs") ?: JSONArray()
            val firstInputAddr = inputs.optJSONObject(0)?.optJSONArray("addresses")?.optString(0) ?: ""
            val isOutgoing = firstInputAddr.equals(address, ignoreCase = true)

            var satAmount = 0L
            var toAddr = ""
            for (j in 0 until outputs.length()) {
                val out = outputs.getJSONObject(j)
                val outAddrs = out.optJSONArray("addresses")
                val outAddr = outAddrs?.optString(0) ?: ""
                val outVal = out.optLong("value", 0L)
                if (isOutgoing) {
                    if (!outAddr.equals(address, ignoreCase = true)) {
                        satAmount += outVal
                        if (toAddr.isEmpty()) toAddr = outAddr
                    }
                } else {
                    if (outAddr.equals(address, ignoreCase = true)) satAmount += outVal
                    if (toAddr.isEmpty()) toAddr = outAddr
                }
            }
            result.add(
                Messages.TransactionsHistory.Builder()
                    .setTime(epochSec)
                    .setDirection(if (isOutgoing) 0L else 1L)
                    .setStatus(if (isConfirmed) 1L else 0L)
                    .setType(0L)
                    .setValue(satAmount.toDouble() / 1e8)
                    .setDecimals(8L)
                    .setTxHash(hash)
                    .setFromAddress(firstInputAddr)
                    .setToAddress(toAddr)
                    .build()
            )
        }
        return result
    }

    // MARK: - ERC20 token transaction history

    /**
     * Fetch ERC20 token transfer history via eth_getLogs.
     * Makes two queries (outgoing + incoming) and fetches block timestamps.
     */
    fun fetchErc20TxHistory(
        address: String,
        contractAddress: String,
        rpc: String,
        decimals: Int,
    ): List<Messages.TransactionsHistory> {
        // keccak256("Transfer(address,address,uint256)")
        val transferSig = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
        val addrLower = address.lowercase()
        val paddedAddr = "0x000000000000000000000000" + addrLower.removePrefix("0x")

        // Outgoing transfers (from == address)
        val outLogs = ethGetLogs(rpc, contractAddress, listOf(transferSig, paddedAddr, null))
        // Incoming transfers (to == address)
        val inLogs  = ethGetLogs(rpc, contractAddress, listOf(transferSig, null, paddedAddr))

        // Batch-fetch timestamps for unique block numbers
        val blockNums = mutableSetOf<String>()
        (outLogs + inLogs).forEach { log ->
            val bn = log.optString("blockNumber", "")
            if (bn.isNotEmpty()) blockNums.add(bn)
        }
        val blockTimestamps = mutableMapOf<String, Long>()
        for (bn in blockNums) {
            blockTimestamps[bn] = runCatching { ethGetBlockTimestamp(rpc, bn) }.getOrDefault(0L)
        }

        val divisor = Math.pow(10.0, decimals.toDouble())

        val all = mutableListOf<Pair<JSONObject, Long>>()
        outLogs.forEach { all.add(it to 0L) }
        inLogs.forEach  { all.add(it to 1L) }
        all.sortByDescending { (log, _) -> erc20HexToUInt64(log.optString("blockNumber", "0x0")) }

        return all.map { (log, dir) ->
            val blockHex = log.optString("blockNumber", "")
            val time = blockTimestamps[blockHex] ?: 0L
            val dataHex = log.optString("data", "0x")
            val rawHex  = if (dataHex.startsWith("0x")) dataHex.substring(2) else dataHex
            val txHash  = log.optString("transactionHash", "")
            val topics  = log.optJSONArray("topics")
            val fromPadded = topics?.optString(1) ?: ""
            val toPadded   = topics?.optString(2) ?: ""
            val fromAddr = "0x" + fromPadded.removePrefix("0x").takeLast(40)
            val toAddr   = "0x" + toPadded.removePrefix("0x").takeLast(40)
            val amount   = erc20HexBigIntToDouble(rawHex) / divisor
            Messages.TransactionsHistory.Builder()
                .setTime(time)
                .setDirection(dir)
                .setStatus(1L) // Logs are always from confirmed blocks
                .setType(0L)
                .setValue(amount)
                .setDecimals(decimals.toLong())
                .setTxHash(txHash)
                .setFromAddress(fromAddr)
                .setToAddress(toAddr)
                .build()
        }
    }

    private fun ethGetLogs(rpc: String, contract: String, topics: List<String?>): List<JSONObject> {
        val topicsJson = "[" + topics.joinToString(",") { t ->
            if (t != null) "\"$t\"" else "null"
        } + "]"
        val params = "[{\"address\":\"$contract\",\"fromBlock\":\"earliest\",\"toBlock\":\"latest\",\"topics\":$topicsJson}]"
        val body   = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getLogs\",\"params\":$params,\"id\":1}"
        val resp   = httpPost(rpc, body, "application/json")
        val json   = JSONObject(resp)
        if (json.has("error")) throw IOException(json.getJSONObject("error").optString("message", "eth_getLogs error"))
        val result = json.optJSONArray("result") ?: return emptyList()
        return (0 until result.length()).map { result.getJSONObject(it) }
    }

    private fun ethGetBlockTimestamp(rpc: String, blockHex: String): Long {
        val params = "[\"$blockHex\",false]"
        val body   = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":$params,\"id\":1}"
        val resp   = httpPost(rpc, body, "application/json")
        val block  = JSONObject(resp).optJSONObject("result") ?: return 0L
        return erc20HexToUInt64(block.optString("timestamp", "0x0"))
    }

    /** Parse hex big-integer string to Double (sufficient precision for token display). */
    private fun erc20HexBigIntToDouble(hex: String): Double {
        var value = 0.0
        for (c in hex.lowercase()) {
            val nibble = c.digitToIntOrNull(16) ?: break
            value = value * 16.0 + nibble.toDouble()
        }
        return value
    }

    private fun erc20HexToUInt64(hex: String): Long {
        val clean = if (hex.startsWith("0x")) hex.substring(2) else hex
        return if (clean.isEmpty()) 0L else java.math.BigInteger(clean, 16).toLong()
    }
}
