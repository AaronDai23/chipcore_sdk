package com.chipcore.sdk.flutter

import android.util.Log
import java.nio.charset.StandardCharsets
import java.util.Locale

internal sealed class BlockchainSpec(
    val coinType: Int,
    /** 对应 card_coin Blockchain.id，用于 WalletManagerRegistry 的键 */
    val id: String,
) {
    abstract fun matches(identifier: String): Boolean
    abstract fun makeAddress(publicKey: ByteArray, isTest: Boolean): String

    open fun resolveDigest(payload: String): ByteArray {
        return payload.hexToByteArrayOrNull()?.takeIf { it.size == 32 }
            ?: sha256(payload.toByteArray(StandardCharsets.UTF_8))
    }

    /**
     * 生成 BIP44/BIP84 路径字节。子类可重写以使用不同 purpose。
     * change=-1 表示路径截止到 account 段（3段：m/purpose'/coinType'/account'）。
     * index=-1  表示路径截止到 change 段（4段：m/purpose'/coinType'/account'/change）。
     */
    open fun defaultPath(account: Int = 0, change: Int = 0, index: Int = 0): ByteArray {
        val segments = when {
            change < 0 -> intArrayOf(44 or HARDENED, coinType or HARDENED, account or HARDENED)
            index < 0  -> intArrayOf(44 or HARDENED, coinType or HARDENED, account or HARDENED, change)
            else       -> intArrayOf(44 or HARDENED, coinType or HARDENED, account or HARDENED, change, index)
        }
        val output = ByteArray(segments.size * 4)
        segments.forEachIndexed { idx, value ->
            val offset = idx * 4
            output[offset] = ((value ushr 24) and 0xFF).toByte()
            output[offset + 1] = ((value ushr 16) and 0xFF).toByte()
            output[offset + 2] = ((value ushr 8) and 0xFF).toByte()
            output[offset + 3] = (value and 0xFF).toByte()
        }
        return output
    }

    object Bitcoin : BlockchainSpec(0, "btc") {
        override fun matches(identifier: String): Boolean {
            val value = identifier.lowercase(Locale.US)
            return value.contains("btc") || value.contains("bitcoin")
        }

        // 路径使用父类默认 m/44'/0'/0'/0/0，地址格式为 P2WPKH bech32 (bc1q/tb1q)
        override fun makeAddress(publicKey: ByteArray, isTest: Boolean): String {
            val compressed = publicKey.compressSecp256k1()
            val hash160 = ripemd160(sha256(compressed))
            val hrp = if (isTest) "tb" else "bc"
            return Bech32.encodeP2WPKH(hrp, hash160)
        }
    }

    object Ethereum : BlockchainSpec(1, "eth") {
        override fun matches(identifier: String): Boolean {
            val value = identifier.lowercase(Locale.US)
            return value.contains("eth") || value.contains("ethereum") || value.contains("evm")
        }

        override fun makeAddress(publicKey: ByteArray, isTest: Boolean): String {
            // 卡片返回的公钥可能是压缩格式(33字节)或未压缩格式(65字节)或纯 X+Y(64字节)
            // ETH 地址 = keccak256(未压缩 X+Y 64字节) 的后 20 字节
            val ethBytes = publicKey.decompressToEthBytes()
            Log.d("ChipCoreNfc", "ETH makeAddress: pubKey[${publicKey.size}]=${publicKey.toHex()} -> ethBytes[${ethBytes.size}]")
            val hash = keccak256(ethBytes)
            val rawHex = hash.copyOfRange(hash.size - 20, hash.size).toHex()
            return "0x" + eip55ChecksumAddress(rawHex)
        }

        override fun resolveDigest(payload: String): ByteArray {
            return payload.hexToByteArrayOrNull()?.takeIf { it.size == 32 }
                ?: keccak256(payload.toByteArray(StandardCharsets.UTF_8))
        }
    }

    /** TRON (TRX) — BIP44 coinType=195, path m/44'/195'/0'/0/0 */
    object Tron : BlockchainSpec(195, "trx") {
        override fun matches(identifier: String): Boolean {
            val value = identifier.lowercase(Locale.US)
            return value.contains("trx") || value.contains("tron")
        }

        override fun makeAddress(publicKey: ByteArray, isTest: Boolean): String {
            // TRX 地址 = Base58Check(0x41 + keccak256(uncompressedPubKey)[12:32])
            val ethBytes = publicKey.decompressToEthBytes()
            val hash = keccak256(ethBytes)
            val raw20 = hash.copyOfRange(hash.size - 20, hash.size)
            val payload = byteArrayOf(0x41.toByte()) + raw20
            Log.d("ChipCoreNfc", "TRX makeAddress: payload=${payload.toHex()}")
            return base58Check(payload)
        }

        override fun resolveDigest(payload: String): ByteArray {
            return payload.hexToByteArrayOrNull()?.takeIf { it.size == 32 }
                ?: keccak256(payload.toByteArray(StandardCharsets.UTF_8))
        }
    }

    /** Dogecoin (DOGE) — BIP44 coinType=3, path m/44'/3'/0'/0/0 */
    object Dogecoin : BlockchainSpec(3, "doge") {
        override fun matches(identifier: String): Boolean {
            val value = identifier.lowercase(Locale.US)
            return value.contains("doge") || value.contains("dogecoin")
        }

        override fun makeAddress(publicKey: ByteArray, isTest: Boolean): String {
            // DOGE P2PKH: version=0x1E(mainnet)/0x71(testnet), hash160(compressedPubKey)
            val compressed = publicKey.compressSecp256k1()
            val hash160 = ripemd160(sha256(compressed))
            val version = if (isTest) 0x71.toByte() else 0x1E.toByte()
            val payload = byteArrayOf(version) + hash160
            Log.d("ChipCoreNfc", "DOGE makeAddress: isTest=$isTest payload=${payload.toHex()}")
            return base58Check(payload)
        }
    }

    companion object {
        private const val HARDENED = 0x80000000.toInt()

        fun fromCurrency(currency: Messages.CurrencyInfoMessage): BlockchainSpec {
            return fromIdentifier(listOf(currency.networkId, currency.symbol, currency.name).joinToString(" "))
        }

        fun fromIdentifier(identifier: String): BlockchainSpec {
            return when {
                Bitcoin.matches(identifier)   -> Bitcoin
                Tron.matches(identifier)      -> Tron
                Dogecoin.matches(identifier)  -> Dogecoin
                else                          -> Ethereum
            }
        }
    }
}
