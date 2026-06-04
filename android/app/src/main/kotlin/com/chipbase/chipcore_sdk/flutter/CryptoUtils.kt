package com.chipcore.sdk.flutter

import android.util.Log
import java.math.BigInteger
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Locale
import org.bouncycastle.crypto.digests.KeccakDigest
import org.bouncycastle.crypto.digests.RIPEMD160Digest

internal fun Map<Int, ByteArray>.toKeyMaterial(): KeyMaterial {
    val publicKey = this[HdWalletApdu.TAG_PUBLIC_KEY]
        ?: throw Messages.FlutterError("invalid-response", "Missing 0x90 public key tag", null)
    val chainCode = this[HdWalletApdu.TAG_CHAIN_CODE]
        ?: throw Messages.FlutterError("invalid-response", "Missing 0x92 ChainCode tag", null)
    return KeyMaterial(publicKey, chainCode)
}

internal fun ensureSuccessStatus(response: ByteArray, message: String) {
    if (response.size < 2) {
        throw Messages.FlutterError("apdu-error", "$message: response too short", null)
    }
    val sw1 = response[response.size - 2].toInt() and 0xFF
    val sw2 = response[response.size - 1].toInt() and 0xFF
    if (sw1 != 0x90 || sw2 != 0x00) {
        throw Messages.FlutterError("apdu-error", "$message: SW=${String.format(Locale.US, "%02X%02X", sw1, sw2)}", null)
    }
}

internal fun Messages.CurrencyInfoMessage.copyWith(
    publicKey: ByteArray? = this.publicKey,
    chainCode: ByteArray? = this.chainCode,
    address: String? = this.address,
): Messages.CurrencyInfoMessage {
    return Messages.CurrencyInfoMessage.Builder()
        .setId(id)
        .setIcon(icon)
        .setName(name)
        .setNetworkId(networkId)
        .setNetworkName(networkName)
        .setNetworkIcon(networkIcon)
        .setSymbol(symbol)
        .setContractAddress(contractAddress)
        .setDecimalCount(decimalCount)
        .setAmount(amount)
        .setAddress(address)
        .setPublicKey(publicKey)
        .setChainCode(chainCode)
        .setIsTest(isTest)
        .build()
}

internal fun ByteArray.compressSecp256k1(): ByteArray {
    if (size == 33) {
        return this
    }
    require(size == 65 && first() == 0x04.toByte()) { "Only uncompressed secp256k1 public keys are supported" }
    val prefix = if ((this[64].toInt() and 1) == 0) 0x02 else 0x03
    return byteArrayOf(prefix.toByte()) + copyOfRange(1, 33)
}

/**
 * 返回适合 ETH 地址计算的未压缩 X+Y 共 64 字节。
 * 支持三种输入格式：
 *   - 33字节压缩公钥 (0x02/0x03 + X)
 *   - 65字节未压缩公钥 (0x04 + X + Y)
 *   - 64字节纯 X+Y（少数情况）
 */
internal fun ByteArray.decompressToEthBytes(): ByteArray {
    return when {
        size == 64 -> this
        size == 65 && first() == 0x04.toByte() -> copyOfRange(1, 65)
        size == 33 -> {
            // 使用 BouncyCastle 解压缩 secp256k1 压缩公钥
            val params = org.bouncycastle.asn1.sec.SECNamedCurves.getByName("secp256k1")
            val point = params.curve.decodePoint(this).normalize()
            val x = point.xCoord.encoded.let { b: ByteArray -> if (b.size < 32) ByteArray(32 - b.size) + b else b.copyOfRange(b.size - 32, b.size) }
            val y = point.yCoord.encoded.let { b: ByteArray -> if (b.size < 32) ByteArray(32 - b.size) + b else b.copyOfRange(b.size - 32, b.size) }
            x + y
        }
        else -> {
            Log.w("ChipCoreNfc", "decompressToEthBytes: 无法识别公钥格式 size=$size prefix=${firstOrNull()?.toInt()?.and(0xFF)?.toString(16)}, 将原样返回")
            this
        }
    }
}

/**
 * EIP-55 混合大小写校验地址编码。
 * card_coin 通过 toDecompressedPublicKey + 链库内已自动应用此标准，与其保持一致。
 */
internal fun eip55ChecksumAddress(hexNoPrefix: String): String {
    val lower = hexNoPrefix.lowercase(Locale.US)
    val hash = keccak256(lower.toByteArray(StandardCharsets.US_ASCII))
    return buildString {
        for (i in lower.indices) {
            val c = lower[i]
            val nibble = (hash[i / 2].toInt() ushr (if (i % 2 == 0) 4 else 0)) and 0xF
            append(if (nibble >= 8 && c.isLetter()) c.uppercaseChar() else c)
        }
    }
}

internal fun ByteArray.toLongValue(): Long {
    if (isEmpty()) {
        return 0L
    }
    return BigInteger(1, this).toLong()
}

internal fun String.hexToByteArrayOrNull(): ByteArray? {
    val normalized = lowercase(Locale.US).removePrefix("0x")
    if (normalized.length % 2 != 0 || normalized.any { !it.isDigit() && it !in 'a'..'f' }) {
        return null
    }
    return ByteArray(normalized.length / 2) { index ->
        normalized.substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}

internal fun sha256(input: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(input)

internal fun ripemd160(input: ByteArray): ByteArray {
    val digest = RIPEMD160Digest()
    digest.update(input, 0, input.size)
    val out = ByteArray(digest.digestSize)
    digest.doFinal(out, 0)
    return out
}

internal fun keccak256(input: ByteArray): ByteArray {
    val digest = KeccakDigest(256)
    digest.update(input, 0, input.size)
    val out = ByteArray(32)
    digest.doFinal(out, 0)
    return out
}

/** Base58Check 编码（带 4 字节 double-SHA256 校验和），用于 TRX/DOGE 地址 */
internal fun base58Check(payload: ByteArray): String {
    val checksum = sha256(sha256(payload)).copyOfRange(0, 4)
    return Base58.encode(payload + checksum)
}

internal object Base58 {
    private const val ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    fun encode(input: ByteArray): String {
        if (input.isEmpty()) {
            return ""
        }
        var number = BigInteger(1, input)
        val base = BigInteger.valueOf(58)
        val encoded = StringBuilder()
        while (number > BigInteger.ZERO) {
            val divRem = number.divideAndRemainder(base)
            encoded.append(ALPHABET[divRem[1].toInt()])
            number = divRem[0]
        }
        input.takeWhile { it == 0.toByte() }.forEach { _ -> encoded.append(ALPHABET[0]) }
        return encoded.reverse().toString()
    }
}

internal fun ByteArray.toHex(): String = joinToString(separator = "") { byte -> "%02x".format(byte) }

/**
 * 将 defaultPath() 返回的路径字节转换为可读 BIP44 字符串，如 m/44'/60'/0'/0/0
 * 与 card_coin logcat 对照路径差异时使用。
 */
internal fun ByteArray.toBip44PathString(): String {
    if (size % 4 != 0) return "(raw) " + toHex()
    val sb = StringBuilder("m")
    for (i in 0 until size / 4) {
        val v = ((this[i * 4].toInt() and 0xFF) shl 24) or
            ((this[i * 4 + 1].toInt() and 0xFF) shl 16) or
            ((this[i * 4 + 2].toInt() and 0xFF) shl 8) or
            (this[i * 4 + 3].toInt() and 0xFF)
        val hardened = (v ushr 31) == 1
        val index = if (hardened) v and 0x7FFFFFFF else v
        sb.append("/").append(index)
        if (hardened) sb.append("'")
    }
    return sb.toString()
}

// ─── Bech32 ──────────────────────────────────────────────────────────────────

internal object Bech32 {
    private val GEN = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
    private const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    fun decode(hrpAndData: String): ByteArray {
        val lower = hrpAndData.lowercase(Locale.US)
        val pos = lower.lastIndexOf('1')
        val hrp = lower.substring(0, pos)
        val data = lower.substring(pos + 1).map { CHARSET.indexOf(it) }
        if (!verifyChecksum(hrp, data)) throw IllegalArgumentException("bad checksum")
        val decoded = convertBits(data.dropLast(6), 5, 8, false)
        val witVer = decoded[0].toInt() and 0xFF
        val witProg = decoded.copyOfRange(1, decoded.size)
        return when (witVer) {
            0 -> {
                if (witProg.size == 20) {
                    // P2WPKH
                    byteArrayOf(0x00, 0x14) + witProg
                } else {
                    // P2WSH
                    byteArrayOf(0x00, 0x20.toByte()) + witProg
                }
            }
            1 -> byteArrayOf(0x51, witProg.size.toByte()) + witProg // P2TR
            else -> throw IllegalArgumentException("unsupported witness version $witVer")
        }
    }

    private fun polymod(values: List<Int>): Int {
        var chk = 1
        for (v in values) {
            val top = chk ushr 25
            chk = ((chk and 0x1ffffff) shl 5) xor v
            for (i in 0..4) if ((top ushr i) and 1 != 0) chk = chk xor GEN[i]
        }
        return chk
    }

    private fun hrpExpand(hrp: String): List<Int> =
        hrp.map { it.code ushr 5 } + listOf(0) + hrp.map { it.code and 31 }

    private fun verifyChecksum(hrp: String, data: List<Int>): Boolean = polymod(hrpExpand(hrp) + data) == 1

    fun encodeP2WPKH(hrp: String, hash160: ByteArray): String {
        // 将 8bit hash160 转为 5bit
        var acc = 0; var bits = 0; val maxv = 31
        val data5 = mutableListOf(0) // witness version 0
        for (b in hash160) {
            acc = ((acc shl 8) or (b.toInt() and 0xff)) and 0xffffffff.toInt(); bits += 8
            while (bits >= 5) { bits -= 5; data5.add((acc ushr bits) and maxv) }
        }
        if (bits > 0) data5.add((acc shl (5 - bits)) and maxv)
        // 计算 checksum
        val expanded = hrpExpand(hrp) + data5 + listOf(0, 0, 0, 0, 0, 0)
        val pm = polymod(expanded) xor 1
        val checksum = (0..5).map { i -> (pm ushr (5 * (5 - i))) and 31 }
        return hrp + "1" + (data5 + checksum).joinToString("") { CHARSET[it].toString() }
    }

    private fun convertBits(data: List<Int>, from: Int, to: Int, pad: Boolean): ByteArray {
        var acc = 0; var bits = 0
        val result = mutableListOf<Byte>()
        val maxv = (1 shl to) - 1
        for (v in data) {
            acc = (acc shl from) or v; bits += from
            while (bits >= to) { bits -= to; result.add(((acc ushr bits) and maxv).toByte()) }
        }
        if (pad && bits > 0) result.add(((acc shl (to - bits)) and maxv).toByte())
        return result.toByteArray()
    }
}

// ─── Base58Check ─────────────────────────────────────────────────────────────

internal object Base58Check {
    private const val ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    fun decode(input: String): ByteArray {
        var num = BigInteger.ZERO
        for (ch in input) {
            val idx = ALPHABET.indexOf(ch)
            if (idx < 0) throw IllegalArgumentException("Invalid Base58 character: $ch")
            num = num.multiply(BigInteger.valueOf(58)).add(BigInteger.valueOf(idx.toLong()))
        }
        val decoded = num.toByteArray().let { if (it[0] == 0.toByte() && it.size > 1) it.copyOfRange(1, it.size) else it }
        val leadingZeros = input.takeWhile { it == '1' }.length
        val full = ByteArray(leadingZeros) + decoded
        val checksum = full.copyOfRange(full.size - 4, full.size)
        val payload = full.copyOfRange(0, full.size - 4)
        val expectedChecksum = sha256(sha256(payload)).copyOfRange(0, 4)
        if (!checksum.contentEquals(expectedChecksum)) throw IllegalArgumentException("Bad Base58Check checksum")
        return payload
    }
}
