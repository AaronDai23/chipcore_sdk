import CryptoSwift
import Flutter
import Foundation

// MARK: - BlockchainSpec（对应 Android BlockchainSpec.kt）

enum BlockchainSpec {
  case bitcoin
  case ethereum
  case tron
  case dogecoin

  /// 对应 Android BlockchainSpec.id，用于 WalletManagerRegistry 的键
  var id: String {
    switch self {
    case .bitcoin:  return "btc"
    case .ethereum: return "eth"
    case .tron:     return "trx"
    case .dogecoin: return "doge"
    }
  }

  func matches(_ identifier: String) -> Bool {
    let value = identifier.lowercased()
    switch self {
    case .bitcoin:
      return value.contains("btc") || value.contains("bitcoin")
    case .ethereum:
      return value.contains("eth") || value.contains("ethereum") || value.contains("evm")
    case .tron:
      return value.contains("trx") || value.contains("tron")
    case .dogecoin:
      return value.contains("doge") || value.contains("dogecoin")
    }
  }

  static func fromCurrency(_ currency: CurrencyInfoMessage) -> BlockchainSpec {
    fromIdentifier([currency.networkId, currency.symbol, currency.name].joined(separator: " "))
  }

  static func fromIdentifier(_ identifier: String) -> BlockchainSpec {
    if bitcoin.matches(identifier) { return .bitcoin }
    if tron.matches(identifier) { return .tron }
    if dogecoin.matches(identifier) { return .dogecoin }
    return .ethereum
  }

  func defaultPath(account: UInt32 = 0, change: UInt32 = 0, index: UInt32 = 0) -> Data {
    let hardened: UInt32 = 0x80000000
    let coinType: UInt32
    switch self {
    case .bitcoin:  coinType = 0
    case .tron:     coinType = 195
    case .dogecoin: coinType = 3
    case .ethereum: coinType = 1   // 与 Android BlockchainSpec.Ethereum(coinType=1) 保持一致，路径 m/44'/1'/0'/0/0
    }
    let segments: [UInt32] = [44 | hardened, coinType | hardened, account | hardened, change, index]
    return segments.reduce(into: Data()) { result, segment in
      var bigEndian = segment.bigEndian
      result.append(Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size))
    }
  }

  func resolveDigest(_ payload: String) -> Data {
    if let data = payload.hexToData(), data.count == 32 {
      return data
    }
    let bytes = Array(payload.utf8)
    switch self {
    case .bitcoin, .dogecoin:
      return Data(bytes.sha256())
    case .ethereum, .tron:
      return Data(bytes.sha3(.keccak256))
    }
  }

  func makeAddress(publicKey: Data, isTest: Bool) -> String {
    switch self {
    case .bitcoin:
      let compressed = publicKey.compressedSecp256k1()
      let hash160 = Data(compressed.bytes.sha256().ripemd160())
      let hrp = isTest ? "tb" : "bc"
      return Bech32.encodeP2WPKH(hrp: hrp, hash160: hash160)
    case .dogecoin:
      let compressed = publicKey.compressedSecp256k1()
      let hash160 = Data(compressed.bytes.sha256().ripemd160())
      let prefix = Data([isTest ? 0x71 : 0x1E])
      let body = prefix + hash160
      let checksum = Data(Data(body.bytes.sha256()).bytes.sha256().prefix(4))
      return Base58.encode(body + checksum)
    case .tron:
      let normalized = publicKey.count == 65 && publicKey.first == 0x04 ? publicKey.dropFirst() : Data(publicKey)
      let hash = Data(Array(normalized).sha3(.keccak256))
      let body = Data([0x41]) + Data(hash.suffix(20))
      let checksum = Data(Data(body.bytes.sha256()).bytes.sha256().prefix(4))
      return Base58.encode(body + checksum)
    case .ethereum:
      let normalized = publicKey.count == 65 && publicKey.first == 0x04 ? publicKey.dropFirst() : Data(publicKey)
      let hash = Data(Array(normalized).sha3(.keccak256))
      let rawHex = Data(hash.suffix(20)).hexString
      return "0x" + eip55Checksum(rawHex)
    }
  }
}

// MARK: - Base58

enum Base58 {
  private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

  static func encode(_ data: Data) -> String {
    if data.isEmpty { return "" }
    var bytes = Array(data)
    let zeroCount = bytes.prefix { $0 == 0 }.count
    var startAt = zeroCount
    var encoded: [Character] = []

    while startAt < bytes.count {
      var remainder = 0
      for index in startAt..<bytes.count {
        let value = Int(bytes[index]) & 0xFF
        let temp = remainder * 256 + value
        bytes[index] = UInt8(temp / 58)
        remainder = temp % 58
      }
      encoded.append(alphabet[remainder])
      while startAt < bytes.count && bytes[startAt] == 0 {
        startAt += 1
      }
    }

    for _ in 0..<zeroCount {
      encoded.append(alphabet[0])
    }
    return String(encoded.reversed())
  }
}

// MARK: - CurrencyInfoMessage extension

extension CurrencyInfoMessage {
  func copyWith(publicKey: Data? = nil, chainCode: Data? = nil, address: String? = nil) -> CurrencyInfoMessage {
    CurrencyInfoMessage(
      id: id,
      icon: icon,
      name: name,
      networkId: networkId,
      networkName: networkName,
      networkIcon: networkIcon,
      symbol: symbol,
      contractAddress: contractAddress,
      decimalCount: decimalCount,
      amount: amount,
      address: address ?? self.address,
      publicKey: publicKey.map { FlutterStandardTypedData(bytes: $0) } ?? self.publicKey,
      chainCode: chainCode.map { FlutterStandardTypedData(bytes: $0) } ?? self.chainCode,
      isTest: isTest
    )
  }
}

// MARK: - EIP-55 混合大小写校验和

private func eip55Checksum(_ hexNoPrefix: String) -> String {
  let lower = hexNoPrefix.lowercased()
  let hashBytes = Array(lower.utf8).sha3(.keccak256)
  var result = ""
  for (i, c) in lower.enumerated() {
    let nibble = (Int(hashBytes[i / 2]) >> (i % 2 == 0 ? 4 : 0)) & 0xF
    result.append(nibble >= 8 && c.isLetter ? Character(c.uppercased()) : c)
  }
  return result
}
