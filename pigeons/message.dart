import 'package:pigeon/pigeon.dart';

//第一步：
/*
命令行生成文件

flutter pub run pigeon \
    --input ./pigeons/message.dart \
    --dart_out lib/pigeons/messages.dart \
    --objc_header_out ios/Runner/messages.h \
    --objc_source_out ios/Runner/messages.m \
    --java_out android/app/src/main/kotlin/com/cardcoin/card_coin/flutter/Messages.java \
    --java_package "com.cardcoin.card_coin.flutter"

    flutter pub run pigeon \
    --input ./pigeons/message.dart \
    --dart_out lib/pigeons/messages.dart \
    --swift_out ios/Runner/Messages.swift \
    --java_out android/app/src/main/kotlin/com/cardcoin/card_coin/flutter/Messages.java \
    --java_package "com.cardcoin.card_coin.flutter"

    dart run pigeon \ 
    --input ./pigeons/message.dart \ 
    --dart_out lib/src/pigeon/messages.dart \ 
    --swift_out ios/Runner/Messages.swift \ 
    --java_out android/app/src/main/kotlin/com/chipbase/chipcore_sdk/flutter/Messages.java \ 
    --java_package "com.chipcore.sdk.flutter"


 */

class FeeMessage {
  late String symbol;
  late String blockchain;
  late String currencyType;
  late String receiverAddress;
  late String sumToSend;
  late String isTest;
}

class SendMessage {
  String? symbol;
  late String blockchainId;
  late String currencyType;
  late String walletAddress;
  late String fee;
  late String sumToSend;
  late String receiverAddress;
  String? gasLimit;
  String? gasPrice;
  late String isTest;
}

class ValidateAddressMessage {
  late String blockchain;
  late String address;
  late String isTest;
}

enum FeeType { low, normal, priority }

enum CurrencyType { coin, token }

class FeeResponse {
  late FeeType type;
  late String value;
  String? gasLimit;
  String? gasPrice;
}

class SendTransactionResponse {
  late bool isSuccess;
  String? errorMsg;
}

class BlockchainErrorMessage {
  int code;
  String customMessage;

  BlockchainErrorMessage(this.code, this.customMessage);
}

class BalanceResponse {
  late CurrencyInfoMessage data;
  BlockchainErrorMessage? errorMessage;

  BalanceResponse(this.data, {this.errorMessage});
}

class CurrencyInfoMessage {
  late String id;
  late String icon;
  late String name;
  late String networkId;
  String? networkName;
  late String networkIcon;
  late String symbol;
  String? contractAddress;
  int? decimalCount;
  String? amount;
  String? address;
  Uint8List? publicKey;
  Uint8List? chainCode;
  int? isTest;
}

class ExtendedPublicKeyMessage {
  String blockchain;
  Uint8List publicKey;
  Uint8List chainCode;

  ExtendedPublicKeyMessage({
    required this.blockchain,
    required this.publicKey,
    required this.chainCode,
  });
}

class CardMessage {
  String uid;
  bool isPasswordSet;
  Uint8List? publicKey;
  List<CurrencyInfoMessage?> currencyList;
  CardMessage(
      {required this.uid,
      this.publicKey,
      required this.isPasswordSet,
      required this.currencyList});
}

class TransactionHistoryRequest {
  late String address;
  late String? page;
  late int type; // 交易类型，0表示充币，1表示提币
  late CurrencyInfoMessage currencyInfo;
}

class TransactionsHistory {
  late int time;
  late int direction; // 交易方向，减少（支出）0，增加（收入）1
  late int status; // 交易状态，-1表示失败，0表示未确认，1表示确认
  late int type; // 交易类型，0表示充币，1表示提币
  late double value; // 交易金额
  late int decimals; // 精度
}

///[cardId]卡片ID
///[data]命令结果
class CommandResponse {
  late String cardId;
  late String appletVersionCode;
  late String appletVersion;
  late bool isActivated;
  late int resetCount;
  Uint8List? data;
}

///[command]请求命令数据
///[checkPwd]是否需要检查密码
///[checkLock]是否需要检查卡片已锁
///[ndefLink]是否需要设置ndefLink
//////[ndefLink]是否需要设置ndefLink
class SendCommandMessage {
  Uint8List? appletId;
  String? cardId;
  Uint8List? command;

  bool? checkLock;
  String? ndefLink;
  String? cardNo;
  bool? checkPwd;
  bool? needRun;
  bool? needSyscUid;

  /// AAR（Android Application Record）包名字符串（逗号分隔），写入前自动去重。
  String? ndefAar;
}

class ChainKeyMessage {
  late String blockchainId;
  int? chainId;
  late String privateKey;
  late String publicKey;
  late String address;
}

class ChainKeyInfo {
  late String cardId;
  late List<ChainKeyMessage?> chainKeys;
}

class SignatureMessage {
  late int r;
  late int s;
  late int v;
}

@HostApi()
abstract class BlockchainApi {
  ///发送拍卡命令
  ///[command]请求命令数据
  ///[checkPwd]是否需要检查密码
  ///[checkLock]是否需要检查卡片已锁
  @async
  CommandResponse scanCardWithCommand(SendCommandMessage sendCommandMessage);
  @async
  CardMessage scanCardAndDerive(List<CurrencyInfoMessage> currencyList,
      String ndefLink, String? cardId, String? cardNo);

  @async
  CardMessage createWalletAndDerive(List<CurrencyInfoMessage> currencyList);

  @async
  void loadCurrencyInfoList(List<CurrencyInfoMessage> currencyList);

  ///初始化钱包
  bool initScanResponse(String uuid);

  ///添加币种
  @async
  bool addCurrencyList(List<CurrencyInfoMessage> currencyList);

  ///获取交易手续费
  @async
  List<FeeResponse> getFee(FeeMessage feeMessage);

  ///发送交易合约
  @async
  SendTransactionResponse sendTransaction(SendMessage sendMessage);

  ///验证钱包地址
  bool validateAddress(ValidateAddressMessage validateMessage);

  ///清除原生币种缓存数据
  void clearLocalCurrency(String cardId, List<String> coinIds);

  @async
  List<TransactionsHistory> loadTransactionHistoryList(
      TransactionHistoryRequest request);

  ///切换钱包
  @async
  bool changeWallet(String cardId, List<CurrencyInfoMessage> currencyList);

  ///上传奔溃信息
  @async
  void postCatchedException(String error);

  @async
  String signLightning(String signText, bool isBtc);
  @async
  ChainKeyInfo createChainKeys(List<String> blockchains);
  @async
  List<ChainKeyMessage> getChainKeys(String cardId, List<String> blockchains);

  @async
  String signText(String blockchainId, String text, int? chainId);

  @async
  String signTransaction(String blockchainId, String text, int? chainId);

  @async
  String generateKey();

  @async
  String signChallenge(String challenge);

  String getBitcoinPublicKey();

  void resetNfcReaderMode();

  String getEthPublicKey();

  @async
  String makeAddresses(String networkId, bool isBtc);

  void bindNetwork();

  bool isVpnActive();

  bool isDualSim();
}

@FlutterApi()
abstract class FlutterClientApi {
  ///更新数字币余额信息
  bool updateCurrencyInfo(List<BalanceResponse> currencyInfoList);
}
