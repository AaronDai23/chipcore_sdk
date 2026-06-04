import 'package:fish_redux/fish_redux.dart';

import '../../pigeon/messages.dart';
import 'action.dart';
import 'state.dart';

Reducer<HomeState> buildReducer() {
  return asReducer({
    HomeActionType.onLoading: _onLoading,
    HomeActionType.onLog: _onLog,
    HomeActionType.onCardInfo: _onCardInfo,
    HomeActionType.onFees: _onFees,
    HomeActionType.onTxResult: _onTxResult,
    HomeActionType.onNdefLink: _onNdefLink,
    HomeActionType.onChainChanged: _onChainChanged,
    HomeActionType.onIsTestChanged: _onIsTestChanged,
    HomeActionType.onToAddressChanged: _onToAddressChanged,
    HomeActionType.onAmountChanged: _onAmountChanged,
    HomeActionType.onFeeSelected: _onFeeSelected,
    HomeActionType.onPinInputChanged: _onPinInputChanged,
    HomeActionType.onPukInputChanged: _onPukInputChanged,
    HomeActionType.onUpdateOldPinChanged: _onUpdateOldPinChanged,
    HomeActionType.onUpdateNewPinChanged: _onUpdateNewPinChanged,
    HomeActionType.onUpdatePukChanged: _onUpdatePukChanged,
    HomeActionType.onPinStatusChanged: _onPinStatusChanged,
    HomeActionType.onLockStatusChanged: _onLockStatusChanged,
    HomeActionType.onBalanceUpdated: _onBalanceUpdated,
    HomeActionType.onTxHistory: _onTxHistory,
  })!;
}

HomeState _onLoading(HomeState state, Action action) {
  return state.clone()..isLoading = action.payload as bool;
}

HomeState _onLog(HomeState state, Action action) {
  final now = DateTime.now();
  final ts =
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
  return state.clone()..log = '[$ts] ${action.payload as String}\n${state.log}';
}

HomeState _onCardInfo(HomeState state, Action action) {
  final Map<String, dynamic> info = action.payload as Map<String, dynamic>;
  // RTAP 是 ETH 上的 ERC-20，地址与 ETH 相同；若 payload 未携带则 fallback
  final rtapAddress =
      (info['rtapAddress'] as String?) ?? (info['ethAddress'] as String?);
  return state.clone()
    ..cardId = info['cardId'] as String?
    ..isPasswordSet = info['isPasswordSet'] as bool?
    ..masterPublicKey = info['masterPublicKey'] as String?
    ..btcAddress = info['btcAddress'] as String?
    ..ethAddress = info['ethAddress'] as String?
    ..trxAddress = info['trxAddress'] as String?
    ..dogeAddress = info['dogeAddress'] as String?
    ..rtapAddress = rtapAddress;
}

HomeState _onFees(HomeState state, Action action) {
  return state.clone()
    ..fees = action.payload as List<FeeResponse>?
    ..selectedFee = null;
}

HomeState _onTxResult(HomeState state, Action action) {
  return state.clone()..txResult = action.payload as String?;
}

HomeState _onChainChanged(HomeState state, Action action) {
  return state.clone()
    ..chain = action.payload as String
    ..fees = null
    ..selectedFee = null
    ..txResult = null
    ..txHistory = null;
}

HomeState _onIsTestChanged(HomeState state, Action action) {
  // 切换测试/主网后，旧地址已失效，需重新扫卡获取新网络地址
  return state.clone()
    ..isTest = action.payload as bool
    ..btcAddress = null
    ..ethAddress = null
    ..trxAddress = null
    ..dogeAddress = null
    ..rtapAddress = null
    ..masterPublicKey = null
    ..fees = null
    ..selectedFee = null
    ..txResult = null;
}

HomeState _onToAddressChanged(HomeState state, Action action) {
  return state.clone()..toAddress = action.payload as String;
}

HomeState _onAmountChanged(HomeState state, Action action) {
  return state.clone()..amount = action.payload as String;
}

HomeState _onFeeSelected(HomeState state, Action action) {
  return state.clone()..selectedFee = action.payload as FeeResponse;
}

HomeState _onNdefLink(HomeState state, Action action) {
  return state.clone()..ndefLink = action.payload as String?;
}

HomeState _onPinInputChanged(HomeState state, Action action) {
  return state.clone()..pinInput = action.payload as String;
}

HomeState _onPukInputChanged(HomeState state, Action action) {
  return state.clone()..pukInput = action.payload as String;
}

HomeState _onUpdateOldPinChanged(HomeState state, Action action) {
  return state.clone()..updateOldPin = action.payload as String;
}

HomeState _onUpdateNewPinChanged(HomeState state, Action action) {
  return state.clone()..updateNewPin = action.payload as String;
}

HomeState _onUpdatePukChanged(HomeState state, Action action) {
  return state.clone()..updatePuk = action.payload as String;
}

HomeState _onPinStatusChanged(HomeState state, Action action) {
  final info = action.payload as Map<String, dynamic>;
  return state.clone()
    ..pinIsSet = info['isSet'] as bool
    ..pinRetryCount = info['retryCount'] as int;
}

HomeState _onLockStatusChanged(HomeState state, Action action) {
  return state.clone()..isCardLocked = action.payload as bool;
}

HomeState _onBalanceUpdated(HomeState state, Action action) {
  final balances = action.payload as Map<String, String?>;
  final next = state.clone();
  balances.forEach((symbol, balance) {
    switch (symbol.toUpperCase()) {
      case 'BTC':
        next.btcBalance = balance;
        break;
      case 'ETH':
        next.ethBalance = balance;
        break;
      case 'TRX':
        next.trxBalance = balance;
        break;
      case 'DOGE':
        next.dogeBalance = balance;
        break;
      case 'RTAP':
        next.rtapBalance = balance;
        break;
    }
  });
  return next;
}

HomeState _onTxHistory(HomeState state, Action action) {
  return state.clone()
    ..txHistory = action.payload as List<TransactionsHistory>?;
}
