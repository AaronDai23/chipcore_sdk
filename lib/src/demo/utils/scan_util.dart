import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../pigeon/messages.dart';

// ─── 响应封装 ────────────────────────────────────────────────

class ScanResponse<T> {
  final bool isSuccess;
  final T? data;
  final String? message;
  final int? sw1;
  final int? sw2;

  /// PlatformException.code，用于区分非 SW 类错误（如 user-cancelled、nfc-tag-lost 等）
  final String? errorCode;

  const ScanResponse(
    this.isSuccess, {
    this.data,
    this.message,
    this.sw1,
    this.sw2,
    this.errorCode,
  });

  bool get isCardLocked => sw1 == 0xAA && sw2 == 0x23;
  bool get isPinIncorrect => sw1 == 0xAA && sw2 == 0x21;
  bool get isPukIncorrect => sw1 == 0xAA && sw2 == 0x24;
  bool get isPinRequired => sw1 == 0xAA && sw2 == 0x22;
  bool get isCardExpired => sw1 == 0xAA && sw2 == 0x25;

  /// 用户主动取消 NFC 扫描弹层
  bool get isCancelled => errorCode == 'user-cancelled';

  /// NFC 连接中断（卡片移开）
  bool get isTagLost => errorCode == 'nfc-tag-lost';

  /// 等待超时（未靠近卡片）
  bool get isTimeout => errorCode == 'nfc-timeout';
}

// ─── SW 状态码 → 可读文案 ────────────────────────────────────

String swErrorMessage(int sw1, int sw2) {
  if (sw1 == 0xAA) {
    switch (sw2) {
      case 0x00:
        return 'Command not allowed';
      case 0x02:
        return 'Invalid P1/P2 parameter';
      case 0x03:
        return 'Invalid data length';
      case 0x10:
        return 'Invalid UID length';
      case 0x11:
        return 'UID verification failed';
      case 0x12:
        return 'Invalid UID data';
      case 0x20:
        return 'Invalid data';
      case 0x21:
        return 'Incorrect PIN';
      case 0x22:
        return 'PIN verification required';
      case 0x23:
        return 'Card locked. Please use PUK to unlock.';
      case 0x24:
        return 'Incorrect PUK';
      case 0x25:
        return 'Card expired. PUK retry limit reached.';
      case 0x30:
        return 'Card not initialized. No key pair found.';
      case 0x31:
        return 'Key pair already exists';
    }
  }
  if (sw1 == 0xAB) {
    switch (sw2) {
      case 0x12:
        return 'Invalid PUK tag';
    }
  }
  if (sw1 == 0xAC) {
    switch (sw2) {
      case 0x01:
        return 'UID not written to card. Secure channel unavailable (AC01)';
    }
  }
  return '未知错误 (SW=${sw1.toRadixString(16).toUpperCase().padLeft(2, '0')}${sw2.toRadixString(16).toUpperCase().padLeft(2, '0')})';
}

/// 从 PlatformException 中解析 SW1/SW2（Kotlin 侧格式: "...: SW=AA21"）
({int sw1, int sw2})? _parseSw(PlatformException e) {
  final msg = e.message ?? '';
  final match = RegExp(r'SW=([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})').firstMatch(msg);
  if (match == null) return null;
  return (
    sw1: int.parse(match.group(1)!, radix: 16),
    sw2: int.parse(match.group(2)!, radix: 16),
  );
}

/// 将 PlatformException/Exception 统一转换为失败的 ScanResponse
///
/// 错误码来源（iOS/Android 双端对齐）：
///   NFC 层：user-cancelled / nfc-timeout / nfc-tag-lost / nfc-io /
///           nfc-unavailable / nfc-disabled / tag-unsupported
///   APDU 层：apdu-error（附 SW=XXYY）/ invalid-response
///   卡片状态：card-locked / card-expired / card-hardware-error / uid-not-synced
///   派生/签名：no-pubkey / sign-error / sig-format
///   交易：insufficient-funds / broadcast-error / fee-error /
///         contract-missing / eth-prepare-error
ScanResponse<T> _fromException<T>(Object e) {
  if (e is PlatformException) {
    final code = e.code;
    final msg = e.message;

    // ── APDU SW 状态码（最高优先级）────────────────────────────
    final sw = _parseSw(e);
    if (sw != null) {
      return ScanResponse(false,
          message: swErrorMessage(sw.sw1, sw.sw2),
          sw1: sw.sw1,
          sw2: sw.sw2,
          errorCode: code);
    }

    // ── 卡片状态 ──────────────────────────────────────────────
    if (code == 'card-locked') {
      return ScanResponse(false,
          message: 'Card locked. Please use PUK to unlock.',
          sw1: 0xAA,
          sw2: 0x23,
          errorCode: code);
    }
    if (code == 'card-expired') {
      return ScanResponse(false,
          message: msg ?? 'Card expired. PUK retry limit reached.',
          sw1: 0xAA,
          sw2: 0x25,
          errorCode: code);
    }
    if (code == 'card-hardware-error') {
      return ScanResponse(false,
          message: msg ??
              'Card key storage error. Please contact your card provider.',
          errorCode: code);
    }
    if (code == 'uid-not-synced') {
      return ScanResponse(false,
          message: msg ?? 'Card UID not synced. Please try again.',
          errorCode: code);
    }
    if (code == 'uid-mismatch') {
      // details 字段携带了实际扫到的卡片 cardId，构造 CommandResponse 供 Flutter 层比对
      final scannedId = (e.details as String?) ?? '';
      final T? payload = scannedId.isNotEmpty && T == CommandResponse
          ? (CommandResponse(
              cardId: scannedId,
              appletVersionCode: '',
              appletVersion: '',
              isActivated: false,
              resetCount: 0,
            ) as T)
          : null;
      return ScanResponse(false,
          message: msg ?? 'Wrong card. Please use the same card as before.',
          errorCode: code,
          data: payload);
    }

    // ── NFC 层 ────────────────────────────────────────────────
    if (code == 'user-cancelled') {
      return ScanResponse(false,
          message: msg ?? 'Session invalidated by user', errorCode: code);
    }
    if (code == 'nfc-timeout') {
      return ScanResponse(false,
          message:
              msg ?? 'Session timed out. Hold your card closer and try again',
          errorCode: code);
    }
    if (code == 'nfc-tag-lost') {
      return ScanResponse(false,
          message: msg ??
              'NFC connection lost. Keep your card steady against the device and try again',
          errorCode: code);
    }
    if (code == 'nfc-unavailable') {
      return ScanResponse(false,
          message: msg ?? 'NFC is not supported on this device',
          errorCode: code);
    }
    if (code == 'nfc-disabled') {
      return ScanResponse(false,
          message: msg ?? 'Please enable NFC in system settings',
          errorCode: code);
    }
    if (code == 'nfc-io') {
      return ScanResponse(false,
          message: msg ?? 'NFC communication error. Please try again',
          errorCode: code);
    }
    if (code == 'tag-unsupported') {
      return ScanResponse(false,
          message: msg ?? 'Tag does not support ISO 7816 / ISO-DEP',
          errorCode: code);
    }

    // ── 派生 / 签名 ───────────────────────────────────────────
    if (code == 'no-pubkey') {
      return ScanResponse(false,
          message: msg ?? 'Public key not derived. Please scan card first.',
          errorCode: code);
    }
    if (code == 'sign-error' || code == 'sig-format') {
      return ScanResponse(false,
          message: msg ?? 'Signing failed. Please try again.', errorCode: code);
    }

    // ── 交易 ──────────────────────────────────────────────────
    if (code == 'insufficient-funds') {
      return ScanResponse(false,
          message: msg ?? 'Insufficient balance to cover amount and fees',
          errorCode: code);
    }
    if (code == 'fee-error') {
      return ScanResponse(false,
          message: msg ??
              'Failed to fetch fee. Please check your network and try again.',
          errorCode: code);
    }
    if (code == 'broadcast-error') {
      return ScanResponse(false,
          message: msg ??
              'Transaction broadcast failed. Please check your network and try again.',
          errorCode: code);
    }
    if (code == 'contract-missing') {
      return ScanResponse(false,
          message: msg ??
              'Contract address not found. Please scan card to initialize currencies first.',
          errorCode: code);
    }
    if (code == 'eth-prepare-error') {
      return ScanResponse(false,
          message: msg ?? 'Failed to build ETH transaction', errorCode: code);
    }

    // ── 其他已知码 ────────────────────────────────────────────
    if (code == 'invalid-response') {
      return ScanResponse(false,
          message: msg ?? 'Invalid card response format', errorCode: code);
    }
    if (code == 'invalid-amount') {
      return ScanResponse(false,
          message: msg ?? 'Invalid amount format', errorCode: code);
    }

    // ── 兜底 ──────────────────────────────────────────────────
    return ScanResponse(false, message: msg ?? code, errorCode: code);
  }
  return ScanResponse(false, message: e.toString());
}

// ─── ScanUtil ────────────────────────────────────────────────

class ScanUtil {
  ScanUtil._();

  static final _api = BlockchainApi();

  // ── NFC 扫卡 ──────────────────────────────────────────────

  /// 扫卡 + 派生地址（对应 scanCardAndDerive）
  static Future<ScanResponse<CardMessage>> scanCardAndDerive(
    List<CurrencyInfoMessage> currencies, {
    String walletName = '',
    String? cardId,
    String? cardNo,
  }) async {
    try {
      final card =
          await _api.scanCardAndDerive(currencies, walletName, cardId, cardNo);
      return ScanResponse(true, data: card);
    } catch (e) {
      return _fromException(e);
    }
  }

  /// 创建钱包 + 派生地址（对应 createWalletAndDerive，新卡初始化）
  static Future<ScanResponse<CardMessage>> createWalletAndDerive(
    List<CurrencyInfoMessage> currencies,
  ) async {
    try {
      final card = await _api.createWalletAndDerive(currencies);
      return ScanResponse(true, data: card);
    } catch (e) {
      return _fromException(e);
    }
  }

  /// 发送原始 APDU 命令
  static Future<ScanResponse<CommandResponse>> sendCommand(
    Uint8List command, {
    bool checkLock = false,
    bool needSyncUid = false,
    String? ndefLink,
    String? cardId,
    String? cardNo,
  }) async {
    try {
      final resp = await _api.scanCardWithCommand(
        SendCommandMessage(
          command: command,
          checkLock: checkLock,
          needSyscUid: needSyncUid,
          ndefLink: ndefLink,
          cardId: cardId,
          cardNo: cardNo,
        ),
      );
      return ScanResponse(true, data: resp);
    } catch (e) {
      return _fromException(e);
    }
  }

  /// 仅扫卡（无额外 APDU），可附带 NDEF 写入 / UID 同步
  static Future<ScanResponse<CommandResponse>> scanOnly({
    bool checkLock = false,
    bool needSyncUid = false,
    String? ndefLink,
  }) async {
    try {
      final resp = await _api.scanCardWithCommand(
        SendCommandMessage(
          checkLock: checkLock,
          needSyscUid: needSyncUid,
          ndefLink: ndefLink,
        ),
      );
      return ScanResponse(true, data: resp);
    } catch (e) {
      return _fromException(e);
    }
  }

  // ── 链上操作（不需要靠卡）──────────────────────────────────

  /// 生成密钥对（对应 generateKey）
  static Future<ScanResponse<String>> generateKey() async {
    try {
      final pubKey = await _api.generateKey();
      return ScanResponse(true, data: pubKey);
    } catch (e) {
      return _fromException(e);
    }
  }

  /// 初始化 WalletManager 并触发异步余额拉取（对应 BlockchainMethods.loadCurrencyInfoList）
  /// 余额结果通过 [registerBalanceCallback] 注册的回调异步返回。
  static Future<void> loadCurrencyInfoList(
      List<CurrencyInfoMessage> currencies) async {
    try {
      await _api.loadCurrencyInfoList(currencies);
    } catch (e) {
      // 余额拉取失败时忽略，不影响主流程
    }
  }

  /// 注册 Kotlin → Flutter 余额回调（对应 BlockchainMethods.getCurrencyListInfo → flutterClientApi）。
  /// 每次调用 [loadCurrencyInfoList] 后，Kotlin 异步拉取完成时会触发此回调。
  /// [onUpdate] 参数：Map<symbol(大写), balance字符串>
  /// [onError] 可选：某条链余额获取失败时调用，参数为错误描述字符串
  static void registerBalanceCallback(
      void Function(Map<String, String?> balances) onUpdate,
      {void Function(String message)? onError}) {
    FlutterClientApi.setUp(_FlutterClientApiImpl(onUpdate, onError: onError));
  }

  /// 查询手续费
  static Future<ScanResponse<List<FeeResponse>>> getFee(
      FeeMessage message) async {
    try {
      final fees = await _api.getFee(message);
      return ScanResponse(true, data: fees);
    } catch (e) {
      return _fromException(e);
    }
  }

  /// 发起交易（签名需靠卡）
  static Future<ScanResponse<SendTransactionResponse>> sendTransaction(
      SendMessage message) async {
    try {
      final resp = await _api.sendTransaction(message);
      return ScanResponse(true, data: resp);
    } catch (e) {
      return _fromException(e);
    }
  }

  /// 验证地址（本地，无需靠卡）
  static Future<ScanResponse<bool>> validateAddress(
      ValidateAddressMessage message) async {
    try {
      final isValid = await _api.validateAddress(message);
      return ScanResponse(true, data: isValid);
    } catch (e) {
      return _fromException(e);
    }
  }

  /// 查询交易历史
  static Future<ScanResponse<List<TransactionsHistory>>>
      loadTransactionHistoryList(TransactionHistoryRequest request) async {
    try {
      final list = await _api.loadTransactionHistoryList(request);
      return ScanResponse(true, data: list);
    } catch (e) {
      return _fromException(e);
    }
  }

  // ── UI 提示 ───────────────────────────────────────────────

  /// 失败时弹出 SnackBar；锁卡时可弹对话框引导解锁
  static void showError(
    BuildContext context,
    ScanResponse response, {
    bool showLockDialog = false,
    VoidCallback? onUnlock,
  }) {
    if (response.isSuccess) return;
    final msg = response.message ?? '未知错误';

    if (showLockDialog && response.isCardLocked) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('卡片已锁定'),
          content: Text(msg),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                onUnlock?.call();
              },
              child: const Text('前往解锁'),
            ),
          ],
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 4),
        backgroundColor: Colors.red,
      ),
    );
  }

  /// 成功时弹出绿色 SnackBar
  static void showSuccess(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        backgroundColor: Colors.green,
      ),
    );
  }
}

// ─── FlutterClientApi 实现（Kotlin → Flutter 余额回调）────────────────────────

class _FlutterClientApiImpl implements FlutterClientApi {
  final void Function(Map<String, String?> balances) _onUpdate;
  final void Function(String message)? _onError;

  const _FlutterClientApiImpl(this._onUpdate, {void Function(String)? onError})
      : _onError = onError;

  @override
  bool updateCurrencyInfo(List<BalanceResponse> currencyInfoList) {
    debugPrint(
        '[FlutterClientApi] updateCurrencyInfo called, count=${currencyInfoList.length}');
    final Map<String, String?> balances = {};
    for (final response in currencyInfoList) {
      final data = response.data;
      final symbol = data.symbol.toUpperCase();
      final errMsg = response.errorMessage?.customMessage;
      debugPrint(
          '[FlutterClientApi] symbol=$symbol amount=${data.amount} error=$errMsg');
      if (errMsg != null && errMsg.isNotEmpty) {
        balances[symbol] = '--';
        _onError?.call('$symbol 余额获取失败: $errMsg');
      } else {
        balances[symbol] = data.amount;
      }
    }
    if (balances.isNotEmpty) {
      debugPrint('[FlutterClientApi] dispatching onBalanceUpdated: $balances');
      _onUpdate(balances);
    }
    return true;
  }
}
