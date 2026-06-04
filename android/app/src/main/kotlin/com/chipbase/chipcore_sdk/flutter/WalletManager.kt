package com.chipcore.sdk.flutter

import android.util.Log
import java.util.Locale

// ─── NativeWalletState ────────────────────────────────────────────────────────

internal class NativeWalletState(private val repository: CardCurrencyRepository) {
    var lastCardId: String? = null
    /** 上次扫卡结果中该卡是否设置了 PIN；用于在签名/发交易前预先弹出原生 PIN 输入框 */
    var lastPinSet: Boolean = false
    private val currencies = LinkedHashMap<String, Messages.CurrencyInfoMessage>()
    private val masters = LinkedHashMap<String, MasterKey>()

    /** 按 id 精确查找 */
    fun findById(id: String): Messages.CurrencyInfoMessage? = currencies[id]

    /** 当前内存中所有不重复的币种（用于持久化） */
    fun allCurrencies(): List<Messages.CurrencyInfoMessage> = currencies.values.distinctBy { it.id }

    fun replaceCurrencies(newCurrencies: List<Messages.CurrencyInfoMessage>) {
        currencies.clear()
        for (currency in newCurrencies) {
            currencies[currency.id] = currency
            currencies[currency.networkId] = currency
        }
    }

    fun mergeCurrencies(newCurrencies: List<Messages.CurrencyInfoMessage>) {
        for (currency in newCurrencies) {
            currencies[currency.id] = currency
            currencies[currency.networkId] = currency
        }
    }

    fun removeCurrencies(coinIds: List<String>) {
        coinIds.forEach(currencies::remove)
    }

    fun findAddress(networkId: String): String? =
        currencies[networkId]?.address ?: currencies.values.firstOrNull { it.networkId == networkId }?.address

    fun updateAddress(networkId: String, address: String) {
        val currency = currencies[networkId] ?: currencies.values.firstOrNull { it.networkId == networkId } ?: return
        val updated = currency.copyWith(address = address)
        currencies[currency.id] = updated
        currencies[currency.networkId] = updated
    }

    fun findPublicKeyHex(keyword: String): String? = currencies.values.firstNotNullOfOrNull { currency ->
        if (
            currency.networkId.contains(keyword, ignoreCase = true) ||
            currency.symbol.contains(keyword, ignoreCase = true) ||
            currency.name.contains(keyword, ignoreCase = true)
        ) {
            currency.publicKey?.toHex()
        } else {
            null
        }
    }

    fun findBySpec(spec: BlockchainSpec): Messages.CurrencyInfoMessage? = currencies.values.firstOrNull { currency ->
        spec.matches(currency.networkId) || spec.matches(currency.symbol) || spec.matches(currency.name)
    }

    fun cacheMasterKey(cardId: String, publicKey: ByteArray, chainCode: ByteArray) {
        masters[cardId] = MasterKey(publicKey, chainCode)
    }

    /** 按 symbol + networkId 查找合约地址（用于 token 发送）*/
    fun findContractAddress(symbol: String, networkId: String): String? {
        val sym = symbol.lowercase()
        val net = networkId.lowercase()
        return currencies.values.firstOrNull { currency ->
            (currency.symbol.lowercase() == sym || currency.id.lowercase() == sym) &&
            currency.networkId.lowercase() == net &&
            !currency.contractAddress.isNullOrEmpty()
        }?.contractAddress
    }

    /** 按 symbol + networkId 查找代币精度（decimals），默认 18 */
    fun findDecimals(symbol: String, networkId: String): Int {
        val sym = symbol.lowercase()
        val net = networkId.lowercase()
        return currencies.values.firstOrNull { currency ->
            (currency.symbol.lowercase() == sym || currency.id.lowercase() == sym) &&
            currency.networkId.lowercase() == net
        }?.decimalCount?.toInt() ?: 18
    }
}

// ─── ChipWalletManager ────────────────────────────────────────────────────────

/**
 * 对应 card_coin 的 WalletManager，管理单条链的地址、公钥及链上操作。
 * 可通过 [WalletManagerRegistry] 按链类型检索。
 */
internal class ChipWalletManager(
    val spec: BlockchainSpec,
    val address: String,
    val publicKey: ByteArray,
    val chainCode: ByteArray,
    val isTest: Boolean,
) {
    /** 最近一次拉取的余额（链原生单位字符串，如 "0.001"），null 表示尚未更新 */
    var balance: String? = null

    fun update() {
        balance = try {
            when (spec) {
                BlockchainSpec.Bitcoin  -> ChainClient.fetchBtcBalance(address, isTest)
                BlockchainSpec.Tron     -> ChainClient.fetchTrxBalance(address)
                BlockchainSpec.Dogecoin -> ChainClient.fetchDogeBalance(address, isTest)
                else                   -> ChainClient.fetchEthBalance(address, isTest)
            }
        } catch (e: Exception) {
            Log.w("ChipCoreNfc", "ChipWalletManager.update failed for ${spec.id}: ${e.message}")
            null
        }
    }

    fun getFees(): List<Messages.FeeResponse> {
        return when (spec) {
            BlockchainSpec.Bitcoin  -> ChainClient.fetchBtcFees(isTest)
            BlockchainSpec.Tron     -> ChainClient.fetchTrxFees()
            BlockchainSpec.Dogecoin -> ChainClient.fetchDogeFees(isTest)
            else                   -> ChainClient.fetchEthFees(isTest)
        }
    }
}

// ─── WalletManagerRegistry ────────────────────────────────────────────────────

/**
 * 对应 card_coin 的 WalletState，管理多条链的 [ChipWalletManager] 实例集合。
 */
internal class WalletManagerRegistry {
    private val managers = LinkedHashMap<String, ChipWalletManager>()

    fun getWalletManager(blockchain: String): ChipWalletManager? {
        return managers[blockchain.lowercase(Locale.US)]
            ?: managers.values.firstOrNull { it.spec.matches(blockchain) }
    }

    fun getWalletManagerBySpec(spec: BlockchainSpec): ChipWalletManager? =
        managers.values.firstOrNull { it.spec == spec }

    fun addWalletManagers(newManagers: List<ChipWalletManager>) {
        for (mgr in newManagers) {
            managers[mgr.spec.id] = mgr
            Log.d("ChipCoreNfc", "WalletManagerRegistry: added ${mgr.spec.id} address=${mgr.address}")
        }
    }

    fun clearWalletManagers() {
        Log.d("ChipCoreNfc", "WalletManagerRegistry: cleared ${managers.size} managers")
        managers.clear()
    }

    fun buildFrom(currencies: List<Messages.CurrencyInfoMessage>): List<ChipWalletManager> {
        return currencies.mapNotNull { currency ->
            val address = currency.address?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val publicKey = currency.publicKey ?: return@mapNotNull null
            val chainCode = currency.chainCode ?: byteArrayOf()
            val spec = BlockchainSpec.fromCurrency(currency)
            ChipWalletManager(
                spec = spec,
                address = address,
                publicKey = publicKey,
                chainCode = chainCode,
                isTest = currency.isTest == 1L,
            )
        }
    }

    fun all(): List<ChipWalletManager> = managers.values.toList()
}

// ─── CardCurrencyRepository ───────────────────────────────────────────────────

/**
 * 按卡片 UID 持久化币种列表（含已派生的地址和公钥），与 card_coin 的 CurrenciesRepository 对应。
 * 底层使用 SharedPreferences + JSON，无第三方依赖。
 */
internal class CardCurrencyRepository(private val activity: android.app.Activity) {
    private val prefs by lazy {
        activity.getSharedPreferences("chipcore_currencies", android.content.Context.MODE_PRIVATE)
    }

    /** 加载指定卡片的币种列表，未找到返回空列表 */
    fun load(cardId: String): List<Messages.CurrencyInfoMessage> {
        val json = prefs.getString("card_$cardId", null) ?: return emptyList()
        return try {
            val arr = org.json.JSONArray(json)
            (0 until arr.length()).mapNotNull { parseCurrency(arr.getJSONObject(it)) }
        } catch (_: Exception) {
            Log.w("ChipCoreNfc", "CardCurrencyRepository: failed to load currencies for $cardId")
            emptyList()
        }
    }

    /** 保存指定卡片的币种列表 */
    fun save(cardId: String, currencies: List<Messages.CurrencyInfoMessage>) {
        val arr = org.json.JSONArray()
        for (c in currencies) arr.put(encodeCurrency(c))
        prefs.edit().putString("card_$cardId", arr.toString()).apply()
        Log.d("ChipCoreNfc", "CardCurrencyRepository: saved ${currencies.size} currencies for $cardId")
    }

    private fun encodeCurrency(c: Messages.CurrencyInfoMessage): org.json.JSONObject {
        return org.json.JSONObject().apply {
            put("id", c.id)
            put("icon", c.icon ?: "")
            put("name", c.name)
            put("networkId", c.networkId)
            putOpt("networkName", c.networkName)
            put("networkIcon", c.networkIcon ?: "")
            put("symbol", c.symbol)
            putOpt("contractAddress", c.contractAddress)
            putOpt("decimalCount", c.decimalCount)
            putOpt("address", c.address)
            putOpt("publicKey", c.publicKey?.toHex())
            putOpt("chainCode", c.chainCode?.toHex())
            putOpt("isTest", c.isTest)
        }
    }

    private fun parseCurrency(o: org.json.JSONObject): Messages.CurrencyInfoMessage? {
        return try {
            val networkName = o.optString("networkName", "").takeIf { it.isNotEmpty() }
            val contractAddress = o.optString("contractAddress", "").takeIf { it.isNotEmpty() }
            val address = o.optString("address", "").takeIf { it.isNotEmpty() }
            val publicKeyHex = o.optString("publicKey", "").takeIf { it.isNotEmpty() }
            val chainCodeHex = o.optString("chainCode", "").takeIf { it.isNotEmpty() }
            Messages.CurrencyInfoMessage.Builder()
                .setId(o.getString("id"))
                .setIcon(o.optString("icon", ""))
                .setName(o.optString("name", ""))
                .setNetworkId(o.getString("networkId"))
                .setNetworkName(networkName)
                .setNetworkIcon(o.optString("networkIcon", ""))
                .setSymbol(o.optString("symbol", ""))
                .setContractAddress(contractAddress)
                .setDecimalCount(if (o.has("decimalCount")) o.getLong("decimalCount") else null)
                .setAmount(null) // 余额不持久化
                .setAddress(address)
                .setPublicKey(publicKeyHex?.hexToByteArrayOrNull())
                .setChainCode(chainCodeHex?.hexToByteArrayOrNull())
                .setIsTest(if (o.has("isTest")) o.getLong("isTest") else null)
                .build()
        } catch (e: Exception) {
            Log.w("ChipCoreNfc", "CardCurrencyRepository: failed to parse currency: ${e.message}")
            null
        }
    }
}
