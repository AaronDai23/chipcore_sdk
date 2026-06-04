import CryptoSwift
import Foundation

// MARK: - BigUInt minimal implementation

typealias BigUInt = UInt256

struct UInt256: Equatable, Comparable, CustomStringConvertible {
  var hi: UInt128
  var lo: UInt128

  init(_ value: UInt64) { lo = UInt128(value); hi = 0 }
  init(_ value: Int) { self.init(UInt64(bitPattern: Int64(value))) }

  static let zero = UInt256(0)
  static let one = UInt256(1)

  var description: String { toDecimalString() }

  func toHexString() -> String {
    if hi == 0 { return String(lo, radix: 16) }
    let loStr = String(lo, radix: 16)
    let padded = String(repeating: "0", count: max(0, 32 - loStr.count)) + loStr
    return String(hi, radix: 16) + padded
  }

  private func toDecimalString() -> String {
    if self == .zero { return "0" }
    var result = ""
    var remaining = self
    let ten = UInt256(10)
    while remaining > .zero {
      let (q, r) = remaining.quotientAndRemainder(dividingBy: ten)
      result = String(r.lo) + result
      remaining = q
    }
    return result
  }

  static func < (lhs: UInt256, rhs: UInt256) -> Bool {
    if lhs.hi != rhs.hi { return lhs.hi < rhs.hi }
    return lhs.lo < rhs.lo
  }

  static func + (lhs: UInt256, rhs: UInt256) -> UInt256 {
    let (newLo, overflow) = lhs.lo.addingReportingOverflow(rhs.lo)
    let newHi = lhs.hi &+ rhs.hi &+ (overflow ? 1 : 0)
    return UInt256(hi: newHi, lo: newLo)
  }

  static func - (lhs: UInt256, rhs: UInt256) -> UInt256 {
    let (newLo, borrow) = lhs.lo.subtractingReportingOverflow(rhs.lo)
    let newHi = lhs.hi &- rhs.hi &- (borrow ? 1 : 0)
    return UInt256(hi: newHi, lo: newLo)
  }

  static func * (lhs: UInt256, rhs: UInt256) -> UInt256 {
    let (newLo, _) = lhs.lo.multipliedReportingOverflow(by: rhs.lo)
    let hiPart = lhs.hi &* rhs.lo &+ lhs.lo &* rhs.hi
    return UInt256(hi: hiPart, lo: newLo)
  }

  func quotientAndRemainder(dividingBy divisor: UInt256) -> (UInt256, UInt256) {
    if divisor > self { return (.zero, self) }
    if divisor.hi == 0 && hi == 0 {
      let q = lo / divisor.lo
      let r = lo % divisor.lo
      return (UInt256(q), UInt256(r))
    }
    var quotient = UInt256.zero
    var remainder = UInt256.zero
    for i in stride(from: 255, through: 0, by: -1) {
      remainder = remainder << 1
      if bitAt(i) { remainder.lo |= 1 }
      if remainder >= divisor {
        remainder = remainder - divisor
        quotient = quotient | (UInt256.one << i)
      }
    }
    return (quotient, remainder)
  }

  static func | (lhs: UInt256, rhs: UInt256) -> UInt256 {
    UInt256(hi: lhs.hi | rhs.hi, lo: lhs.lo | rhs.lo)
  }

  static func << (lhs: UInt256, rhs: Int) -> UInt256 {
    if rhs == 0 { return lhs }
    if rhs >= 128 { return UInt256(hi: lhs.lo << (rhs - 128), lo: 0) }
    let newHi = (lhs.hi << rhs) | (lhs.lo >> (128 - rhs))
    let newLo = lhs.lo << rhs
    return UInt256(hi: newHi, lo: newLo)
  }

  func bitAt(_ pos: Int) -> Bool {
    if pos >= 128 {
      let shift = pos - 128
      return (hi >> shift) & 1 == 1
    } else {
      return (lo >> pos) & 1 == 1
    }
  }

  init?(_ string: String, radix: Int = 10) {
    var result = UInt256.zero
    for ch in string {
      guard let digit = ch.hexDigitValue ?? (radix == 10 ? ch.wholeNumberValue : nil) else { return nil }
      if digit >= radix { return nil }
      result = result * UInt256(radix) + UInt256(digit)
    }
    self = result
  }

  init(hi: UInt128, lo: UInt128) { self.hi = hi; self.lo = lo }

  static func / (lhs: UInt256, rhs: UInt256) -> UInt256 {
    lhs.quotientAndRemainder(dividingBy: rhs).0
  }

  static func % (lhs: UInt256, rhs: UInt256) -> UInt256 {
    lhs.quotientAndRemainder(dividingBy: rhs).1
  }

  func toByteArray() -> [UInt8] {
    var result = [UInt8]()
    var n = self
    while n > .zero {
      let (q, r) = n.quotientAndRemainder(dividingBy: UInt256(256))
      result.insert(UInt8(r.lo), at: 0)
      n = q
    }
    return result
  }
}

extension UInt256: ExpressibleByIntegerLiteral {
  init(integerLiteral value: UInt64) { self.init(value) }
}

typealias UInt128 = UInt64 // simplified: treat UInt128 as UInt64

// MARK: - SHA256 / RIPEMD160 wrappers

enum SHA256 {
  static func hash(data: Data) -> Data {
    Data(data.bytes.sha256())
  }
}

enum RIPEMD160 {
  static func hash(message: Data) -> Data {
    Data(message.bytes.ripemd160())
  }
}

// MARK: - Pure-Swift RIPEMD-160 implementation

extension [UInt8] {
  func ripemd160() -> [UInt8] {
    var msg = self
    let bitLen = UInt64(msg.count) * 8
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0) }
    for i in 0..<8 { msg.append(UInt8((bitLen >> (i * 8)) & 0xFF)) }

    var h0: UInt32 = 0x6745_2301
    var h1: UInt32 = 0xEFCD_AB89
    var h2: UInt32 = 0x98BA_DCFE
    var h3: UInt32 = 0x1032_5476
    var h4: UInt32 = 0xC3D2_E1F0

    let KL: [UInt32] = [0x0000_0000, 0x5A82_7999, 0x6ED9_EBA1, 0x8F1B_BCDC, 0xA953_FD4E]
    let KR: [UInt32] = [0x50A2_8BE6, 0x5C4D_D124, 0x6D70_3EF3, 0x7A6D_76E9, 0x0000_0000]
    let RL: [Int] = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15, 7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8,
                     3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12, 1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2,
                     4,0,5,9,7,12,2,10,14,1,3,8,11,6,15,13]
    let RR: [Int] = [5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12, 6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2,
                     15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13, 8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14,
                     12,15,10,4,1,5,8,7,6,2,13,14,0,3,9,11]
    let SL: [Int] = [11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8, 7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12,
                     11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5, 11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12,
                     9,15,5,11,6,8,13,12,5,12,13,14,11,8,5,6]
    let SR: [Int] = [8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6, 9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11,
                     9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5, 15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8,
                     8,5,12,9,12,5,14,6,8,13,6,5,15,13,11,11]

    func f(_ j: Int, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
      switch j {
      case 0..<16:  return b ^ c ^ d
      case 16..<32: return (b & c) | (~b & d)
      case 32..<48: return (b | ~c) ^ d
      case 48..<64: return (b & d) | (c & ~d)
      default:      return b ^ (c | ~d)
      }
    }
    func rotL32(_ x: UInt32, _ n: Int) -> UInt32 { (x << n) | (x >> (32 - n)) }

    for off in stride(from: 0, to: msg.count, by: 64) {
      let X = (0..<16).map { i -> UInt32 in
        let b = off + i * 4
        return UInt32(msg[b]) | (UInt32(msg[b+1]) << 8) | (UInt32(msg[b+2]) << 16) | (UInt32(msg[b+3]) << 24)
      }
      var (al, bl, cl, dl, el) = (h0, h1, h2, h3, h4)
      var (ar, br, cr, dr, er) = (h0, h1, h2, h3, h4)

      for j in 0..<80 {
        let rnd = j / 16
        var T = al &+ f(j, bl, cl, dl) &+ X[RL[j]] &+ KL[rnd]
        T = rotL32(T, SL[j]) &+ el
        al = el; el = dl; dl = rotL32(cl, 10); cl = bl; bl = T

        T = ar &+ f(79 - j, br, cr, dr) &+ X[RR[j]] &+ KR[rnd]
        T = rotL32(T, SR[j]) &+ er
        ar = er; er = dr; dr = rotL32(cr, 10); cr = br; br = T
      }
      let T = h1 &+ cl &+ dr
      h1 = h2 &+ dl &+ er
      h2 = h3 &+ el &+ ar
      h3 = h4 &+ al &+ br
      h4 = h0 &+ bl &+ cr
      h0 = T
    }

    var out = [UInt8](repeating: 0, count: 20)
    for (i, h) in [h0, h1, h2, h3, h4].enumerated() {
      out[i*4]   = UInt8(h         & 0xFF)
      out[i*4+1] = UInt8((h >> 8)  & 0xFF)
      out[i*4+2] = UInt8((h >> 16) & 0xFF)
      out[i*4+3] = UInt8((h >> 24) & 0xFF)
    }
    return out
  }
}

// MARK: - Shared Data / String extension helpers

extension Data {
  var reversed: Data { Data(self.reversed() as [UInt8]) }

  init?(hexString: String) {
    let normalized = hexString.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive, range: hexString.range(of: "0x", options: .caseInsensitive))
    guard normalized.count % 2 == 0 else { return nil }
    var result = Data()
    var index = normalized.startIndex
    while index < normalized.endIndex {
      let next = normalized.index(index, offsetBy: 2)
      guard let byte = UInt8(normalized[index..<next], radix: 16) else { return nil }
      result.append(byte)
      index = next
    }
    self = result
  }

  func rightPadded(to length: Int) -> Data {
    if count >= length { return self }
    return self + Data(repeating: 0, count: length - count)
  }
}

extension [UInt8] {
  func rightPadded(to length: Int) -> [UInt8] {
    if count >= length { return self }
    return self + Array(repeating: 0, count: length - count)
  }
}

extension String {
  func dropPrefix(_ prefix: String) -> String {
    if hasPrefix(prefix) { return String(dropFirst(prefix.count)) }
    return self
  }
}

extension BigUInt {
  func toByteData() -> Data {
    let b = toByteArray()
    return b.isEmpty ? Data([0]) : Data(b)
  }
}

extension DataProtocol {
  func keccak256() -> Data {
    var d = Data(self)
    return Data(d.sha3(.keccak256))
  }
}
