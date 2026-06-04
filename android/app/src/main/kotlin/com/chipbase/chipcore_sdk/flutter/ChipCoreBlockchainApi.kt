package com.chipcore.sdk.flutter

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import java.math.BigInteger
import java.nio.charset.StandardCharsets
import java.util.Locale
import org.json.JSONObject

class ChipCoreBlockchainApi private constructor(
    private val activity: Activity,
    binaryMessenger: BinaryMessenger,
) : Messages.BlockchainApi {

    /** 与 card_coin 的 CardCoinPlugin.flutterClientApi 对应：Kotlin → Flutter 余额回调 */
    private val flutterClientApi = Messages.FlutterClientApi(binaryMessenger)

    private val repository = CardCurrencyRepository(activity)
    private val sessionManager = AndroidIso7816SessionManager(activity)
    private val state = NativeWalletState(repository)
    /** 对应 card_coin 的 walletState，管理各链 WalletManager 实例 */
    private val walletManagerRegistry = WalletManagerRegistry()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun scanCardWithCommand(
        sendCommandMessage: Messages.SendCommandMessage,
        result: Messages.Result<Messages.CommandResponse>,
    ) {
        val command    = sendCommandMessage.command        // null = 只需建联，不执行额外指令
        val checkLock  = sendCommandMessage.checkLock ?: false
        val checkPwd   = sendCommandMessage.checkPwd  ?: false
        val ndefLink   = sendCommandMessage.ndefLink?.takeIf { it.isNotEmpty() }
        val needSyncUid = sendCommandMessage.needSyscUid ?: false
        // 优先使用调用方指定的 AID，否则使用默认 HD Wallet AID
        val aid = sendCommandMessage.appletId?.takeIf { it.isNotEmpty() } ?: HdWalletApdu.HD_WALLET_AID

        sessionManager.withSession(
            aid,
            { channel ->
                val client = HdWalletCardClient(channel.isoDep, channel.tag.id, channel.aesKey)
                // 参考 Tangem WriteUidCommand 调用顺序：
                // 若需要同步 UID，先于 getStatus 执行，确保 applet 内部 UID 已就绪，
                // 避免 getStatus 返回 SW=AC01 后才补救。
                if (needSyncUid) {
                    try {
                        client.writeUid()
                    } catch (e: Exception) {
                        Log.w("ChipCoreNfc", "writeUid (pre-getStatus) failed (non-fatal): ${e.message}")
                    }
                }
                // 读取卡状态，用于填充 CommandResponse 字段和执行 checkLock/checkPwd 守卫
                val status = client.getStatus()

                // checkLock: 卡片已锁（PIN 耗尽）→ 模拟 card_coin 返回 DeviceLockError
                if (checkLock && status.isLock) {
                    return@withSession Result.failure(
                        Messages.FlutterError(
                            "card-locked",
                            "DeviceLockError:${channel.tag.id.toHex()}",
                            null,
                        )
                    )
                }
                // checkPwd: PIN 已设置且卡片已作废 → 同样拦截
                if (checkPwd && status.isExpired) {
                    return@withSession Result.failure(
                        Messages.FlutterError(
                            "card-expired",
                            "Card has expired. PUK retry limit reached.",
                            null,
                        )
                    )
                }

                // ── UID 一致性校验 ──────────────────────────────────────────────
                val currentCardId = channel.tag.id.toHex()
                if (command != null) {
                    // 1. 调用方明确传入了期望 UID（最高优先级）
                    val expectedId = sendCommandMessage.cardId?.takeIf { it.isNotEmpty() }
                    Log.d("ChipCoreNfc", "UID check: expected=$expectedId current=$currentCardId")
                    if (expectedId != null && !expectedId.equals(currentCardId, ignoreCase = true)) {
                        return@withSession Result.failure(
                            Messages.FlutterError(
                                "uid-mismatch",
                                "Wrong card. Expected $expectedId but scanned $currentCardId.",
                                currentCardId,
                            )
                        )
                    }
                    // 2. 无指定时，回退到缓存 UID 校验
                    if (expectedId == null) {
                        val cachedId = state.lastCardId
                        if (!cachedId.isNullOrEmpty() && !cachedId.equals(currentCardId, ignoreCase = true)) {
                            return@withSession Result.failure(
                                Messages.FlutterError(
                                    "uid-mismatch",
                                    "Wrong card. Expected $cachedId but scanned $currentCardId.",
                                    currentCardId,
                                )
                            )
                        }
                    }
                }

                // ── NDEF 写入（对应 card_coin StoreNdefDataRunnable / INS=0x63）──
                // 直接写入调用方传入的 ndefLink，不做任何拼接
                var ndefWriteResult: String? = null
                if (ndefLink != null) {
                    try {
                        Log.d("ChipCoreNfc", "writeNdef url=$ndefLink")
                        ndefWriteResult = client.writeNdefAndVerify(ndefLink)
                    } catch (e: Exception) {
                        Log.w("ChipCoreNfc", "writeNdef failed (non-fatal): ${e.message}")
                    }
                }

                // ── UID 同步写入已在 getStatus 前完成（Tangem WriteUidCommand 顺序）──

                state.lastCardId = currentCardId

                // ── 执行调用方传入的 APDU 命令（command 为 null 时跳过，仅返回状态）──
                // chipcore 的 send() 会剥离 SW 字节并解密，因此在返回前追加 0x90 0x00，
                // 使 Flutter 侧 CommandResponse.fromData 能正确识别 isSuccess=true
                val responseBytes: ByteArray = if (command != null) {
                    client.sendCommand(command) + byteArrayOf(0x90.toByte(), 0x00.toByte())
                } else if (ndefWriteResult != null) {
                    // command 为 null 但有 NDEF 写入时，将回读的 URL 作为 data 返回，供 Flutter 侧验证
                    ndefWriteResult.toByteArray(StandardCharsets.UTF_8)
                } else {
                    byteArrayOf()
                }

                Result.success(
                    Messages.CommandResponse.Builder()
                        .setCardId(channel.tag.id.toHex())
                        .setAppletVersionCode(status.versionCode ?: "")
                        .setAppletVersion(status.version ?: "")
                        .setIsActivated(status.hasKeyPair)
                        .setResetCount(status.resetCount)
                        .setData(responseBytes)
                        .build(),
                )
            },
            { outcome ->
                outcome.onSuccess(result::success).onFailure(result::error)
            },
        )
    }

    override fun scanCardAndDerive(
        currencyList: List<Messages.CurrencyInfoMessage>,
        ndefLink: String,
        cardId: String?,
        cardNo: String?,
        result: Messages.Result<Messages.CardMessage>,
    ) {
        deriveCard(currencyList, result, generateIfMissing = true, aliasId = cardId)
    }

    override fun createWalletAndDerive(
        currencyList: List<Messages.CurrencyInfoMessage>,
        result: Messages.Result<Messages.CardMessage>,
    ) {
        deriveCard(currencyList, result, generateIfMissing = true)
    }

    override fun loadCurrencyInfoList(
        currencyList: List<Messages.CurrencyInfoMessage>,
        result: Messages.VoidResult,
    ) {
        // Flutter 只传币种描述符（networkId/symbol/isTest），native 从 WalletManagerRegistry 取 address/publicKey
        // 若 WalletManagerRegistry 为空（冷启动），使用 currencyList 中携带的 address 兜底
        result.success()
        // ── 确定本次要查询的条目：优先从 WalletManagerRegistry 取，缺失则从 currencyList 兜底 ──
        data class BalanceTarget(
            val currency: Messages.CurrencyInfoMessage,
            val address: String,
            val spec: BlockchainSpec,
            val isTest: Boolean,
        )
        val targets = mutableListOf<BalanceTarget>()
        for (currency in currencyList) {
            val spec = BlockchainSpec.fromCurrency(currency)
            val isTest = currency.isTest == 1L
            // 优先从 WalletManagerRegistry 取已完整注册的 address（扫卡后由 deriveCard 写入）
            val manager = walletManagerRegistry.getWalletManagerBySpec(spec)
            val address = manager?.address?.takeIf { it.isNotEmpty() }
                ?: currency.address?.takeIf { it.isNotEmpty() }
                ?: continue // 两者都没有，跳过
            targets.add(BalanceTarget(currency, address, spec, isTest))
        }
        for (target in targets) {
            Thread {
                var balance: String? = null
                var fetchError: Exception? = null
                try {
                    val contractAddress = target.currency.contractAddress?.takeIf { it.isNotEmpty() }
                    balance = when {
                        target.spec == BlockchainSpec.Bitcoin ->
                            ChainClient.fetchBtcBalance(target.address, target.isTest)
                        target.spec == BlockchainSpec.Dogecoin ->
                            ChainClient.fetchDogeBalance(target.address, target.isTest)
                        target.spec == BlockchainSpec.Tron && contractAddress != null -> {
                            val decimals = (target.currency.decimalCount ?: 18L).toInt()
                            ChainClient.fetchTRC20Balance(target.address, contractAddress, target.isTest, decimals)
                        }
                        target.spec == BlockchainSpec.Tron ->
                            ChainClient.fetchTrxBalance(target.address)
                        contractAddress != null -> {
                            val rpc = ChainClient.evmRpc(target.currency.networkId, target.isTest)
                            val decimals = (target.currency.decimalCount ?: 18L).toInt()
                            ChainClient.fetchERC20Balance(target.address, contractAddress, rpc, decimals)
                        }
                        else -> {
                            val rpc = ChainClient.evmRpc(target.currency.networkId, target.isTest)
                            ChainClient.fetchEthBalance(target.address, rpc)
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Balance fetch failed for ${target.spec.id}: ${e.message}")
                    fetchError = e
                }
                val c = target.currency
                val updatedCurrency = Messages.CurrencyInfoMessage.Builder()
                    .setId(c.id)
                    .setIcon(c.icon ?: "")
                    .setName(c.name)
                    .setNetworkId(c.networkId)
                    .setNetworkName(c.networkName)
                    .setNetworkIcon(c.networkIcon ?: "")
                    .setSymbol(c.symbol)
                    .setContractAddress(c.contractAddress)
                    .setDecimalCount(c.decimalCount)
                    .setAmount(balance ?: if (fetchError != null) "--" else null)
                    .setAddress(target.address)
                    .setIsTest(c.isTest)
                    .build()
                val responseBuilder = Messages.BalanceResponse.Builder().setData(updatedCurrency)
                if (fetchError != null) {
                    val blockchainError = Messages.BlockchainErrorMessage.Builder()
                        .setCode(0L)
                        .setCustomMessage(fetchError!!.message ?: "Balance fetch failed")
                        .build()
                    responseBuilder.setErrorMessage(blockchainError)
                }
                val balanceResponse = responseBuilder.build()
                mainHandler.post {
                    flutterClientApi.updateCurrencyInfo(
                        listOf(balanceResponse),
                        object : Messages.Result<Boolean> {
                            override fun success(result: Boolean) {}
                            override fun error(error: Throwable) {
                                Log.w(TAG, "updateCurrencyInfo callback error: ${error.message}")
                            }
                        },
                    )
                }
            }.start()
        }
    }

    /**
     * 构造携带余额的 CurrencyInfoMessage，与 BlockchainMethods.buildBlockchainCurrencyInfo 对应。
     * balance 来自 ChipWalletManager.balance（update() 后写入）。
     */
    private fun buildCurrencyWithBalance(
        currency: Messages.CurrencyInfoMessage,
        manager: ChipWalletManager,
        @Suppress("UNUSED_PARAMETER") errorMsg: String?,
    ): Messages.CurrencyInfoMessage {
        return Messages.CurrencyInfoMessage.Builder()
            .setId(currency.id)
            .setIcon(currency.icon ?: "")
            .setName(currency.name)
            .setNetworkId(currency.networkId)
            .setNetworkName(currency.networkName)
            .setNetworkIcon(currency.networkIcon ?: "")
            .setSymbol(currency.symbol)
            .setContractAddress(currency.contractAddress)
            .setDecimalCount(currency.decimalCount)
            .setAmount(manager.balance) // 余额写入 amount 字段
            .setAddress(manager.address)
            .setPublicKey(currency.publicKey)
            .setChainCode(currency.chainCode)
            .setIsTest(currency.isTest)
            .build()
    }

    override fun initScanResponse(uuid: String): Boolean {
        val uuidLower = uuid.lowercase()
        // 注意：不能用 state.lastCardId == uuid 作早返回，因为 scanCardWithCommand(scanOnly) 也会
        // 设置 state.lastCardId，但不重建 walletManagerRegistry。若在 scanOnly 后直接早返回，
        // registry 仍然保存着上一张卡的地址，导致余额全为 0。
        // 先用原始值查，再用小写查（老 SDK 用大写 toHexString，chipcore 用小写 toHex）
        val stored = repository.load(uuid).ifEmpty { repository.load(uuidLower) }
        if (stored.isNotEmpty()) {
            state.lastCardId = uuid
            state.replaceCurrencies(stored)
            walletManagerRegistry.clearWalletManagers()
            walletManagerRegistry.addWalletManagers(walletManagerRegistry.buildFrom(stored))
            Log.d(TAG, "initScanResponse: restored ${stored.size} currencies for card $uuid")
            return true
        }
        return false
    }

    override fun addCurrencyList(
        currencyList: List<Messages.CurrencyInfoMessage>,
        result: Messages.Result<Boolean>,
    ) {
        // 过滤出需要重新派生的币种：
        //   1. 尚未有地址（首次添加）
        //   2. 存储中的 isTest 与传入的 isTest 不一致（切换主网/测试网）
        val newCurrencies = currencyList.filter { incoming ->
            val existing = state.findById(incoming.id)
            existing?.address.isNullOrEmpty() || existing?.isTest != incoming.isTest
        }
        if (newCurrencies.isEmpty()) {
            // 全部已派生，直接合并内存并持久化，不需要靠卡
            state.mergeCurrencies(currencyList)
            state.lastCardId?.let { repository.save(it, state.allCurrencies()) }
            // 更新 WalletManager 实例
            walletManagerRegistry.addWalletManagers(walletManagerRegistry.buildFrom(currencyList))
            Log.d(TAG, "addCurrencyList: all ${currencyList.size} currencies already derived, skip NFC")
            result.success(true)
            return
        }
        Log.d(TAG, "addCurrencyList: ${newCurrencies.size} new currencies need NFC derivation")
        sessionManager.withSession(
            HdWalletApdu.HD_WALLET_AID,
            { channel ->
                val client = HdWalletCardClient(channel.isoDep, channel.tag.id, channel.aesKey)
                val derivedCurrencies = ensureKeyAndDerive(client, newCurrencies, generateIfMissing = false).currencies
                state.mergeCurrencies(derivedCurrencies)
                val cardId = channel.tag.id.toHex()
                state.lastCardId = cardId
                repository.save(cardId, state.allCurrencies())
                // 新派生的币种加入 WalletManager
                walletManagerRegistry.addWalletManagers(walletManagerRegistry.buildFrom(derivedCurrencies))
                Result.success(true)
            },
            { outcome ->
                outcome.onSuccess(result::success).onFailure(result::error)
            },
        )
    }

    override fun getFee(
        feeMessage: Messages.FeeMessage,
        result: Messages.Result<List<Messages.FeeResponse>>,
    ) {
        val isTest = feeMessage.isTest == "true" || feeMessage.isTest == "1"
        val blockchain = feeMessage.blockchain
        // 与 card_coin 一致：优先通过 WalletManager 获取手续费；未命中则直接查链
        val manager = walletManagerRegistry.getWalletManager(blockchain)
        Thread {
            try {
                val isToken = feeMessage.currencyType.lowercase() == "token" || feeMessage.currencyType == "1"
                val fees = manager?.getFees() ?: when {
                    BlockchainSpec.Bitcoin.matches(blockchain)   -> ChainClient.fetchBtcFees(isTest)
                    BlockchainSpec.Tron.matches(blockchain)      -> ChainClient.fetchTrxFees()
                    BlockchainSpec.Dogecoin.matches(blockchain)  -> ChainClient.fetchDogeFees(isTest)
                    isToken -> {
                        // 按 symbol 路由，避免 RTAP/RTBP 后端配置错误走到主网
                        val rpc = ChainClient.evmRpcBySymbol(blockchain, feeMessage.symbol, isTest)
                        val contractAddr = state.findContractAddress(feeMessage.symbol, blockchain) ?: ""
                        val fromAddr = manager?.address ?: state.findAddress(blockchain) ?: ""
                        ChainClient.fetchEVMTokenFees(rpc, contractAddr, fromAddr, feeMessage.receiverAddress)
                    }
                    else -> ChainClient.fetchEVMNativeFees(ChainClient.evmRpc(blockchain, isTest))
                }
                mainHandler.post { result.success(fees) }
            } catch (e: Exception) {
                mainHandler.post { result.error(flutterError("fee-error", e.message ?: "Fee fetch failed")) }
            }
        }.start()
    }

    override fun sendTransaction(
        sendMessage: Messages.SendMessage,
        result: Messages.Result<Messages.SendTransactionResponse>,
    ) {
        if (state.lastPinSet) {
            sessionManager.showPinInputDialog { pinCode ->
                if (pinCode == null) {
                    // 用户取消 PIN 输入时重置缓存，避免下次提现仍预弹 PIN 框
                    state.lastPinSet = false
                    mainHandler.post { result.error(flutterError("pin-cancelled", "PIN input cancelled")) }
                    return@showPinInputDialog
                }
                dispatchSendTransaction(sendMessage, result, pinCode)
            }
        } else {
            dispatchSendTransaction(sendMessage, result, null)
        }
    }

    private fun dispatchSendTransaction(
        sendMessage: Messages.SendMessage,
        result: Messages.Result<Messages.SendTransactionResponse>,
        pinCode: ByteArray?,
    ) {
        val blockchainId = sendMessage.blockchainId
        when {
            BlockchainSpec.Bitcoin.matches(blockchainId)  -> sendBtcTransaction(sendMessage, result, pinCode)
            BlockchainSpec.Tron.matches(blockchainId)     -> sendTrxTransaction(sendMessage, result, pinCode)
            BlockchainSpec.Dogecoin.matches(blockchainId) -> sendDogeTransaction(sendMessage, result, pinCode)
            else                                          -> sendEthTransaction(sendMessage, result, pinCode)
        }
    }

    private fun sendEthTransaction(
        msg: Messages.SendMessage,
        result: Messages.Result<Messages.SendTransactionResponse>,
        pinCode: ByteArray? = null,
    ) {
        val isTest = msg.isTest == "true" || msg.isTest == "1"
        val isToken = msg.currencyType.lowercase() == "token" || msg.currencyType == "1"
        val to = msg.receiverAddress
        val from = msg.walletAddress
        Thread {
            try {
                // 按 symbol 路由：RTAP/RTBP 后端可能返回 testnet=false 但实际在 Sepolia
                val rpc = ChainClient.evmRpcBySymbol(msg.blockchainId, msg.symbol ?: "", isTest)
                android.util.Log.d("ChipCoreNfc", "[sendEth] symbol=${msg.symbol} blockchainId=${msg.blockchainId} isTest=$isTest isToken=$isToken → rpc=$rpc")
                val nonce = ChainClient.ethNonce(rpc, from)
                val gasPrice = msg.gasPrice?.let { hex ->
                    if (hex.startsWith("0x", ignoreCase = true)) BigInteger(hex.removePrefix("0x"), 16)
                    else BigInteger(hex)
                } ?: ChainClient.ethGasPrice(rpc)
                val chainId = ChainClient.ethChainId(rpc)

                // ERC20 token 发送：to=contract, value=0, data=transfer(receiver, amount)
                val txTo: String
                val txValue: BigInteger
                val txData: ByteArray
                val txGasLimit: BigInteger
                if (isToken) {
                    val contractAddress = msg.contractAddress?.takeIf { it.isNotEmpty() }
                        ?: state.findContractAddress(msg.symbol ?: "", msg.blockchainId) ?: to
                    val decimals = state.findDecimals(msg.symbol ?: "", msg.blockchainId)
                    android.util.Log.d("ChipCoreNfc", "[sendEth] isToken=true symbol=${msg.symbol} blockchainId=${msg.blockchainId} contractAddress=$contractAddress decimals=$decimals allCurrencyNetworkIds=${state.allCurrencies().map { "${it.symbol}/${it.networkId}/${it.contractAddress}" }}")
                    val amountRaw = EthEncoder.parseTokenAmount(msg.sumToSend, decimals)
                    txTo = contractAddress
                    txValue = BigInteger.ZERO
                    txData = EthEncoder.encodeERC20Transfer(to, amountRaw)
                    txGasLimit = msg.gasLimit?.let { if (it.startsWith("0x", ignoreCase = true)) BigInteger(it.removePrefix("0x"), 16) else BigInteger(it) } ?: BigInteger.valueOf(80000)
                } else {
                    txTo = to
                    txValue = EthEncoder.parseEthValue(msg.sumToSend)
                    txData = ByteArray(0)
                    txGasLimit = msg.gasLimit?.let { if (it.startsWith("0x", ignoreCase = true)) BigInteger(it.removePrefix("0x"), 16) else BigInteger(it) } ?: BigInteger.valueOf(100000)
                }

                val signingHash = EthEncoder.buildLegacyTxHash(nonce, gasPrice, txGasLimit, txTo, txValue, txData, chainId)

                sessionManager.withSession(
                    HdWalletApdu.HD_WALLET_AID,
                    { channel ->
                        val client = HdWalletCardClient(channel.isoDep, channel.tag.id, channel.aesKey)
                        val spec = BlockchainSpec.fromIdentifier(msg.blockchainId)
                        val pubKeyBytes = state.findPublicKeyHex(msg.blockchainId)
                            ?.hexToByteArrayOrNull()
                            ?: state.findPublicKeyHex("eth")?.hexToByteArrayOrNull()
                            ?: client.deriveKey(spec.defaultPath()).publicKey
                        val sigBytes = client.sign(spec.defaultPath(), signingHash, pinCode)
                        val (r, s, recId) = EthEncoder.parseAndRecoverSignature(sigBytes, signingHash, pubKeyBytes)
                        val v = chainId * BigInteger.valueOf(2) + BigInteger.valueOf(35) + BigInteger.valueOf(recId.toLong())
                        val rawTx = EthEncoder.encodeLegacySignedTx(nonce, gasPrice, txGasLimit, txTo, txValue, txData, v, r, s)
                        Result.success(rawTx)
                    },
                    { outcome ->
                        outcome.onSuccess { rawTx ->
                            Thread {
                                try {
                                    val txHash = ChainClient.ethBroadcast(rawTx, rpc)
                                    mainHandler.post {
                                        result.success(
                                            Messages.SendTransactionResponse.Builder()
                                                .setIsSuccess(true)
                                                .setErrorMsg(txHash)
                                                .build(),
                                        )
                                    }
                                } catch (e: Exception) {
                                    mainHandler.post {
                                        result.error(flutterError("broadcast-error", e.message ?: "Broadcast failed"))
                                    }
                                }
                            }.start()
                        }.onFailure { e ->
                            handlePinRequired(
                                e,
                                onRetry = { pin -> sendEthTransaction(msg, result, pin) },
                                onError = { result.error(it) },
                            )
                        }
                    },
                )
            } catch (e: Exception) {
                mainHandler.post { result.error(flutterError("eth-prepare-error", e.message ?: "Transaction preparation failed")) }
            }
        }.start()
    }

    private fun sendBtcTransaction(
        msg: Messages.SendMessage,
        result: Messages.Result<Messages.SendTransactionResponse>,
        pinCode: ByteArray? = null,
    ) {
        val isTest = msg.isTest == "true" || msg.isTest == "1"
        val from = msg.walletAddress
        val to = msg.receiverAddress
        Thread {
            try {
                val utxos = ChainClient.fetchBtcUtxos(from, isTest)
                if (utxos.isEmpty()) {
                    mainHandler.post { result.error(flutterError("no-utxo", "该地址无可用 UTXO")) }
                    return@Thread
                }
                val feeRateSat = msg.gasPrice?.toLongOrNull() ?: ChainClient.fetchBtcFeeRate(isTest)
                val valueStr = msg.sumToSend
                val valueSat = BtcEncoder.parseAmount(valueStr)
                val (selectedUtxos, changeSat) = BtcEncoder.selectUtxos(utxos, valueSat, to, from, feeRateSat)
                val outputsToSign = buildList {
                    add(BtcEncoder.BtcOutput(to, valueSat))
                    if (changeSat > 546L) add(BtcEncoder.BtcOutput(from, changeSat))
                }

                sessionManager.withSession(
                    HdWalletApdu.HD_WALLET_AID,
                    { channel ->
                        val client = HdWalletCardClient(channel.isoDep, channel.tag.id, channel.aesKey)
                        val spec = BlockchainSpec.Bitcoin
                        val derivedKey = client.deriveKey(spec.defaultPath())
                        val pubKey = derivedKey.publicKey.compressSecp256k1()
                        val witnesses = mutableListOf<List<ByteArray>>()
                        for ((index, utxo) in selectedUtxos.withIndex()) {
                            val scriptCode = BtcEncoder.p2wpkhScriptCode(pubKey)
                            val sigHash = BtcEncoder.buildSegwitSigHash(selectedUtxos, outputsToSign, index, scriptCode, utxo.value)
                            val derSig = client.sign(spec.defaultPath(), sigHash, pinCode)
                            val normalizedDer = BtcEncoder.normalizeSignatureDer(derSig)
                            val sigWithHashType = normalizedDer + byteArrayOf(0x01) // SIGHASH_ALL
                            witnesses.add(listOf(sigWithHashType, pubKey))
                        }
                        val rawTx = BtcEncoder.encodeSegwitTx(selectedUtxos, outputsToSign, witnesses)
                        Result.success(rawTx)
                    },
                    { outcome ->
                        outcome.onSuccess { rawTx ->
                            Thread {
                                try {
                                    val txId = ChainClient.btcBroadcast(rawTx, isTest)
                                    mainHandler.post {
                                        result.success(
                                            Messages.SendTransactionResponse.Builder()
                                                .setIsSuccess(true)
                                                .setErrorMsg(txId)
                                                .build(),
                                        )
                                    }
                                } catch (e: Exception) {
                                    mainHandler.post {
                                        result.error(flutterError("broadcast-error", e.message ?: "BTC broadcast failed"))
                                    }
                                }
                            }.start()
                        }.onFailure { e ->
                            handlePinRequired(
                                e,
                                onRetry = { pin -> sendBtcTransaction(msg, result, pin) },
                                onError = { result.error(it) },
                            )
                        }
                    },
                )
            } catch (e: Exception) {
                mainHandler.post { result.error(flutterError("btc-prepare-error", e.message ?: "BTC transaction preparation failed")) }
            }
        }.start()
    }

    // ── TRX 交易（使用 TronGrid API + 卡片 ECDSA 签名）────────────────────────
    private fun sendTrxTransaction(
        msg: Messages.SendMessage,
        result: Messages.Result<Messages.SendTransactionResponse>,
        pinCode: ByteArray? = null,
    ) {
        val from = msg.walletAddress
        val to = msg.receiverAddress
        Thread {
            try {
                // 1. 将发送金额转换为 SUN（1 TRX = 1,000,000 SUN）
                val amountTrx = msg.sumToSend.toBigDecimalOrNull()
                    ?: throw Messages.FlutterError("invalid-amount", "Invalid TRX amount format", null)
                val amountSun = amountTrx.multiply(java.math.BigDecimal("1000000")).toLong()
                // 2. 调用 TronGrid 创建交易（visible=true 告知 API 地址为 Base58Check 格式）
                val createTxBody = """{"owner_address":"$from","to_address":"$to","amount":$amountSun,"visible":true}"""
                val createTxResp = ChainClient.trxPost("https://api.trongrid.io/wallet/createtransaction", createTxBody)
                val createTxJson = JSONObject(createTxResp)
                if (!createTxJson.has("txID")) {
                    throw Messages.FlutterError("trx-create-error", "Failed to create TRX transaction: $createTxResp", null)
                }
                val txIdHex = createTxJson.getString("txID")
                val txIdBytes = txIdHex.hexToByteArrayOrNull()
                    ?: throw Messages.FlutterError("trx-txid-error", "Failed to parse TRX txID", null)

                sessionManager.withSession(
                    HdWalletApdu.HD_WALLET_AID,
                    { channel ->
                        val client = HdWalletCardClient(channel.isoDep, channel.tag.id, channel.aesKey)
                        val spec = BlockchainSpec.Tron
                        // 3. 获取公钥（注册表 → state → NFC 派生），用于签名恢复 v 字节
                        val rawPubKey = walletManagerRegistry.getWalletManagerBySpec(BlockchainSpec.Tron)?.publicKey
                            ?: state.findPublicKeyHex("trx")?.hexToByteArrayOrNull()
                            ?: client.deriveKey(spec.defaultPath()).publicKey
                        val uncompressedPub = rawPubKey.decompressToEthBytes()
                        // 4. 用卡片对 txID（32 字节）签名
                        val derSig = client.sign(spec.defaultPath(), txIdBytes, pinCode)
                        // 5. DER → r+s+v（65 字节）供 Tron 使用
                        val sig65 = TrxEncoder.derToTrxSignature(derSig, txIdBytes, uncompressedPub)
                        Result.success(sig65)
                    },
                    { outcome ->
                        outcome.onSuccess { sig65 ->
                            Thread {
                                try {
                                    // 6. 组装广播请求（把签名注入原交易 JSON）
                                    createTxJson.put("signature", org.json.JSONArray().apply { put(sig65.toHex()) })
                                    val broadcastResp = ChainClient.trxPost(
                                        "https://api.trongrid.io/wallet/broadcasttransaction",
                                        createTxJson.toString(),
                                    )
                                    val broadcastJson = JSONObject(broadcastResp)
                                    val success = broadcastJson.optBoolean("result", false)
                                    if (success) {
                                        mainHandler.post {
                                            result.success(
                                                Messages.SendTransactionResponse.Builder()
                                                    .setIsSuccess(true)
                                                    .setErrorMsg(txIdHex)
                                                    .build(),
                                            )
                                        }
                                    } else {
                                        val msg2 = broadcastJson.optString("message", broadcastResp)
                                        mainHandler.post {
                                            result.error(flutterError("trx-broadcast-error", "TRX broadcast failed: $msg2"))
                                        }
                                    }
                                } catch (e: Exception) {
                                    mainHandler.post { result.error(flutterError("trx-broadcast-error", e.message ?: "TRX 广播失败")) }
                                }
                            }.start()
                        }.onFailure { e ->
                            handlePinRequired(
                                e,
                                onRetry = { pin -> sendTrxTransaction(msg, result, pin) },
                                onError = { result.error(it) },
                            )
                        }
                    },
                )
            } catch (e: Exception) {
                mainHandler.post { result.error(flutterError("trx-prepare-error", e.message ?: "TRX transaction preparation failed")) }
            }
        }.start()
    }

    // ── DOGE 交易（P2PKH 遗留格式，类 BTC）──────────────────────────────────
    private fun sendDogeTransaction(
        msg: Messages.SendMessage,
        result: Messages.Result<Messages.SendTransactionResponse>,
        pinCode: ByteArray? = null,
    ) {
        val isTest = msg.isTest == "true" || msg.isTest == "1"
        val from = msg.walletAddress
        val to = msg.receiverAddress
        Thread {
            try {
                val utxos = ChainClient.fetchDogeUtxos(from, isTest)
                android.util.Log.d("ChipCoreApi", "[DOGE tx] utxos=${utxos.size} totalSat=${utxos.sumOf { it.value }} sumToSend=${msg.sumToSend} gasPrice=${msg.gasPrice}")
                if (utxos.isEmpty()) {
                    mainHandler.post { result.error(flutterError("no-utxo", "该 DOGE 地址无可用 UTXO")) }
                    return@Thread
                }
                // DOGE 手续费：gasPrice = sat/byte（来自 fetchDogeFees），默认 1000 sat/byte（约 0.226 DOGE/tx）
                val feeRateSat = msg.gasPrice?.toLongOrNull() ?: 1000L
                val valueSat = DogeEncoder.parseAmount(msg.sumToSend)
                android.util.Log.d("ChipCoreApi", "[DOGE tx] valueSat=$valueSat feeRateSat=$feeRateSat")
                val (selectedUtxos, changeSat) = DogeEncoder.selectUtxos(utxos, valueSat, feeRateSat)
                val outputs = buildList {
                    add(DogeEncoder.DogeOutput(to, valueSat))
                    if (changeSat > 100_000L) add(DogeEncoder.DogeOutput(from, changeSat))
                }

                sessionManager.withSession(
                    HdWalletApdu.HD_WALLET_AID,
                    { channel ->
                        val client = HdWalletCardClient(channel.isoDep, channel.tag.id, channel.aesKey)
                        val spec = BlockchainSpec.Dogecoin
                        val derivedKey = client.deriveKey(spec.defaultPath())
                        val pubKey = derivedKey.publicKey.compressSecp256k1()
                        val signatures = mutableListOf<ByteArray>()
                        for ((index, _) in selectedUtxos.withIndex()) {
                            val sigHash = DogeEncoder.buildP2pkhSigHash(selectedUtxos, outputs, index, pubKey)
                            android.util.Log.d("ChipCoreApi", "[DOGE sig] sigHash[$index]=${sigHash.joinToString("") { "%02x".format(it) }}")
                            val derSig = client.sign(spec.defaultPath(), sigHash, pinCode)
                            android.util.Log.d("ChipCoreApi", "[DOGE sig] rawSig[$index](${derSig.size}B)=${derSig.joinToString("") { "%02x".format(it) }}")
                            val normalizedDer = BtcEncoder.normalizeSignatureDer(derSig)
                            android.util.Log.d("ChipCoreApi", "[DOGE sig] normalizedDer[$index](${normalizedDer.size}B)=${normalizedDer.joinToString("") { "%02x".format(it) }}")
                            signatures.add(normalizedDer + byteArrayOf(0x01)) // SIGHASH_ALL
                        }
                        android.util.Log.d("ChipCoreApi", "[DOGE sig] pubKey(${pubKey.size}B)=${pubKey.joinToString("") { "%02x".format(it) }}")
                        val rawTx = DogeEncoder.encodeP2pkhTx(selectedUtxos, outputs, signatures, pubKey)
                        Result.success(rawTx)
                    },
                    { outcome ->
                        outcome.onSuccess { rawTx ->
                            Thread {
                                try {
                                    val txId = ChainClient.dogeBroadcast(rawTx, isTest)
                                    mainHandler.post {
                                        result.success(
                                            Messages.SendTransactionResponse.Builder()
                                                .setIsSuccess(true)
                                                .setErrorMsg(txId)
                                                .build(),
                                        )
                                    }
                                } catch (e: Exception) {
                                    mainHandler.post { result.error(flutterError("broadcast-error", e.message ?: "DOGE broadcast failed")) }
                                }
                            }.start()
                        }.onFailure { e ->
                            handlePinRequired(
                                e,
                                onRetry = { pin -> sendDogeTransaction(msg, result, pin) },
                                onError = { result.error(it) },
                            )
                        }
                    },
                )
            } catch (e: Exception) {
                mainHandler.post { result.error(flutterError("doge-prepare-error", e.message ?: "DOGE transaction preparation failed")) }
            }
        }.start()
    }

    override fun validateAddress(validateMessage: Messages.ValidateAddressMessage): Boolean {
        val blockchain = validateMessage.blockchain.lowercase(Locale.US)
        val address = validateMessage.address.trim()
        return when {
            blockchain.contains("eth") || blockchain.contains("evm")       -> ETH_ADDRESS_REGEX.matches(address)
            blockchain.contains("btc") || blockchain.contains("bitcoin")   -> BTC_ADDRESS_REGEX.matches(address)
            blockchain.contains("trx") || blockchain.contains("tron")      -> validateTrxAddress(address)
            blockchain.contains("doge") || blockchain.contains("dogecoin") -> validateDogeAddress(address)
            else -> false
        }
    }

    /** TRX: Base58Check 解码后必须是 21 字节且首字节 = 0x41 */
    private fun validateTrxAddress(address: String): Boolean = try {
        val decoded = Base58Check.decode(address)
        decoded.size == 21 && decoded[0] == 0x41.toByte()
    } catch (e: Exception) { false }

    /** DOGE: Base58Check 解码后必须是 21 字节
     *  首字节：0x1E = 主网 P2PKH(D...)，0x16 = 主网 P2SH(A...)，0x71 = 测试网(m/n...) */
    private fun validateDogeAddress(address: String): Boolean = try {
        val decoded = Base58Check.decode(address)
        decoded.size == 21 && decoded[0] in byteArrayOf(0x1E.toByte(), 0x16.toByte(), 0x71.toByte())
    } catch (e: Exception) { false }

    override fun clearLocalCurrency(cardId: String, coinIds: List<String>) {
        if (state.lastCardId == cardId) {
            state.removeCurrencies(coinIds)
        }
    }

    override fun loadTransactionHistoryList(
        request: Messages.TransactionHistoryRequest,
        result: Messages.Result<List<Messages.TransactionsHistory>>,
    ) {
        val address = request.address.ifEmpty { return result.error(notImplementedError("地址为空")) }
        val symbol = request.currencyInfo.symbol.uppercase()
        val isTest = (request.currencyInfo.isTest ?: 0L) != 0L
        Thread {
            try {
                val history: List<Messages.TransactionsHistory> = when (symbol) {
                    "BTC"  -> ChainClient.fetchBtcTxHistory(address, isTest)
                    "ETH"  -> ChainClient.fetchEthTxHistory(address, isTest)
                    "TRX"  -> ChainClient.fetchTrxTxHistory(address)
                    "DOGE" -> ChainClient.fetchDogeTxHistory(address, isTest)
                    else   -> {
                        val contractAddr = request.currencyInfo.contractAddress ?: ""
                        if (contractAddr.isNotEmpty()) {
                            val rpc = ChainClient.evmRpcBySymbol(
                                networkId = request.currencyInfo.networkId,
                                symbol = symbol, isTest = isTest)
                            val decimals = (request.currencyInfo.decimalCount ?: 18L).toInt()
                            ChainClient.fetchErc20TxHistory(address, contractAddr, rpc, decimals)
                        } else {
                            emptyList()
                        }
                    }
                }
                mainHandler.post { result.success(history) }
            } catch (e: Exception) {
                mainHandler.post { result.error(flutterError("tx-history-error", e.message ?: "Query failed")) }
            }
        }.start()
    }

    override fun changeWallet(
        cardId: String,
        currencyList: List<Messages.CurrencyInfoMessage>,
        result: Messages.Result<Boolean>,
    ) {
        state.lastCardId = cardId
        state.replaceCurrencies(currencyList)
        // 与 card_coin 的 changeWallet 一致：切换卡片时重建 WalletManager
        walletManagerRegistry.clearWalletManagers()
        walletManagerRegistry.addWalletManagers(walletManagerRegistry.buildFrom(currencyList))
        result.success(true)
    }

    override fun postCatchedException(error: String, result: Messages.VoidResult) {
        Log.e(TAG, error)
        result.success()
    }

    override fun signLightning(signText: String, isBtc: Boolean, result: Messages.Result<String>) {
        signDigest(
            blockchainId = if (isBtc) "btc" else "eth",
            payload = signText,
            result = result,
        )
    }

    override fun createChainKeys(blockchains: List<String>, result: Messages.Result<Messages.ChainKeyInfo>) {
        sessionManager.withSession(
            HdWalletApdu.HD_WALLET_AID,
            { channel ->
                val client = HdWalletCardClient(channel.isoDep, channel.tag.id, channel.aesKey)
                val entries = blockchains.map { blockchainId ->
                    val spec = BlockchainSpec.fromIdentifier(blockchainId)
                    val derived = client.deriveKey(spec.defaultPath())
                    Messages.ChainKeyMessage.Builder()
                        .setBlockchainId(blockchainId)
                        .setChainId(null)
                        .setPrivateKey("")
                        .setPublicKey(derived.publicKey.toHex())
                        .setAddress(spec.makeAddress(derived.publicKey, isTest = false))
                        .build()
                }
                Result.success(
                    Messages.ChainKeyInfo.Builder()
                        .setCardId(channel.tag.id.toHex())
                        .setChainKeys(entries)
                        .build(),
                )
            },
            { outcome ->
                outcome.onSuccess(result::success).onFailure(result::error)
            },
        )
    }

    override fun getChainKeys(
        cardId: String,
        blockchains: List<String>,
        result: Messages.Result<List<Messages.ChainKeyMessage>>,
    ) {
        val entries = blockchains.mapNotNull { blockchainId ->
            val spec = BlockchainSpec.fromIdentifier(blockchainId)
            val currency = state.findBySpec(spec) ?: return@mapNotNull null
            Messages.ChainKeyMessage.Builder()
                .setBlockchainId(blockchainId)
                .setChainId(null)
                .setPrivateKey("")
                .setPublicKey(currency.publicKey?.toHex().orEmpty())
                .setAddress(currency.address.orEmpty())
                .build()
        }
        result.success(entries)
    }

    override fun signText(
        blockchainId: String,
        text: String,
        chainId: Long?,
        result: Messages.Result<String>,
    ) {
        signDigest(blockchainId, text, result)
    }

    override fun signTransaction(
        blockchainId: String,
        text: String,
        chainId: Long?,
        result: Messages.Result<String>,
    ) {
        signDigest(blockchainId, text, result)
    }

    override fun generateKey(result: Messages.Result<String>) {
        sessionManager.withSession(
            HdWalletApdu.HD_WALLET_AID,
            { channel ->
                val client = HdWalletCardClient(channel.isoDep, channel.tag.id, channel.aesKey)
                val generated = client.generateKeyPair()
                state.cacheMasterKey(channel.tag.id.toHex(), generated.publicKey, generated.chainCode)
                Result.success(generated.publicKey.toHex())
            },
            { outcome ->
                outcome.onSuccess(result::success).onFailure(result::error)
            },
        )
    }

    override fun signChallenge(challenge: String, result: Messages.Result<String>) {
        // 与 signText 一致：对挑战字符串用 ETH 路径签名
        signDigest(blockchainId = "eth", payload = challenge, result = result)
    }

    override fun getBitcoinPublicKey(): String =
        walletManagerRegistry.getWalletManagerBySpec(BlockchainSpec.Bitcoin)?.publicKey?.toHex()
            ?: state.findPublicKeyHex("btc")
            ?: throw notImplementedError("BTC public key not available. Please run scanCardAndDerive or addCurrencyList first.")

    override fun resetNfcReaderMode() {
        sessionManager.reset()
    }

    override fun getEthPublicKey(): String =
        walletManagerRegistry.getWalletManagerBySpec(BlockchainSpec.Ethereum)?.publicKey?.toHex()
            ?: state.findPublicKeyHex("eth")
            ?: throw notImplementedError("ETH public key not available. Please run scanCardAndDerive or addCurrencyList first.")

    override fun makeAddresses(
        networkId: String,
        isBtc: Boolean,
        result: Messages.Result<String>,
    ) {
        val address = state.findAddress(networkId)
        if (address != null) {
            result.success(address)
            return
        }
        val spec = if (isBtc) BlockchainSpec.Bitcoin else BlockchainSpec.Ethereum
        // 与 card_coin 一致：优先从 WalletManager 获取地址
        val manager = walletManagerRegistry.getWalletManagerBySpec(spec)
        if (manager != null) {
            result.success(manager.address)
            return
        }
        val currency = state.findBySpec(spec)
        val publicKey = currency?.publicKey
        if (publicKey != null) {
            val addressFromKey = spec.makeAddress(publicKey, currency.isTest == 1L)
            state.updateAddress(networkId, addressFromKey)
            result.success(addressFromKey)
            return
        }
        result.error(notImplementedError("尚未拿到对应链的公钥。请先执行 scanCardAndDerive 或 addCurrencyList。"))
    }

    override fun bindNetwork() = Unit

    override fun isVpnActive(): Boolean = false

    override fun isDualSim(): Boolean = false

    private fun deriveCard(
        currencyList: List<Messages.CurrencyInfoMessage>,
        result: Messages.Result<Messages.CardMessage>,
        generateIfMissing: Boolean,
        aliasId: String? = null,
    ) {
        Log.d(TAG, "deriveCard: received ${currencyList.size} currencies from Flutter: ${currencyList.map { "${it.id}/${it.symbol}" }}")
        sessionManager.withSession(
            HdWalletApdu.HD_WALLET_AID,
            { channel ->
                val client = HdWalletCardClient(channel.isoDep, channel.tag.id, channel.aesKey)
                val cardId = channel.tag.id.toHex()
                // 若调用方传入了期望的卡片 UID（aliasId），校验是否与实际刷到的卡一致
                if (!aliasId.isNullOrEmpty() && aliasId.lowercase() != cardId.lowercase()) {
                    Log.w(TAG, "deriveCard: uid-mismatch expected=$aliasId actual=$cardId")
                    return@withSession Result.failure(
                        Messages.FlutterError(
                            "uid-mismatch",
                            "Wrong card. Expected $aliasId but scanned $cardId.",
                            cardId,
                        )
                    )
                }
                // 与 card_coin 一致：优先加载本卡已存储的币种，传入的 currencyList 作为首次默认值
                val storedCurrencies = repository.load(cardId)
                val mergedList = if (storedCurrencies.isEmpty()) {
                    Log.d(TAG, "deriveCard: no stored currencies for $cardId, using defaults (${currencyList.size})")
                    currencyList
                } else {
                    // 以 incoming currencyList 为优先（保证 isTest 等字段最新）
                    // 仅追加 stored 中 incoming 未覆盖的额外币种（如历史添加的其他链）
                    val incomingIds = currencyList.map { it.id }.toSet()
                    val extras = storedCurrencies.filter { it.id !in incomingIds }
                    Log.d(TAG, "deriveCard: loaded ${storedCurrencies.size} stored, ${extras.size} extras appended for $cardId")
                    currencyList + extras
                }
                val snapshot = ensureKeyAndDerive(client, mergedList, generateIfMissing)
                state.lastCardId = snapshot.cardId
                state.lastPinSet = snapshot.isPasswordSet
                state.cacheMasterKey(snapshot.cardId, snapshot.masterPublicKey, snapshot.masterChainCode)
                state.replaceCurrencies(snapshot.currencies)
                // 与 card_coin 的 handleScanResponse 一致：扩展时先清空旧 WalletManager，再重建新实例
                walletManagerRegistry.clearWalletManagers()
                walletManagerRegistry.addWalletManagers(walletManagerRegistry.buildFrom(snapshot.currencies))
                // 持久化到 SharedPreferences，按卡片 UID 分隔
                repository.save(cardId, snapshot.currencies)
                // 若调用方传入了 server-side cardId（如服务器 UUID），同时存一份别名，
                // 以便 initScanResponse(serverUuid) 能命中缓存。
                // 注意：老 SDK toHexString() 是大写，chipcore toHex() 是小写，两者可能大小写不同但值相同。
                if (!aliasId.isNullOrEmpty() && aliasId.lowercase() != cardId.lowercase()) {
                    repository.save(aliasId, snapshot.currencies)
                    Log.d(TAG, "deriveCard: also saved under alias $aliasId")
                }
                Result.success(
                    Messages.CardMessage.Builder()
                        .setUid(snapshot.uid)
                        .setIsPasswordSet(snapshot.isPasswordSet)
                        .setPublicKey(snapshot.masterPublicKey)
                        .setCurrencyList(snapshot.currencies)
                        .build(),
                )
            },
            { outcome ->
                outcome.onSuccess(result::success).onFailure(result::error)
            },
        )
    }

    private fun ensureKeyAndDerive(
        client: HdWalletCardClient,
        currencyList: List<Messages.CurrencyInfoMessage>,
        generateIfMissing: Boolean,
    ): CardSnapshot {
        // AC 01：UID 未写入 NXP 卡片，先 writeUid 再重试 getStatus
        val status = try {
            client.getStatus()
        } catch (e: Messages.FlutterError) {
            if (e.message?.contains("SW=AC01") == true) {
                Log.d(TAG, "getStatus SW=AC01：UID 未写入 NXP 卡片，执行 writeUid 后重试")
                client.writeUid()
                client.getStatus()
            } else throw e
        }

        // ── 主密钥处理 ──
        // 假设：INS=0x41 不仅生成密钥，也会将密钥从 flash 加载到卡片工作内存（RAM）。
        // 不调用 INS=0x41，卡片 RAM 中没有密钥，INS=0x42（derive）返回 SW=0005。
        // 因此无论 hasKeyPair 是否为 true，都必须调用 INS=0x41 来加载密钥到 RAM。
        // INS=0x41 是幂等的：有密钥时直接返回已有密钥，无密钥时生成新密钥。
        if (!generateIfMissing && !status.hasKeyPair) {
            throw flutterError("key-not-found", "No key pair found on card")
        }
        Log.d(TAG, "调用 INS=0x41 加载/生成密钥（hasKeyPair=${status.hasKeyPair}，将密钥载入卡片 RAM）")
        val rootKey = client.generateKeyPair()
        // flash 写入需要时间：首次生成等待 500ms，已有密钥仅做 RAM 加载等待 100ms
        val loadDelay = if (!status.hasKeyPair) 500L else 100L
        Thread.sleep(loadDelay)

        // 按派生路径分组：同一路径的币（原生币 + 同网络代币）只派生一次
        Log.d(TAG, "ensureKeyAndDerive: currencyList.size=${currencyList.size}, ids=${currencyList.map { it.id }}")
        data class PathGroup(val spec: BlockchainSpec, val path: ByteArray, val entries: MutableList<Pair<Int, Messages.CurrencyInfoMessage>> = mutableListOf())
        val pathOrder = mutableListOf<String>()
        val pathGroups = LinkedHashMap<String, PathGroup>()
        for ((idx, currency) in currencyList.withIndex()) {
            val spec = BlockchainSpec.fromCurrency(currency)
            val path = spec.defaultPath()
            val key = path.toHex()
            Log.d(TAG, "  [$idx] id=${currency.id} sym=${currency.symbol} networkId=${currency.networkId} → spec=${spec.id} pathKey=${key.take(8)}")
            if (!pathGroups.containsKey(key)) {
                pathOrder.add(key)
                pathGroups[key] = PathGroup(spec, path)
            }
            pathGroups[key]!!.entries.add(idx to currency)
        }

        val output = arrayOfNulls<Messages.CurrencyInfoMessage>(currencyList.size)
        for (key in pathOrder) {
            val group = pathGroups[key] ?: continue
            Log.d(TAG, "▶ derive [${group.spec.id}] path=${group.path.toBip44PathString()} (${group.entries.size} currencies)")
            val derived = try {
                client.deriveKey(group.path)
            } catch (e: Messages.FlutterError) {
                if (e.message?.contains("SW=0005") == true) {
                    Log.e(TAG, "derive SW=0005：卡片密钥存储故障，无法派生 ${group.spec.id}")
                    throw flutterError("card-hardware-error", "Card key storage error (SW=0005). Please contact your card provider.")
                }
                if (e.message?.contains("SW=AC01") == true) {
                    Log.e(TAG, "derive SW=AC01：NXP 卡片 UID 未同步")
                    throw flutterError("uid-not-synced", "Card UID not synced. Please try again.")
                }
                throw e
            }
            Log.d(TAG, "  rawPubKey  [${derived.publicKey.size}]: ${derived.publicKey.toHex()}")
            for ((idx, currency) in group.entries) {
                val isTest = currency.isTest == 1L
                val address = group.spec.makeAddress(derived.publicKey, isTest)
                Log.d(TAG, "  address (${if (isTest) "testnet" else "mainnet"}): $address")
                output[idx] = currency.copyWith(
                    publicKey = derived.publicKey,
                    chainCode = derived.chainCode,
                    address = address,
                )
            }
        }
        val derivedCurrencies = output.filterNotNull()

        // rootKey 为本次 INS=0x41 返回的主密钥（始终调用，不再可空）
        val masterKey = rootKey

        return CardSnapshot(
            cardId = client.cardId,
            uid = status.uid?.toHex() ?: client.cardId,
            isPasswordSet = status.pinSet,
            masterPublicKey = masterKey.publicKey,
            masterChainCode = masterKey.chainCode,
            currencies = derivedCurrencies,
        )
    }

    private fun signDigest(
        blockchainId: String,
        payload: String,
        result: Messages.Result<String>,
    ) {
        if (state.lastPinSet) {
            sessionManager.showPinInputDialog { pinCode ->
                if (pinCode == null) {
                    // 用户取消 PIN 输入时重置缓存，避免下次操作仍预弹 PIN 框
                    state.lastPinSet = false
                    mainHandler.post { result.error(flutterError("pin-cancelled", "PIN input cancelled")) }
                    return@showPinInputDialog
                }
                doSignDigest(blockchainId, payload, pinCode, result)
            }
        } else {
            doSignDigest(blockchainId, payload, null, result)
        }
    }

    private fun doSignDigest(
        blockchainId: String,
        payload: String,
        pinCode: ByteArray?,
        result: Messages.Result<String>,
    ) {
        sessionManager.withSession(
            HdWalletApdu.HD_WALLET_AID,
            { channel ->
                val client = HdWalletCardClient(channel.isoDep, channel.tag.id, channel.aesKey)
                val spec = BlockchainSpec.fromIdentifier(blockchainId)
                val digest = spec.resolveDigest(payload)
                val signature = client.sign(spec.defaultPath(), digest, pinCode)
                Result.success(signature.toHex())
            },
            { outcome ->
                outcome.onSuccess(result::success).onFailure { e ->
                    handlePinRequired(
                        e,
                        onRetry = { pin -> doSignDigest(blockchainId, payload, pin, result) },
                        onError = { result.error(it) },
                    )
                }
            },
        )
    }

    private fun flutterError(code: String, message: String): Messages.FlutterError {
        return Messages.FlutterError(code, message, null)
    }

    /**
     * 统一处理 "pin-required" 错误：更新 lastPinSet 缓存、弹 PIN 输入框、回调重试。
     * @param e         NFC session 失败的异常
     * @param onRetry   用户输入 PIN 后的重试入口
     * @param onError   非 pin-required 错误时透传给 result
     */
    private fun handlePinRequired(
        e: Throwable,
        onRetry: (ByteArray) -> Unit,
        onError: (Messages.FlutterError) -> Unit,
    ) {
        val err = e as? Messages.FlutterError ?: flutterError("sign-error", e.message ?: "Signing failed")
        if (err.code == "pin-required") {
            state.lastPinSet = true
            sessionManager.showPinInputDialog { pinCode ->
                if (pinCode == null) {
                    mainHandler.post { onError(flutterError("pin-cancelled", "PIN input cancelled")) }
                } else {
                    onRetry(pinCode)
                }
            }
        } else {
            mainHandler.post { onError(err) }
        }
    }

    private fun notImplementedError(message: String): Messages.FlutterError {
        return flutterError("not-implemented", message)
    }

    companion object {
        private const val TAG = "ChipCoreBlockchainApi"
        private val ETH_ADDRESS_REGEX = Regex("^0x[a-fA-F0-9]{40}$")
        private val BTC_ADDRESS_REGEX =
            Regex("^(bc1|tb1)[ac-hj-np-z02-9]{11,71}$|^[13mn2][A-HJ-NP-Za-km-z1-9]{25,34}$")

        fun register(binaryMessenger: BinaryMessenger, activity: Activity) {
            Messages.BlockchainApi.setUp(binaryMessenger, ChipCoreBlockchainApi(activity, binaryMessenger))
        }
    }
}

