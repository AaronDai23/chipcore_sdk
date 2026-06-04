import Foundation

// MARK: - ChainClient（对应 Android ChainClient.kt）

enum ChainClient {
  private static let btcMainApi = "https://mempool.space/api"
  private static let btcTestApi = "https://mempool.space/testnet4/api"
  private static let ethMainRpc = "https://ethereum.publicnode.com"
  private static let ethTestRpc = "https://ethereum-sepolia.publicnode.com"
  private static let bscMainRpc = "https://bsc-dataseed.bnbchain.org"
  private static let bscTestRpc = "https://bsc-testnet-dataseed.bnbchain.org"
  private static let polygonMainRpc = "https://polygon-rpc.com"
  private static let polygonTestRpc = "https://rpc-amoy.polygon.technology"
  // RTAP / RTBP：ERC20 合约部署在 Ethereum Sepolia 测试网，强制使用 Sepolia RPC
  private static let sepoliaRpc = "https://ethereum-sepolia.publicnode.com"
  private static let sepoliaSymbols: Set<String> = ["RTAP", "RTBP"]
  private static let tronMainApi = "https://api.trongrid.io"

  static func ethRpc(isTest: Bool) -> String { isTest ? ethTestRpc : ethMainRpc }

  /// 根据 networkId 返回对应的 EVM RPC 端点
  static func evmRpc(networkId: String, isTest: Bool) -> String {
    let net = networkId.lowercased()
    if net.contains("binance") || net.contains("bsc") || net.contains("bnb") {
      return isTest ? bscTestRpc : bscMainRpc
    }
    if net.contains("polygon") || net.contains("matic") || net.contains("pol") {
      return isTest ? polygonTestRpc : polygonMainRpc
    }
    return isTest ? ethTestRpc : ethMainRpc
  }

  /// 按 symbol + networkId 联合路由。
  /// 对于后端 testnet 字段配置错误的代币（如 RTAP/RTBP 返回 testnet=false 但实际在 Sepolia），直接按 symbol 强制选正确 RPC。
  static func evmRpcBySymbol(networkId: String, symbol: String, isTest: Bool) -> String {
    if sepoliaSymbols.contains(symbol.uppercased()) { return sepoliaRpc }
    return evmRpc(networkId: networkId, isTest: isTest)
  }

  static func fetchBtcFees(isTest: Bool) throws -> [FeeResponse] {
    let api = isTest ? btcTestApi : btcMainApi
    let json = try httpGet("\(api)/v1/fees/recommended")
    guard let obj = json as? [String: Any] else { throw urlError("bad fees json") }
    let low      = (obj["economyFee"]  as? NSNumber)?.uint64Value ?? 1
    let normal   = (obj["halfHourFee"] as? NSNumber)?.uint64Value ?? 2
    let priority = (obj["fastestFee"]  as? NSNumber)?.uint64Value ?? 3
    return [
      FeeResponse(type: .low,      value: String(low),      gasLimit: nil, gasPrice: nil),
      FeeResponse(type: .normal,   value: String(normal),   gasLimit: nil, gasPrice: nil),
      FeeResponse(type: .priority, value: String(priority), gasLimit: nil, gasPrice: nil),
    ]
  }

  static func fetchBtcFeeRate(isTest: Bool) throws -> UInt64 {
    let api = isTest ? btcTestApi : btcMainApi
    let json = try httpGet("\(api)/v1/fees/recommended")
    guard let obj = json as? [String: Any] else { throw urlError("bad fees json") }
    return (obj["halfHourFee"] as? NSNumber)?.uint64Value ?? 2
  }

  static func fetchEthFees(isTest: Bool) throws -> [FeeResponse] {
    return try fetchEVMNativeFees(rpc: ethRpc(isTest: isTest))
  }

  static func ethGasPrice(rpc: String) throws -> BigUInt {
    let result = try rpcCall(endpoint: rpc, method: "eth_gasPrice", params: "[]")
    let hex = result.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).dropFirst(2)
    return BigUInt(String(hex), radix: 16) ?? BigUInt(20_000_000_000)
  }

  static func ethNonce(rpc: String, address: String) throws -> BigUInt {
    let result = try rpcCall(endpoint: rpc, method: "eth_getTransactionCount", params: "[\"\(address)\",\"pending\"]")
    let hex = result.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).dropFirst(2)
    return BigUInt(String(hex), radix: 16) ?? .zero
  }

  static func ethChainId(rpc: String) throws -> BigUInt {
    let result = try rpcCall(endpoint: rpc, method: "eth_chainId", params: "[]")
    let hex = result.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).dropFirst(2)
    return BigUInt(String(hex), radix: 16) ?? BigUInt(1)
  }

  static func ethBroadcast(rawTx: Data, rpc: String) throws -> String {
    let hex = "0x" + rawTx.hexString
    let result = try rpcCall(endpoint: rpc, method: "eth_sendRawTransaction", params: "[\"\(hex)\"]")
    return result.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  }

  static func fetchBtcUtxos(address: String, isTest: Bool) throws -> [BtcUtxo] {
    let api = isTest ? btcTestApi : btcMainApi
    guard let arr = try httpGet("\(api)/address/\(address)/utxo") as? [[String: Any]] else {
      return []
    }
    return arr.compactMap { obj -> BtcUtxo? in
      guard let txid = obj["txid"] as? String,
            let vout = obj["vout"] as? Int,
            let value = obj["value"] as? Int64 else { return nil }
      let status = obj["status"] as? [String: Any]
      let confirmed = status?["confirmed"] as? Bool ?? false
      guard confirmed else { return nil }
      return BtcUtxo(txid: txid, vout: vout, value: UInt64(value))
    }
  }

  static func btcBroadcast(rawTx: Data, isTest: Bool) throws -> String {
    let api = isTest ? btcTestApi : btcMainApi
    let hex = rawTx.hexString
    return try httpPost(url: "\(api)/tx", body: hex, contentType: "text/plain") as? String ?? ""
  }

  // MARK: - 余额查询

  static func fetchBtcBalance(address: String, isTest: Bool) throws -> String {
    let api = isTest ? btcTestApi : btcMainApi
    guard let arr = try httpGet("\(api)/address/\(address)/utxo") as? [[String: Any]] else {
      return "0"
    }
    let satoshis = arr.reduce(Int64(0)) { acc, obj in
      let status = obj["status"] as? [String: Any]
      let confirmed = status?["confirmed"] as? Bool ?? false
      guard confirmed, let value = obj["value"] as? Int64 else { return acc }
      return acc + value
    }
    return decimalString(satoshis, exponentiation: -8)
  }

  static func fetchEthBalance(address: String, isTest: Bool) throws -> String {
    return try fetchEthBalance(address: address, rpc: ethRpc(isTest: isTest))
  }

  static func fetchEthBalance(address: String, rpc: String) throws -> String {
    let result = try rpcCall(endpoint: rpc, method: "eth_getBalance", params: "[\"\(address)\",\"latest\"]")
    let hex = result.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).dropFirst(2)
    let wei = BigUInt(String(hex), radix: 16) ?? .zero
    return EthEncoder.weiToEthString(wei)
  }

  static func fetchERC20Balance(address: String, contractAddress: String, rpc: String, decimals: Int) throws -> String {
    let callData = EthEncoder.encodeERC20BalanceOf(address: address)
    let dataHex = "0x" + callData.hexString
    let params = "[{\"to\":\"\(contractAddress)\",\"data\":\"\(dataHex)\"},\"latest\"]"
    let result = try rpcCall(endpoint: rpc, method: "eth_call", params: params)
    let hex = result.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).dropFirst(2)
    let raw = BigUInt(String(hex), radix: 16) ?? .zero
    return EthEncoder.formatTokenAmount(raw, decimals: decimals)
  }

  static func fetchTrxBalance(address: String) throws -> String {
    guard let json = try httpGet("\(tronMainApi)/v1/accounts/\(address)") as? [String: Any],
          let dataArr = json["data"] as? [[String: Any]] else {
      return "0"
    }
    let sunBalance = dataArr.first?["balance"] as? Int64 ?? 0
    return decimalString(sunBalance, exponentiation: -6)
  }

  static func fetchTRC20Balance(address: String, contractAddress: String, isTest: Bool, decimals: Int = 18) throws -> String {
    let queryHost = isTest ? "https://nile.trongrid.io" : tronMainApi
    let body = """
    {"owner_address":"\(address)",
     "contract_address":"\(contractAddress)",
     "function_selector":"balanceOf(address)",
     "parameter":"\(EthEncoder.encodeTronBalanceOfParam(address: address))",
     "call_value":0,"fee_limit":1000000}
    """
    guard let json = try httpPost(
      url: "\(queryHost)/wallet/triggerconstantcontract",
      body: body,
      contentType: "application/json"
    ) as? [String: Any],
          let resultArr = json["constant_result"] as? [String],
          let hexStr = resultArr.first else {
      return "0"
    }
    let raw = BigUInt(hexStr, radix: 16) ?? .zero
    return EthEncoder.formatTokenAmount(raw, decimals: decimals)
  }

  static func fetchEVMNativeFees(rpc: String) throws -> [FeeResponse] {
    let gasPrice = try ethGasPrice(rpc: rpc)
    let gasLimit: BigUInt = 100000
    func weiForFactor(_ f: UInt64) -> String {
      let gp = gasPrice * BigUInt(f) / BigUInt(100)
      return EthEncoder.weiToEthString(gp * gasLimit)
    }
    func gpHex(_ f: UInt64) -> String { "0x" + (gasPrice * BigUInt(f) / BigUInt(100)).toHexString() }
    return [
      FeeResponse(type: .low,      value: weiForFactor(100), gasLimit: "100000", gasPrice: gpHex(100)),
      FeeResponse(type: .normal,   value: weiForFactor(120), gasLimit: "100000", gasPrice: gpHex(120)),
      FeeResponse(type: .priority, value: weiForFactor(150), gasLimit: "100000", gasPrice: gpHex(150)),
    ]
  }

  static func fetchEVMTokenFees(rpc: String, contractAddress: String, fromAddress: String, toAddress: String) throws -> [FeeResponse] {
    let gasPrice = try ethGasPrice(rpc: rpc)
    let sampleData = EthEncoder.encodeERC20Transfer(to: toAddress, amount: BigUInt(1))
    let dataHex = "0x" + sampleData.hexString
    let gasLimit: BigUInt
    do {
      let estimatedHex = try rpcCall(
        endpoint: rpc,
        method: "eth_estimateGas",
        params: "[{\"from\":\"\(fromAddress)\",\"to\":\"\(contractAddress)\",\"data\":\"\(dataHex)\"}]"
      )
      let hex = estimatedHex.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).dropFirst(2)
      gasLimit = (BigUInt(String(hex), radix: 16) ?? 80000) * BigUInt(12) / BigUInt(10)
    } catch {
      gasLimit = 80000
    }
    let gasLimitStr = gasLimit.description
    func weiForFactor(_ f: UInt64) -> String {
      let gp = gasPrice * BigUInt(f) / BigUInt(100)
      return EthEncoder.weiToEthString(gp * gasLimit)
    }
    func gpHex(_ f: UInt64) -> String { "0x" + (gasPrice * BigUInt(f) / BigUInt(100)).toHexString() }
    return [
      FeeResponse(type: .low,      value: weiForFactor(100), gasLimit: gasLimitStr, gasPrice: gpHex(100)),
      FeeResponse(type: .normal,   value: weiForFactor(120), gasLimit: gasLimitStr, gasPrice: gpHex(120)),
      FeeResponse(type: .priority, value: weiForFactor(150), gasLimit: gasLimitStr, gasPrice: gpHex(150)),
    ]
  }

  static func fetchTrxFees() -> [FeeResponse] {
    [
      FeeResponse(type: .low,      value: "1", gasLimit: nil, gasPrice: nil),
      FeeResponse(type: .normal,   value: "1", gasLimit: nil, gasPrice: nil),
      FeeResponse(type: .priority, value: "3", gasLimit: nil, gasPrice: nil),
    ]
  }

  static func fetchDogeBalance(address: String, isTest: Bool) throws -> String {
    let base = dogeCypherBase(isTest: isTest)
    guard let json = try httpGet("\(base)/addrs/\(address)/balance") as? [String: Any] else {
      return "0"
    }
    let satoshis = json["final_balance"] as? Int64 ?? json["balance"] as? Int64 ?? 0
    return decimalString(satoshis, exponentiation: -8)
  }

  static func fetchDogeFees(isTest: Bool) throws -> [FeeResponse] {
    let base = dogeCypherBase(isTest: isTest)
    guard let json = try httpGet("\(base)") as? [String: Any] else {
      return defaultDogeFees()
    }
    let lowPerKb  = json["low_fee_per_kb"]    as? Int64 ?? 1_000_000
    let medPerKb  = json["medium_fee_per_kb"] as? Int64 ?? 1_000_000
    let highPerKb = json["high_fee_per_kb"]   as? Int64 ?? 3_000_000
    let txBytes: Int64 = 226
    func satPerByte(_ perKb: Int64) -> Int64 { max(1, (perKb + 999) / 1000) }
    func totalFee(_ satPB: Int64) -> Int64 { satPB * txBytes }
    func dogeStr(_ sat: Int64) -> String { decimalString(sat, exponentiation: -8) }
    let lowSatPB  = satPerByte(lowPerKb)
    let medSatPB  = satPerByte(medPerKb)
    let highSatPB = satPerByte(highPerKb)
    return [
      FeeResponse(type: .low,      value: dogeStr(totalFee(lowSatPB)),  gasLimit: nil, gasPrice: "\(lowSatPB)"),
      FeeResponse(type: .normal,   value: dogeStr(totalFee(medSatPB)),  gasLimit: nil, gasPrice: "\(medSatPB)"),
      FeeResponse(type: .priority, value: dogeStr(totalFee(highSatPB)), gasLimit: nil, gasPrice: "\(highSatPB)"),
    ]
  }

  private static func defaultDogeFees() -> [FeeResponse] {
    // fallback: 1 DOGE/kB \u2248 1000 sat/byte, 226 bytes per tx
    let satPB: Int64 = 1000
    let fee = decimalString(satPB * 226, exponentiation: -8)
    let gpStr = "\(satPB)"
    return [
      FeeResponse(type: .low,      value: fee, gasLimit: nil, gasPrice: gpStr),
      FeeResponse(type: .normal,   value: fee, gasLimit: nil, gasPrice: gpStr),
      FeeResponse(type: .priority, value: fee, gasLimit: nil, gasPrice: gpStr),
    ]
  }

  static func fetchDogeUtxos(address: String, isTest: Bool) throws -> [DogeUtxo] {
    let base = dogeCypherBase(isTest: isTest)
    guard let json = try httpGet("\(base)/addrs/\(address)?unspentOnly=true&includeScript=true") as? [String: Any],
          let txrefs = json["txrefs"] as? [[String: Any]] else {
      return []
    }
    return txrefs.compactMap { ref -> DogeUtxo? in
      guard let txid  = ref["tx_hash"] as? String,
            let vout  = ref["tx_output_n"] as? Int,
            let value = ref["value"] as? Int64 else { return nil }
      return DogeUtxo(txid: txid, vout: vout, value: value)
    }
  }

  static func dogeBroadcast(rawTx: Data, isTest: Bool) throws -> String {
    let base = dogeCypherBase(isTest: isTest)
    let hex = rawTx.hexString
    let body = "{\"tx\":\"\(hex)\"}"
    guard let json = try httpPost(url: "\(base)/txs/push", body: body, contentType: "application/json") as? [String: Any],
          let txHash = json["tx"] as? [String: Any],
          let txid   = txHash["hash"] as? String else {
      throw PigeonError(code: "broadcast-error", message: "DOGE broadcast failed: no txid in response", details: nil)
    }
    return txid
  }

  private static func dogeCypherBase(isTest: Bool) -> String {
    let net = isTest ? "doge/test3" : "doge/main"
    return "https://api.blockcypher.com/v1/\(net)"
  }

  // MARK: - Transaction history

  static func fetchBtcTxHistory(address: String, isTest: Bool) throws -> [TransactionsHistory] {
    let base = isTest ? btcTestApi : btcMainApi
    guard let arr = try httpGet("\(base)/address/\(address)/txs") as? [[String: Any]] else { return [] }
    return arr.compactMap { tx -> TransactionsHistory? in
      let vin  = tx["vin"]  as? [[String: Any]] ?? []
      let vout = tx["vout"] as? [[String: Any]] ?? []
      let isOutgoing = vin.contains { ($0["prevout"] as? [String: Any])?["scriptpubkey_address"] as? String == address }
      var satAmount: Int64 = 0
      for out in vout {
        let outAddr = (out["scriptpubkey_address"] as? String) ?? ""
        let outVal  = out["value"] as? Int64 ?? 0
        if isOutgoing { if outAddr != address { satAmount += outVal } }
        else          { if outAddr == address { satAmount += outVal } }
      }
      let status  = tx["status"] as? [String: Any]
      let confirmed = status?["confirmed"] as? Bool ?? false
      let blockTime = status?["block_time"] as? Int64 ?? 0
      return TransactionsHistory(
        time:      blockTime,
        direction: isOutgoing ? 0 : 1,
        status:    confirmed  ? 1 : 0,
        type:      0,
        value:     Double(satAmount) / 1e8,
        decimals:  8
      )
    }
  }

  static func fetchEthTxHistory(address: String, isTest: Bool) throws -> [TransactionsHistory] {
    let url = "https://api.blockcypher.com/v1/eth/main/addrs/\(address)/full?limit=25"
    guard let json = try httpGet(url) as? [String: Any],
          let txs  = json["txs"] as? [[String: Any]] else { return [] }
    let addrLower = address.lowercased()
    return txs.compactMap { tx -> TransactionsHistory? in
      let inputs  = tx["inputs"]  as? [[String: Any]] ?? []
      let outputs = tx["outputs"] as? [[String: Any]] ?? []
      let fromAddr = ((inputs.first?["addresses"] as? [String])?.first) ?? ""
      var valueWei: Double = 0
      for out in outputs {
        let addrs = out["addresses"] as? [String] ?? []
        if (addrs.first?.lowercased() ?? "") != addrLower {
          let weiStr = out["value"] as? String ?? "\(out["value"] as? Int64 ?? 0)"
          valueWei = Double(weiStr) ?? 0
          break
        }
      }
      if valueWei == 0, let first = outputs.first {
        let weiStr = first["value"] as? String ?? "\(first["value"] as? Int64 ?? 0)"
        valueWei = Double(weiStr) ?? 0
      }
      let isOutgoing   = fromAddr.lowercased() == addrLower
      let confirmedStr = tx["confirmed"] as? String ?? ""
      let epochSec     = iso8601ToEpoch(confirmedStr)
      let confirmations = tx["confirmations"] as? Int64 ?? 0
      return TransactionsHistory(
        time:      epochSec,
        direction: isOutgoing ? 0 : 1,
        status:    confirmations > 0 ? 1 : 0,
        type:      0,
        value:     valueWei / 1e18,
        decimals:  18
      )
    }
  }

  static func fetchTrxTxHistory(address: String) throws -> [TransactionsHistory] {
    let url = "\(tronMainApi)/v1/accounts/\(address)/transactions?limit=25&only_confirmed=false&visible=true"
    guard let json = try httpGet(url) as? [String: Any],
          let data = json["data"] as? [[String: Any]] else { return [] }
    return data.compactMap { tx -> TransactionsHistory? in
      guard let rawData   = tx["raw_data"]  as? [String: Any],
            let contracts = rawData["contract"] as? [[String: Any]],
            let contract  = contracts.first,
            (contract["type"] as? String) == "TransferContract" else { return nil }
      guard let param = contract["parameter"] as? [String: Any],
            let value = param["value"] as? [String: Any] else { return nil }
      let ownerAddr = value["owner_address"] as? String ?? ""
      let amountSun = value["amount"] as? Int64 ?? 0
      let blockTs   = (tx["block_timestamp"] as? Int64 ?? 0) / 1000
      let isOutgoing = ownerAddr == address
      let ret = (tx["ret"] as? [[String: Any]])?.first
      let contractRet = ret?["contractRet"] as? String ?? ""
      let statusCode: Int64 = contractRet == "SUCCESS" ? 1 : (contractRet.isEmpty ? 0 : -1)
      return TransactionsHistory(
        time:      blockTs,
        direction: isOutgoing ? 0 : 1,
        status:    statusCode,
        type:      0,
        value:     Double(amountSun) / 1e6,
        decimals:  6
      )
    }
  }

  static func fetchDogeTxHistory(address: String, isTest: Bool) throws -> [TransactionsHistory] {
    let base = dogeCypherBase(isTest: isTest)
    guard let json = try httpGet("\(base)/addrs/\(address)/full?limit=25") as? [String: Any],
          let txs  = json["txs"] as? [[String: Any]] else { return [] }
    return txs.compactMap { tx -> TransactionsHistory? in
      let inputs  = tx["inputs"]  as? [[String: Any]] ?? []
      let outputs = tx["outputs"] as? [[String: Any]] ?? []
      let fromAddr = ((inputs.first?["addresses"] as? [String])?.first) ?? ""
      let isOutgoing = fromAddr == address
      var satAmount: Int64 = 0
      for out in outputs {
        let outAddr = (out["addresses"] as? [String])?.first ?? ""
        let outVal  = out["value"] as? Int64 ?? 0
        if isOutgoing { if outAddr != address { satAmount += outVal } }
        else          { if outAddr == address { satAmount += outVal } }
      }
      let confirmedStr = tx["confirmed"] as? String ?? (tx["received"] as? String ?? "")
      let isConfirmed  = (tx["confirmed"] as? String) != nil
      let epochSec     = iso8601ToEpoch(confirmedStr)
      return TransactionsHistory(
        time:      epochSec,
        direction: isOutgoing ? 0 : 1,
        status:    isConfirmed ? 1 : 0,
        type:      0,
        value:     Double(satAmount) / 1e8,
        decimals:  8
      )
    }
  }

  private static func iso8601ToEpoch(_ str: String) -> Int64 {
    guard !str.isEmpty else { return 0 }
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fmt.date(from: str) { return Int64(date.timeIntervalSince1970) }
    fmt.formatOptions = [.withInternetDateTime]
    if let date = fmt.date(from: str) { return Int64(date.timeIntervalSince1970) }
    return 0
  }

  // MARK: - Private helpers

  private static func decimalString(_ raw: Int64, exponentiation exp: Int) -> String {
    let divisor = Foundation.Decimal(sign: .plus, exponent: exp, significand: 1)
    let value = Foundation.Decimal(raw) * divisor
    var result = value
    var rounded = Foundation.Decimal()
    NSDecimalRound(&rounded, &result, 8, .plain)
    return NSDecimalNumber(decimal: rounded).stringValue
  }

  private static func rpcCall(endpoint: String, method: String, params: String) throws -> String {
    let body = "{\"jsonrpc\":\"2.0\",\"method\":\"\(method)\",\"params\":\(params),\"id\":1}"
    guard let json = try httpPost(url: endpoint, body: body, contentType: "application/json") as? [String: Any] else {
      throw urlError("RPC response invalid")
    }
    if let err = json["error"] as? [String: Any] {
      throw urlError(err["message"] as? String ?? "RPC error")
    }
    let result = json["result"]
    if let str = result as? String { return str }
    if let num = result as? NSNumber { return num.stringValue }
    throw urlError("RPC result missing")
  }

  @discardableResult
  private static func httpGet(_ urlStr: String) throws -> Any {
    let sem = DispatchSemaphore(value: 0)
    var resultData: Data?
    var resultError: Error?
    let url = URL(string: urlStr)!
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: req) { data, _, error in
      resultData = data; resultError = error; sem.signal()
    }.resume()
    sem.wait()
    if let error = resultError { throw error }
    guard let data = resultData else { throw urlError("no data") }
    return try JSONSerialization.jsonObject(with: data)
  }

  @discardableResult
  private static func httpPost(url urlStr: String, body: String, contentType: String) throws -> Any {
    let sem = DispatchSemaphore(value: 0)
    var resultData: Data?
    var resultError: Error?
    var resultCode: Int = 0
    let url = URL(string: urlStr)!
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.httpMethod = "POST"
    req.setValue(contentType, forHTTPHeaderField: "Content-Type")
    req.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")
    req.httpBody = body.data(using: .utf8)
    URLSession.shared.dataTask(with: req) { data, response, error in
      resultData = data
      resultError = error
      resultCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      sem.signal()
    }.resume()
    sem.wait()
    if let error = resultError { throw error }
    guard let data = resultData else { throw urlError("no data") }
    if resultCode < 200 || resultCode >= 300 {
      throw urlError("HTTP \(resultCode): \(String(data: data, encoding: .utf8) ?? "")")
    }
    if contentType == "text/plain" {
      return String(data: data, encoding: .utf8) ?? ""
    }
    return try JSONSerialization.jsonObject(with: data)
  }

  private static func urlError(_ msg: String) -> Error {
    NSError(domain: "ChainClient", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
  }

  /// POST JSON body string to a Tron node and return parsed JSON dict.
  static func trxHttpPost(_ urlStr: String, body: String) throws -> [String: Any]? {
    return try httpPost(url: urlStr, body: body, contentType: "application/json") as? [String: Any]
  }

  /// POST raw Data body to a Tron node (for broadcast) and return parsed JSON dict.
  static func trxHttpPostData(_ urlStr: String, data: Data) throws -> [String: Any]? {
    let sem = DispatchSemaphore(value: 0)
    var resultData: Data?
    var resultError: Error?
    let url = URL(string: urlStr)!
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.httpBody = data
    URLSession.shared.dataTask(with: req) { d, _, e in resultData = d; resultError = e; sem.signal() }.resume()
    sem.wait()
    if let error = resultError { throw error }
    guard let respData = resultData else { throw urlError("no data") }
    return try JSONSerialization.jsonObject(with: respData) as? [String: Any]
  }

  // MARK: - ERC20 token transaction history

  /// Fetch ERC20 token transfer history for a given wallet address via eth_getLogs.
  /// Makes two log queries (outgoing + incoming) and fetches block timestamps for each unique block.
  static func fetchErc20TxHistory(
    address: String,
    contractAddress: String,
    rpc: String,
    decimals: Int
  ) throws -> [TransactionsHistory] {
    // keccak256("Transfer(address,address,uint256)")
    let transferSig = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    let addrLower   = address.lowercased()
    // EVM topic padding: 12 zero bytes + 20-byte address
    let paddedAddr  = "0x000000000000000000000000" + addrLower.dropFirst(2)

    // Outgoing transfers (from == address)
    let outLogs = try ethGetLogs(rpc: rpc, contract: contractAddress,
                                  topics: [transferSig, paddedAddr, nil])
    // Incoming transfers (to == address)
    let inLogs  = try ethGetLogs(rpc: rpc, contract: contractAddress,
                                  topics: [transferSig, nil, paddedAddr])

    // Collect unique block numbers to batch-fetch timestamps
    var seenBlocks = Set<String>()
    for log in outLogs + inLogs {
      if let bn = log["blockNumber"] as? String { seenBlocks.insert(bn) }
    }
    var blockTimestamps: [String: Int64] = [:]
    for bn in seenBlocks {
      blockTimestamps[bn] = (try? ethGetBlockTimestamp(rpc: rpc, blockHex: bn)) ?? 0
    }

    let divisor = pow(10.0, Double(decimals))

    var all: [(log: [String: Any], direction: Int64)] =
      outLogs.map { ($0, 0) } + inLogs.map { ($0, 1) }

    // Sort descending by block number (most recent first)
    all.sort {
      erc20HexToUInt64($0.log["blockNumber"] as? String ?? "0x0") >
      erc20HexToUInt64($1.log["blockNumber"] as? String ?? "0x0")
    }

    return all.compactMap { log, dir -> TransactionsHistory? in
      let blockHex = log["blockNumber"] as? String ?? ""
      let time     = blockTimestamps[blockHex] ?? 0
      let dataHex  = log["data"] as? String ?? "0x"
      let rawStr   = dataHex.hasPrefix("0x") ? String(dataHex.dropFirst(2)) : dataHex
      let amount   = erc20HexBigIntToDouble(rawStr) / divisor
      return TransactionsHistory(
        time:      time,
        direction: dir,
        status:    1, // Logs are always from confirmed blocks
        type:      0,
        value:     amount,
        decimals:  Int64(decimals)
      )
    }
  }

  /// Call eth_getLogs and return the array of log objects.
  private static func ethGetLogs(
    rpc: String, contract: String, topics: [String?]
  ) throws -> [[String: Any]] {
    let topicsJson = "[" + topics.map { t -> String in
      guard let t = t else { return "null" }
      return "\"\(t)\""
    }.joined(separator: ",") + "]"
    let params = "[{\"address\":\"\(contract)\",\"fromBlock\":\"earliest\",\"toBlock\":\"latest\",\"topics\":\(topicsJson)}]"
    let body   = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getLogs\",\"params\":\(params),\"id\":1}"
    guard let json = try httpPost(url: rpc, body: body, contentType: "application/json") as? [String: Any] else {
      throw urlError("eth_getLogs: invalid response")
    }
    if let err = json["error"] as? [String: Any] {
      throw urlError(err["message"] as? String ?? "eth_getLogs error")
    }
    return json["result"] as? [[String: Any]] ?? []
  }

  /// Fetch the Unix timestamp (seconds) of a block by its hex block number.
  private static func ethGetBlockTimestamp(rpc: String, blockHex: String) throws -> Int64 {
    let params = "[\"\(blockHex)\",false]"
    let body   = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":\(params),\"id\":1}"
    guard let json = try httpPost(url: rpc, body: body, contentType: "application/json") as? [String: Any],
          let block = json["result"] as? [String: Any],
          let tsHex = block["timestamp"] as? String else { return 0 }
    return Int64(bitPattern: erc20HexToUInt64(tsHex))
  }

  /// Parse a hex string (no 0x prefix) representing a 256-bit unsigned integer into Double.
  /// Precision is exact for values ≤ 2^53; larger values lose fractional precision
  /// but display-level accuracy is preserved (sufficient for token amounts).
  private static func erc20HexBigIntToDouble(_ hex: String) -> Double {
    var value: Double = 0
    for c in hex.lowercased() {
      guard let nibble = Int(String(c), radix: 16) else { break }
      value = value * 16.0 + Double(nibble)
    }
    return value
  }

  private static func erc20HexToUInt64(_ hex: String) -> UInt64 {
    let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
    return UInt64(clean, radix: 16) ?? 0
  }
}
