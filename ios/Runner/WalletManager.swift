import Flutter
import Foundation

// MARK: - NativeWalletState（对应 Android WalletManager.kt）

final class NativeWalletState {
  var lastCardId: String?
  var lastPinSet: Bool = false
  private var currencies: [String: CurrencyInfoMessage] = [:]
  private var masterKeys: [String: KeyMaterial] = [:]

  func replaceCurrencies(_ newCurrencies: [CurrencyInfoMessage]) {
    // 清空前先快照已有的 publicKey/chainCode，避免 loadCurrencyInfoList 把
    // 卡片扫描存入的密钥数据覆盖掉
    let savedKeys: [String: CurrencyInfoMessage] = currencies.values.reduce(into: [:]) { dict, c in
      if c.publicKey != nil { dict[c.id] = c }
    }
    currencies.removeAll()
    for currency in newCurrencies {
      let toStore: CurrencyInfoMessage
      if currency.publicKey == nil, let saved = savedKeys[currency.id] {
        toStore = currency.copyWith(publicKey: saved.publicKey!.data, chainCode: saved.chainCode?.data)
      } else {
        toStore = currency
      }
      currencies[toStore.id] = toStore
      currencies[toStore.networkId] = toStore
    }
  }

  func allCurrencies() -> [CurrencyInfoMessage] {
    var seen = Set<String>()
    return currencies.values.filter { seen.insert($0.id).inserted }
  }

  func findById(_ id: String) -> CurrencyInfoMessage? {
    currencies[id]
  }

  func mergeCurrencies(_ newCurrencies: [CurrencyInfoMessage]) {
    for currency in newCurrencies {
      // 若新数据不含 publicKey/chainCode，保留已有条目的密钥信息（卡片扫描时写入）
      let existing = currencies[currency.id]
      let merged: CurrencyInfoMessage
      if currency.publicKey == nil, let existingKey = existing?.publicKey {
        merged = currency.copyWith(
          publicKey: existingKey.data,
          chainCode: existing?.chainCode?.data
        )
      } else {
        merged = currency
      }
      currencies[merged.id] = merged
      currencies[merged.networkId] = merged
    }
  }

  func removeCurrencies(_ coinIds: [String]) {
    for coinId in coinIds {
      currencies.removeValue(forKey: coinId)
    }
  }

  func findAddress(networkId: String) -> String? {
    currencies[networkId]?.address ?? currencies.values.first(where: { $0.networkId == networkId })?.address
  }

  func updateAddress(networkId: String, address: String) {
    guard let currency = currencies[networkId] ?? currencies.values.first(where: { $0.networkId == networkId }) else { return }
    let updated = currency.copyWith(address: address)
    currencies[currency.id] = updated
    currencies[currency.networkId] = updated
  }

  func findPublicKeyHex(keyword: String) -> String? {
    // 必须限定有 publicKey 的 currency，避免同一 networkId 下 ERC20 token
    // (无 publicKey) 被先迭代到，导致误返回 nil。
    currencies.values.first {
      $0.publicKey != nil && (
        $0.networkId.localizedCaseInsensitiveContains(keyword) ||
        $0.symbol.localizedCaseInsensitiveContains(keyword) ||
        $0.name.localizedCaseInsensitiveContains(keyword)
      )
    }?.publicKey?.data.hexString
  }

  func findBySpec(_ spec: BlockchainSpec) -> CurrencyInfoMessage? {
    currencies.values.first {
      spec.matches($0.networkId) || spec.matches($0.symbol) || spec.matches($0.name)
    }
  }

  func cacheMasterKey(cardId: String, publicKey: Data, chainCode: Data) {
    masterKeys[cardId] = KeyMaterial(publicKey: publicKey, chainCode: chainCode)
  }

  // MARK: - UserDefaults 持久化

  private static let storageKeyPrefix = "chip_wallet_currencies_"

  func saveCurrencies(cardId: String, currencies: [CurrencyInfoMessage]) {
    let key = Self.storageKeyPrefix + cardId
    let encoded = currencies.compactMap { currency -> [String: Any]? in
      var dict: [String: Any] = [
        "id": currency.id,
        "name": currency.name,
        "networkId": currency.networkId,
        "networkName": currency.networkName ?? "",
        "networkIcon": currency.networkIcon ?? "",
        "symbol": currency.symbol,
        "icon": currency.icon ?? "",
        "isTest": currency.isTest ?? 0,
      ]
      if let addr = currency.address { dict["address"] = addr }
      if let ca = currency.contractAddress { dict["contractAddress"] = ca }
      if let dc = currency.decimalCount { dict["decimalCount"] = dc }
      if let pk = currency.publicKey { dict["publicKey"] = pk.data.base64EncodedString() }
      if let cc = currency.chainCode { dict["chainCode"] = cc.data.base64EncodedString() }
      return dict
    }
    UserDefaults.standard.set(encoded, forKey: key)
  }

  func loadCurrencies(cardId: String) -> [CurrencyInfoMessage] {
    let key = Self.storageKeyPrefix + cardId
    guard let arr = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return [] }
    return arr.compactMap { dict -> CurrencyInfoMessage? in
      guard let id = dict["id"] as? String,
            let name = dict["name"] as? String,
            let networkId = dict["networkId"] as? String,
            let symbol = dict["symbol"] as? String else { return nil }
      let msg = CurrencyInfoMessage(
        id: id,
        icon: dict["icon"] as? String ?? "",
        name: name,
        networkId: networkId,
        networkName: dict["networkName"] as? String,
        networkIcon: dict["networkIcon"] as? String ?? "",
        symbol: symbol,
        contractAddress: dict["contractAddress"] as? String,
        decimalCount: dict["decimalCount"] as? Int64,
        amount: nil,
        address: dict["address"] as? String,
        publicKey: (dict["publicKey"] as? String).flatMap { Data(base64Encoded: $0) }.map { FlutterStandardTypedData(bytes: $0) },
        chainCode: (dict["chainCode"] as? String).flatMap { Data(base64Encoded: $0) }.map { FlutterStandardTypedData(bytes: $0) },
        isTest: dict["isTest"] as? Int64
      )
      return msg
    }
  }

  func findContractAddress(symbol: String, networkId: String) -> String? {
    let sym = symbol.lowercased()
    let net = networkId.lowercased()
    return currencies.values.first {
      ($0.symbol.lowercased() == sym || $0.id.lowercased() == sym) &&
      $0.networkId.lowercased() == net &&
      ($0.contractAddress.map { !$0.isEmpty } ?? false)
    }?.contractAddress
  }

  func findDecimals(symbol: String, networkId: String) -> Int {
    let sym = symbol.lowercased()
    let net = networkId.lowercased()
    return currencies.values.first {
      ($0.symbol.lowercased() == sym || $0.id.lowercased() == sym) &&
      $0.networkId.lowercased() == net
    }.map { Int($0.decimalCount ?? 18) } ?? 18
  }
}

// MARK: - ChipWalletManager（对应 Android ChipWalletManager）

final class ChipWalletManager {
  let spec: BlockchainSpec
  let address: String
  let publicKey: Data
  let chainCode: Data
  let isTest: Bool
  var balance: String?

  init(spec: BlockchainSpec, address: String, publicKey: Data, chainCode: Data, isTest: Bool) {
    self.spec      = spec
    self.address   = address
    self.publicKey = publicKey
    self.chainCode = chainCode
    self.isTest    = isTest
  }
}

// MARK: - WalletManagerRegistry（对应 Android WalletManagerRegistry）

final class WalletManagerRegistry {
  private var managers: [String: ChipWalletManager] = [:]

  /// 通过 blockchain 字符串（如 "btc"、"ETH"）查找
  func getWalletManager(_ blockchain: String) -> ChipWalletManager? {
    managers[blockchain.lowercased()]
  }

  func getWalletManagerBySpec(_ spec: BlockchainSpec) -> ChipWalletManager? {
    managers.values.first { $0.spec == spec }
  }

  func addWalletManagers(_ newManagers: [ChipWalletManager]) {
    for manager in newManagers {
      managers[manager.spec.id.lowercased()] = manager
    }
  }

  func clearWalletManagers() {
    managers.removeAll()
  }

  /// 根据 CurrencyInfoMessage 列表构建 ChipWalletManager 列表
  func buildFrom(_ currencies: [CurrencyInfoMessage]) -> [ChipWalletManager] {
    currencies.compactMap { currency -> ChipWalletManager? in
      let spec     = BlockchainSpec.fromCurrency(currency)
      let isTest   = (currency.isTest ?? 0) != 0
      guard let address = currency.address, !address.isEmpty else { return nil }
      guard let pubKeyData = currency.publicKey?.data, !pubKeyData.isEmpty else { return nil }
      let chainCodeData = currency.chainCode?.data ?? Data()
      return ChipWalletManager(
        spec:      spec,
        address:   address,
        publicKey: pubKeyData,
        chainCode: chainCodeData,
        isTest:    isTest
      )
    }
  }

  func all() -> [ChipWalletManager] { Array(managers.values) }
}
