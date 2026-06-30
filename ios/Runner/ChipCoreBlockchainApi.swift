import CommonCrypto
import CoreNFC
import CryptoSwift
import Flutter
import Foundation

final class ChipCoreBlockchainApi: NSObject, BlockchainApi {
  private let sessionManager = IOSIso7816SessionManager()
  private let state = NativeWalletState()
  private var walletManagerRegistry = WalletManagerRegistry()
  private let flutterClientApi: FlutterClientApi

  init(binaryMessenger: FlutterBinaryMessenger) {
    self.flutterClientApi = FlutterClientApi(binaryMessenger: binaryMessenger)
  }

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    BlockchainApiSetup.setUp(binaryMessenger: binaryMessenger, api: ChipCoreBlockchainApi(binaryMessenger: binaryMessenger))
  }

  func scanCardWithCommand(sendCommandMessage: SendCommandMessage, completion: @escaping (Result<CommandResponse, Error>) -> Void) {
    let command    = sendCommandMessage.command?.data
    let checkLock  = sendCommandMessage.checkLock ?? false
    let checkPwd   = sendCommandMessage.checkPwd  ?? false
    let ndefLink   = sendCommandMessage.ndefLink.flatMap { $0.isEmpty ? nil : $0 }
    let needSyncUid = sendCommandMessage.needSyscUid ?? false
    let aid = sendCommandMessage.appletId?.data ?? HdWalletApdu.hdWalletAid

    sessionManager.withSession(appletId: aid, operation: { channel, finish in
      let client = HdWalletCardClient(channel: channel)

      // 1. 先读取卡状态（不加密）
      client.getStatus { statusResult in
        switch statusResult {
        case .failure(let error):
          finish(.failure(error))
        case .success(let status):
          // ── UID 一致性校验：有 command 时，确认当前卡片与缓存 UID 一致 ──
          let currentCardId = channel.cardId
          if command != nil {
            let cachedId = self.state.lastCardId
            if let cached = cachedId, !cached.isEmpty,
               cached.lowercased() != currentCardId.lowercased() {
              finish(.failure(PigeonError(
                code: "uid-mismatch",
                message: "Card UID mismatch. Expected \(cached) but scanned \(currentCardId). Please use the same card as before.",
                details: nil
              )))
              return
            }
          }
          self.state.lastCardId = currentCardId

          // checkLock 守卫
          if checkLock && status.isLock {
            finish(.failure(PigeonError(code: "card-locked", message: "DeviceLockError:\(channel.cardId)", details: nil)))
            return
          }
          // checkPwd 守卫
          if checkPwd && status.isExpired {
            finish(.failure(PigeonError(code: "card-expired", message: "Card has expired. PUK retry limit reached.", details: nil)))
            return
          }

          // 2. NDEF 写入（可选）
          func afterNdef(_ ndefResult: String?) {
            // 2.5. AAR 写入（INS=0x67，去重：仅当卡片当前值与目标不同时才写）
            func afterAar() {
              // 3. UID 同步写入（可选）
              func afterUid() {
                // 4. 执行主命令（可选）
                if let command {
                  client.sendCommand(command) { cmdResult in
                    switch cmdResult {
                    case .failure(let error):
                      finish(.failure(error))
                    case .success(let responseBytes):
                      finish(.success(CommandResponse(
                        cardId: channel.cardId,
                        appletVersionCode: status.versionCode ?? "",
                        appletVersion: status.version ?? "",
                        isActivated: status.hasKeyPair,
                        resetCount: status.resetCount,
                        data: FlutterStandardTypedData(bytes: responseBytes)
                      )))
                    }
                  }
                } else if let ndefResult {
                  // command 为 nil 但有 NDEF 写入，将回读 URL 以 UTF-8 编码作为 data 返回
                  let resultBytes = ndefResult.data(using: .utf8) ?? Data()
                  finish(.success(CommandResponse(
                    cardId: channel.cardId,
                    appletVersionCode: status.versionCode ?? "",
                    appletVersion: status.version ?? "",
                    isActivated: status.hasKeyPair,
                    resetCount: status.resetCount,
                    data: FlutterStandardTypedData(bytes: resultBytes)
                  )))
                } else {
                  finish(.success(CommandResponse(
                    cardId: channel.cardId,
                    appletVersionCode: status.versionCode ?? "",
                    appletVersion: status.version ?? "",
                    isActivated: status.hasKeyPair,
                    resetCount: status.resetCount,
                    data: nil
                  )))
                }
              }

              if needSyncUid {
                client.writeUid { _ in afterUid() }
              } else {
                afterUid()
              }
            }

            let targetAar = sendCommandMessage.ndefAar.flatMap { $0.isEmpty ? nil : $0 }
            if let targetAar {
              client.readAar { readResult in
                let currentAar = (try? readResult.get()) ?? ""
                if currentAar != targetAar {
                  client.writeAar(packages: targetAar) { _ in
                    NSLog("ChipCoreNfc: writeAar: updated")
                    afterAar()
                  }
                } else {
                  NSLog("ChipCoreNfc: writeAar: skipped (unchanged)")
                  afterAar()
                }
              }
            } else {
              afterAar()
            }
          }

          if let ndefLink {
            client.writeNdefAndVerify(url: ndefLink) { result in
              afterNdef(try? result.get())
            }
          } else {
            afterNdef(nil)
          }
        }
      }
    }, completion: { outcome in
      switch outcome {
      case .success(let value as CommandResponse):
        completion(.success(value))
      case .success:
        completion(.failure(PigeonError(code: "invalid-response", message: "scanCardWithCommand: unexpected response type", details: nil)))
      case .failure(let error):
        completion(.failure(error))
      }
    })
  }

  func scanCardAndDerive(currencyList: [CurrencyInfoMessage], ndefLink: String, cardId: String?, cardNo: String?, completion: @escaping (Result<CardMessage, Error>) -> Void) {
    deriveCard(currencyList: currencyList, generateIfMissing: true, completion: completion)
  }

  func createWalletAndDerive(currencyList: [CurrencyInfoMessage], completion: @escaping (Result<CardMessage, Error>) -> Void) {
    deriveCard(currencyList: currencyList, generateIfMissing: true, completion: completion)
  }

  func loadCurrencyInfoList(currencyList: [CurrencyInfoMessage], completion: @escaping (Result<Void, Error>) -> Void) {
    NSLog("ChipCoreNfc: loadCurrencyInfoList called, count=%d", currencyList.count)
    state.replaceCurrencies(currencyList)
    completion(.success(()))
    // 异步拉取各链余额，完成后回调 FlutterClientApi.updateCurrencyInfo
    for currency in currencyList {
      let isTest = currency.isTest == 1
      guard let address = currency.address, !address.isEmpty else {
        NSLog("ChipCoreNfc: skip currency symbol=%@ (no address)", currency.symbol)
        continue
      }
      let networkId = currency.networkId
      let contractAddress = currency.contractAddress
      let decimals = Int(currency.decimalCount ?? 18)
      NSLog("ChipCoreNfc: fetching balance symbol=%@ addr=%@ isTest=%d", currency.symbol, address, isTest ? 1 : 0)
      DispatchQueue.global(qos: .userInitiated).async {
        var balance: String? = nil
        var errorMsg: String? = nil
        do {
          if BlockchainSpec.bitcoin.matches(networkId) {
            balance = try ChainClient.fetchBtcBalance(address: address, isTest: isTest)
          } else if BlockchainSpec.dogecoin.matches(networkId) {
            balance = try ChainClient.fetchDogeBalance(address: address, isTest: isTest)
          } else if BlockchainSpec.tron.matches(networkId) {
            if let contract = contractAddress, !contract.isEmpty {
              // TRC20 代币余额
              balance = try ChainClient.fetchTRC20Balance(address: address, contractAddress: contract, isTest: isTest)
            } else {
              balance = try ChainClient.fetchTrxBalance(address: address)
            }
          } else {
            // EVM 兼容链：ETH / BSC(binance) / Polygon 等
            let rpc = ChainClient.evmRpcBySymbol(networkId: networkId, symbol: currency.symbol, isTest: isTest)
            if let contract = contractAddress, !contract.isEmpty {
              // ERC20 代币余额
              balance = try ChainClient.fetchERC20Balance(address: address, contractAddress: contract, rpc: rpc, decimals: decimals)
            } else {
              balance = try ChainClient.fetchEthBalance(address: address, rpc: rpc)
            }
          }
          NSLog("ChipCoreNfc: balance fetched symbol=%@ balance=%@", currency.symbol, balance ?? "nil")
        } catch {
          errorMsg = error.localizedDescription
          NSLog("ChipCoreNfc: balance fetch error symbol=%@ error=%@", currency.symbol, errorMsg!)
        }
        var updated = currency
        updated.amount = balance ?? (errorMsg != nil ? "--" : nil)
        let response: BalanceResponse
        if let msg = errorMsg {
          response = BalanceResponse(
            data: updated,
            errorMessage: BlockchainErrorMessage(code: 0, customMessage: msg)
          )
        } else {
          response = BalanceResponse(data: updated)
        }
        DispatchQueue.main.async {
          NSLog("ChipCoreNfc: calling updateCurrencyInfo symbol=%@ amount=%@", updated.symbol, updated.amount ?? "nil")
          self.flutterClientApi.updateCurrencyInfo(currencyInfoList: [response]) { result in
            switch result {
            case .success(let ok):
              NSLog("ChipCoreNfc: updateCurrencyInfo reply ok=%d", ok ? 1 : 0)
            case .failure(let err):
              NSLog("ChipCoreNfc: updateCurrencyInfo error=%@", err.message ?? err.code)
            }
          }
        }
      }
    }
  }

  func initScanResponse(uuid: String) throws -> Bool {
    // NFC tagId.hexString 为小写，服务器返回的 uid 可能为大写，统一忽略大小写比较
    let normalizedUuid = uuid.lowercased()
    // 注意：不能用 lastCardId == uuid 作早返回（对齐 Android 行为）。
    // scanOnly 流程会设置 state.lastCardId 但不重建 walletManagerRegistry，
    // 若此处早返回，registry 仍为旧数据/空数据，导致 TRX/ETH 公钥缺失。
    // 先用原始值查，再用小写查（兼容旧版大写存储；对齐 Android 双查策略）
    let stored = state.loadCurrencies(cardId: uuid).isEmpty
      ? state.loadCurrencies(cardId: normalizedUuid)
      : state.loadCurrencies(cardId: uuid)
    if !stored.isEmpty {
      state.lastCardId = normalizedUuid
      state.replaceCurrencies(stored)
      walletManagerRegistry.clearWalletManagers()
      walletManagerRegistry.addWalletManagers(walletManagerRegistry.buildFrom(stored))
      return true
    }
    return false
  }

  func addCurrencyList(currencyList: [CurrencyInfoMessage], completion: @escaping (Result<Bool, Error>) -> Void) {
    // 过滤出需要重新派生的币种：
    //   1. 尚未有地址（首次添加）
    //   2. 存储中的 isTest 与传入的 isTest 不一致（切换主网/测试网）
    let newCurrencies = currencyList.filter { incoming in
      let existing = state.findById(incoming.id)
      return (existing?.address == nil || existing!.address!.isEmpty) ||
             existing?.isTest != incoming.isTest
    }
    if newCurrencies.isEmpty {
      // 全部已派生，直接合并内存并持久化，不需要靠卡
      state.mergeCurrencies(currencyList)
      walletManagerRegistry.addWalletManagers(walletManagerRegistry.buildFrom(currencyList))
      if let cardId = state.lastCardId {
        state.saveCurrencies(cardId: cardId, currencies: state.allCurrencies())
      }
      completion(.success(true))
      return
    }
    sessionManager.withSession(appletId: HdWalletApdu.hdWalletAid, operation: { channel, finish in
      let client = HdWalletCardClient(channel: channel)
      self.ensureKeyAndDerive(client: client, currencyList: newCurrencies, generateIfMissing: false) { outcome in
        switch outcome {
        case .success(let snapshot):
          let derived = snapshot.currencies.compactMap { $0 }
          self.state.mergeCurrencies(derived)
          let cardId = snapshot.cardId
          self.state.lastCardId = cardId
          self.state.saveCurrencies(cardId: cardId, currencies: self.state.allCurrencies())
          self.walletManagerRegistry.addWalletManagers(self.walletManagerRegistry.buildFrom(derived))
          finish(.success(true))
        case .failure(let error):
          finish(.failure(error))
        }
      }
    }, completion: { outcome in
      switch outcome {
      case .success(let value as Bool):
        completion(.success(value))
      case .success:
        completion(.failure(PigeonError(code: "invalid-response", message: "addCurrencyList: unexpected response type", details: nil)))
      case .failure(let error):
        completion(.failure(error))
      }
    })
  }

  func getFee(feeMessage: FeeMessage, completion: @escaping (Result<[FeeResponse], Error>) -> Void) {
    let isTest = feeMessage.isTest == "true" || feeMessage.isTest == "1"
    let blockchain = feeMessage.blockchain
    let isToken = feeMessage.currencyType.lowercased() == "token" || feeMessage.currencyType == "1"
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let fees: [FeeResponse]
        if BlockchainSpec.bitcoin.matches(blockchain) {
          fees = try ChainClient.fetchBtcFees(isTest: isTest)
        } else if BlockchainSpec.tron.matches(blockchain) {
          fees = ChainClient.fetchTrxFees()
        } else if BlockchainSpec.dogecoin.matches(blockchain) {
          fees = try ChainClient.fetchDogeFees(isTest: isTest)
        } else {
          // EVM 兼容链：ETH / BSC / Polygon 等
          let rpc = ChainClient.evmRpcBySymbol(networkId: blockchain, symbol: feeMessage.symbol, isTest: isTest)
          if isToken {
            let contract = self.state.findContractAddress(symbol: feeMessage.symbol, networkId: blockchain)
            let fromAddress = self.state.findAddress(networkId: blockchain) ?? feeMessage.receiverAddress
            fees = try ChainClient.fetchEVMTokenFees(
              rpc: rpc,
              contractAddress: contract ?? feeMessage.receiverAddress,
              fromAddress: fromAddress,
              toAddress: feeMessage.receiverAddress
            )
          } else {
            fees = try ChainClient.fetchEVMNativeFees(rpc: rpc)
          }
        }
        DispatchQueue.main.async { completion(.success(fees)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(PigeonError(code: "fee-error", message: error.localizedDescription, details: nil))) }
      }
    }
  }

  func sendTransaction(sendMessage: SendMessage, completion: @escaping (Result<SendTransactionResponse, Error>) -> Void) {
    if state.lastPinSet {
      sessionManager.showPinInputDialog { pinCode in
        if pinCode == nil {
          self.state.lastPinSet = false
          DispatchQueue.main.async {
            completion(.failure(PigeonError(code: "pin-cancelled", message: "PIN input cancelled", details: nil)))
          }
          return
        }
        self.dispatchSendTransaction(sendMessage, completion: completion, pinCode: pinCode)
      }
    } else {
      dispatchSendTransaction(sendMessage, completion: completion, pinCode: nil)
    }
  }

  private func dispatchSendTransaction(_ msg: SendMessage, completion: @escaping (Result<SendTransactionResponse, Error>) -> Void, pinCode: Data?) {
    let blockchainId = msg.blockchainId
    if BlockchainSpec.bitcoin.matches(blockchainId) {
      sendBtcTransaction(msg: msg, completion: completion, pinCode: pinCode)
    } else if BlockchainSpec.tron.matches(blockchainId) {
      sendTrxTransaction(msg: msg, completion: completion, pinCode: pinCode)
    } else if BlockchainSpec.dogecoin.matches(blockchainId) {
      sendDogeTransaction(msg: msg, completion: completion, pinCode: pinCode)
    } else {
      sendEthTransaction(msg: msg, completion: completion, pinCode: pinCode)
    }
  }

  private func sendEthTransaction(msg: SendMessage, completion: @escaping (Result<SendTransactionResponse, Error>) -> Void, pinCode: Data? = nil) {
    let isTest = msg.isTest == "true" || msg.isTest == "1"
    let from = msg.walletAddress
    let isToken = msg.currencyType.lowercased() == "token" || msg.currencyType == "1"
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        // 根据 symbol + networkId 选择正确的 EVM RPC
        let rpc = ChainClient.evmRpcBySymbol(networkId: msg.blockchainId, symbol: msg.symbol ?? "", isTest: isTest)
        let nonce = try ChainClient.ethNonce(rpc: rpc, address: from)
        let gasPrice: BigUInt
        if let gp = msg.gasPrice, gp.hasPrefix("0x") {
          gasPrice = try BigUInt(String(gp.dropFirst(2)), radix: 16) ?? ChainClient.ethGasPrice(rpc: rpc)
        } else if let gp = msg.gasPrice, let gpInt = BigUInt(gp) {
          gasPrice = gpInt
        } else {
          gasPrice = try ChainClient.ethGasPrice(rpc: rpc)
        }
        let chainId = try ChainClient.ethChainId(rpc: rpc)

        // 区分原生币 vs ERC20 代币
        let txTo: String
        let txValue: BigUInt
        let txData: Data
        let txGasLimit: BigUInt

        if isToken {
          // 优先用 Flutter 传入的 contractAddress（与 Android 对齐），取不到再从 state 查
          let rawContractAddress: String? = msg.contractAddress.flatMap { $0.isEmpty ? nil : $0 }
            ?? self.state.findContractAddress(symbol: msg.symbol ?? "", networkId: msg.blockchainId)
          guard let contractAddress = rawContractAddress else {
            DispatchQueue.main.async {
              completion(.failure(PigeonError(code: "contract-missing", message: "Contract address not found. Please scan card to initialize currencies first.", details: nil)))
            }
            return
          }
          let decimals = self.state.findDecimals(symbol: msg.symbol ?? "", networkId: msg.blockchainId)
          let tokenAmount = EthEncoder.parseTokenAmount(msg.sumToSend, decimals: decimals)
          txTo = contractAddress
          txValue = .zero
          txData = EthEncoder.encodeERC20Transfer(to: msg.receiverAddress, amount: tokenAmount)
          txGasLimit = msg.gasLimit.flatMap { BigUInt($0) } ?? 80000
        } else {
          txTo = msg.receiverAddress
          txValue = EthEncoder.parseEthValue(msg.sumToSend)
          txData = Data()
          txGasLimit = msg.gasLimit.flatMap { BigUInt($0) } ?? 100000
        }

        let signingHash = EthEncoder.buildLegacyTxHash(
          nonce: nonce, gasPrice: gasPrice, gasLimit: txGasLimit,
          to: txTo, value: txValue, data: txData, chainId: chainId
        )

        self.sessionManager.withSession(appletId: HdWalletApdu.hdWalletAid, operation: { channel, finish in
          let client = HdWalletCardClient(channel: channel)
          // EVM 链（包括 BSC、Polygon）均使用 ethereum 派生路径 (m/44'/1'/...)
          let spec = BlockchainSpec.fromIdentifier(msg.blockchainId)

          // 签名并构建原始交易（与 Android 对齐：用 doSign 避免代码重复）
          func doSign(_ pubKeyData: Data) {
            client.sign(path: spec.defaultPath(), digest: signingHash, pinCode: pinCode) { signResult in
              switch signResult {
              case .success(let sigBytes):
                do {
                  NSLog("ChipCoreNfc: sigBytes [%d] %@", sigBytes.count, sigBytes.hexString)
                  let (r, s, recId) = try EthEncoder.parseAndRecoverSignature(sigBytes: sigBytes, msgHash: signingHash, pubKey: pubKeyData)
                  NSLog("ChipCoreNfc: parseAndRecover OK recId=%d r=%@ s=%@", recId, r.hexString, s.hexString)
                  let v = chainId * 2 + 35 + BigUInt(recId)
                  let rawTx = EthEncoder.encodeLegacySignedTx(
                    nonce: nonce, gasPrice: gasPrice, gasLimit: txGasLimit,
                    to: txTo, value: txValue, data: txData, v: v, r: r, s: s
                  )
                  NSLog("ChipCoreNfc: rawTx built [%d] bytes, broadcasting to %@", rawTx.count, rpc)
                  finish(.success(rawTx))
                } catch {
                  NSLog("ChipCoreNfc: doSign encode error: %@", error.localizedDescription)
                  finish(.failure(error))
                }
              case .failure(let err):
                finish(.failure(err))
              }
            }
          }

          // 优先从内存取公钥；都取不到时从卡片派生（与 Android 行为一致）
          if let hex = self.state.findPublicKeyHex(keyword: msg.blockchainId), let d = Data(hexString: hex) {
            NSLog("ChipCoreNfc: pubkey found via blockchainId keyword")
            doSign(d)
          } else if let hex = self.state.findPublicKeyHex(keyword: "eth"), let d = Data(hexString: hex) {
            NSLog("ChipCoreNfc: pubkey found via 'eth' fallback")
            doSign(d)
          } else {
            // 兜底：在 NFC session 内直接派生（Android: client.deriveKey(spec.defaultPath()).publicKey）
            NSLog("ChipCoreNfc: no pubkey in state, deriving from card")
            client.deriveKey(path: spec.defaultPath()) { deriveResult in
              switch deriveResult {
              case .success(let derived):
                NSLog("ChipCoreNfc: pubkey derived from card OK")
                doSign(derived.publicKey)
              case .failure(let error):
                NSLog("ChipCoreNfc: deriveKey failed: %@", error.localizedDescription)
                finish(.failure(PigeonError(code: "no-pubkey", message: "Key derivation failed: \(error.localizedDescription)", details: nil)))
              }
            }
          }
        }, completion: { outcome in
          switch outcome {
          case .success(let rawTx as Data):
            DispatchQueue.global(qos: .userInitiated).async {
              do {
                NSLog("ChipCoreNfc: broadcasting rawTx [%d] bytes to %@", rawTx.count, rpc)
                let txHash = try ChainClient.ethBroadcast(rawTx: rawTx, rpc: rpc)
                NSLog("ChipCoreNfc: broadcast OK txHash=%@", txHash)
                DispatchQueue.main.async { completion(.success(SendTransactionResponse(isSuccess: true, errorMsg: txHash))) }
              } catch {
                NSLog("ChipCoreNfc: broadcast error: %@", error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(PigeonError(code: "broadcast-error", message: error.localizedDescription, details: nil))) }
              }
            }
          case .success:
            DispatchQueue.main.async { completion(.failure(PigeonError(code: "sign-error", message: "Unexpected ETH signature result type", details: nil))) }
          case .failure(let error):
            self.handlePinRequired(error: error,
              onRetry: { pin in self.sendEthTransaction(msg: msg, completion: completion, pinCode: pin) },
              onError: { e in DispatchQueue.main.async { completion(.failure(e)) } })
          }
        })
      } catch {
        DispatchQueue.main.async { completion(.failure(PigeonError(code: "eth-prepare-error", message: error.localizedDescription, details: nil))) }
      }
    }
  }

  private func sendBtcTransaction(msg: SendMessage, completion: @escaping (Result<SendTransactionResponse, Error>) -> Void, pinCode: Data? = nil) {
    let isTest = msg.isTest == "true" || msg.isTest == "1"
    let from = msg.walletAddress
    let to = msg.receiverAddress
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let utxos = try ChainClient.fetchBtcUtxos(address: from, isTest: isTest)
        guard !utxos.isEmpty else {
          DispatchQueue.main.async { completion(.failure(PigeonError(code: "no-utxo", message: "No available UTXOs for this address", details: nil))) }
          return
        }
        let feeRate = try msg.gasPrice.flatMap { UInt64($0) } ?? ChainClient.fetchBtcFeeRate(isTest: isTest)
        let valueSat = BtcEncoder.parseAmount(msg.sumToSend)
        let (selectedUtxos, changeSat) = try BtcEncoder.selectUtxos(utxos: utxos, valueSat: valueSat, to: to, from: from, feeRateSatPerVb: feeRate)
        var outputs: [(address: String, value: UInt64)] = [(to, valueSat)]
        if changeSat > 546 { outputs.append((from, changeSat)) }

        self.sessionManager.withSession(appletId: HdWalletApdu.hdWalletAid, operation: { channel, finish in
          let client = HdWalletCardClient(channel: channel)
          let spec = BlockchainSpec.bitcoin
          client.deriveKey(path: spec.defaultPath()) { deriveResult in
            switch deriveResult {
            case .success(let derived):
              let pubKey = BtcEncoder.compressPublicKey(derived.publicKey)
              var witnesses: [[Data]] = []
              var signIndex = 0

              func signNext() {
                if signIndex >= selectedUtxos.count {
                  let rawTx = BtcEncoder.encodeSegwitTx(inputs: selectedUtxos, outputs: outputs, witnesses: witnesses)
                  finish(.success(rawTx))
                  return
                }
                let utxo = selectedUtxos[signIndex]
                let scriptCode = BtcEncoder.p2wpkhScriptCode(pubKey: pubKey)
                let sigHash = BtcEncoder.buildSegwitSigHash(inputs: selectedUtxos, outputs: outputs, inputIndex: signIndex, scriptCode: scriptCode, inputValue: utxo.value)
                client.sign(path: spec.defaultPath(), digest: sigHash, pinCode: pinCode) { signResult in
                  switch signResult {
                  case .success(let derSig):
                    let normalizedDer = BtcEncoder.normalizeSignatureDer(derSig)
                    var sigWithHashType = normalizedDer
                    sigWithHashType.append(0x01) // SIGHASH_ALL
                    witnesses.append([sigWithHashType, pubKey])
                    signIndex += 1
                    signNext()
                  case .failure(let error):
                    finish(.failure(error))
                  }
                }
              }

              signNext()

            case .failure(let error):
              finish(.failure(error))
            }
          }
        }, completion: { outcome in
          switch outcome {
          case .success(let rawTx as Data):
            DispatchQueue.global(qos: .userInitiated).async {
              do {
                let txId = try ChainClient.btcBroadcast(rawTx: rawTx, isTest: isTest)
                DispatchQueue.main.async { completion(.success(SendTransactionResponse(isSuccess: true, errorMsg: txId))) }
              } catch {
                DispatchQueue.main.async { completion(.failure(PigeonError(code: "broadcast-error", message: error.localizedDescription, details: nil))) }
              }
            }
          case .success:
            DispatchQueue.main.async { completion(.failure(PigeonError(code: "sign-error", message: "Unexpected BTC signature result type", details: nil))) }
          case .failure(let error):
            self.handlePinRequired(error: error,
              onRetry: { pin in self.sendBtcTransaction(msg: msg, completion: completion, pinCode: pin) },
              onError: { e in DispatchQueue.main.async { completion(.failure(e)) } })
          }
        })
      } catch {
        DispatchQueue.main.async { completion(.failure(PigeonError(code: "btc-prepare-error", message: error.localizedDescription, details: nil))) }
      }
    }
  }

  // MARK: - TRX Transaction

  private func sendTrxTransaction(msg: SendMessage, completion: @escaping (Result<SendTransactionResponse, Error>) -> Void, pinCode: Data? = nil) {
    let from = msg.walletAddress
    NSLog("ChipCoreNfc TRX: sendTrxTransaction from=%@ to=%@ amount=%@", from, msg.receiverAddress, msg.sumToSend)
    let to = msg.receiverAddress
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        guard let amountTrx = Double(msg.sumToSend) else {
          DispatchQueue.main.async { completion(.failure(PigeonError(code: "invalid-amount", message: "Invalid TRX amount format", details: nil))) }
          return
        }
        let amountSun = Int64(amountTrx * 1_000_000)
        let createBody = "{\"owner_address\":\"\(from)\",\"to_address\":\"\(to)\",\"amount\":\(amountSun),\"visible\":true}"
        guard let createJson = try ChainClient.trxHttpPost("https://api.trongrid.io/wallet/createtransaction", body: createBody),
              let txIdHex = createJson["txID"] as? String,
              let txIdBytes = Data(hexString: txIdHex) else {
          DispatchQueue.main.async { completion(.failure(PigeonError(code: "trx-create-error", message: "Failed to create TRX transaction", details: nil))) }
          return
        }
        self.sessionManager.withSession(appletId: HdWalletApdu.hdWalletAid, operation: { channel, finish in
          let client = HdWalletCardClient(channel: channel)
          let spec = BlockchainSpec.tron

          func doSign(ethPubKey: Data) {
            client.sign(path: spec.defaultPath(), digest: txIdBytes, pinCode: pinCode) { signResult in
              switch signResult {
              case .success(let derSig):
                do {
                  let sig65 = try TrxEncoder.derToTrxSignature(derSig: derSig, msgHash: txIdBytes, ethPubKey: ethPubKey)
                  finish(.success((sig65, txIdHex, createJson)))
                } catch { finish(.failure(error)) }
              case .failure(let err): finish(.failure(err))
              }
            }
          }

          // 优先从注册表取公钥；再从 state 找；取不到时在 NFC session 内派生（对齐 ETH/Android 行为）
          if let pubKeyData = self.walletManagerRegistry.getWalletManagerBySpec(.tron)?.publicKey,
             let ethPubKey = pubKeyData.decompressedSecp256k1NoPrefix() {
            NSLog("ChipCoreNfc TRX: pubkey from registry")
            doSign(ethPubKey: ethPubKey)
          } else if let hex = self.state.findPublicKeyHex(keyword: "trx"),
                    let pubKeyData = Data(hexString: hex),
                    let ethPubKey = pubKeyData.decompressedSecp256k1NoPrefix() {
            NSLog("ChipCoreNfc TRX: pubkey from state")
            doSign(ethPubKey: ethPubKey)
          } else {
            NSLog("ChipCoreNfc TRX: no cached pubkey, deriving from card")
            client.deriveKey(path: spec.defaultPath()) { deriveResult in
              switch deriveResult {
              case .success(let derived):
                NSLog("ChipCoreNfc TRX: pubkey derived OK")
                guard let ethPubKey = derived.publicKey.decompressedSecp256k1NoPrefix() else {
                  finish(.failure(PigeonError(code: "no-pubkey", message: "Failed to decompress TRX public key", details: nil)))
                  return
                }
                doSign(ethPubKey: ethPubKey)
              case .failure(let error):
                NSLog("ChipCoreNfc TRX: deriveKey failed: %@", error.localizedDescription)
                finish(.failure(PigeonError(code: "no-pubkey", message: "Key derivation failed: \(error.localizedDescription)", details: nil)))
              }
            }
          }
        }, completion: { outcome in
          switch outcome {
          case .success(let val as (Data, String, [String: Any])):
            let (sig65, txIdHex2, createJson2) = val
            DispatchQueue.global(qos: .userInitiated).async {
              do {
                var mutableJson = createJson2
                mutableJson["signature"] = [sig65.hexString]
                let broadcastBody = try JSONSerialization.data(withJSONObject: mutableJson)
                guard let broadcastJson = try ChainClient.trxHttpPostData("https://api.trongrid.io/wallet/broadcasttransaction", data: broadcastBody) else {
                  DispatchQueue.main.async { completion(.failure(PigeonError(code: "trx-broadcast-error", message: "TRX broadcast: empty response", details: nil))) }
                  return
                }
                if broadcastJson["result"] as? Bool != true {
                  let errMsg = broadcastJson["message"] as? String ?? "unknown"
                  DispatchQueue.main.async { completion(.failure(PigeonError(code: "trx-broadcast-error", message: "TRX broadcast failed: \(errMsg)", details: nil))) }
                  return
                }
                DispatchQueue.main.async { completion(.success(SendTransactionResponse(isSuccess: true, errorMsg: txIdHex2))) }
              } catch {
                DispatchQueue.main.async { completion(.failure(PigeonError(code: "trx-broadcast-error", message: error.localizedDescription, details: nil))) }
              }
            }
          case .success:
            DispatchQueue.main.async { completion(.failure(PigeonError(code: "sign-error", message: "Unexpected TRX signature type", details: nil))) }
          case .failure(let err):
            self.handlePinRequired(error: err,
              onRetry: { pin in self.sendTrxTransaction(msg: msg, completion: completion, pinCode: pin) },
              onError: { e in DispatchQueue.main.async { completion(.failure(e)) } })
          }
        })
      } catch {
        DispatchQueue.main.async { completion(.failure(PigeonError(code: "trx-prepare-error", message: error.localizedDescription, details: nil))) }
      }
    }
  }

  // MARK: - DOGE Transaction

  private func sendDogeTransaction(msg: SendMessage, completion: @escaping (Result<SendTransactionResponse, Error>) -> Void, pinCode: Data? = nil) {
    let isTest = msg.isTest == "true" || msg.isTest == "1"
    let from = msg.walletAddress
    let to = msg.receiverAddress
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let utxos = try ChainClient.fetchDogeUtxos(address: from, isTest: isTest)
        guard !utxos.isEmpty else {
          DispatchQueue.main.async { completion(.failure(PigeonError(code: "no-utxo", message: "No available UTXOs for this DOGE address", details: nil))) }
          return
        }
        let feeRateSat = msg.gasPrice.flatMap { Int64($0) } ?? 1000
        let valueSat = DogeEncoder.parseAmount(msg.sumToSend)
        let (selectedUtxos, changeSat) = try DogeEncoder.selectUtxos(utxos: utxos, valueSat: valueSat, feeRateSatPerByte: feeRateSat)
        var outputs: [(address: String, value: Int64)] = [(to, valueSat)]
        if changeSat > 100_000 { outputs.append((from, changeSat)) }
        self.sessionManager.withSession(appletId: HdWalletApdu.hdWalletAid, operation: { channel, finish in
          let client = HdWalletCardClient(channel: channel)
          let spec = BlockchainSpec.dogecoin
          client.deriveKey(path: spec.defaultPath()) { deriveResult in
            switch deriveResult {
            case .success(let derived):
              let pubKey = derived.publicKey.compressedSecp256k1()
              var signatures: [Data] = []
              var signIndex = 0
              func signNext() {
                if signIndex >= selectedUtxos.count {
                  let rawTx = DogeEncoder.encodeP2pkhTx(inputs: selectedUtxos, outputs: outputs, signatures: signatures, pubKey: pubKey)
                  finish(.success(rawTx))
                  return
                }
                let sigHash = DogeEncoder.buildP2pkhSigHash(inputs: selectedUtxos, outputs: outputs, signingIndex: signIndex, pubKey: pubKey)
                NSLog("ChipCoreNfc: [DOGE] signing input[%d], sigHash [%d] bytes: %@", signIndex, sigHash.count, sigHash.hexString)
                client.sign(path: spec.defaultPath(), digest: sigHash, pinCode: pinCode) { signResult in
                  switch signResult {
                  case .success(let derSig):
                    NSLog("ChipCoreNfc: [DOGE] sign[%d] raw sig [%d] bytes: %@", signIndex, derSig.count, derSig.hexString)
                    var sigWithHashType = BtcEncoder.normalizeSignatureDer(derSig)
                    NSLog("ChipCoreNfc: [DOGE] sign[%d] normalizedDer [%d] bytes: %@", signIndex, sigWithHashType.count, sigWithHashType.hexString)
                    sigWithHashType.append(0x01) // SIGHASH_ALL
                    signatures.append(sigWithHashType)
                    signIndex += 1
                    signNext()
                  case .failure(let err):
                    NSLog("ChipCoreNfc: [DOGE] sign[%d] failed: %@", signIndex, err.localizedDescription)
                    finish(.failure(err))
                  }
                }
              }
              signNext()
            case .failure(let err): finish(.failure(err))
            }
          }
        }, completion: { outcome in
          switch outcome {
          case .success(let rawTx as Data):
            DispatchQueue.global(qos: .userInitiated).async {
              do {
                NSLog("ChipCoreNfc: [DOGE] broadcasting rawTx [%d] bytes: %@", rawTx.count, rawTx.hexString)
                let txId = try ChainClient.dogeBroadcast(rawTx: rawTx, isTest: isTest)
                NSLog("ChipCoreNfc: [DOGE] broadcast OK txId=%@", txId)
                DispatchQueue.main.async { completion(.success(SendTransactionResponse(isSuccess: true, errorMsg: txId))) }
              } catch {
                NSLog("ChipCoreNfc: [DOGE] broadcast error: %@", error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(PigeonError(code: "broadcast-error", message: error.localizedDescription, details: nil))) }
              }
            }
          case .success:
            DispatchQueue.main.async { completion(.failure(PigeonError(code: "sign-error", message: "Unexpected DOGE signature type", details: nil))) }
          case .failure(let err):
            self.handlePinRequired(error: err,
              onRetry: { pin in self.sendDogeTransaction(msg: msg, completion: completion, pinCode: pin) },
              onError: { e in DispatchQueue.main.async { completion(.failure(e)) } })
          }
        })
      } catch {
        DispatchQueue.main.async { completion(.failure(PigeonError(code: "doge-prepare-error", message: error.localizedDescription, details: nil))) }
      }
    }
  }

  // MARK: - PIN required handler

  private func handlePinRequired(error: Error, onRetry: @escaping (Data) -> Void, onError: @escaping (Error) -> Void) {
    if let pigeonError = error as? PigeonError,
       pigeonError.code == "pin-required" || pigeonError.code == "SW-0005" {
      state.lastPinSet = true
      sessionManager.showPinInputDialog { pin in
        guard let pin = pin else {
          self.state.lastPinSet = false
          onError(PigeonError(code: "pin-cancelled", message: "PIN input was cancelled", details: nil))
          return
        }
        onRetry(pin)
      }
    } else {
      onError(error)
    }
  }

  func validateAddress(validateMessage: ValidateAddressMessage) throws -> Bool {
    let blockchain = validateMessage.blockchain.lowercased()
    let address = validateMessage.address.trimmingCharacters(in: .whitespacesAndNewlines)
    if blockchain.contains("eth") || blockchain.contains("evm") {
      return address.range(of: "^0x[a-fA-F0-9]{40}$", options: .regularExpression) != nil
    }
    if blockchain.contains("btc") || blockchain.contains("bitcoin") {
      return address.range(of: "^(bc1|tb1)[ac-hj-np-z02-9]{11,71}$|^[13mn2][A-HJ-NP-Za-km-z1-9]{25,34}$", options: .regularExpression) != nil
    }
    if blockchain.contains("trx") || blockchain.contains("tron") {
      // TRX: Base58Check 解码后 21 字节，首字节 = 0x41
      guard let decoded = Base58Check.decode(address), decoded.count == 21 else { return false }
      return decoded[0] == 0x41
    }
    if blockchain.contains("doge") || blockchain.contains("dogecoin") {
      // DOGE: 0x1E=主网P2PKH(D...)，0x16=主网P2SH(A...)，0x71=测试网(m/n...)
      guard let decoded = Base58Check.decode(address), decoded.count == 21 else { return false }
      return decoded[0] == 0x1E || decoded[0] == 0x16 || decoded[0] == 0x71
    }
    return false
  }

  func clearLocalCurrency(cardId: String, coinIds: [String]) throws {
    if state.lastCardId?.lowercased() == cardId.lowercased() {
      state.removeCurrencies(coinIds)
    }
  }

  func loadTransactionHistoryList(request: TransactionHistoryRequest, completion: @escaping (Result<[TransactionsHistory], Error>) -> Void) {
    let address = request.address
    guard !address.isEmpty else {
      completion(.failure(notImplementedError("地址为空")))
      return
    }
    let symbol = request.currencyInfo.symbol.uppercased()
    let isTest = (request.currencyInfo.isTest ?? 0) != 0
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let history: [TransactionsHistory]
        switch symbol {
        case "BTC":  history = try ChainClient.fetchBtcTxHistory(address: address, isTest: isTest)
        case "ETH":  history = try ChainClient.fetchEthTxHistory(address: address, isTest: isTest)
        case "TRX":  history = try ChainClient.fetchTrxTxHistory(address: address)
        case "DOGE": history = try ChainClient.fetchDogeTxHistory(address: address, isTest: isTest)
        default:
          let contractAddr = request.currencyInfo.contractAddress ?? ""
          if !contractAddr.isEmpty {
            let rpc = ChainClient.evmRpcBySymbol(
              networkId: request.currencyInfo.networkId,
              symbol: symbol, isTest: isTest)
            let decimals = Int(request.currencyInfo.decimalCount ?? 18)
            history = try ChainClient.fetchErc20TxHistory(
              address: address, contractAddress: contractAddr,
              rpc: rpc, decimals: decimals)
          } else {
            history = []
          }
        }
        DispatchQueue.main.async { completion(.success(history)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(PigeonError(code: "tx-history-error", message: error.localizedDescription, details: nil))) }
      }
    }
  }

  func changeWallet(cardId: String, currencyList: [CurrencyInfoMessage], completion: @escaping (Result<Bool, Error>) -> Void) {
    state.lastCardId = cardId
    state.replaceCurrencies(currencyList)
    walletManagerRegistry.clearWalletManagers()
    walletManagerRegistry.addWalletManagers(walletManagerRegistry.buildFrom(currencyList))
    completion(.success(true))
  }

  func postCatchedException(error: String, completion: @escaping (Result<Void, Error>) -> Void) {
    NSLog("ChipCore native error: %@", error)
    completion(.success(()))
  }

  func signLightning(signText: String, isBtc: Bool, completion: @escaping (Result<String, Error>) -> Void) {
    signDigest(blockchainId: isBtc ? "btc" : "eth", payload: signText, completion: completion)
  }

  func createChainKeys(blockchains: [String], completion: @escaping (Result<ChainKeyInfo, Error>) -> Void) {
    sessionManager.withSession(appletId: HdWalletApdu.hdWalletAid, operation: { channel, finish in
      let client = HdWalletCardClient(channel: channel)
      self.deriveChainKeys(client: client, blockchains: blockchains) { outcome in
        switch outcome {
        case .success(let chainKeys):
          finish(.success(ChainKeyInfo(cardId: channel.cardId, chainKeys: chainKeys)))
        case .failure(let error):
          finish(.failure(error))
        }
      }
    }, completion: { outcome in
      switch outcome {
      case .success(let value as ChainKeyInfo):
        completion(.success(value))
      case .success:
        completion(.failure(PigeonError(code: "invalid-response", message: "createChainKeys: unexpected response type", details: nil)))
      case .failure(let error):
        completion(.failure(error))
      }
    })
  }

  func getChainKeys(cardId: String, blockchains: [String], completion: @escaping (Result<[ChainKeyMessage], Error>) -> Void) {
    let chainKeys = blockchains.compactMap { blockchainId -> ChainKeyMessage? in
      let spec = BlockchainSpec.fromIdentifier(blockchainId)
      guard let currency = state.findBySpec(spec) else { return nil }
      return ChainKeyMessage(
        blockchainId: blockchainId,
        chainId: nil,
        privateKey: "",
        publicKey: currency.publicKey?.data.hexString ?? "",
        address: currency.address ?? ""
      )
    }
    completion(.success(chainKeys))
  }

  func signText(blockchainId: String, text: String, chainId: Int64?, completion: @escaping (Result<String, Error>) -> Void) {
    signDigest(blockchainId: blockchainId, payload: text, completion: completion)
  }

  func signTransaction(blockchainId: String, text: String, chainId: Int64?, completion: @escaping (Result<String, Error>) -> Void) {
    signDigest(blockchainId: blockchainId, payload: text, completion: completion)
  }

  func generateKey(completion: @escaping (Result<String, Error>) -> Void) {
    sessionManager.withSession(appletId: HdWalletApdu.hdWalletAid, operation: { channel, finish in
      let client = HdWalletCardClient(channel: channel)
      client.generateKeyPair { outcome in
        switch outcome {
        case .success(let generated):
          self.state.cacheMasterKey(cardId: channel.cardId, publicKey: generated.publicKey, chainCode: generated.chainCode)
          finish(.success(generated.publicKey.hexString))
        case .failure(let error):
          finish(.failure(error))
        }
      }
    }, completion: { outcome in
      switch outcome {
      case .success(let value as String):
        completion(.success(value))
      case .success:
        completion(.failure(PigeonError(code: "invalid-response", message: "generateKey: unexpected response type", details: nil)))
      case .failure(let error):
        completion(.failure(error))
      }
    })
  }

  func signChallenge(challenge: String, completion: @escaping (Result<String, Error>) -> Void) {
    // 与 Android 对齐：用 ETH 路径对 challenge 签名
    signDigest(blockchainId: "eth", payload: challenge, completion: completion)
  }

  func getBitcoinPublicKey() throws -> String {
    guard let key = state.findPublicKeyHex(keyword: "btc") else {
      throw notImplementedError("BTC public key not available. Please run scanCardAndDerive or addCurrencyList first.")
    }
    return key
  }

  func resetNfcReaderMode() throws {
    sessionManager.reset()
  }

  func getEthPublicKey() throws -> String {
    guard let key = state.findPublicKeyHex(keyword: "eth") else {
      throw notImplementedError("ETH public key not available. Please run scanCardAndDerive or addCurrencyList first.")
    }
    return key
  }

  func makeAddresses(networkId: String, isBtc: Bool, completion: @escaping (Result<String, Error>) -> Void) {
    if let address = state.findAddress(networkId: networkId) {
      completion(.success(address))
      return
    }
    let spec: BlockchainSpec = isBtc ? .bitcoin : .ethereum
    if let currency = state.findBySpec(spec), let publicKey = currency.publicKey?.data {
      let address = spec.makeAddress(publicKey: publicKey, isTest: currency.isTest == 1)
      state.updateAddress(networkId: networkId, address: address)
      completion(.success(address))
      return
    }
    completion(.failure(notImplementedError("Public key not available for this chain. Please run scanCardAndDerive or addCurrencyList first.")))
  }

  func bindNetwork() throws {}

  func isVpnActive() throws -> Bool { false }

  func isDualSim() throws -> Bool { false }

  private func deriveCard(currencyList: [CurrencyInfoMessage], generateIfMissing: Bool, completion: @escaping (Result<CardMessage, Error>) -> Void) {
    sessionManager.withSession(appletId: HdWalletApdu.hdWalletAid, operation: { channel, finish in
      let client = HdWalletCardClient(channel: channel)
      self.ensureKeyAndDerive(client: client, currencyList: currencyList, generateIfMissing: generateIfMissing) { outcome in
        switch outcome {
        case .success(let snapshot):
          self.state.lastCardId = snapshot.cardId
          self.state.lastPinSet = snapshot.isPasswordSet
          self.state.cacheMasterKey(cardId: snapshot.cardId, publicKey: snapshot.masterPublicKey, chainCode: snapshot.masterChainCode)
          let validCurrencies = snapshot.currencies.compactMap { $0 }
          self.state.replaceCurrencies(validCurrencies)
          self.state.saveCurrencies(cardId: snapshot.cardId, currencies: validCurrencies)
          self.walletManagerRegistry.clearWalletManagers()
          self.walletManagerRegistry.addWalletManagers(self.walletManagerRegistry.buildFrom(validCurrencies))
          finish(.success(CardMessage(
            uid: snapshot.uid,
            isPasswordSet: snapshot.isPasswordSet,
            publicKey: FlutterStandardTypedData(bytes: snapshot.masterPublicKey),
            currencyList: snapshot.currencies
          )))
        case .failure(let error):
          finish(.failure(error))
        }
      }
    }, completion: { outcome in
      switch outcome {
      case .success(let value as CardMessage):
        completion(.success(value))
      case .success:
        completion(.failure(PigeonError(code: "invalid-response", message: "deriveCard: unexpected response type", details: nil)))
      case .failure(let error):
        completion(.failure(error))
      }
    })
  }

  private func ensureKeyAndDerive(client: HdWalletCardClient, currencyList: [CurrencyInfoMessage], generateIfMissing: Bool, completion: @escaping (Result<CardSnapshot, Error>) -> Void) {
    client.getStatus { statusResult in
      switch statusResult {
      case .success(let status):
        self.ensureMasterKey(client: client, status: status, generateIfMissing: generateIfMissing, currencies: currencyList, completion: completion)
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  private func ensureMasterKey(client: HdWalletCardClient, status: CardStatus, generateIfMissing: Bool, currencies: [CurrencyInfoMessage], completion: @escaping (Result<CardSnapshot, Error>) -> Void) {
    let continueWithKey: (KeyMaterial?) -> Void = { masterKey in
      self.deriveCurrencies(client: client, currencies: currencies) { derivedResult in
        switch derivedResult {
        case .success(let derivedCurrencies):
          let fallbackKey = derivedCurrencies.first??.publicKey?.data ?? Data()
          let fallbackChainCode = derivedCurrencies.first??.chainCode?.data ?? Data()
          completion(.success(CardSnapshot(
            cardId: client.cardId,
            uid: status.uid?.hexString ?? client.cardId,
            isPasswordSet: status.pinSet,
            masterPublicKey: masterKey?.publicKey ?? fallbackKey,
            masterChainCode: masterKey?.chainCode ?? fallbackChainCode,
            currencies: derivedCurrencies
          )))
        case .failure(let error):
          completion(.failure(error))
        }
      }
    }

    if status.hasKeyPair {
      continueWithKey(nil)
      return
    }

    if !generateIfMissing {
      completion(.failure(PigeonError(code: "key-not-found", message: "No key pair found on card", details: nil)))
      return
    }

    client.generateKeyPair { generated in
      switch generated {
      case .success(let keyMaterial):
        continueWithKey(keyMaterial)
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  private func deriveCurrencies(client: HdWalletCardClient, currencies: [CurrencyInfoMessage], completion: @escaping (Result<[CurrencyInfoMessage?], Error>) -> Void) {
    // 按派生路径分组：同一路径的币（原生币 + 同网络代币）只派生一次
    struct PathGroup {
      let spec: BlockchainSpec
      let path: Data
      var entries: [(index: Int, currency: CurrencyInfoMessage)]
    }
    var pathOrder: [String] = []
    var pathGroups: [String: PathGroup] = [:]
    for (idx, currency) in currencies.enumerated() {
      let spec = BlockchainSpec.fromCurrency(currency)
      let path = spec.defaultPath()
      let key = path.hexString
      if pathGroups[key] != nil {
        pathGroups[key]!.entries.append((idx, currency))
      } else {
        pathOrder.append(key)
        pathGroups[key] = PathGroup(spec: spec, path: path, entries: [(idx, currency)])
      }
    }

    var output: [CurrencyInfoMessage?] = Array(repeating: nil, count: currencies.count)
    var groupIdx = 0

    func nextGroup() {
      if groupIdx >= pathOrder.count {
        completion(.success(output))
        return
      }
      let key = pathOrder[groupIdx]
      groupIdx += 1
      guard let group = pathGroups[key] else { nextGroup(); return }
      client.deriveKey(path: group.path) { outcome in
        switch outcome {
        case .success(let derived):
          // 同路径下所有币（含代币）共享同一公钥；代币地址 = 宿主链地址
          for entry in group.entries {
            let isTest = entry.currency.isTest == 1
            let address = group.spec.makeAddress(publicKey: derived.publicKey, isTest: isTest)
            output[entry.index] = entry.currency.copyWith(
              publicKey: derived.publicKey,
              chainCode: derived.chainCode,
              address: address
            )
          }
          nextGroup()
        case .failure(let error):
          completion(.failure(error))
        }
      }
    }

    nextGroup()
  }

  private func deriveChainKeys(client: HdWalletCardClient, blockchains: [String], completion: @escaping (Result<[ChainKeyMessage?], Error>) -> Void) {
    var index = 0
    var output: [ChainKeyMessage?] = []

    func next() {
      if index >= blockchains.count {
        completion(.success(output))
        return
      }
      let blockchainId = blockchains[index]
      index += 1
      let spec = BlockchainSpec.fromIdentifier(blockchainId)
      client.deriveKey(path: spec.defaultPath()) { outcome in
        switch outcome {
        case .success(let derived):
          output.append(ChainKeyMessage(
            blockchainId: blockchainId,
            chainId: nil,
            privateKey: "",
            publicKey: derived.publicKey.hexString,
            address: spec.makeAddress(publicKey: derived.publicKey, isTest: false)
          ))
          next()
        case .failure(let error):
          completion(.failure(error))
        }
      }
    }

    next()
  }

  private func signDigest(blockchainId: String, payload: String, completion: @escaping (Result<String, Error>) -> Void) {
    // 与 Android signDigest 对齐：若卡已设 PIN 则预弹 PIN 框
    if state.lastPinSet {
      sessionManager.showPinInputDialog { pinCode in
        if pinCode == nil {
          self.state.lastPinSet = false
          DispatchQueue.main.async {
            completion(.failure(PigeonError(code: "pin-cancelled", message: "PIN input cancelled", details: nil)))
          }
          return
        }
        self.doSignDigest(blockchainId: blockchainId, payload: payload, pinCode: pinCode, completion: completion)
      }
    } else {
      doSignDigest(blockchainId: blockchainId, payload: payload, pinCode: nil, completion: completion)
    }
  }

  private func doSignDigest(blockchainId: String, payload: String, pinCode: Data?, completion: @escaping (Result<String, Error>) -> Void) {
    sessionManager.withSession(appletId: HdWalletApdu.hdWalletAid, operation: { channel, finish in
      let client = HdWalletCardClient(channel: channel)
      let spec = BlockchainSpec.fromIdentifier(blockchainId)
      client.sign(path: spec.defaultPath(), digest: spec.resolveDigest(payload), pinCode: pinCode) { outcome in
        switch outcome {
        case .success(let signature):
          finish(.success(signature.hexString))
        case .failure(let error):
          finish(.failure(error))
        }
      }
    }, completion: { outcome in
      switch outcome {
      case .success(let value as String):
        completion(.success(value))
      case .success:
        completion(.failure(PigeonError(code: "invalid-response", message: "signDigest: unexpected response type", details: nil)))
      case .failure(let error):
        self.handlePinRequired(error: error,
          onRetry: { pin in self.doSignDigest(blockchainId: blockchainId, payload: payload, pinCode: pin, completion: completion) },
          onError: { e in DispatchQueue.main.async { completion(.failure(e)) } })
      }
    })
  }

  private func notImplementedError(_ message: String) -> PigeonError {
    PigeonError(code: "not-implemented", message: message, details: nil)
  }
}

private final class HdWalletCardClient {
  private var channel: IOSSessionChannel
  var cardId: String { channel.cardId }
  /// 每个 NFC session 仅查询一次卡 PIN 状态（与 Android 对齐）
  private var pinStatusChecked = false
  private var cardHasPin = false

  init(channel: IOSSessionChannel) {
    self.channel = channel
  }

  // MARK: - getStatus（不加密，skipEncrypt=true）

  func getStatus(completion: @escaping (Result<CardStatus, Error>) -> Void) {
    channel.send(apduData: HdWalletApdu.simple(ins: HdWalletApdu.insGetStatus), context: "读取卡状态失败", skipEncrypt: true) { outcome in
      switch outcome {
      case .success(let payload):
        do {
          let tags = try parseStatusResponse(payload)
          let keyFlagSet = tags[HdWalletApdu.tagHasKeyPair]?.first == 0x01
          let status = CardStatus(
            hasKeyPair: keyFlagSet,
            masterKeyFlagSet: keyFlagSet,
            pinSet: tags[HdWalletApdu.tagPinSet]?.first == 0x01,
            uid: tags[HdWalletApdu.tagUid],
            version: tags[HdWalletApdu.tagAppletVersion].flatMap { String(data: $0, encoding: .utf8) },
            versionCode: tags[HdWalletApdu.tagAppletVersionCode].flatMap { String(data: $0, encoding: .utf8) },
            resetCount: Int64(tags[HdWalletApdu.tagResetCount]?.unsignedIntValue ?? 0),
            pinRetry: tags[HdWalletApdu.tagPinRetry].flatMap { $0.first }.map { Int($0) } ?? 3,
            pukRetry: tags[HdWalletApdu.tagPukRetry].flatMap { $0.first }.map { Int($0) } ?? 5
          )
          NSLog("ChipCoreNfc: getStatus hasKeyPair=%d pinSet=%d pinRetry=%d pukRetry=%d isLock=%d uid=%@ version=%@",
                status.hasKeyPair ? 1 : 0, status.pinSet ? 1 : 0,
                status.pinRetry, status.pukRetry, status.isLock ? 1 : 0,
                status.uid?.hexString ?? "", status.version ?? "")
          completion(.success(status))
        } catch {
          completion(.failure(error))
        }
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  // MARK: - reselect（重新 SELECT applet 刷新 aesKey）

  func reselect(aid: Data, completion: @escaping (Result<Void, Error>) -> Void) {
    let selectApdu = Data([0x00, 0xA4, 0x04, 0x00, UInt8(aid.count)]) + aid + Data([0x00])
    channel.sendRaw(apduData: selectApdu) { outcome in
      switch outcome {
      case .success(let response):
        guard response.count >= 2 else {
          completion(.failure(PigeonError(code: "reselect-error", message: "Reselect response too short", details: nil)))
          return
        }
        let sw1 = response[response.count - 2]
        let sw2 = response[response.count - 1]
        if sw1 == 0x90 && sw2 == 0x00 {
          let newKeyBase = response.dropLast(2)
          if let tagIdData = Data(hexString: self.channel.cardId) {
            self.channel.aesKey = newKeyBase + tagIdData.prefix(4)
            NSLog("ChipCoreNfc: reselect 刷新 aesKey [%d] %@", self.channel.aesKey.count, self.channel.aesKey.hexString)
          }
          completion(.success(()))
        } else {
          completion(.failure(PigeonError(code: "reselect-error", message: String(format: "reselect SW=%02X%02X", sw1, sw2), details: nil)))
        }
      case .failure(let error):
        NSLog("ChipCoreNfc: reselect 失败: %@", error.localizedDescription)
        completion(.failure(error))
      }
    }
  }

  // MARK: - generateKeyPair（不加密）

  func generateKeyPair(completion: @escaping (Result<KeyMaterial, Error>) -> Void) {
    channel.send(apduData: HdWalletApdu.simple(ins: HdWalletApdu.insGenerateKey), context: "生成密钥失败", skipEncrypt: true) { outcome in
      completion(outcome.flatMap { payload in
        Result { try self.parseKeyMaterial(payload) }
      })
    }
  }

  // MARK: - deriveKey（AES 加密，与 Android 一致：aesKey 非空时数据 APDU 均加密）

  func deriveKey(path: Data, completion: @escaping (Result<KeyMaterial, Error>) -> Void) {
    NSLog("ChipCoreNfc: deriveKey path [%d] %@", path.count, path.hexString)
    let payload = HdWalletApdu.tlv(tag: HdWalletApdu.tagDerivePath, value: path)
    channel.send(apduData: HdWalletApdu.withData(ins: HdWalletApdu.insDerive, data: payload), context: "派生公钥失败") { outcome in
      switch outcome {
      case .success(let raw):
        NSLog("ChipCoreNfc: deriveKey response [%d] %@", raw.count, raw.hexString)
        let result = Result { try self.parseKeyMaterial(raw) }
        if case .failure(let e) = result {
          NSLog("ChipCoreNfc: deriveKey parseKeyMaterial failed: %@", e.localizedDescription)
        }
        completion(result)
      case .failure(let error):
        NSLog("ChipCoreNfc: deriveKey failed: %@", error.localizedDescription)
        completion(.failure(error))
      }
    }
  }

  // MARK: - sign（加密）

  func sign(path: Data, digest: Data, pinCode: Data? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
    // 首次签名时获取实时 PIN 状态（每 NFC session 仅一次），与 Android 对齐
    if !pinStatusChecked {
      pinStatusChecked = true
      getStatus { [self] statusResult in
        switch statusResult {
        case .success(let status):
          self.cardHasPin = status.pinSet
          NSLog("ChipCoreNfc: sign realtime cardHasPin=%d", status.pinSet ? 1 : 0)
          if status.pinSet && pinCode == nil {
            completion(.failure(PigeonError(code: "pin-required", message: "Card PIN is set, please enter PIN to sign", details: nil)))
          } else {
            self.doActualSign(path: path, digest: digest, pinCode: pinCode, completion: completion)
          }
        case .failure(let error):
          completion(.failure(error))
        }
      }
    } else {
      if cardHasPin && pinCode == nil {
        completion(.failure(PigeonError(code: "pin-required", message: "Card PIN is set, please enter PIN to sign", details: nil)))
      } else {
        doActualSign(path: path, digest: digest, pinCode: pinCode, completion: completion)
      }
    }
  }

  private func doActualSign(path: Data, digest: Data, pinCode: Data?, completion: @escaping (Result<Data, Error>) -> Void) {
    var payload = HdWalletApdu.tlv(tag: HdWalletApdu.tagSignMessage, value: digest) +
      HdWalletApdu.tlv(tag: HdWalletApdu.tagDerivePath, value: path)
    if let pin = pinCode {
      payload += HdWalletApdu.tlv(tag: HdWalletApdu.tagPinCode, value: pin)
    }
    // sign 需要 reselect 刷新 aesKey，再加密发送
    reselect(aid: HdWalletApdu.hdWalletAid) { [self] reselectResult in
      switch reselectResult {
      case .failure(let error):
        completion(.failure(error))
      case .success:
        self.channel.send(apduData: HdWalletApdu.withData(ins: HdWalletApdu.insSign, data: payload), context: "签名失败") { outcome in
          switch outcome {
          case .success(let raw):
            NSLog("ChipCoreNfc: sign APDU success, response [%d] bytes", raw.count)
            completion(Result {
              let tags = try parseResponse(raw)
              guard let signature = tags[HdWalletApdu.tagSignature] else {
                throw PigeonError(code: "invalid-response", message: "Signature response missing 0x98 tag", details: nil)
              }
              return signature
            })
          case .failure(let err):
            NSLog("ChipCoreNfc: sign APDU failed: %@", err.localizedDescription)
            completion(.failure(err))
          }
        }
      }
    }
  }

  // MARK: - sendCommand（加密，需先 reselect）

  func sendCommand(_ command: Data, completion: @escaping (Result<Data, Error>) -> Void) {
    reselect(aid: HdWalletApdu.hdWalletAid) { [self] reselectResult in
      switch reselectResult {
      case .failure(let error):
        completion(.failure(error))
      case .success:
        self.channel.send(apduData: command, context: "sendCommand failed") { outcome in
          completion(outcome)
        }
      }
    }
  }

  // MARK: - writeNdef（加密）

  func writeNdef(url: String, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let urlBytes = url.data(using: .utf8) else {
      completion(.failure(PigeonError(code: "invalid-argument", message: "Failed to encode NDEF URL", details: nil)))
      return
    }
    let payload = HdWalletApdu.tlv(tag: HdWalletApdu.tagNdefUrl, value: urlBytes)
    channel.send(apduData: HdWalletApdu.withData(ins: HdWalletApdu.insStoreNdef, data: payload), context: "Write NDEF failed") { outcome in
      completion(outcome.map { _ in () })
    }
  }

  func readNdef(completion: @escaping (Result<String, Error>) -> Void) {
    channel.send(apduData: HdWalletApdu.simple(ins: HdWalletApdu.insGetNdef), context: "Read NDEF failed") { outcome in
      switch outcome {
      case .success(let raw):
        guard raw.count >= 2 else { completion(.success("")); return }
        let tag = raw[0]
        let len = Int(raw[1])
        if tag != HdWalletApdu.tagNdefUrl || raw.count < 2 + len {
          completion(.success(""))
          return
        }
        let str = String(data: raw.subdata(in: 2..<(2 + len)), encoding: .utf8) ?? ""
        completion(.success(str))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func writeNdefAndVerify(url: String, completion: @escaping (Result<String, Error>) -> Void) {
    writeNdef(url: url) { writeResult in
      switch writeResult {
      case .failure(let error):
        completion(.failure(error))
      case .success:
        self.readNdef { readResult in
          switch readResult {
          case .success(let readBack):
            NSLog("ChipCoreNfc: writeNdef verify: expected=%@ got=%@", url, readBack)
            completion(.success(readBack))
          case .failure:
            completion(.success(url)) // 回读失败时原样返回
          }
        }
      }
    }
  }

  // MARK: - writeAar / readAar（AAR 包名读写）

  /**
   写入 AAR 包名列表（INS=0x67）。
   - packages: 逗号分隔的包名，如 "com.android.chrome,com.android.browser"。
     清空列表：传入空字符串（发送 AC 00）。
   */
  func writeAar(packages: String, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let packagesBytes = packages.data(using: .utf8) else {
      completion(.failure(PigeonError(code: "invalid-argument", message: "Failed to encode AAR packages", details: nil)))
      return
    }
    let payload = HdWalletApdu.tlv(tag: HdWalletApdu.tagAarData, value: packagesBytes)
    channel.send(apduData: HdWalletApdu.withData(ins: HdWalletApdu.insStoreAar, data: payload), context: "Write AAR failed") { outcome in
      completion(outcome.map { _ in () })
    }
  }

  /// 读取 AAR 包名列表（INS=0x66）。返回逗号分隔的包名字符串，列表为空时返回 ""。
  func readAar(completion: @escaping (Result<String, Error>) -> Void) {
    channel.send(apduData: HdWalletApdu.simple(ins: HdWalletApdu.insGetAar), context: "Read AAR failed") { outcome in
      switch outcome {
      case .success(let raw):
        guard raw.count >= 2 else { completion(.success(""));  return }
        let tag = raw[0]
        let len = Int(raw[1])
        if tag != HdWalletApdu.tagAarData || raw.count < 2 + len {
          completion(.success(""))
          return
        }
        let str = String(data: raw.subdata(in: 2..<(2 + len)), encoding: .utf8) ?? ""
        completion(.success(str))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  // MARK: - writeUid（裸 APDU，不加密）

  func writeUid(completion: @escaping (Result<Void, Error>) -> Void) {
    guard let uid = Data(hexString: cardId) else {
      completion(.failure(PigeonError(code: "invalid-uid", message: "cardId cannot be parsed as bytes", details: nil)))
      return
    }
    let payload = Data([HdWalletApdu.tagUidStore]) + Data([UInt8(uid.count)]) + uid
    let apdu = HdWalletApdu.withData(ins: HdWalletApdu.insStoreUid, data: payload)
    channel.sendRaw(apduData: apdu) { outcome in
      switch outcome {
      case .success(let response):
        do {
          try ensureSuccessStatus(response: response, message: "Write UID failed")
          completion(.success(()))
        } catch {
          completion(.failure(error))
        }
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  // MARK: - Private helpers

  private func parseKeyMaterial(_ payload: Data) throws -> KeyMaterial {
    let tags = try parseResponse(payload)
    guard let publicKey = tags[HdWalletApdu.tagPublicKey] else {
      throw PigeonError(code: "invalid-response", message: "Missing 0x90 public key tag", details: nil)
    }
    guard let chainCode = tags[HdWalletApdu.tagChainCode] else {
      throw PigeonError(code: "invalid-response", message: "Missing 0x92 ChainCode tag", details: nil)
    }
    return KeyMaterial(publicKey: publicKey, chainCode: chainCode)
  }
}

private enum HdWalletApdu {
  static let hdWalletAid = Data([0x68, 0x64, 0x69, 0x6E, 0x73, 0x74, 0x61, 0x63, 0x61, 0x73, 0x68, 0x00])

  static let cla: UInt8 = 0x80
  static let insGetStatus: UInt8 = 0x31
  static let insGenerateKey: UInt8 = 0x41
  static let insDerive: UInt8 = 0x42
  static let insSign: UInt8 = 0x43
  // PIN 管理
  static let insCreatePin: UInt8 = 0x50
  static let insUpdatePin: UInt8 = 0x51
  static let insUnlock: UInt8 = 0x52
  static let insCancelPin: UInt8 = 0x57
  // NDEF 读/写
  static let insGetNdef: UInt8 = 0x62
  static let insStoreNdef: UInt8 = 0x63
  // UID 同步写入
  static let insStoreUid: UInt8 = 0x65
  // AAR（Android Application Record）包名读/写
  static let insGetAar: UInt8 = 0x66
  static let insStoreAar: UInt8 = 0x67
  static let tagAarData: UInt8 = 0xAC

  static let tagPublicKey: UInt8 = 0x90
  static let tagPrivateKey: UInt8 = 0x91
  static let tagChainCode: UInt8 = 0x92
  static let tagSignMessage: UInt8 = 0x93
  static let tagDerivePath: UInt8 = 0x94
  static let tagPinCode: UInt8 = 0x95
  static let tagPukCode: UInt8 = 0x96
  static let tagSignature: UInt8 = 0x98
  static let tagHasKeyPair: UInt8 = 0x99
  static let tagPinSet: UInt8 = 0x9A
  static let tagNdefUrl: UInt8 = 0x9B
  static let tagPinRetry: UInt8 = 0x9C
  static let tagPukRetry: UInt8 = 0x9D
  static let tagAppletVersion: UInt8 = 0xA0
  static let tagMasterKeyMaterial: UInt8 = 0xA1
  static let tagAppletVersionCode: UInt8 = 0xA2
  static let tagResetCount: UInt8 = 0xA4
  static let tagUid: UInt8 = 0xA5
  static let tagUidStore: UInt8 = 0xA5

  static func simple(ins: UInt8) -> Data {
    Data([cla, ins, 0x00, 0x00])
  }

  static func withData(ins: UInt8, data: Data) -> Data {
    Data([cla, ins, 0x00, 0x00, UInt8(data.count)]) + data
  }

  static func tlv(tag: UInt8, value: Data) -> Data {
    Data([tag, UInt8(value.count)]) + value
  }
}

// MARK: - TLV 解析（通用，支持 BER-TLV 0x81/0x82 多字节长度，与 Android 对齐）

private func parseResponse(_ payload: Data) throws -> [UInt8: Data] {
  var tags: [UInt8: Data] = [:]
  var index = 0
  let bytes = Array(payload)
  while index < bytes.count {
    let tag = bytes[index]
    if tag == 0x00 { break }
    index += 1
    guard index < bytes.count else { break }
    let lenByte = Int(bytes[index])
    index += 1
    let length: Int
    if lenByte <= 0x7F {
      length = lenByte
    } else if lenByte == 0x81 {
      guard index < bytes.count else {
        throw PigeonError(code: "invalid-response", message: "BER-TLV 0x81 length incomplete", details: nil)
      }
      length = Int(bytes[index])
      index += 1
    } else if lenByte == 0x82 {
      guard index + 1 < bytes.count else {
        throw PigeonError(code: "invalid-response", message: "BER-TLV 0x82 length incomplete", details: nil)
      }
      length = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
      index += 2
    } else {
      throw PigeonError(code: "invalid-response", message: "Unsupported TLV length 0x\(String(lenByte, radix: 16, uppercase: true))", details: nil)
    }
    let end = index + length
    guard end <= bytes.count else {
      throw PigeonError(code: "invalid-response", message: "TLV length out of bounds", details: nil)
    }
    tags[tag] = Data(bytes[index..<end])
    index = end
  }
  return tags
}

// MARK: - getStatus 响应专用解析（已知 tag 顺序扫描，与 Android 一致）

private func parseStatusResponse(_ payload: Data) throws -> [UInt8: Data] {
  let knownTags: [UInt8] = [
    HdWalletApdu.tagHasKeyPair,       // 0x99
    HdWalletApdu.tagPinSet,           // 0x9A
    HdWalletApdu.tagPinRetry,         // 0x9C
    HdWalletApdu.tagPukRetry,         // 0x9D
    0x9E,
    0x9F,
    HdWalletApdu.tagAppletVersion,    // 0xA0
    0xA1,
    HdWalletApdu.tagAppletVersionCode,// 0xA2
    0xA3,
    HdWalletApdu.tagResetCount,       // 0xA4
    HdWalletApdu.tagUid,              // 0xA5
    0xA6,
    0xA7,
    0xA8,
  ]
  var map: [UInt8: Data] = [:]
  let bytes = Array(payload)
  for tag in knownTags {
    guard let idx = bytes.firstIndex(where: { $0 == tag }) else { continue }
    guard idx + 1 < bytes.count else { continue }
    let len = Int(bytes[idx + 1])
    let end = idx + 2 + len
    guard end <= bytes.count else { continue }
    map[tag] = Data(bytes[(idx + 2)..<end])
  }
  return map
}

