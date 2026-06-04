import CommonCrypto
import CoreNFC
import Foundation

// MARK: - Card data structures

struct KeyMaterial {
  let publicKey: Data
  let chainCode: Data
}

struct CardStatus {
  let hasKeyPair: Bool
  let masterKeyFlagSet: Bool
  let pinSet: Bool
  let uid: Data?
  let version: String?
  let versionCode: String?
  let resetCount: Int64
  let pinRetry: Int
  let pukRetry: Int
  /// PIN 已耗尽，需 PUK 解锁
  var isLock: Bool { pinRetry == 0 && pukRetry > 0 }
  /// PUK 也已耗尽，卡片作废
  var isExpired: Bool { pinRetry == 0 && pukRetry == 0 }
}

struct CardSnapshot {
  let cardId: String
  let uid: String
  let isPasswordSet: Bool
  let masterPublicKey: Data
  let masterChainCode: Data
  let currencies: [CurrencyInfoMessage?]
}

// MARK: - IOSSessionChannel

struct IOSSessionChannel {
  let tag: NFCISO7816Tag
  let cardId: String
  /// SELECT APPLET 响应数据 + 卡 UID 前 4 字节，与 Android 保持一致
  var aesKey: Data

  // MARK: - 裸 APDU 发送（不做加解密）

  func sendRaw(apduData: Data, completion: @escaping (Result<Data, Error>) -> Void) {
    do {
      let apdu = try apduData.parseApdu()
      tag.sendCommand(apdu: apdu) { data, sw1, sw2, error in
        if let error {
          completion(.failure(error))
          return
        }
        var response = data
        response.append(sw1)
        response.append(sw2)
        completion(.success(response))
      }
    } catch {
      completion(.failure(error))
    }
  }

  // MARK: - 带 AES 加解密的发送（skipEncrypt=true 时不加密，对应 getStatus / generateKeyPair）

  func send(apduData: Data, context: String, skipEncrypt: Bool = false, completion: @escaping (Result<Data, Error>) -> Void) {
    let actualApdu: Data
    if apduData.count > 4, !aesKey.isEmpty, !skipEncrypt {
      let plainData = apduData.dropFirst(5)
      if let enc = aesCbcEncrypt(data: Data(plainData), key: aesKey) {
        actualApdu = apduData.prefix(4) + Data([UInt8(enc.count)]) + enc + Data([0x00])
      } else {
        actualApdu = apduData + Data([0x00])
      }
    } else if apduData.count > 4 {
      actualApdu = apduData + Data([0x00])
    } else {
      actualApdu = apduData
    }
    sendRaw(apduData: actualApdu) { outcome in
      switch outcome {
      case .success(let response):
        do {
          try ensureSuccessStatus(response: response, message: context)
          let body = response.dropLast(2)
          if body.isEmpty || self.aesKey.isEmpty {
            completion(.success(body))
            return
          }
          if let decrypted = aesCbcDecrypt(data: body, key: self.aesKey) {
            completion(.success(decrypted))
          } else {
            completion(.success(body))
          }
        } catch {
          completion(.failure(error))
        }
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }
}

// MARK: - AES-128-CBC helpers（与 Android 一致，IV = key，PKCS7 填充）

func aesCbcEncrypt(data: Data, key: Data) -> Data? {
  let keyBytes = key.prefix(16)
  let padLen = 16 - (data.count % 16)
  var padded = data
  padded.append(contentsOf: repeatElement(UInt8(padLen), count: padLen))
  var output = Data(count: padded.count)
  var numBytesEncrypted = 0
  let status = keyBytes.withUnsafeBytes { keyPtr in
    padded.withUnsafeBytes { dataPtr in
      output.withUnsafeMutableBytes { outPtr in
        CCCrypt(
          CCOperation(kCCEncrypt),
          CCAlgorithm(kCCAlgorithmAES),
          CCOptions(0),
          keyPtr.baseAddress, kCCKeySizeAES128,
          keyPtr.baseAddress,
          dataPtr.baseAddress, padded.count,
          outPtr.baseAddress, padded.count,
          &numBytesEncrypted
        )
      }
    }
  }
  guard status == kCCSuccess else { return nil }
  return output.prefix(numBytesEncrypted)
}

func aesCbcDecrypt(data: Data, key: Data) -> Data? {
  guard !data.isEmpty, data.count % 16 == 0 else { return nil }
  let keyBytes = key.prefix(16)
  var output = Data(count: data.count)
  var numBytesDecrypted = 0
  let status = keyBytes.withUnsafeBytes { keyPtr in
    data.withUnsafeBytes { dataPtr in
      output.withUnsafeMutableBytes { outPtr in
        CCCrypt(
          CCOperation(kCCDecrypt),
          CCAlgorithm(kCCAlgorithmAES),
          CCOptions(0),
          keyPtr.baseAddress, kCCKeySizeAES128,
          keyPtr.baseAddress,
          dataPtr.baseAddress, data.count,
          outPtr.baseAddress, data.count,
          &numBytesDecrypted
        )
      }
    }
  }
  guard status == kCCSuccess else { return nil }
  var result = output.prefix(numBytesDecrypted)
  if let padLen = result.last.map({ Int($0) }),
     padLen >= 1, padLen <= 16,
     result.count >= padLen,
     result.suffix(padLen).allSatisfy({ $0 == UInt8(padLen) }) {
    result = result.dropLast(padLen)
  }
  return Data(result)
}

// MARK: - IOSIso7816SessionManager

final class IOSIso7816SessionManager {
  private var delegateRef: AnyObject?
  private weak var currentSession: NFCTagReaderSession?

  func withSession(appletId: Data?, operation: @escaping (IOSSessionChannel, @escaping (Result<Any, Error>) -> Void) -> Void, completion: @escaping (Result<Any, Error>) -> Void) {
    guard #available(iOS 13.0, *) else {
      completion(.failure(PigeonError(code: "nfc-unavailable", message: "ISO 7816 tag sessions require iOS 13 or later", details: nil)))
      return
    }
    guard NFCTagReaderSession.readingAvailable else {
      completion(.failure(PigeonError(code: "nfc-unavailable", message: "NFC is not supported on this device", details: nil)))
      return
    }

    let delegate = ISO7816TagSessionDelegate(appletId: appletId, operation: operation, completion: completion)
    guard let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: delegate) else {
      completion(.failure(PigeonError(code: "nfc-unavailable", message: "Failed to create NFC session", details: nil)))
      return
    }
    session.alertMessage = "Hold your card near  iphone camera on upper back, until you see a ✅"
    delegate.bind(session: session)
    delegateRef = delegate
    currentSession = session
    session.begin()
  }

  func reset() {
    currentSession?.invalidate()
    currentSession = nil
    delegateRef = nil
  }

  /// 弹出 PIN 输入对话框（6 位数字），completion(nil) 表示用户取消。
  func showPinInputDialog(completion: @escaping (Data?) -> Void) {
    DispatchQueue.main.async {
      let alert = UIAlertController(title: "PIN Required", message: "Enter your 6-digit PIN", preferredStyle: .alert)
      alert.addTextField { tf in
        tf.keyboardType        = .numberPad
        tf.isSecureTextEntry   = true
        tf.placeholder         = "6-digit PIN"
      }
      alert.addAction(UIAlertAction(title: "Confirm", style: .default) { _ in
        guard let text = alert.textFields?.first?.text, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
          completion(nil); return
        }
        // 与 Android 对齐：每个数字字符转为数值字节（'0'→0x00, '1'→0x01 ... '9'→0x09）
        let data = Data(text.unicodeScalars.map { UInt8($0.value - 48) })
        completion(data)
      })
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) })
      // iOS 15+ 推荐使用 connectedScenes 获取 rootViewController
      let keyWindow: UIWindow?
      if #available(iOS 15.0, *) {
        keyWindow = UIApplication.shared.connectedScenes
          .compactMap { $0 as? UIWindowScene }
          .flatMap { $0.windows }
          .first { $0.isKeyWindow }
      } else {
        keyWindow = UIApplication.shared.windows.first { $0.isKeyWindow }
      }
      keyWindow?.rootViewController?.present(alert, animated: true)
    }
  }
}

// MARK: - ISO7816TagSessionDelegate

@available(iOS 13.0, *)
final class ISO7816TagSessionDelegate: NSObject, NFCTagReaderSessionDelegate {
  private let appletId: Data?
  private let operation: (IOSSessionChannel, @escaping (Result<Any, Error>) -> Void) -> Void
  private let completion: (Result<Any, Error>) -> Void
  private weak var session: NFCTagReaderSession?
  private var finished = false

  init(appletId: Data?, operation: @escaping (IOSSessionChannel, @escaping (Result<Any, Error>) -> Void) -> Void, completion: @escaping (Result<Any, Error>) -> Void) {
    self.appletId = appletId
    self.operation = operation
    self.completion = completion
  }

  func bind(session: NFCTagReaderSession) {
    self.session = session
  }

  func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

  func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
    let mapped = IOSNfcErrorMapper.map(error)
    finish(.failure(mapped), invalidate: false)
  }

  func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
    guard let firstTag = tags.first else {
      finish(.failure(PigeonError(code: "tag-missing", message: "No tag detected", details: nil)))
      return
    }
    session.connect(to: firstTag) { connectError in
      if let connectError {
        self.finish(.failure(IOSNfcErrorMapper.map(connectError)))
        return
      }
      guard case let .iso7816(tag) = firstTag else {
        self.finish(.failure(PigeonError(code: "tag-unsupported", message: "Tag does not support ISO 7816", details: nil)))
        return
      }
      self.selectAppletIfNeeded(tag: tag, tagId: tag.identifier)
    }
  }

  private func selectAppletIfNeeded(tag: NFCISO7816Tag, tagId: Data) {
    if let appletId, !appletId.isEmpty {
      let selectApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04, p2Parameter: 0x00, data: appletId, expectedResponseLength: -1)
      tag.sendCommand(apdu: selectApdu) { data, sw1, sw2, error in
        if let error {
          self.finish(.failure(error))
          return
        }
        var response = data
        response.append(sw1)
        response.append(sw2)
        do {
          try ensureSuccessStatus(response: response, message: "Select applet failed")
          let aesKeyBase = response.dropLast(2)
          let aesKey = aesKeyBase + tagId.prefix(4)
          NSLog("ChipCoreNfc: SELECT aesKeyBase [%d] %@", aesKeyBase.count, aesKeyBase.hexString)
          NSLog("ChipCoreNfc: sessionKey [%d] %@", aesKey.count, aesKey.hexString)
          self.beginOperation(tag: tag, tagId: tagId, aesKey: aesKey)
        } catch {
          self.finish(.failure(error))
        }
      }
    } else {
      beginOperation(tag: tag, tagId: tagId, aesKey: Data())
    }
  }

  private func beginOperation(tag: NFCISO7816Tag, tagId: Data, aesKey: Data) {
    let channel = IOSSessionChannel(tag: tag, cardId: tagId.hexString, aesKey: aesKey)
    operation(channel) { result in
      self.finish(result)
    }
  }

  private func finish(_ result: Result<Any, Error>, invalidate: Bool = true) {
    guard !finished else { return }
    finished = true
    if invalidate {
      if case .failure(let error) = result {
        let pigeonErr = error as? PigeonError
        // "pin-required" 是流程控制信号而非真正错误，静默关闭 NFC UI，再弹 PIN 输入框
        if pigeonErr?.code == "pin-required" {
          session?.invalidate()
        } else {
          let errMsg = pigeonErr?.message ?? error.localizedDescription
          session?.invalidate(errorMessage: errMsg)
        }
      } else {
        session?.invalidate()
      }
    }else {
        session?.invalidate()
    }
    completion(result)
  }
}

// MARK: - APDU helpers

extension Data {
  var bytes: [UInt8] { Array(self) }

  func parseApdu() throws -> NFCISO7816APDU {
    if count < 4 {
      throw PigeonError(code: "invalid-apdu", message: "APDU must be at least 4 bytes", details: nil)
    }
    let bytes = Array(self)
    let cla = bytes[0]
    let ins = bytes[1]
    let p1 = bytes[2]
    let p2 = bytes[3]
    if count == 4 {
      return NFCISO7816APDU(instructionClass: cla, instructionCode: ins, p1Parameter: p1, p2Parameter: p2, data: Data(), expectedResponseLength: -1)
    }
    let lc = Int(bytes[4])
    let start = 5
    let end = start + lc
    guard end <= count else {
      throw PigeonError(code: "invalid-apdu", message: "APDU Lc does not match actual data length", details: nil)
    }
    let body = lc > 0 ? Data(bytes[start..<end]) : Data()
    // Le=0x00 in ISO 7816 means "expect up to 256 bytes"; absent Le = -1 (any length)
    let le: Int = end < count ? (bytes[end] == 0 ? 256 : Int(bytes[end])) : -1
    return NFCISO7816APDU(instructionClass: cla, instructionCode: ins, p1Parameter: p1, p2Parameter: p2, data: body, expectedResponseLength: le)
  }

  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }

  var unsignedIntValue: UInt64 {
    reduce(0) { ($0 << 8) | UInt64($1) }
  }

  func compressedSecp256k1() -> Data {
    if count == 33 { return self }
    guard count == 65, first == 0x04 else { return self }
    let yLastByte = self[index(before: endIndex)]
    let prefix: UInt8 = (yLastByte & 1) == 0 ? 0x02 : 0x03
    return Data([prefix]) + self[1..<33]
  }
}

extension String {
  func hexToData() -> Data? {
    let normalized = lowercased().replacingOccurrences(of: "0x", with: "")
    guard normalized.count % 2 == 0 else { return nil }
    var result = Data(capacity: normalized.count / 2)
    var index = normalized.startIndex
    while index < normalized.endIndex {
      let next = normalized.index(index, offsetBy: 2)
      guard let byte = UInt8(normalized[index..<next], radix: 16) else { return nil }
      result.append(byte)
      index = next
    }
    return result
  }
}

func ensureSuccessStatus(response: Data, message: String) throws {
  guard response.count >= 2 else {
    throw PigeonError(code: "apdu-error", message: "\(message): response too short", details: nil)
  }
  let sw1 = response[response.index(response.endIndex, offsetBy: -2)]
  let sw2 = response[response.index(response.endIndex, offsetBy: -1)]
  guard sw1 == 0x90, sw2 == 0x00 else {
    throw PigeonError(code: "apdu-error", message: String(format: "%@: SW=%02X%02X", message, sw1, sw2), details: nil)
  }
}

// MARK: - IOSNfcErrorMapper
// 将 CoreNFC 原生错误统一映射到与 Android 对齐的 PigeonError 码：
//   user-cancelled / nfc-timeout / nfc-tag-lost / nfc-io / tag-unsupported

@available(iOS 13.0, *)
enum IOSNfcErrorMapper {
  static func map(_ error: Error) -> PigeonError {
    if let pigeonErr = error as? PigeonError { return pigeonErr }
    guard let nfcErr = error as? NFCReaderError else {
      return PigeonError(code: "nfc-io", message: error.localizedDescription, details: nil)
    }
    switch nfcErr.code {
    case .readerSessionInvalidationErrorUserCanceled:
      return PigeonError(code: "user-cancelled", message: "Session invalidated by user", details: nil)
    case .readerSessionInvalidationErrorSessionTimeout:
      return PigeonError(code: "nfc-timeout", message: "Session timed out. Hold your card closer and try again", details: nil)
    case .readerSessionInvalidationErrorSessionTerminatedUnexpectedly,
         .readerTransceiveErrorTagConnectionLost,
         .readerTransceiveErrorSessionInvalidated,
         .readerTransceiveErrorTagNotConnected:
      return PigeonError(code: "nfc-tag-lost", message: "NFC connection lost. Keep your card steady against the device and try again", details: nil)
    case .readerSessionInvalidationErrorSystemIsBusy:
      return PigeonError(code: "nfc-io", message: "NFC system is busy. Please try again shortly", details: nil)
    default:
      return PigeonError(code: "nfc-io", message: nfcErr.localizedDescription, details: nil)
    }
  }
}
