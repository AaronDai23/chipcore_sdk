import 'package:fish_redux/fish_redux.dart';

import '../../pigeon/messages.dart';

class HomeState implements Cloneable<HomeState> {
  /// 加载中标志
  bool isLoading = false;

  /// 日志输出
  String log = '';

  /// 卡片信息
  String? cardId;
  bool? isPasswordSet;
  String? masterPublicKey; // 仅调试展示用
  String? btcAddress;
  String? ethAddress;
  String? trxAddress;
  String? dogeAddress;
  String? rtapAddress;

  /// 手续费查询结果
  List<FeeResponse>? fees;

  /// 各链余额（loadCurrencyInfoList 异步回调后更新）
  String? btcBalance;
  String? ethBalance;
  String? trxBalance;
  String? dogeBalance;
  String? rtapBalance;

  /// 表单字段
  String chain = 'ETH'; // 'BTC' | 'ETH' | 'TRX' | 'DOGE'
  bool isTest = false;
  String toAddress = '';
  String amount = '';

  /// 选中的手续费
  FeeResponse? selectedFee;

  /// 发送结果
  String? txResult;

  /// 交易历史记录（当前链）
  List<TransactionsHistory>? txHistory;

  /// NDEF 写入结果（卡片实际存储的 URL）
  String? ndefLink;

  /// PIN 状态：null=未查询, false=未设置, true=已设置
  bool? pinIsSet;

  /// PIN 剩余重试次数（查询后更新）
  int pinRetryCount = 3;

  /// 卡片是否被锁定（PIN 耗尽）：null=未查询, true=已锁, false=未锁
  bool? isCardLocked;

  /// PIN 管理输入
  String pinInput = ''; // 设置/取消/解锁时的 PIN（6位）
  String pukInput = ''; // 取消/解锁时的 PUK（8位）
  String updateOldPin = ''; // 更新 PIN 时的旧 PIN
  String updateNewPin = ''; // 更新 PIN 时的新 PIN
  String updatePuk = ''; // 更新 PIN 时需要的 PUK

  @override
  HomeState clone() {
    return HomeState()
      ..isLoading = isLoading
      ..log = log
      ..cardId = cardId
      ..isPasswordSet = isPasswordSet
      ..masterPublicKey = masterPublicKey
      ..btcAddress = btcAddress
      ..ethAddress = ethAddress
      ..trxAddress = trxAddress
      ..dogeAddress = dogeAddress
      ..rtapAddress = rtapAddress
      ..fees = fees
      ..btcBalance = btcBalance
      ..ethBalance = ethBalance
      ..trxBalance = trxBalance
      ..dogeBalance = dogeBalance
      ..rtapBalance = rtapBalance
      ..chain = chain
      ..isTest = isTest
      ..toAddress = toAddress
      ..amount = amount
      ..selectedFee = selectedFee
      ..txResult = txResult
      ..txHistory = txHistory
      ..ndefLink = ndefLink
      ..pinIsSet = pinIsSet
      ..pinRetryCount = pinRetryCount
      ..isCardLocked = isCardLocked
      ..pinInput = pinInput
      ..pukInput = pukInput
      ..updateOldPin = updateOldPin
      ..updateNewPin = updateNewPin
      ..updatePuk = updatePuk;
  }
}

HomeState initState(Map<String, dynamic>? params) => HomeState();
