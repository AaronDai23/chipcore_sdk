import 'package:fish_redux/fish_redux.dart';

import '../../pigeon/messages.dart';

enum HomeActionType {
  scanCard,
  createWallet,
  generateKey,
  getFee,
  sendTransaction,
  writeNdef,
  readNdef,
  syncUid,
  validateAddr,
  setPin,
  updatePin,
  cancelPin,
  unlockCard,
  queryPinStatus,
  checkLockStatus,
  getBalance,
  getTxHistory,
  onPageInit, // 页面初始化时尝试从缓存恢复
  // 纯 reducer 动作
  onLoading,
  onLog,
  onCardInfo,
  onFees,
  onTxResult,
  onNdefLink,
  onChainChanged,
  onIsTestChanged,
  onToAddressChanged,
  onAmountChanged,
  onFeeSelected,
  onPinInputChanged,
  onPukInputChanged,
  onUpdateOldPinChanged,
  onUpdateNewPinChanged,
  onUpdatePukChanged,
  onPinStatusChanged,
  onLockStatusChanged,
  onBalanceUpdated,
  onTxHistory,
}

class HomeActionCreator {
  static Action scanCard() => const Action(HomeActionType.scanCard);
  static Action generateKey() => const Action(HomeActionType.generateKey);
  static Action getFee() => const Action(HomeActionType.getFee);
  static Action sendTransaction() =>
      const Action(HomeActionType.sendTransaction);
  static Action createWallet() => const Action(HomeActionType.createWallet);
  static Action writeNdef() => const Action(HomeActionType.writeNdef);
  static Action readNdef() => const Action(HomeActionType.readNdef);
  static Action syncUid() => const Action(HomeActionType.syncUid);
  static Action validateAddr() => const Action(HomeActionType.validateAddr);
  static Action setPin() => const Action(HomeActionType.setPin);
  static Action updatePin() => const Action(HomeActionType.updatePin);
  static Action cancelPin() => const Action(HomeActionType.cancelPin);
  static Action unlockCard() => const Action(HomeActionType.unlockCard);
  static Action queryPinStatus() => const Action(HomeActionType.queryPinStatus);
  static Action checkLockStatus() =>
      const Action(HomeActionType.checkLockStatus);
  static Action getBalance() => const Action(HomeActionType.getBalance);
  static Action getTxHistory() => const Action(HomeActionType.getTxHistory);
  static Action onPageInit() => const Action(HomeActionType.onPageInit);

  static Action onNdefLink(String? url) =>
      Action(HomeActionType.onNdefLink, payload: url);

  static Action onLoading(bool loading) =>
      Action(HomeActionType.onLoading, payload: loading);

  static Action onLog(String message) =>
      Action(HomeActionType.onLog, payload: message);

  static Action onCardInfo({
    required String? cardId,
    required bool? isPasswordSet,
    required String? masterPublicKey,
    required String? btcAddress,
    required String? ethAddress,
    String? trxAddress,
    String? dogeAddress,
    String? rtapAddress,
  }) =>
      Action(HomeActionType.onCardInfo, payload: {
        'cardId': cardId,
        'isPasswordSet': isPasswordSet,
        'masterPublicKey': masterPublicKey,
        'btcAddress': btcAddress,
        'ethAddress': ethAddress,
        'trxAddress': trxAddress,
        'dogeAddress': dogeAddress,
        'rtapAddress': rtapAddress,
      });

  static Action onFees(List<FeeResponse>? fees) =>
      Action(HomeActionType.onFees, payload: fees);

  static Action onTxResult(String? result) =>
      Action(HomeActionType.onTxResult, payload: result);

  static Action onChainChanged(String chain) =>
      Action(HomeActionType.onChainChanged, payload: chain);

  static Action onIsTestChanged(bool isTest) =>
      Action(HomeActionType.onIsTestChanged, payload: isTest);

  static Action onToAddressChanged(String address) =>
      Action(HomeActionType.onToAddressChanged, payload: address);

  static Action onAmountChanged(String amount) =>
      Action(HomeActionType.onAmountChanged, payload: amount);

  static Action onFeeSelected(FeeResponse fee) =>
      Action(HomeActionType.onFeeSelected, payload: fee);

  static Action onPinInputChanged(String pin) =>
      Action(HomeActionType.onPinInputChanged, payload: pin);

  static Action onPukInputChanged(String puk) =>
      Action(HomeActionType.onPukInputChanged, payload: puk);

  static Action onUpdateOldPinChanged(String pin) =>
      Action(HomeActionType.onUpdateOldPinChanged, payload: pin);

  static Action onUpdateNewPinChanged(String pin) =>
      Action(HomeActionType.onUpdateNewPinChanged, payload: pin);

  static Action onUpdatePukChanged(String puk) =>
      Action(HomeActionType.onUpdatePukChanged, payload: puk);

  static Action onPinStatusChanged(
          {required bool isSet, required int retryCount}) =>
      Action(HomeActionType.onPinStatusChanged,
          payload: {'isSet': isSet, 'retryCount': retryCount});

  static Action onLockStatusChanged({required bool isLocked}) =>
      Action(HomeActionType.onLockStatusChanged, payload: isLocked);

  /// payload: Map<String, String?> {symbol -> balance}
  static Action onBalanceUpdated(Map<String, String?> balances) =>
      Action(HomeActionType.onBalanceUpdated, payload: balances);

  static Action onTxHistory(List<TransactionsHistory>? history) =>
      Action(HomeActionType.onTxHistory, payload: history);
}
