import CryptoSwift
import Foundation

// MARK: - secp256k1 key recovery (using CryptoSwift CS.BigUInt)

enum Secp256k1 {
  // secp256k1 curve parameters
  static let p  = CS.BigUInt(Data(hexString: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F")!)
  static let n  = CS.BigUInt(Data(hexString: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")!)
  static let Gx = CS.BigUInt(Data(hexString: "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798")!)
  static let Gy = CS.BigUInt(Data(hexString: "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8")!)

  struct ECPoint {
    var x: CS.BigUInt
    var y: CS.BigUInt
    var isInfinity: Bool { x == 0 && y == 0 }
  }
  static let G = ECPoint(x: Gx, y: Gy)

  // Field arithmetic mod p
  static func fadd(_ a: CS.BigUInt, _ b: CS.BigUInt) -> CS.BigUInt { (a + b) % p }
  static func fsub(_ a: CS.BigUInt, _ b: CS.BigUInt) -> CS.BigUInt {
    a >= b ? (a - b) % p : p - (b - a) % p
  }
  static func fmul(_ a: CS.BigUInt, _ b: CS.BigUInt) -> CS.BigUInt { (a * b) % p }
  static func finv(_ a: CS.BigUInt) -> CS.BigUInt { a.inverse(p) ?? 0 }

  // EC point addition (affine)
  static func pointAdd(_ P: ECPoint, _ Q: ECPoint) -> ECPoint {
    if P.isInfinity { return Q }
    if Q.isInfinity { return P }
    if P.x == Q.x {
      return P.y == Q.y ? pointDouble(P) : ECPoint(x: 0, y: 0)
    }
    let lam = fmul(fsub(Q.y, P.y), finv(fsub(Q.x, P.x)))
    let rx  = fsub(fsub(fmul(lam, lam), P.x), Q.x)
    let ry  = fsub(fmul(lam, fsub(P.x, rx)), P.y)
    return ECPoint(x: rx, y: ry)
  }

  // EC point doubling (affine)
  static func pointDouble(_ P: ECPoint) -> ECPoint {
    if P.isInfinity { return P }
    let num = fmul(CS.BigUInt(3), fmul(P.x, P.x))
    let den = fmul(CS.BigUInt(2), P.y)
    let lam = fmul(num, finv(den))
    let rx  = fsub(fmul(lam, lam), fmul(CS.BigUInt(2), P.x))
    let ry  = fsub(fmul(lam, fsub(P.x, rx)), P.y)
    return ECPoint(x: rx, y: ry)
  }

  // Scalar multiplication: k * P
  static func scalarMul(_ k: CS.BigUInt, _ P: ECPoint) -> ECPoint {
    var result = ECPoint(x: 0, y: 0)
    var addend = P
    var kk = k
    while kk > 0 {
      if kk % 2 == 1 { result = pointAdd(result, addend) }
      addend = pointDouble(addend)
      kk >>= 1
    }
    return result
  }

  /// Recover uncompressed public key (65 bytes: 0x04 || x || y) from (hash, r, s, recId).
  static func recoverPublicKey(hash: Data, r: CS.BigUInt, s: CS.BigUInt, recId: Int) -> Data? {
    let x = r
    // y^2 = x^3 + 7 mod p; sqrt via exponentiation since p ≡ 3 mod 4
    let x3 = fmul(fmul(x, x), x)
    let y2 = fadd(x3, CS.BigUInt(7))
    let exp = (p + 1) / 4
    var y = y2.power(exp, modulus: p)
    guard fmul(y, y) == y2 else { return nil }
    // Ensure correct y parity
    let yIsOdd = y % 2 == 1
    if (recId & 1 == 0 && yIsOdd) || (recId & 1 == 1 && !yIsOdd) { y = p - y }
    let R = ECPoint(x: x, y: y)
    let e = CS.BigUInt(hash) % n
    guard let rInv = r.inverse(n) else { return nil }
    // Q = r^-1 * s * R + r^-1 * (-e) * G
    let eNeg = e == 0 ? CS.BigUInt(0) : (n - e)
    let z1   = (rInv * eNeg) % n
    let z2   = (rInv * (s % n)) % n
    let Q    = pointAdd(scalarMul(z1, G), scalarMul(z2, R))
    guard !Q.isInfinity else { return nil }
    return Data([0x04]) + to32Bytes(Q.x) + to32Bytes(Q.y)
  }

  static func to32Bytes(_ val: CS.BigUInt) -> Data {
    let bytes = val.serialize()
    if bytes.count >= 32 { return Data(bytes.suffix(32)) }
    return Data(repeating: 0, count: 32 - bytes.count) + bytes
  }
}

// MARK: - BtcUtxo

struct BtcUtxo {
  let txid: String
  let vout: Int
  let value: UInt64
}

// MARK: - BtcEncoder（对应 Android BlockchainEncoders.kt BTC 部分）

enum BtcEncoder {
  static func parseAmount(_ str: String) -> UInt64 {
    if str.contains(".") {
      let parts = str.split(separator: ".")
      let whole = UInt64(parts[0]) ?? 0
      let fracRaw = (String(parts.count > 1 ? parts[1] : "") + "00000000").prefix(8)
      let frac = UInt64(fracRaw) ?? 0
      return whole * 100_000_000 + frac
    }
    return UInt64(str) ?? 0
  }

  static func compressPublicKey(_ key: Data) -> Data {
    if key.count == 33 { return key }
    guard key.count == 65, key[0] == 0x04 else { return key }
    let prefix: UInt8 = (key[64] & 1) == 0 ? 0x02 : 0x03
    return Data([prefix]) + key[1..<33]
  }

  static func selectUtxos(utxos: [BtcUtxo], valueSat: UInt64, to: String, from: String, feeRateSatPerVb: UInt64) throws -> ([BtcUtxo], UInt64) {
    let sorted = utxos.sorted { $0.value > $1.value }
    var selected: [BtcUtxo] = []
    var total: UInt64 = 0
    for utxo in sorted {
      selected.append(utxo)
      total += utxo.value
      let vsize = estimateVsize(inputCount: selected.count, outputCount: 2)
      let fee = vsize * feeRateSatPerVb
      if total >= valueSat + fee {
        return (selected, total - valueSat - fee)
      }
    }
    throw PigeonError(code: "insufficient-funds", message: "余额不足以支付金额和手续费", details: nil)
  }

  private static func estimateVsize(inputCount: Int, outputCount: Int) -> UInt64 {
    let base = 10 + inputCount * 41 + outputCount * 31
    let witness = 1 + inputCount * (1 + 1 + 73 + 1 + 33)
    return UInt64((base * 4 + witness + 3) / 4)
  }

  static func p2wpkhScriptCode(pubKey: Data) -> Data {
    let hash160 = RIPEMD160.hash(message: SHA256.hash(data: pubKey))
    return Data([0x19, 0x76, 0xA9, 0x14]) + hash160 + Data([0x88, 0xAC])
  }

  static func buildSegwitSigHash(inputs: [BtcUtxo], outputs: [(address: String, value: UInt64)], inputIndex: Int, scriptCode: Data, inputValue: UInt64) -> Data {
    var prevouts = Data()
    for u in inputs {
      prevouts += Data(hexString: u.txid)!.reversed + int32LE(UInt32(u.vout))
    }
    let hashPrevouts = sha256d(prevouts)

    var seqData = Data()
    for _ in inputs { seqData += int32LE(0xFFFFFFFE) }
    let hashSequence = sha256d(seqData)

    var outData = Data()
    for o in outputs {
      outData += int64LE(o.value)
      let script = scriptForAddress(o.address)
      outData += varInt(UInt64(script.count)) + script
    }
    let hashOutputs = sha256d(outData)

    let utxo = inputs[inputIndex]
    var preimage = Data()
    preimage += int32LE(2) // version
    preimage += hashPrevouts
    preimage += hashSequence
    preimage += Data(hexString: utxo.txid)!.reversed + int32LE(UInt32(utxo.vout))
    preimage += scriptCode
    preimage += int64LE(inputValue)
    preimage += int32LE(0xFFFFFFFE) // sequence
    preimage += hashOutputs
    preimage += int32LE(0) // locktime
    preimage += int32LE(1) // SIGHASH_ALL
    return sha256d(preimage)
  }

  static func encodeSegwitTx(inputs: [BtcUtxo], outputs: [(address: String, value: UInt64)], witnesses: [[Data]]) -> Data {
    var raw = int32LE(2) + Data([0x00, 0x01]) + varInt(UInt64(inputs.count))
    for u in inputs {
      raw += Data(hexString: u.txid)!.reversed + int32LE(UInt32(u.vout)) + Data([0x00]) + int32LE(0xFFFFFFFE)
    }
    raw += varInt(UInt64(outputs.count))
    for o in outputs {
      let script = scriptForAddress(o.address)
      raw += int64LE(o.value) + varInt(UInt64(script.count)) + script
    }
    for witness in witnesses {
      raw += varInt(UInt64(witness.count))
      for item in witness { raw += varInt(UInt64(item.count)) + item }
    }
    raw += int32LE(0)
    return raw
  }

  static func normalizeSignatureDer(_ sig: Data) -> Data {
    let n = Data(hexString: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")!

    // Handle raw 64-byte r||s format (same as Android normalizeSignatureDer)
    if sig.count == 64 && sig[0] != 0x30 {
      let r = Data(sig[0..<32])
      let s = Data(sig[32..<64])
      let normalizedS = isGreaterThanHalfN(s, n: n) ? subtractFromN(s, n: n) : s
      return encodeDer(r: r, s: normalizedS)
    }

    guard sig[0] == 0x30 else { return sig }
    var offset = 2
    guard sig[offset] == 0x02 else { return sig }
    let rLen = Int(sig[offset + 1])
    let rBytes = sig[(offset + 2)..<(offset + 2 + rLen)]
    offset += 2 + rLen
    guard sig[offset] == 0x02 else { return sig }
    let sLen = Int(sig[offset + 1])
    let sBytes = sig[(offset + 2)..<(offset + 2 + sLen)]

    // Strip DER leading zero to get actual s integer for comparison
    let s = Data(Data(sBytes).drop(while: { $0 == 0 }))
    let normalizedS = isGreaterThanHalfN(s, n: n) ? subtractFromN(s, n: n) : s
    return encodeDer(r: Data(rBytes), s: normalizedS)
  }

  /// Full 32-byte lexicographic comparison: s > half_order?
  /// half_n = 7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
  private static func isGreaterThanHalfN(_ s: Data, n: Data) -> Bool {
    let halfN: [UInt8] = [
      0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
      0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
      0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
      0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
    ]
    // Left-pad s to 32 bytes (big-endian comparison)
    let sb: [UInt8] = s.count >= 32
      ? Array(s.prefix(32))
      : Array(Data(repeating: 0, count: 32 - s.count)) + Array(s)
    for i in 0..<32 {
      if sb[i] > halfN[i] { return true }
      if sb[i] < halfN[i] { return false }
    }
    return false
  }

  private static func subtractFromN(_ s: Data, n: Data) -> Data {
    var result = [UInt8](repeating: 0, count: 32)
    var borrow: Int = 0
    let nb = Array(n)
    let sb = Array(s.prefix(32).rightPadded(to: 32))
    for i in stride(from: 31, through: 0, by: -1) {
      let diff = Int(nb[i]) - Int(sb[i]) - borrow
      result[i] = UInt8(bitPattern: Int8(diff & 0xFF))
      borrow = diff < 0 ? 1 : 0
    }
    return Data(result)
  }

  static func encodeDer(r: Data, s: Data) -> Data {
    func pad(_ d: Data) -> Data {
      var clean = Data(d.drop(while: { $0 == 0 }))
      if let first = clean.first, first >= 0x80 { clean = Data([0x00]) + clean }
      return Data(clean)
    }
    let rp = pad(r); let sp = pad(s)
    let body = Data([0x02, UInt8(rp.count)]) + rp + Data([0x02, UInt8(sp.count)]) + sp
    return Data([0x30, UInt8(body.count)]) + body
  }

  private static func scriptForAddress(_ address: String) -> Data {
    if address.lowercased().hasPrefix("bc1") || address.lowercased().hasPrefix("tb1") {
      return Bech32.decode(address)
    }
    guard let decoded = Base58Check.decode(address), !decoded.isEmpty else {
      return Data()
    }
    let prefix = decoded[0]
    let hash = decoded[1..<min(21, decoded.count)]
    switch prefix {
    case 0x00: return Data([0x76, 0xA9, 0x14]) + hash + Data([0x88, 0xAC])
    case 0x05: return Data([0xA9, 0x14]) + hash + Data([0x87])
    default: return Data()
    }
  }

  static func int32LE(_ value: UInt32) -> Data {
    var v = value.littleEndian
    return Data(bytes: &v, count: 4)
  }

  static func int64LE(_ value: UInt64) -> Data {
    var v = value.littleEndian
    return Data(bytes: &v, count: 8)
  }

  static func varInt(_ value: UInt64) -> Data {
    switch value {
    case 0..<0xFD: return Data([UInt8(value)])
    case 0xFD...0xFFFF:
      var v = UInt16(value).littleEndian
      return Data([0xFD]) + Data(bytes: &v, count: 2)
    case 0x10000...0xFFFFFFFF:
      var v = UInt32(value).littleEndian
      return Data([0xFE]) + Data(bytes: &v, count: 4)
    default:
      var v = value.littleEndian
      return Data([0xFF]) + Data(bytes: &v, count: 8)
    }
  }

  private static func sha256d(_ data: Data) -> Data {
    SHA256.hash(data: SHA256.hash(data: data))
  }
}

// MARK: - EthEncoder（对应 Android BlockchainEncoders.kt ETH 部分）

enum EthEncoder {

  // MARK: - ERC20 ABI

  static func encodeERC20Transfer(to: String, amount: BigUInt) -> Data {
    let selector = Data([0xa9, 0x05, 0x9c, 0xbb])
    let paddedTo = padLeft(Data(hexString: to.dropPrefix("0x")) ?? Data(), to: 32)
    let paddedAmount = padLeft(amount.toByteData(), to: 32)
    return selector + paddedTo + paddedAmount
  }

  static func encodeERC20BalanceOf(address: String) -> Data {
    let selector = Data([0x70, 0xa0, 0x82, 0x31])
    let paddedAddr = padLeft(Data(hexString: address.dropPrefix("0x")) ?? Data(), to: 32)
    return selector + paddedAddr
  }

  /// 将 TRX Base58Check 地址编码为 ABI 参数（32 字节，左侧补零）
  static func encodeTronBalanceOfParam(address: String) -> String {
    guard let decoded = Base58Check.decode(address), decoded.count >= 21 else { return "" }
    // Tron 地址 = 0x41 + 20-byte hash160; ABI encoding pads hash160 to 32 bytes on the left
    let hash160 = decoded[1..<21]
    var padded = Data(repeating: 0, count: 32)
    padded.replaceSubrange(12..<32, with: hash160)
    return padded.hexString
  }

  static func parseTokenAmount(_ amount: String, decimals: Int) -> BigUInt {
    let parts = amount.split(separator: ".", maxSplits: 1)
    let whole = BigUInt(String(parts[0])) ?? .zero
    var scale = BigUInt(1)
    for _ in 0..<decimals { scale = scale * BigUInt(10) }
    if parts.count == 2 {
      let fracStr = (String(parts[1]) + String(repeating: "0", count: decimals)).prefix(decimals)
      let frac = BigUInt(String(fracStr)) ?? .zero
      return whole * scale + frac
    }
    return whole * scale
  }

  static func formatTokenAmount(_ raw: BigUInt, decimals: Int) -> String {
    if decimals == 0 { return raw.description }
    var scale = BigUInt(1)
    for _ in 0..<decimals { scale = scale * BigUInt(10) }
    let (whole, remainder) = raw.quotientAndRemainder(dividingBy: scale)
    if remainder == .zero { return whole.description }
    var fracStr = remainder.description
    while fracStr.count < decimals { fracStr = "0" + fracStr }
    fracStr = String(fracStr.reversed().drop(while: { $0 == "0" }).reversed())
    return "\(whole).\(fracStr)"
  }

  private static func padLeft(_ data: Data, to length: Int) -> Data {
    if data.count >= length { return data }
    return Data(repeating: 0, count: length - data.count) + data
  }

  // MARK: - ETH transaction

  static func parseEthValue(_ amount: String) -> BigUInt {
    if amount.contains(".") {
      let parts = amount.split(separator: ".", maxSplits: 1)
      let whole = BigUInt(String(parts[0])) ?? .zero
      let fracStr = (String(parts.count > 1 ? parts[1] : "") + "000000000000000000").prefix(18)
      let frac = BigUInt(String(fracStr)) ?? .zero
      let scale = pow10_18()
      return whole * scale + frac
    }
    return BigUInt(amount) ?? .zero
  }

  static func weiToEthString(_ wei: BigUInt) -> String {
    let scale = pow10_18()
    let (whole, remainder) = wei.quotientAndRemainder(dividingBy: scale)
    if remainder == .zero { return whole.description }
    var fracStr = remainder.description
    while fracStr.count < 18 { fracStr = "0" + fracStr }
    fracStr = String(fracStr.reversed().drop(while: { $0 == "0" }).reversed())
    return "\(whole).\(fracStr)"
  }

  private static func pow10_18() -> BigUInt {
    var result = BigUInt(1)
    for _ in 0..<18 { result = result * BigUInt(10) }
    return result
  }

  static func buildLegacyTxHash(nonce: BigUInt, gasPrice: BigUInt, gasLimit: BigUInt, to: String, value: BigUInt, data: Data, chainId: BigUInt) -> Data {
    let items: [Data] = [
      rlpEncode(nonce),
      rlpEncode(gasPrice),
      rlpEncode(gasLimit),
      rlpEncode(Data(hexString: to.dropPrefix("0x")) ?? Data()),
      rlpEncode(value),
      rlpEncode(data),
      rlpEncode(chainId),
      rlpEncode(BigUInt(0)),
      rlpEncode(BigUInt(0)),
    ]
    return keccak256(rlpList(items))
  }

  static func encodeLegacySignedTx(nonce: BigUInt, gasPrice: BigUInt, gasLimit: BigUInt, to: String, value: BigUInt, data: Data, v: BigUInt, r: Data, s: Data) -> Data {
    let items: [Data] = [
      rlpEncode(nonce),
      rlpEncode(gasPrice),
      rlpEncode(gasLimit),
      rlpEncode(Data(hexString: to.dropPrefix("0x")) ?? Data()),
      rlpEncode(value),
      rlpEncode(data),
      rlpEncode(v),
      rlpEncode(Data(r.drop(while: { $0 == 0 }))),
      rlpEncode(Data(s.drop(while: { $0 == 0 }))),
    ]
    return rlpList(items)
  }

  /// 解析卡片签名并恢复 recId，返回 (r: Data, s: Data, recId: Int)。
  /// s 已做 low-S 规范化。
  static func parseAndRecoverSignature(sigBytes: Data, msgHash: Data, pubKey: Data) throws -> (Data, Data, Int) {
    let rData: Data
    let sData: Data
    if sigBytes.count == 64 {
      rData = Data(sigBytes[0..<32])
      sData = Data(sigBytes[32..<64])
    } else if sigBytes.count == 65 {
      rData = Data(sigBytes[1..<33])
      sData = Data(sigBytes[33..<65])
    } else if sigBytes[0] == 0x30 {
      (rData, sData) = try parseDer(sigBytes)
    } else {
      throw PigeonError(code: "sig-format", message: "无法识别签名格式 length=\(sigBytes.count)", details: nil)
    }
    // Low-S canonicalization
    let rBig = CS.BigUInt(rData)
    var sBig = CS.BigUInt(sData)
    let halfN = Secp256k1.n / 2
    if sBig > halfN { sBig = Secp256k1.n - sBig }
    let sNorm = Secp256k1.to32Bytes(sBig)
    // Recover recId by comparing compressed pubkeys
    let pubKeyCompressed = pubKey.compressedSecp256k1()
    for recId in 0...1 {
      if let recovered = Secp256k1.recoverPublicKey(hash: msgHash, r: rBig, s: sBig, recId: recId) {
        if recovered.compressedSecp256k1() == pubKeyCompressed {
          return (rData, sNorm, recId)
        }
      }
    }
    return (rData, sNorm, 0) // fallback
  }

  private static func parseDer(_ der: Data) throws -> (Data, Data) {
    var offset = 2
    guard der[offset] == 0x02 else { throw PigeonError(code: "sig-format", message: "DER R tag error", details: nil) }
    let rLen = Int(der[offset + 1])
    var r = Data(der[(offset + 2)..<(offset + 2 + rLen)])
    if r.first == 0x00 { r = Data(r.dropFirst()) }  // strip DER positive-integer padding
    offset += 2 + rLen
    guard der[offset] == 0x02 else { throw PigeonError(code: "sig-format", message: "DER S tag error", details: nil) }
    let sLen = Int(der[offset + 1])
    var s = Data(der[(offset + 2)..<(offset + 2 + sLen)])
    if s.first == 0x00 { s = Data(s.dropFirst()) }
    return (r, s)
  }

  private static func rlpEncode(_ value: BigUInt) -> Data { rlpEncode(Data(value.toByteArray())) }

  static func rlpEncode(_ bytes: Data) -> Data {
    if bytes.isEmpty { return Data([0x80]) }
    if bytes.count == 1, bytes[0] < 0x80 { return bytes }
    if bytes.count <= 55 { return Data([UInt8(0x80 + bytes.count)]) + bytes }
    let lenBytes = intToMinBytes(bytes.count)
    return Data([UInt8(0xB7 + lenBytes.count)]) + lenBytes + bytes
  }

  private static func rlpList(_ items: [Data]) -> Data {
    let payload = items.reduce(Data()) { $0 + $1 }
    if payload.count <= 55 { return Data([UInt8(0xC0 + payload.count)]) + payload }
    let lenBytes = intToMinBytes(payload.count)
    return Data([UInt8(0xF7 + lenBytes.count)]) + lenBytes + payload
  }

  private static func intToMinBytes(_ value: Int) -> Data {
    var result = [UInt8]()
    var v = value
    while v > 0 { result.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
    return Data(result)
  }

  private static func keccak256(_ data: Data) -> Data {
    data.keccak256()
  }
}

// MARK: - Bech32

enum Bech32 {
  private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
  private static let gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

  static func encodeP2WPKH(hrp: String, hash160: Data) -> String {
    var data5 = [0] // witness version 0
    var acc = 0; var bits = 0
    for b in hash160 {
      acc = ((acc << 8) | Int(b)) & 0xffffffff; bits += 8
      while bits >= 5 { bits -= 5; data5.append((acc >> bits) & 31) }
    }
    if bits > 0 { data5.append((acc << (5 - bits)) & 31) }
    let checksum = computeChecksum(hrp: hrp, data: data5)
    let result = (data5 + checksum).map { charset[$0] }
    return hrp + "1" + String(result)
  }

  private static func computeChecksum(hrp: String, data: [Int]) -> [Int] {
    var values = hrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]
    let pm = polymod(values) ^ 1
    return (0..<6).map { i in (pm >> (5 * (5 - i))) & 31 }
  }

  private static func hrpExpand(_ hrp: String) -> [Int] {
    hrp.unicodeScalars.map { Int($0.value) >> 5 } + [0] + hrp.unicodeScalars.map { Int($0.value) & 31 }
  }

  private static func polymod(_ values: [Int]) -> Int {
    var chk = 1
    for v in values {
      let top = chk >> 25
      chk = ((chk & 0x1ffffff) << 5) ^ v
      for i in 0..<5 { if (top >> i) & 1 != 0 { chk ^= gen[i] } }
    }
    return chk
  }

  static func decode(_ hrpAndData: String) -> Data {
    let lower = hrpAndData.lowercased()
    guard let pos = lower.lastIndex(of: "1") else { return Data() }
    let dataStr = String(lower[lower.index(after: pos)...])
    let data = dataStr.compactMap { charset.firstIndex(of: $0) }
    let decoded = convertBits(data.dropLast(6), from: 5, to: 8, pad: false)
    guard !decoded.isEmpty else { return Data() }
    let witVer = Int(decoded[0])
    let witProg = decoded.dropFirst()
    switch witVer {
    case 0:
      if witProg.count == 20 { return Data([0x00, 0x14]) + witProg }
      return Data([0x00, 0x20]) + witProg
    default:
      return Data([UInt8(0x50 + witVer), UInt8(witProg.count)]) + witProg
    }
  }

  private static func convertBits(_ data: ArraySlice<Int>, from: Int, to: Int, pad: Bool) -> [UInt8] {
    var acc = 0; var bits = 0
    var result = [UInt8]()
    let maxv = (1 << to) - 1
    for v in data {
      acc = (acc << from) | v; bits += from
      while bits >= to { bits -= to; result.append(UInt8((acc >> bits) & maxv)) }
    }
    if pad, bits > 0 { result.append(UInt8((acc << (to - bits)) & maxv)) }
    return result
  }
}

// MARK: - DogeEncoder（P2PKH 遗留格式，对应 Android DogeEncoder）

struct DogeUtxo {
  let txid: String
  let vout: Int
  let value: Int64
}

enum DogeEncoder {
  static func parseAmount(_ amountStr: String) -> Int64 {
    if amountStr.contains(".") {
      let parts = amountStr.split(separator: ".")
      let whole = Int64(parts[0]) ?? 0
      let fracStr = (String(parts.count > 1 ? parts[1] : "") + "00000000").prefix(8)
      let frac = Int64(fracStr) ?? 0
      return whole * 100_000_000 + frac
    }
    return Int64(amountStr) ?? 0
  }

  /// 简单贪心 UTXO 选择（P2PKH 标准交易约 148*inputs + 34*outputs + 10 字节）
  static func selectUtxos(utxos: [DogeUtxo], valueSat: Int64, feeRateSatPerByte: Int64) throws -> ([DogeUtxo], Int64) {
    let sorted = utxos.sorted { $0.value > $1.value }
    var selected: [DogeUtxo] = []
    var total: Int64 = 0
    for utxo in sorted {
      selected.append(utxo)
      total += utxo.value
      let n = Int64(selected.count)
      let fee2 = (10 + n * 148 + 2 * 34) * feeRateSatPerByte
      if total >= valueSat + fee2 {
        return (selected, total - valueSat - fee2)
      }
      let fee1 = (10 + n * 148 + 1 * 34) * feeRateSatPerByte
      if total >= valueSat + fee1 {
        return (selected, 0)
      }
    }
    let allN  = Int64(utxos.count)
    let maxFee = (10 + allN * 148 + 34) * feeRateSatPerByte
    let totalSat = utxos.reduce(Int64(0)) { $0 + $1.value }
    let maxSend = max(0, totalSat - maxFee)
    let whole = maxSend / 100_000_000
    let frac = maxSend % 100_000_000
    let maxDogeStr = frac == 0 ? "\(whole)" : "\(whole).\(String(format: "%08d", frac).trimmingCharacters(in: CharacterSet(charactersIn: "0").inverted.inverted))"
    throw PigeonError(code: "insufficient-funds", message: "Insufficient DOGE balance. Maximum sendable: \(maxDogeStr) DOGE (after fees)", details: nil)
  }

  /// P2PKH sighash（SIGHASH_ALL）= SHA256d(serialized tx for signing)
  static func buildP2pkhSigHash(inputs: [DogeUtxo], outputs: [(address: String, value: Int64)], signingIndex: Int, pubKey: Data) -> Data {
    let scriptPubKey = p2pkhScript(pubKey: pubKey)
    var raw = int32LE(1)  // version
    raw += varInt(UInt64(inputs.count))
    for (index, utxo) in inputs.enumerated() {
      raw += hexToBytesLE(utxo.txid)
      raw += int32LE(UInt32(utxo.vout))
      raw += index == signingIndex
        ? varInt(UInt64(scriptPubKey.count)) + scriptPubKey
        : Data([0x00])
      raw += int32LE(0xFFFFFFFF)  // sequence
    }
    raw += varInt(UInt64(outputs.count))
    for out in outputs {
      raw += int64LE(UInt64(bitPattern: out.value))
      let script = p2pkhScriptForAddress(out.address)
      raw += varInt(UInt64(script.count)) + script
    }
    raw += int32LE(0)  // locktime
    raw += int32LE(1)  // SIGHASH_ALL
    return sha256d(raw)
  }

  /// 编码带 scriptSig 的 P2PKH 已签名交易
  static func encodeP2pkhTx(inputs: [DogeUtxo], outputs: [(address: String, value: Int64)], signatures: [Data], pubKey: Data) -> Data {
    var raw = int32LE(1)  // version
    raw += varInt(UInt64(inputs.count))
    for (index, utxo) in inputs.enumerated() {
      raw += hexToBytesLE(utxo.txid)
      raw += int32LE(UInt32(utxo.vout))
      let sig = signatures[index]
      let scriptSig = Data([UInt8(sig.count)]) + sig + Data([UInt8(pubKey.count)]) + pubKey
      raw += varInt(UInt64(scriptSig.count)) + scriptSig
      raw += int32LE(0xFFFFFFFF)  // sequence
    }
    raw += varInt(UInt64(outputs.count))
    for out in outputs {
      raw += int64LE(UInt64(bitPattern: out.value))
      let script = p2pkhScriptForAddress(out.address)
      raw += varInt(UInt64(script.count)) + script
    }
    raw += int32LE(0)  // locktime
    return raw
  }

  static func p2pkhScript(pubKey: Data) -> Data {
    let hash160 = Data(pubKey.bytes.sha256().ripemd160())
    return Data([0x76, 0xA9, 0x14]) + hash160 + Data([0x88, 0xAC])
  }

  static func p2pkhScriptForAddress(_ address: String) -> Data {
    guard let decoded = Base58Check.decode(address), decoded.count >= 21 else { return Data() }
    let hash160 = decoded[1..<21]
    return Data([0x76, 0xA9, 0x14]) + hash160 + Data([0x88, 0xAC])
  }

  private static func hexToBytesLE(_ hex: String) -> Data {
    let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
    var result = Data(capacity: cleaned.count / 2)
    var idx = cleaned.startIndex
    while idx < cleaned.endIndex {
      let next = cleaned.index(idx, offsetBy: 2)
      guard let b = UInt8(cleaned[idx..<next], radix: 16) else { break }
      result.append(b)
      idx = next
    }
    return Data(result.reversed())
  }

  private static func int32LE(_ value: UInt32) -> Data {
    var v = value.littleEndian; return Data(bytes: &v, count: 4)
  }
  private static func int64LE(_ value: UInt64) -> Data {
    var v = value.littleEndian; return Data(bytes: &v, count: 8)
  }
  private static func varInt(_ value: UInt64) -> Data {
    switch value {
    case 0..<0xFD: return Data([UInt8(value)])
    case 0xFD...0xFFFF:
      var v = UInt16(value).littleEndian; return Data([0xFD]) + Data(bytes: &v, count: 2)
    default:
      var v = UInt32(value).littleEndian; return Data([0xFE]) + Data(bytes: &v, count: 4)
    }
  }
  private static func sha256d(_ data: Data) -> Data { Data(Data(data.bytes.sha256()).bytes.sha256()) }
}

// MARK: - TrxEncoder（DER → r+s+v 65 字节签名，对应 Android TrxEncoder）

enum TrxEncoder {
  /// 将卡片返回的 DER 签名转换为 TRX 65 字节签名（r‖s‖v）。
  /// [msgHash]   = 被签名的 32 字节 txID
  /// [ethPubKey] = 64 字节未压缩公钥（去掉 0x04 前缀的 X+Y）
  static func derToTrxSignature(derSig: Data, msgHash: Data, ethPubKey: Data) throws -> Data {
    let rData: Data
    let sData: Data
    if derSig.count == 64 {
      rData = Data(derSig[0..<32])
      sData = Data(derSig[32..<64])
    } else if derSig.count == 65 {
      rData = Data(derSig[1..<33])
      sData = Data(derSig[33..<65])
    } else if !derSig.isEmpty && derSig[0] == 0x30 {
      (rData, sData) = try parseTrxDer(derSig)
    } else {
      throw PigeonError(code: "trx-sig-format", message: "Unrecognised TRX signature format length=\(derSig.count)", details: nil)
    }
    let rBig = CS.BigUInt(rData)
    var sBig = CS.BigUInt(sData)
    let halfN = Secp256k1.n / 2
    if sBig > halfN { sBig = Secp256k1.n - sBig }
    for recId in 0...1 {
      guard let recovered = Secp256k1.recoverPublicKey(hash: msgHash, r: rBig, s: sBig, recId: recId) else { continue }
      // ethPubKey 是 64 字节（无 0x04 前缀），recovered 是 65 字节（含 0x04）
      let recoveredNoPrefix = recovered.count == 65 ? Data(recovered[1...]) : recovered
      if recoveredNoPrefix == ethPubKey {
        return Secp256k1.to32Bytes(rBig) + Secp256k1.to32Bytes(sBig) + Data([UInt8(recId)])
      }
    }
    throw PigeonError(code: "trx-sig-error", message: "Failed to determine TRX signature recovery byte (v)", details: nil)
  }

  private static func parseTrxDer(_ der: Data) throws -> (Data, Data) {
    var offset = 2
    guard der[offset] == 0x02 else { throw PigeonError(code: "sig-format", message: "DER R tag error", details: nil) }
    let rLen = Int(der[offset + 1])
    var r = Data(der[(offset + 2)..<(offset + 2 + rLen)])
    if r.first == 0x00 { r = Data(r.dropFirst()) }
    offset += 2 + rLen
    guard der[offset] == 0x02 else { throw PigeonError(code: "sig-format", message: "DER S tag error", details: nil) }
    let sLen = Int(der[offset + 1])
    var s = Data(der[(offset + 2)..<(offset + 2 + sLen)])
    if s.first == 0x00 { s = Data(s.dropFirst()) }
    return (r, s)
  }
}

// MARK: - Base58Check

enum Base58Check {
  private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

  static func decode(_ input: String) -> Data? {
    var digits = [UInt8]()
    for ch in input {
      guard let idx = alphabet.firstIndex(of: ch) else { return nil }
      var v = UInt64(idx)
      for i in stride(from: digits.count - 1, through: 0, by: -1) {
        v += UInt64(digits[i]) * 58
        digits[i] = UInt8(v & 0xFF)
        v >>= 8
      }
      while v > 0 { digits.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
    }
    let leading = input.prefix(while: { $0 == "1" }).count
    let result = Array(repeating: UInt8(0), count: leading) + digits
    guard result.count >= 4 else { return nil }
    let payload = Data(result.dropLast(4))
    let checksum = Data(result.suffix(4))
    let expected = Data(SHA256.hash(data: SHA256.hash(data: payload)).prefix(4))
    guard checksum == expected else { return nil }
    return payload
  }
}

// MARK: - secp256k1 pubkey decompression helper

extension Data {
  /// 将 33 字节压缩 secp256k1 公钥解压为 64 字节（无 0x04 前缀）。
  /// 若已经是 65 字节非压缩格式，则去掉 0x04 前缀后返回。
  /// 若已经是 64 字节，则直接返回。无效输入返回 nil。
  func decompressedSecp256k1NoPrefix() -> Data? {
    if count == 64 { return self }
    if count == 65 && first == 0x04 { return Data(self[1...]) }
    if count == 33, let prefix = first, (prefix == 0x02 || prefix == 0x03) {
      let x = CS.BigUInt(Data(self[1...]))
      let x3 = Secp256k1.fmul(Secp256k1.fmul(x, x), x)
      let y2 = Secp256k1.fadd(x3, CS.BigUInt(7))
      let exp = (Secp256k1.p + 1) / 4
      var y = y2.power(exp, modulus: Secp256k1.p)
      guard Secp256k1.fmul(y, y) == y2 else { return nil }
      let isOdd = y % 2 == 1
      let prefixIsOdd = prefix == 0x03
      if isOdd != prefixIsOdd { y = Secp256k1.p - y }
      return Secp256k1.to32Bytes(x) + Secp256k1.to32Bytes(y)
    }
    return nil
  }
}
