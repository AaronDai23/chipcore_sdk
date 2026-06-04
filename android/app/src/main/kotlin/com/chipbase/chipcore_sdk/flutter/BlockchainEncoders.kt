package com.chipcore.sdk.flutter

import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.bouncycastle.crypto.params.ECDomainParameters
import org.bouncycastle.math.ec.ECPoint

// ─── ETH encoder / decoder ────────────────────────────────────────────────────

internal object EthEncoder {

    private val CURVE_PARAMS: ECDomainParameters by lazy {
        val spec = org.bouncycastle.asn1.x9.X9ECParameters.getInstance(
            org.bouncycastle.asn1.sec.SECNamedCurves.getByName("secp256k1"),
        )
        ECDomainParameters(spec.curve, spec.g, spec.n, spec.h)
    }

    fun parseEthValue(amount: String): BigInteger {
        return if (amount.contains(".")) {
            val parts = amount.split(".")
            val whole = BigInteger(parts[0])
            val fracStr = (parts.getOrElse(1) { "0" } + "000000000000000000").take(18)
            val frac = BigInteger(fracStr)
            whole.multiply(BigInteger.TEN.pow(18)).add(frac)
        } else {
            BigInteger(amount).multiply(BigInteger.TEN.pow(18))
        }
    }

    fun weiToEthString(wei: BigInteger): String {
        val divisor = BigInteger.TEN.pow(18)
        val whole = wei.divide(divisor)
        val remainder = wei.remainder(divisor)
        if (remainder == BigInteger.ZERO) return whole.toString()
        val fracStr = remainder.toString().padStart(18, '0').trimEnd('0')
        return "$whole.$fracStr"
    }

    fun buildLegacyTxHash(
        nonce: BigInteger,
        gasPrice: BigInteger,
        gasLimit: BigInteger,
        to: String,
        value: BigInteger,
        data: ByteArray,
        chainId: BigInteger,
    ): ByteArray {
        val items = listOf(
            rlpEncode(nonce),
            rlpEncode(gasPrice),
            rlpEncode(gasLimit),
            rlpEncode(to.hexToBytes()),
            rlpEncode(value),
            rlpEncode(data),
            rlpEncode(chainId),
            rlpEncode(BigInteger.ZERO),
            rlpEncode(BigInteger.ZERO),
        )
        val raw = rlpList(items)
        return keccak256(raw)
    }

    fun encodeLegacySignedTx(
        nonce: BigInteger,
        gasPrice: BigInteger,
        gasLimit: BigInteger,
        to: String,
        value: BigInteger,
        data: ByteArray,
        v: BigInteger,
        r: BigInteger,
        s: BigInteger,
    ): ByteArray {
        val items = listOf(
            rlpEncode(nonce),
            rlpEncode(gasPrice),
            rlpEncode(gasLimit),
            rlpEncode(to.hexToBytes()),
            rlpEncode(value),
            rlpEncode(data),
            rlpEncode(v),
            rlpEncode(r.toByteArrayUnsigned()),
            rlpEncode(s.toByteArrayUnsigned()),
        )
        return rlpList(items)
    }

    /** Parse DER or raw (64/65 bytes) signature and recover recId for ETH. */
    fun parseAndRecoverSignature(sigBytes: ByteArray, msgHash: ByteArray, pubKeyBytes: ByteArray): Triple<BigInteger, BigInteger, Int> {
        val (r, s) = when {
            sigBytes.size == 64 -> {
                BigInteger(1, sigBytes.copyOfRange(0, 32)) to BigInteger(1, sigBytes.copyOfRange(32, 64))
            }
            sigBytes.size == 65 -> {
                BigInteger(1, sigBytes.copyOfRange(1, 33)) to BigInteger(1, sigBytes.copyOfRange(33, 65))
            }
            sigBytes[0] == 0x30.toByte() -> parseDer(sigBytes)
            else -> throw Messages.FlutterError("sig-format", "Unrecognised signature format length=${sigBytes.size}", null)
        }
        val canonicalS = canonicalize(s)
        val recId = recoverRecId(msgHash, r, canonicalS, pubKeyBytes)
        return Triple(r, canonicalS, recId)
    }

    private fun parseDer(der: ByteArray): Pair<BigInteger, BigInteger> {
        var offset = 2 // skip 0x30 0x?? (sequence tag + length)
        if (der[0] != 0x30.toByte()) throw Messages.FlutterError("sig-format", "DER first byte is not 0x30", null)
        offset = 2
        // R
        if (der[offset] != 0x02.toByte()) throw Messages.FlutterError("sig-format", "DER R tag error", null)
        val rLen = der[offset + 1].toInt() and 0xFF
        val r = BigInteger(1, der.copyOfRange(offset + 2, offset + 2 + rLen))
        offset += 2 + rLen
        // S
        if (der[offset] != 0x02.toByte()) throw Messages.FlutterError("sig-format", "DER S tag error", null)
        val sLen = der[offset + 1].toInt() and 0xFF
        val s = BigInteger(1, der.copyOfRange(offset + 2, offset + 2 + sLen))
        return r to s
    }

    private fun canonicalize(s: BigInteger): BigInteger {
        val halfOrder = CURVE_PARAMS.n.shiftRight(1)
        return if (s > halfOrder) CURVE_PARAMS.n.subtract(s) else s
    }

    private fun recoverRecId(hash: ByteArray, r: BigInteger, s: BigInteger, pubKey: ByteArray): Int {
        val expectedPub = CURVE_PARAMS.curve.decodePoint(pubKey)
        for (recId in 0..1) {
            val recovered = runCatching { recoverPublicKey(hash, r, s, recId) }.getOrNull() ?: continue
            if (recovered == expectedPub) return recId
        }
        return 0
    }

    private fun recoverPublicKey(hash: ByteArray, r: BigInteger, s: BigInteger, recId: Int): ECPoint {
        val curve = CURVE_PARAMS.curve
        val n = CURVE_PARAMS.n
        val x = r.add(BigInteger.valueOf(recId.toLong() / 2).multiply(n))
        val prime = (curve as org.bouncycastle.math.ec.ECCurve.Fp).q
        if (x >= prime) throw IllegalArgumentException("x >= prime")
        val R = curve.decodePoint(byteArrayOf((0x02 + (recId and 1)).toByte()) + x.toByteArray().padStart32())
        val eInv = BigInteger(1, hash).negate().mod(n)
        val rInv = r.modInverse(n)
        return CURVE_PARAMS.g.multiply(rInv.multiply(eInv).mod(n)).add(R.multiply(rInv.multiply(s).mod(n))).normalize()
    }

    private fun ByteArray.padStart32(): ByteArray =
        if (size >= 32) copyOfRange(size - 32, size) else ByteArray(32 - size) + this

    private fun String.hexToBytes(): ByteArray {
        val cleaned = removePrefix("0x")
        return ByteArray(cleaned.length / 2) { i -> cleaned.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }

    private fun BigInteger.toByteArrayUnsigned(): ByteArray {
        if (this == BigInteger.ZERO) return ByteArray(0) // 0 → empty bytes → RLP 0x80
        val ba = toByteArray()
        return if (ba.size > 1 && ba[0] == 0.toByte()) ba.copyOfRange(1, ba.size) else ba
    }

    // ── ERC20 ABI 编码 ────────────────────────────────────────────────────────────────────────────────

    /** 编码 ERC20 transfer(address,uint256) 调用数据 */
    fun encodeERC20Transfer(to: String, amount: BigInteger): ByteArray {
        // keccak256("transfer(address,uint256)") 前4字节 = 0xa9059cbb
        val selector = byteArrayOf(0xa9.toByte(), 0x05, 0x9c.toByte(), 0xbb.toByte())
        val toBytes = to.hexToBytes()
        val paddedTo = padLeft(toBytes, 32)
        val paddedAmount = padLeft(amount.toByteArrayUnsigned(), 32)
        return selector + paddedTo + paddedAmount
    }

    /** 编码 ERC20 balanceOf(address) 调用数据 */
    fun encodeERC20BalanceOf(address: String): ByteArray {
        // keccak256("balanceOf(address)") 前4字节 = 0x70a08231
        val selector = byteArrayOf(0x70, 0xa0.toByte(), 0x82.toByte(), 0x31)
        val paddedAddr = padLeft(address.hexToBytes(), 32)
        return selector + paddedAddr
    }

    /** 把 decimal 字符串按 decimals 精度解析为最小单位 BigInteger */
    fun parseTokenAmount(amount: String, decimals: Int): BigInteger {
        val parts = amount.split(".", limit = 2)
        val whole = BigInteger(parts[0])
        val scale = BigInteger.TEN.pow(decimals)
        if (parts.size == 2) {
            val fracStr = (parts[1] + "0".repeat(decimals)).take(decimals)
            val frac = BigInteger(fracStr)
            return whole.multiply(scale).add(frac)
        }
        return whole.multiply(scale)
    }

    /** 把最小单位 BigInteger 格式化为可读余额字符串 */
    fun formatTokenAmount(raw: BigInteger, decimals: Int): String {
        if (decimals == 0) return raw.toString()
        val scale = BigInteger.TEN.pow(decimals)
        val whole = raw.divide(scale)
        val remainder = raw.remainder(scale)
        if (remainder == BigInteger.ZERO) return whole.toString()
        val fracStr = remainder.toString().padStart(decimals, '0').trimEnd('0')
        return "$whole.$fracStr"
    }

    private fun padLeft(data: ByteArray, length: Int): ByteArray {
        if (data.size >= length) return data
        return ByteArray(length - data.size) + data
    }

    // ── Minimal RLP encoder ──────────────────────────────────────────────────

    private fun rlpEncode(value: BigInteger): ByteArray = rlpEncode(value.toByteArrayUnsigned())

    fun rlpEncode(bytes: ByteArray): ByteArray {
        return when {
            bytes.isEmpty() -> byteArrayOf(0x80.toByte())
            bytes.size == 1 && (bytes[0].toInt() and 0xFF) < 0x80 -> bytes
            bytes.size <= 55 -> byteArrayOf((0x80 + bytes.size).toByte()) + bytes
            else -> {
                val lenBytes = intToMinBytes(bytes.size)
                byteArrayOf((0xB7 + lenBytes.size).toByte()) + lenBytes + bytes
            }
        }
    }

    private fun rlpList(items: List<ByteArray>): ByteArray {
        val payload = items.fold(byteArrayOf()) { acc, b -> acc + b }
        return when {
            payload.size <= 55 -> byteArrayOf((0xC0 + payload.size).toByte()) + payload
            else -> {
                val lenBytes = intToMinBytes(payload.size)
                byteArrayOf((0xF7 + lenBytes.size).toByte()) + lenBytes + payload
            }
        }
    }

    private fun intToMinBytes(value: Int): ByteArray {
        val buf = ByteArray(4)
        buf[0] = (value ushr 24).toByte()
        buf[1] = (value ushr 16).toByte()
        buf[2] = (value ushr 8).toByte()
        buf[3] = value.toByte()
        return buf.dropWhile { it == 0.toByte() }.toByteArray()
    }
}

// ─── BTC encoder ─────────────────────────────────────────────────────────────

internal object BtcEncoder {

    data class Utxo(val txid: String, val vout: Int, val value: Long, val confirmed: Boolean)
    data class BtcOutput(val address: String, val value: Long)

    fun parseAmount(amountStr: String): Long {
        return if (amountStr.contains(".")) {
            val parts = amountStr.split(".")
            val whole = parts[0].toLong()
            val fracStr = (parts.getOrElse(1) { "0" } + "00000000").take(8)
            whole * 100_000_000L + fracStr.toLong()
        } else {
            amountStr.toLong()
        }
    }

    /** Simple greedy UTXO selection. Returns (selectedUtxos, changeSat). */
    fun selectUtxos(
        utxos: List<Utxo>,
        valueSat: Long,
        toAddress: String,
        changeAddress: String,
        feeRateSatPerVb: Long,
    ): Pair<List<Utxo>, Long> {
        val sorted = utxos.sortedByDescending { it.value }
        val selected = mutableListOf<Utxo>()
        var total = 0L
        for (utxo in sorted) {
            selected.add(utxo)
            total += utxo.value
            val estimatedVsize = estimateVsize(selected.size, 2)
            val fee = estimatedVsize * feeRateSatPerVb
            if (total >= valueSat + fee) {
                val change = total - valueSat - fee
                return selected to change
            }
        }
        throw Messages.FlutterError("insufficient-funds", "Insufficient balance to cover amount and fees", null)
    }

    /** P2WPKH vsize: (overhead + inputs*41 + outputs*31) rounded up. */
    private fun estimateVsize(inputCount: Int, outputCount: Int): Long {
        val baseSize = 10 + inputCount * 41 + outputCount * 31
        val witnessSize = 1 + inputCount * (1 + 1 + 73 + 1 + 33)
        return ((baseSize * 4 + witnessSize + 3) / 4).toLong()
    }

    /** OP_DUP OP_HASH160 <20-byte-hash> OP_EQUALVERIFY OP_CHECKSIG → not P2WPKH witness script */
    fun p2wpkhScriptCode(compressedPubKey: ByteArray): ByteArray {
        val hash160 = ripemd160(sha256(compressedPubKey))
        return byteArrayOf(0x19, 0x76, 0xA9.toByte(), 0x14) + hash160 + byteArrayOf(0x88.toByte(), 0xAC.toByte())
    }

    /** BIP143 segwit sighash (SIGHASH_ALL = 1). */
    fun buildSegwitSigHash(
        inputs: List<Utxo>,
        outputs: List<BtcOutput>,
        inputIndex: Int,
        scriptCode: ByteArray,
        inputValue: Long,
    ): ByteArray {
        val hashPrevouts = sha256(sha256(inputs.fold(byteArrayOf()) { acc, u ->
            acc + u.txid.reversed2() + int32LE(u.vout)
        }))
        val hashSequence = sha256(sha256(inputs.fold(byteArrayOf()) { acc, _ -> acc + int32LE(0xFFFFFFFE.toInt()) }))
        val hashOutputs = sha256(sha256(outputs.fold(byteArrayOf()) { acc, o ->
            acc + int64LE(o.value) + varInt(scriptAddress(o.address).size.toLong()) + scriptAddress(o.address)
        }))

        val utxo = inputs[inputIndex]
        val preimage = int32LE(2) + // version
            hashPrevouts +
            hashSequence +
            utxo.txid.reversed2() +
            int32LE(utxo.vout) +
            scriptCode +
            int64LE(inputValue) +
            int32LE(0xFFFFFFFE.toInt()) + // sequence
            hashOutputs +
            int32LE(0) + // locktime
            int32LE(1) // SIGHASH_ALL
        return sha256(sha256(preimage))
    }

    fun encodeSegwitTx(inputs: List<Utxo>, outputs: List<BtcOutput>, witnesses: List<List<ByteArray>>): ByteArray {
        var raw = int32LE(2) + // version
            byteArrayOf(0x00, 0x01) + // marker + flag
            varInt(inputs.size.toLong())
        for (utxo in inputs) {
            raw += utxo.txid.reversed2() + int32LE(utxo.vout) + byteArrayOf(0x00) + int32LE(0xFFFFFFFE.toInt())
        }
        raw += varInt(outputs.size.toLong())
        for (output in outputs) {
            val script = scriptAddress(output.address)
            raw += int64LE(output.value) + varInt(script.size.toLong()) + script
        }
        for (witness in witnesses) {
            raw += varInt(witness.size.toLong())
            for (item in witness) {
                raw += varInt(item.size.toLong()) + item
            }
        }
        raw += int32LE(0) // locktime
        return raw
    }

    /** Normalize a DER signature, ensuring low-S canonical form. */
    fun normalizeSignatureDer(sigBytes: ByteArray): ByteArray {
        val curveOrder = BigInteger("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141", 16)
        val halfOrder = curveOrder.shiftRight(1)

        if (sigBytes[0] != 0x30.toByte()) {
            // 卡片返回原始 64 字节 r||s（非 DER 格式）
            if (sigBytes.size == 64) {
                val r = BigInteger(1, sigBytes.copyOfRange(0, 32))
                var s = BigInteger(1, sigBytes.copyOfRange(32, 64))
                if (s > halfOrder) s = curveOrder.subtract(s)
                return encodeDer(r, s)
            }
            return sigBytes // 未知格式，原样返回
        }

        // 已是 DER 格式：解析并做低 s 规范化
        var offset = 2
        val rLen = sigBytes[offset + 1].toInt() and 0xFF
        val rBytes = sigBytes.copyOfRange(offset + 2, offset + 2 + rLen)
        offset += 2 + rLen
        val sLen = sigBytes[offset + 1].toInt() and 0xFF
        val sBytes = sigBytes.copyOfRange(offset + 2, offset + 2 + sLen)

        val r = BigInteger(1, rBytes)
        var s = BigInteger(1, sBytes)
        if (s > halfOrder) s = curveOrder.subtract(s)

        return encodeDer(r, s)
    }

    private fun encodeDer(r: BigInteger, s: BigInteger): ByteArray {
        // BigInteger.toByteArray() 使用二进制补码，正数高位为1时会加 0x00 前缀
        // 这正好符合 DER 编码要求：整数最高位为1时必须加 0x00 以表示正数
        val rb = r.toByteArray()
        val sb = s.toByteArray()
        val body = byteArrayOf(0x02, rb.size.toByte()) + rb +
            byteArrayOf(0x02, sb.size.toByte()) + sb
        return byteArrayOf(0x30, body.size.toByte()) + body
    }

    private fun scriptAddress(address: String): ByteArray {
        return try {
            Bech32.decode(address)
        } catch (_: Exception) {
            val decoded = Base58Check.decode(address)
            val prefix = decoded[0].toInt() and 0xFF
            when (prefix) {
                0x00 -> byteArrayOf(0x76, 0xA9.toByte(), 0x14) + decoded.copyOfRange(1, 21) + byteArrayOf(0x88.toByte(), 0xAC.toByte())
                0x05 -> byteArrayOf(0xA9.toByte(), 0x14) + decoded.copyOfRange(1, 21) + byteArrayOf(0x87.toByte())
                else -> throw Messages.FlutterError("address-error", "Unsupported address type prefix: $prefix", null)
            }
        }
    }

    private fun String.reversed2(): ByteArray {
        val hex = this.removePrefix("0x")
        return ByteArray(hex.length / 2) { i -> hex.substring(i * 2, i * 2 + 2).toInt(16).toByte() }.reversedArray()
    }

    private fun int32LE(value: Int): ByteArray {
        val buf = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(value)
        return buf.array()
    }

    private fun int64LE(value: Long): ByteArray {
        val buf = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        buf.putLong(value)
        return buf.array()
    }

    private fun varInt(value: Long): ByteArray = when {
        value < 0xFD -> byteArrayOf(value.toByte())
        value <= 0xFFFF -> byteArrayOf(0xFD.toByte(), (value and 0xFF).toByte(), ((value shr 8) and 0xFF).toByte())
        value <= 0xFFFFFFFFL -> {
            byteArrayOf(0xFE.toByte()) + int32LE(value.toInt())
        }
        else -> byteArrayOf(0xFF.toByte()) + int64LE(value)
    }
}

// ─── DOGE encoder（P2PKH 遗留格式）────────────────────────────────────────────

internal object DogeEncoder {

    data class DogeUtxo(val txid: String, val vout: Int, val value: Long)
    data class DogeOutput(val address: String, val value: Long)

    fun parseAmount(amountStr: String): Long {
        return if (amountStr.contains(".")) {
            val parts = amountStr.split(".")
            val whole = parts[0].toLong()
            val fracStr = (parts.getOrElse(1) { "0" } + "00000000").take(8)
            whole * 100_000_000L + fracStr.toLong()
        } else {
            amountStr.toLong()
        }
    }

    /** 简单贪心 UTXO 选择（P2PKH 标准交易约 148*inputs + 34*outputs + 10 字节）*/
    fun selectUtxos(
        utxos: List<DogeUtxo>,
        valueSat: Long,
        feeRateSatPerByte: Long,
    ): Pair<List<DogeUtxo>, Long> {
        val sorted = utxos.sortedByDescending { it.value }
        val selected = mutableListOf<DogeUtxo>()
        var total = 0L
        for (utxo in sorted) {
            selected.add(utxo)
            total += utxo.value
            val n = selected.size.toLong()
            // 优先尝试 2 个输出（含找零）
            val fee2 = (10 + n * 148 + 2 * 34L) * feeRateSatPerByte
            if (total >= valueSat + fee2) {
                val change = total - valueSat - fee2
                return selected to change
            }
            // 降级：1 个输出（不找零，找零金额并入手续费）
            val fee1 = (10 + n * 148 + 1 * 34L) * feeRateSatPerByte
            if (total >= valueSat + fee1) {
                return selected to 0L   // 找零为 0，差额作为手续费
            }
        }
        // 计算最多可发送金额，提示用户
        val allInputs = utxos.size.toLong()
        val maxFee = (10 + allInputs * 148 + 34L) * feeRateSatPerByte
        val totalSat = utxos.sumOf { it.value }
        val maxSend = (totalSat - maxFee).coerceAtLeast(0L)
        val maxDoge = java.math.BigDecimal(maxSend)
            .divide(java.math.BigDecimal("100000000"), 8, java.math.RoundingMode.DOWN)
            .stripTrailingZeros().toPlainString()
        throw Messages.FlutterError("insufficient-funds", "Insufficient DOGE balance. Maximum sendable: $maxDoge DOGE (after fees)", null)
    }

    /** P2PKH sighash（SIGHASH_ALL）：SHA256(SHA256(serialized_tx_for_signing)) */
    fun buildP2pkhSigHash(
        inputs: List<DogeUtxo>,
        outputs: List<DogeOutput>,
        signingIndex: Int,
        pubKey: ByteArray,
    ): ByteArray {
        val scriptPubKey = p2pkhScript(pubKey)
        var raw = int32LE(1) // version
        raw += varInt(inputs.size.toLong())
        for ((index, utxo) in inputs.withIndex()) {
            raw += utxo.txid.hexToBytesLE()
            raw += int32LE(utxo.vout)
            if (index == signingIndex) {
                raw += varInt(scriptPubKey.size.toLong()) + scriptPubKey
            } else {
                raw += byteArrayOf(0x00) // empty script for non-signing inputs
            }
            raw += int32LE(0xFFFFFFFF.toInt()) // sequence
        }
        raw += varInt(outputs.size.toLong())
        for (out in outputs) {
            raw += int64LE(out.value)
            val script = p2pkhScriptForAddress(out.address)
            raw += varInt(script.size.toLong()) + script
        }
        raw += int32LE(0) // locktime
        raw += int32LE(1) // SIGHASH_ALL
        return sha256(sha256(raw))
    }

    /** 编码 P2PKH 已签名交易（带 scriptSig） */
    fun encodeP2pkhTx(
        inputs: List<DogeUtxo>,
        outputs: List<DogeOutput>,
        signatures: List<ByteArray>,
        pubKey: ByteArray,
    ): ByteArray {
        var raw = int32LE(1) // version
        raw += varInt(inputs.size.toLong())
        for ((index, utxo) in inputs.withIndex()) {
            raw += utxo.txid.hexToBytesLE()
            raw += int32LE(utxo.vout)
            val sig = signatures[index]
            // scriptSig = <len> <sig> <len> <pubkey>
            val scriptSig = byteArrayOf(sig.size.toByte()) + sig +
                byteArrayOf(pubKey.size.toByte()) + pubKey
            raw += varInt(scriptSig.size.toLong()) + scriptSig
            raw += int32LE(0xFFFFFFFF.toInt()) // sequence
        }
        raw += varInt(outputs.size.toLong())
        for (out in outputs) {
            raw += int64LE(out.value)
            val script = p2pkhScriptForAddress(out.address)
            raw += varInt(script.size.toLong()) + script
        }
        raw += int32LE(0) // locktime
        return raw
    }

    private fun p2pkhScript(pubKey: ByteArray): ByteArray {
        val hash160 = ripemd160(sha256(pubKey))
        return byteArrayOf(0x76, 0xA9.toByte(), 0x14) + hash160 +
            byteArrayOf(0x88.toByte(), 0xAC.toByte())
    }

    private fun p2pkhScriptForAddress(address: String): ByteArray {
        val decoded = Base58Check.decode(address)
        val hash160 = decoded.copyOfRange(1, 21)
        return byteArrayOf(0x76, 0xA9.toByte(), 0x14) + hash160 +
            byteArrayOf(0x88.toByte(), 0xAC.toByte())
    }

    private fun String.hexToBytesLE(): ByteArray {
        val hex = this.removePrefix("0x")
        return ByteArray(hex.length / 2) { i ->
            hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }.reversedArray()
    }

    private fun int32LE(value: Int): ByteArray {
        val buf = java.nio.ByteBuffer.allocate(4).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        buf.putInt(value); return buf.array()
    }

    private fun int64LE(value: Long): ByteArray {
        val buf = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        buf.putLong(value); return buf.array()
    }

    private fun varInt(value: Long): ByteArray = when {
        value < 0xFD -> byteArrayOf(value.toByte())
        value <= 0xFFFF -> byteArrayOf(0xFD.toByte(), (value and 0xFF).toByte(), ((value shr 8) and 0xFF).toByte())
        else -> byteArrayOf(0xFE.toByte()) + int32LE(value.toInt())
    }
}

// ─── TRX encoder（DER → r+s+v 65 字节签名）────────────────────────────────────

internal object TrxEncoder {

    private val CURVE_PARAMS: org.bouncycastle.crypto.params.ECDomainParameters by lazy {
        val spec = org.bouncycastle.asn1.x9.X9ECParameters.getInstance(
            org.bouncycastle.asn1.sec.SECNamedCurves.getByName("secp256k1"),
        )
        org.bouncycastle.crypto.params.ECDomainParameters(spec.curve, spec.g, spec.n, spec.h)
    }

    /**
     * 将卡片返回的 DER 签名转换为 TRX 所需的 65 字节签名（r ++ s ++ v）。
     * v（恢复 ID）通过尝试 0/1 并比较恢复出的公钥确定。
     * [msgHash]    = 被签名的 32 字节 txID
     * [ethPubKey]  = 64 字节未压缩公钥（去掉 0x04 前缀的 X+Y）
     */
    fun derToTrxSignature(derSig: ByteArray, msgHash: ByteArray, ethPubKey: ByteArray): ByteArray {
        // 1. 解析签名：兼容 DER 格式和卡片返回的 raw 64 字节 r‖s 格式
        val (r, s) = when {
            derSig.size == 64 ->
                BigInteger(1, derSig.copyOfRange(0, 32)) to BigInteger(1, derSig.copyOfRange(32, 64))
            derSig.size == 65 ->
                BigInteger(1, derSig.copyOfRange(1, 33)) to BigInteger(1, derSig.copyOfRange(33, 65))
            derSig.isNotEmpty() && derSig[0] == 0x30.toByte() ->
                parseDer(derSig)
            else -> throw Messages.FlutterError("trx-sig-format", "Unrecognised TRX signature format length=${derSig.size}", null)
        }
        // 2. 确保 low-S
        val curveOrder = CURVE_PARAMS.n
        val halfOrder = curveOrder.shiftRight(1)
        val sFinal = if (s > halfOrder) curveOrder.subtract(s) else s
        // 3. 试 v=0, v=1 恢复公钥
        val recId = (0..1).firstOrNull { v ->
            val recovered = recoverPubKey(msgHash, r, sFinal, v) ?: return@firstOrNull false
            val recoveredBytes = recovered.getEncoded(false).copyOfRange(1, 65) // 去掉 0x04
            recoveredBytes.contentEquals(ethPubKey)
        } ?: throw Messages.FlutterError("trx-sig-error", "Failed to determine TRX signature recovery byte (v)", null)
        // 4. 编码 r + s + v（各 32 字节）
        fun BigInteger.to32Bytes(): ByteArray {
            val ba = toByteArray()
            return when {
                ba.size == 32 -> ba
                ba.size > 32 -> ba.copyOfRange(ba.size - 32, ba.size)
                else -> ByteArray(32 - ba.size) + ba
            }
        }
        return r.to32Bytes() + sFinal.to32Bytes() + byteArrayOf(recId.toByte())
    }

    private fun parseDer(der: ByteArray): Pair<BigInteger, BigInteger> {
        var offset = 2
        val rLen = der[offset + 1].toInt() and 0xFF
        val r = BigInteger(1, der.copyOfRange(offset + 2, offset + 2 + rLen))
        offset += 2 + rLen
        val sLen = der[offset + 1].toInt() and 0xFF
        val s = BigInteger(1, der.copyOfRange(offset + 2, offset + 2 + sLen))
        return r to s
    }

    private fun recoverPubKey(hash: ByteArray, r: BigInteger, s: BigInteger, recId: Int): org.bouncycastle.math.ec.ECPoint? {
        return try {
            val n = CURVE_PARAMS.n
            val x = r.add(BigInteger.valueOf((recId / 2).toLong()).multiply(n))
            val curve = CURVE_PARAMS.curve
            val xBytes = run {
                val ba = x.toByteArray()
                when {
                    ba.size == 33 -> ba.copyOfRange(1, 33)
                    ba.size < 32  -> ByteArray(32 - ba.size) + ba
                    else          -> ba
                }
            }
            val prefix = if (recId % 2 == 0) 0x02.toByte() else 0x03.toByte()
            val R = curve.decodePoint(byteArrayOf(prefix) + xBytes)
            if (!R.multiply(n).isInfinity) return null
            val e = BigInteger(1, hash)
            val rInv = r.modInverse(n)
            // Q = r⁻¹ · s · R + r⁻¹ · (−e) · G = z2·R + z1·G
            val z1 = rInv.multiply(n.subtract(e)).mod(n)  // r⁻¹ · (n − e)
            val z2 = rInv.multiply(s).mod(n)              // r⁻¹ · s
            CURVE_PARAMS.g.multiply(z1).add(R.multiply(z2)).normalize()
        } catch (_: Exception) {
            null
        }
    }
}
