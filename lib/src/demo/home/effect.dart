import 'package:fish_redux/fish_redux.dart';
import 'package:flutter/material.dart' hide Action;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../pigeon/messages.dart';
import '../utils/scan_util.dart';
import 'action.dart';
import 'state.dart';

// --- 本地缓存 key ---
const _kCardId = 'cc_cardId';
const _kIsTest = 'cc_isTest';
const _kIsPasswordSet = 'cc_isPasswordSet';
const _kMasterPublicKey = 'cc_masterPublicKey';
const _kBtcAddress = 'cc_btcAddress';
const _kEthAddress = 'cc_ethAddress';
const _kTrxAddress = 'cc_trxAddress';
const _kDogeAddress = 'cc_dogeAddress';
const _kRtapAddress = 'cc_rtapAddress';

String _hexEncode(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return '';
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// BTC CurrencyInfoMessage
CurrencyInfoMessage _btcCurrency({bool isTest = false}) => CurrencyInfoMessage(
      id: 'btc',
      icon: '',
      name: 'Bitcoin',
      networkId: 'btc',
      networkName: 'Bitcoin',
      networkIcon: '',
      symbol: 'BTC',
      contractAddress: null,
      decimalCount: 8,
      amount: null,
      address: null,
      publicKey: null,
      chainCode: null,
      isTest: isTest ? 1 : 0,
    );

/// TRX CurrencyInfoMessage
CurrencyInfoMessage _trxCurrency({bool isTest = false}) => CurrencyInfoMessage(
      id: 'trx',
      icon: '',
      name: 'TRON',
      networkId: 'trx',
      networkName: 'TRON',
      networkIcon: '',
      symbol: 'TRX',
      contractAddress: null,
      decimalCount: 6,
      amount: null,
      address: null,
      publicKey: null,
      chainCode: null,
      isTest: isTest ? 1 : 0,
    );

/// DOGE CurrencyInfoMessage
CurrencyInfoMessage _dogeCurrency({bool isTest = false}) => CurrencyInfoMessage(
      id: 'doge',
      icon: '',
      name: 'Dogecoin',
      networkId: 'doge',
      networkName: 'Dogecoin',
      networkIcon: '',
      symbol: 'DOGE',
      contractAddress: null,
      decimalCount: 8,
      amount: null,
      address: null,
      publicKey: null,
      chainCode: null,
      isTest: isTest ? 1 : 0,
    );

/// ETH CurrencyInfoMessage
CurrencyInfoMessage _ethCurrency({bool isTest = false}) => CurrencyInfoMessage(
      id: 'eth',
      icon: '',
      name: 'Ethereum',
      networkId: 'eth',
      networkName: 'Ethereum',
      networkIcon: '',
      symbol: 'ETH',
      contractAddress: null,
      decimalCount: 18,
      amount: null,
      address: null,
      publicKey: null,
      chainCode: null,
      isTest: isTest ? 1 : 0,
    );

/// RTAP (Refiny A Pt) CurrencyInfoMessage — ETH 测试网 ERC-20 代币
CurrencyInfoMessage _rtapCurrency() => CurrencyInfoMessage(
      id: 'rtap',
      icon:
          'https://loankyc-sgp.oss-ap-southeast-1.aliyuncs.com/public/35462e61d1da4d32844046f4f6f805e9/crypto/aliyun_oss_d09b834b26814956897a546f2803ca97.png',
      name: 'Refiny A Pt',
      networkId: 'ETH/test',
      networkName: 'Ethereum',
      networkIcon: '',
      symbol: 'RTAP',
      contractAddress: '0x1eBD8550F79A553771C8f3A0D891E4C83A7641c1',
      decimalCount: 18,
      amount: null,
      address: null,
      publicKey: null,
      chainCode: null,
      isTest: 1,
    );

Effect<HomeState> buildEffect() {
  return combineEffects<HomeState>({
    Lifecycle.initState: _onPageInit,
    HomeActionType.scanCard: _scanCard,
    HomeActionType.createWallet: _createWallet,
    HomeActionType.generateKey: _generateKey,
    HomeActionType.getFee: _getFee,
    HomeActionType.sendTransaction: _sendTransaction,
    HomeActionType.getBalance: _getBalance,
    HomeActionType.getTxHistory: _getTxHistory,
    HomeActionType.writeNdef: _writeNdef,
    HomeActionType.readNdef: _readNdef,
    HomeActionType.syncUid: _syncUid,
    HomeActionType.validateAddr: _validateAddr,
    HomeActionType.setPin: _setPin,
    HomeActionType.updatePin: _updatePin,
    HomeActionType.cancelPin: _cancelPin,
    HomeActionType.unlockCard: _unlockCard,
    HomeActionType.queryPinStatus: _queryPinStatus,
    HomeActionType.checkLockStatus: _checkLockStatus,
  })!;
}

/// 页面初始化：尝试从本地缓存恢复上次扫卡数据，无需靠卡
Future<void> _onPageInit(Action action, Context<HomeState> ctx) async {
  // 注册 Kotlin → Flutter 余额回调（与 BlockchainMethods.flutterClientApi.updateCurrencyInfo 对应）
  ScanUtil.registerBalanceCallback(
    (balances) {
      ctx.dispatch(HomeActionCreator.onBalanceUpdated(balances));
      final logLines = balances.entries
          .map((e) => '${e.key}: ${e.value ?? "--"}')
          .join('\n');
      ctx.dispatch(HomeActionCreator.onLog('余额更新:\n$logLines'));
    },
    onError: (msg) {
      ctx.dispatch(HomeActionCreator.onLog(msg));
    },
  );

  final prefs = await SharedPreferences.getInstance();
  final cardId = prefs.getString(_kCardId);
  if (cardId == null) return; // 未曾扫过卡，跳过

  final cachedIsTest = prefs.getBool(_kIsTest) ?? false;
  final currentIsTest = ctx.state.isTest;
  final sameNetwork = cachedIsTest == currentIsTest;

  ctx.dispatch(HomeActionCreator.onCardInfo(
    cardId: cardId,
    isPasswordSet: prefs.getBool(_kIsPasswordSet),
    masterPublicKey: sameNetwork ? prefs.getString(_kMasterPublicKey) : null,
    btcAddress: sameNetwork ? prefs.getString(_kBtcAddress) : null,
    ethAddress: sameNetwork ? prefs.getString(_kEthAddress) : null,
    trxAddress: sameNetwork ? prefs.getString(_kTrxAddress) : null,
    dogeAddress: sameNetwork ? prefs.getString(_kDogeAddress) : null,
    rtapAddress: sameNetwork
        ? (prefs.getString(_kRtapAddress) ?? prefs.getString(_kEthAddress))
        : null,
  ));

  final networkLabel =
      sameNetwork ? (currentIsTest ? '(测试网)' : '(主网)') : '(网络已切换，请重新扫卡)';
  ctx.dispatch(HomeActionCreator.onLog('已从缓存恢复卡片 uid=$cardId $networkLabel'));

  // 有地址时自动查询余额，无需靠卡
  if (sameNetwork) {
    final btcAddr = prefs.getString(_kBtcAddress);
    final ethAddr = prefs.getString(_kEthAddress);
    final trxAddr = prefs.getString(_kTrxAddress);
    final dogeAddr = prefs.getString(_kDogeAddress);
    final rtapAddr =
        prefs.getString(_kRtapAddress) ?? prefs.getString(_kEthAddress);
    final hasAddress = [btcAddr, ethAddr, trxAddr, dogeAddr, rtapAddr]
        .any((a) => a != null && a.isNotEmpty);
    if (hasAddress) {
      ctx.dispatch(HomeActionCreator.onLog('自动查询余额…'));
      CurrencyInfoMessage withAddr(CurrencyInfoMessage c, String? addr) {
        if (addr != null && addr.isNotEmpty) c.address = addr;
        return c;
      }

      final currencies = [
        withAddr(_btcCurrency(isTest: currentIsTest), btcAddr),
        withAddr(_ethCurrency(isTest: currentIsTest), ethAddr),
        withAddr(_trxCurrency(isTest: currentIsTest), trxAddr),
        withAddr(_dogeCurrency(isTest: currentIsTest), dogeAddr),
        withAddr(_rtapCurrency(), rtapAddr),
      ];
      await ScanUtil.loadCurrencyInfoList(currencies);
    }
  }
}

/// 扫卡成功后将结果写入本地缓存（只存 UI 展示所需字段，公钥由 native SDK 持久化）
Future<void> _saveCardCache({
  required String cardId,
  required bool? isPasswordSet,
  required String? masterPublicKey,
  required String? btcAddress,
  required String? ethAddress,
  required String? trxAddress,
  required String? dogeAddress,
  required String? rtapAddress,
  required bool isTest,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kCardId, cardId);
  await prefs.setBool(_kIsTest, isTest);
  if (isPasswordSet != null) {
    await prefs.setBool(_kIsPasswordSet, isPasswordSet);
  }
  if (masterPublicKey != null) {
    await prefs.setString(_kMasterPublicKey, masterPublicKey);
  }
  if (btcAddress != null) await prefs.setString(_kBtcAddress, btcAddress);
  if (ethAddress != null) await prefs.setString(_kEthAddress, ethAddress);
  if (trxAddress != null) await prefs.setString(_kTrxAddress, trxAddress);
  if (dogeAddress != null) await prefs.setString(_kDogeAddress, dogeAddress);
  if (rtapAddress != null) await prefs.setString(_kRtapAddress, rtapAddress);
}

Future<void> _scanCard(Action action, Context<HomeState> ctx) async {
  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('开始扫卡…'));
  final bool isTest = ctx.state.isTest;
  final result = await ScanUtil.scanCardAndDerive(
    [
      _btcCurrency(isTest: isTest),
      _ethCurrency(isTest: isTest),
      _trxCurrency(isTest: isTest),
      _dogeCurrency(isTest: isTest),
      _rtapCurrency(),
    ],
  );
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('扫卡失败: ${result.message}'));
    ctx.dispatch(HomeActionCreator.onLoading(false));
    return;
  }
  final card = result.data!;

  String? btcAddr;
  String? ethAddr;
  String? trxAddr;
  String? dogeAddr;
  String? rtapAddr;
  for (final cur in card.currencyList) {
    if (cur == null) continue;
    final sym = cur.symbol.toUpperCase();
    debugPrint(
        '[scanResult] sym=$sym addr=${cur.address} isTest=${cur.isTest}');
    if (sym == 'BTC') btcAddr = cur.address;
    if (sym == 'ETH') ethAddr = cur.address;
    if (sym == 'TRX') trxAddr = cur.address;
    if (sym == 'DOGE') dogeAddr = cur.address;
    if (sym == 'RTAP') rtapAddr = cur.address;
  }
  // ERC-20 代币与基础链（ETH）共用同一地址；若 Kotlin 未单独返回 RTAP 条目则 fallback
  rtapAddr ??= ethAddr;
  debugPrint('[scanResult] final rtapAddr=$rtapAddr ethAddr=$ethAddr');
  final masterPubKeyHex = _hexEncode(card.publicKey);

  ctx.dispatch(HomeActionCreator.onCardInfo(
    cardId: card.uid,
    isPasswordSet: card.isPasswordSet,
    masterPublicKey: masterPubKeyHex.isEmpty ? null : masterPubKeyHex,
    btcAddress: btcAddr,
    ethAddress: ethAddr,
    trxAddress: trxAddr,
    dogeAddress: dogeAddr,
    rtapAddress: rtapAddr,
  ));
  ctx.dispatch(HomeActionCreator.onLog(
      '扫卡成功 uid=${card.uid} pinSet=${card.isPasswordSet} 币种数=${card.currencyList.length}\nBTC: $btcAddr\nETH: $ethAddr\nTRX: $trxAddr\nDOGE: $dogeAddr\nRTAP: $rtapAddr'));

  if (card.uid.isNotEmpty) {
    await _saveCardCache(
      cardId: card.uid,
      isPasswordSet: card.isPasswordSet,
      masterPublicKey: masterPubKeyHex.isEmpty ? null : masterPubKeyHex,
      btcAddress: btcAddr,
      ethAddress: ethAddr,
      trxAddress: trxAddr,
      dogeAddress: dogeAddr,
      rtapAddress: rtapAddr,
      isTest: isTest,
    );
  }
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

Future<void> _generateKey(Action action, Context<HomeState> ctx) async {
  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('生成密钥对…'));
  final result = await ScanUtil.generateKey();
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('生成失败: ${result.message}'));
  } else {
    ctx.dispatch(HomeActionCreator.onLog('密钥生成成功\n公钥: ${result.data}'));
  }
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

Future<void> _getFee(Action action, Context<HomeState> ctx) async {
  final state = ctx.state;
  if (state.toAddress.isEmpty || state.amount.isEmpty) {
    ctx.dispatch(HomeActionCreator.onLog('请先填写收款地址和金额'));
    return;
  }

  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog(
      '查询 ${state.chain} 手续费 (${state.isTest ? '测试网' : '主网'})…'));
  final result = await ScanUtil.getFee(FeeMessage(
    symbol: state.chain,
    blockchain: state.chain.toLowerCase(),
    currencyType: 'coin',
    receiverAddress: state.toAddress,
    sumToSend: state.amount,
    isTest: state.isTest ? '1' : '0',
  ));
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('查询手续费失败: ${result.message}'));
    ctx.dispatch(HomeActionCreator.onLoading(false));
    return;
  }
  final fees = result.data!;
  ctx.dispatch(HomeActionCreator.onFees(fees));
  final sb = StringBuffer('手续费查询结果:\n');
  for (final f in fees) {
    final label = _feeLabel(f.type);
    sb.writeln(
        '  $label: ${f.value}${f.gasLimit != null ? " (gasLimit=${f.gasLimit})" : ""}');
  }
  ctx.dispatch(HomeActionCreator.onLog(sb.toString().trim()));
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

Future<void> _sendTransaction(Action action, Context<HomeState> ctx) async {
  final state = ctx.state;
  final selectedFee = state.selectedFee;
  if (selectedFee == null) {
    ctx.dispatch(HomeActionCreator.onLog('请先查询并选择手续费'));
    return;
  }

  final walletAddress = switch (state.chain) {
    'BTC' => state.btcAddress,
    'TRX' => state.trxAddress,
    'DOGE' => state.dogeAddress,
    _ => state.ethAddress,
  };
  if (walletAddress == null || walletAddress.isEmpty) {
    ctx.dispatch(HomeActionCreator.onLog('请先扫卡获取地址'));
    return;
  }

  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('发起 ${state.chain} 交易，请靠近卡片签名…'));
  final result = await ScanUtil.sendTransaction(SendMessage(
    symbol: state.chain,
    blockchainId: state.chain.toLowerCase(),
    currencyType: 'coin',
    walletAddress: walletAddress,
    fee: selectedFee.value,
    sumToSend: state.amount,
    receiverAddress: state.toAddress,
    gasLimit: selectedFee.gasLimit,
    gasPrice: selectedFee.gasPrice,
    isTest: state.isTest ? '1' : '0',
  ));
  if (!result.isSuccess) {
    debugPrint('[sendTransaction] 失败: ${result.message}');
    ctx.dispatch(HomeActionCreator.onLog('交易失败: ${result.message}'));
    ctx.dispatch(HomeActionCreator.onLoading(false));
    return;
  }
  final resp = result.data!;
  if (resp.isSuccess) {
    debugPrint('[sendTransaction] 成功: ${resp.errorMsg}');
    ctx.dispatch(HomeActionCreator.onTxResult(resp.errorMsg ?? '广播成功'));
    ctx.dispatch(
        HomeActionCreator.onLog('交易成功 txHash/Info: ${resp.errorMsg ?? "ok"}'));
  } else {
    debugPrint('[sendTransaction] 报错: ${resp.errorMsg}');
    ctx.dispatch(HomeActionCreator.onTxResult(null));
    ctx.dispatch(HomeActionCreator.onLog('交易失败: ${resp.errorMsg}'));
  }
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

// ─── 创建钱包（新卡初始化，生成密钥 + 派生地址）─────────────
Future<void> _createWallet(Action action, Context<HomeState> ctx) async {
  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('创建钱包…（请靠近卡片）'));
  final bool isTest = ctx.state.isTest;
  final result = await ScanUtil.createWalletAndDerive(
    [
      _btcCurrency(isTest: isTest),
      _ethCurrency(isTest: isTest),
      _trxCurrency(isTest: isTest),
      _dogeCurrency(isTest: isTest),
    ],
  );
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('创建钱包失败: ${result.message}'));
    ctx.dispatch(HomeActionCreator.onLoading(false));
    return;
  }
  final card = result.data!;
  String? btcAddr, ethAddr, trxAddr, dogeAddr;
  for (final cur in card.currencyList) {
    if (cur == null) continue;
    final sym = cur.symbol.toUpperCase();
    if (sym == 'BTC') btcAddr = cur.address;
    if (sym == 'ETH') ethAddr = cur.address;
    if (sym == 'TRX') trxAddr = cur.address;
    if (sym == 'DOGE') dogeAddr = cur.address;
  }
  final masterPubKeyHex = _hexEncode(card.publicKey);
  ctx.dispatch(HomeActionCreator.onCardInfo(
    cardId: card.uid,
    isPasswordSet: card.isPasswordSet,
    masterPublicKey: masterPubKeyHex.isEmpty ? null : masterPubKeyHex,
    btcAddress: btcAddr,
    ethAddress: ethAddr,
    trxAddress: trxAddr,
    dogeAddress: dogeAddr,
  ));
  ctx.dispatch(HomeActionCreator.onLog(
      '创建钱包成功 uid=${card.uid}\nBTC: $btcAddr\nETH: $ethAddr\nTRX: $trxAddr\nDOGE: $dogeAddr'));
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

// ─── 读取 NDEF（INS=0x62，不需要额外参数）─────────────────────
Future<void> _readNdef(Action action, Context<HomeState> ctx) async {
  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('读取 NDEF…'));
  // INS_GET_NDEF = 0x62，4字节头部 APDU（CLA=0x80, INS=0x62, P1=0x00, P2=0x00）
  final result = await ScanUtil.sendCommand(
    Uint8List.fromList([0x80, 0x62, 0x00, 0x00]),
  );
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('读取 NDEF 失败: ${result.message}'));
    ctx.dispatch(HomeActionCreator.onLoading(false));
    return;
  }
  // 响应 data = AES 解密后的裸数据，格式 [0x9B, len, ...urlBytes]
  String? url;
  final data = result.data?.data;
  if (data != null && data.length >= 2) {
    final tag = data[0] & 0xFF;
    final len = data[1] & 0xFF;
    if (tag == 0x9B && data.length >= 2 + len && len > 0) {
      url = String.fromCharCodes(data.sublist(2, 2 + len));
    }
  }
  ctx.dispatch(HomeActionCreator.onNdefLink(url));
  ctx.dispatch(HomeActionCreator.onLog(
      url != null ? '读取 NDEF 成功:\n$url' : '读取 NDEF: 卡片内无内容'));
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

// ─── UID 同步（INS=0x65，写入卡片 UID 到卡内存）─────────────
Future<void> _syncUid(Action action, Context<HomeState> ctx) async {
  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('同步 UID…（请靠近卡片）'));
  final result = await ScanUtil.scanOnly(needSyncUid: true);
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('UID 同步失败: ${result.message}'));
  } else {
    ctx.dispatch(
        HomeActionCreator.onLog('UID 同步成功\ncardId=${result.data?.cardId}'));
  }
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

// ─── 验证地址（本地验证，无需靠卡）──────────────────────────
Future<void> _validateAddr(Action action, Context<HomeState> ctx) async {
  final state = ctx.state;
  final address = switch (state.chain) {
    'BTC' => state.btcAddress,
    'TRX' => state.trxAddress,
    'DOGE' => state.dogeAddress,
    _ => state.ethAddress,
  };
  if (address == null || address.isEmpty) {
    ctx.dispatch(HomeActionCreator.onLog('请先扫卡获取 ${state.chain} 地址'));
    return;
  }
  final result = await ScanUtil.validateAddress(ValidateAddressMessage(
    address: address,
    blockchain: state.chain.toLowerCase(),
    isTest: state.isTest ? '1' : '0',
  ));
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('验证地址失败: ${result.message}'));
    return;
  }
  final isValid = result.data!;
  ctx.dispatch(HomeActionCreator.onLog(
      '验证 ${state.chain} 地址: $address\n结果: ${isValid ? "✅ 有效" : "❌ 无效"}'));
}

/// NDEF 写入测试：调用 scanCardWithCommand，传入带 uid= 末尾的测试模板 URL，
/// 写入成功后 response.data 即为卡片实际存储的完整 URL（含真实 UID）。
const _kTestNdefTemplate =
    'crypto.dropromo.com?code=25_DEC_01&orgId=smart_card_pro&source=TASK&uid=';

Future<void> _writeNdef(Action action, Context<HomeState> ctx) async {
  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('开始写入 NDEF…'));
  final result = await ScanUtil.scanOnly(ndefLink: _kTestNdefTemplate);
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('NDEF 写入失败: ${result.message}'));
    ctx.dispatch(HomeActionCreator.onLoading(false));
    return;
  }
  // response.data 存放的是卡片回读的完整 URL（含真实 UID）
  final rawData = result.data?.data;
  final writtenUrl = rawData != null && rawData.isNotEmpty
      ? String.fromCharCodes(rawData)
      : null;
  ctx.dispatch(HomeActionCreator.onNdefLink(writtenUrl));
  ctx.dispatch(HomeActionCreator.onLog(
    writtenUrl != null ? 'NDEF 写入成功 ✅\n$writtenUrl' : 'NDEF 写入完成（无回读数据）',
  ));
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

String _feeLabel(FeeType type) {
  switch (type) {
    case FeeType.low:
      return '慢速 (low)';
    case FeeType.normal:
      return '正常 (normal)';
    case FeeType.priority:
      return '快速 (priority)';
  }
}

// ─── PIN 工具方法 ─────────────────────────────────────────────

/// 将 PIN/PUK 字符串转换为每位数字的字节列表，例如 "123456" → [1,2,3,4,5,6]
List<int> _codeToDigits(String code) =>
    code.split('').map((c) => int.parse(c)).toList();

/// 构建 Create PIN APDU (INS=0x50)
/// data = [0x95, pinLen, ...pinDigits]
Uint8List _buildCreatePinApdu(String pin) {
  final digits = _codeToDigits(pin);
  final data = [0x95, digits.length, ...digits];
  return Uint8List.fromList([0x80, 0x50, 0x00, 0x00, data.length, ...data]);
}

/// 构建 Cancel PIN APDU (INS=0x57)
/// data = [0x95, pinLen, ...pin, 0x96, pukLen, ...puk]
Uint8List _buildCancelPinApdu(String pin, String puk) {
  final pinDigits = _codeToDigits(pin);
  final pukDigits = _codeToDigits(puk);
  final data = [
    0x95,
    pinDigits.length,
    ...pinDigits,
    0x96,
    pukDigits.length,
    ...pukDigits,
  ];
  return Uint8List.fromList([0x80, 0x57, 0x00, 0x00, data.length, ...data]);
}

/// 构建 Unlock APDU (INS=0x52)
/// data = [0x96, pukLen, ...puk, 0x95, newPinLen, ...newPin]
Uint8List _buildUnlockApdu(String puk, String newPin) {
  final pukDigits = _codeToDigits(puk);
  final pinDigits = _codeToDigits(newPin);
  final data = [
    0x96,
    pukDigits.length,
    ...pukDigits,
    0x95,
    pinDigits.length,
    ...pinDigits,
  ];
  return Uint8List.fromList([0x80, 0x52, 0x00, 0x00, data.length, ...data]);
}

// ─── 设置 PIN (INS=0x50) ─────────────────────────────────────
Future<void> _setPin(Action action, Context<HomeState> ctx) async {
  final pin = ctx.state.pinInput.trim();
  if (pin.length != 6 || int.tryParse(pin) == null) {
    ctx.dispatch(HomeActionCreator.onLog('请输入 6 位数字 PIN'));
    return;
  }
  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('设置 PIN…（请靠近卡片）'));
  final result = await ScanUtil.sendCommand(_buildCreatePinApdu(pin));
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('设置 PIN 失败: ${result.message}'));
    ScanUtil.showError(ctx.context, result);
    ctx.dispatch(HomeActionCreator.onLoading(false));
    return;
  }
  final data = result.data?.data;
  String pukStr = '';
  if (data != null && data.length > 2) {
    pukStr = data.sublist(2).map((b) => b.toString()).join();
  }
  ctx.dispatch(HomeActionCreator.onLog(
    pukStr.isNotEmpty ? '✅ 设置 PIN 成功' : '✅ 设置 PIN 成功（响应无 PUK 数据）',
  ));
  ctx.dispatch(
      HomeActionCreator.onPinStatusChanged(isSet: true, retryCount: 3));
  ctx.dispatch(HomeActionCreator.onLoading(false));
  if (pukStr.isNotEmpty) {
    await _showPukDialog(ctx.context, pukStr, isNew: false);
  }
}

// ─── 更新 PIN (INS=0x51) ─────────────────────────────────────
/// 构建 Update PIN APDU: data = [0x95, oldPinLen, ...oldPin, 0x95, newPinLen, ...newPin]
Uint8List _buildUpdatePinApdu(String oldPin, String newPin) {
  final oldDigits = _codeToDigits(oldPin);
  final newDigits = _codeToDigits(newPin);
  final data = [
    0x95,
    oldDigits.length,
    ...oldDigits,
    0x95,
    newDigits.length,
    ...newDigits,
  ];
  return Uint8List.fromList([0x80, 0x51, 0x00, 0x00, data.length, ...data]);
}

Future<void> _updatePin(Action action, Context<HomeState> ctx) async {
  final oldPin = ctx.state.updateOldPin.trim();
  final newPin = ctx.state.updateNewPin.trim();
  if (oldPin.length != 6 || int.tryParse(oldPin) == null) {
    ctx.dispatch(HomeActionCreator.onLog('请输入 6 位数字旧 PIN'));
    return;
  }
  if (newPin.length != 6 || int.tryParse(newPin) == null) {
    ctx.dispatch(HomeActionCreator.onLog('请输入 6 位数字新 PIN'));
    return;
  }
  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('更新 PIN…（请靠近卡片）'));
  final result =
      await ScanUtil.sendCommand(_buildUpdatePinApdu(oldPin, newPin));
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('更新 PIN 失败: ${result.message}'));
    ScanUtil.showError(ctx.context, result);
    ctx.dispatch(HomeActionCreator.onLoading(false));
    return;
  }
  final data = result.data?.data;
  String newPuk = '';
  if (data != null && data.length > 2) {
    newPuk = data.sublist(2).map((b) => b.toString()).join();
  }
  ctx.dispatch(HomeActionCreator.onLog('✅ PIN 更新成功'));
  ScanUtil.showSuccess(ctx.context, 'PIN 更新成功');
  ctx.dispatch(HomeActionCreator.onLoading(false));
  if (newPuk.isNotEmpty) {
    await _showPukDialog(ctx.context, newPuk, isNew: true);
  }
}

// ─── 取消 PIN (INS=0x57) ─────────────────────────────────────
Future<void> _cancelPin(Action action, Context<HomeState> ctx) async {
  final pin = ctx.state.pinInput.trim();
  final puk = ctx.state.pukInput.trim();
  if (pin.length != 6 || int.tryParse(pin) == null) {
    ctx.dispatch(HomeActionCreator.onLog('请输入 6 位数字 PIN'));
    return;
  }
  if (puk.length != 8 || int.tryParse(puk) == null) {
    ctx.dispatch(HomeActionCreator.onLog('请输入 8 位数字 PUK'));
    return;
  }
  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('取消 PIN…（请靠近卡片）'));
  final result = await ScanUtil.sendCommand(_buildCancelPinApdu(pin, puk));
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('取消 PIN 失败: ${result.message}'));
    ScanUtil.showError(ctx.context, result);
    ctx.dispatch(HomeActionCreator.onLoading(false));
    return;
  }
  ctx.dispatch(HomeActionCreator.onLog('✅ PIN 已取消'));
  ctx.dispatch(
      HomeActionCreator.onPinStatusChanged(isSet: false, retryCount: 3));
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

// ─── 解锁卡片 (INS=0x52，PUK + 新PIN) ────────────────────────
Future<void> _unlockCard(Action action, Context<HomeState> ctx) async {
  final puk = ctx.state.pukInput.trim();
  final pin = ctx.state.pinInput.trim();
  if (puk.length != 8 || int.tryParse(puk) == null) {
    ctx.dispatch(HomeActionCreator.onLog('请输入 8 位数字 PUK'));
    return;
  }
  if (pin.length != 6 || int.tryParse(pin) == null) {
    ctx.dispatch(HomeActionCreator.onLog('请输入 6 位数字新 PIN'));
    return;
  }
  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('解锁卡片…（请靠近卡片）'));
  final result = await ScanUtil.sendCommand(_buildUnlockApdu(puk, pin));
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('解锁失败: ${result.message}'));
    ScanUtil.showError(ctx.context, result);
    ctx.dispatch(HomeActionCreator.onLoading(false));
    return;
  }
  ctx.dispatch(HomeActionCreator.onLog('✅ 卡片解锁成功'));
  ctx.dispatch(
      HomeActionCreator.onPinStatusChanged(isSet: true, retryCount: 3));
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

// ─── 查询是否被锁 ─────────────────────────────────────────────
Future<void> _getBalance(Action action, Context<HomeState> ctx) async {
  final state = ctx.state;
  final isTest = state.isTest;

  // 优先从 native WalletManagerRegistry 取地址；
  // 将 Flutter state 中的地址作为 fallback，确保扫卡失败或冷启动时仍可查询余额
  CurrencyInfoMessage withAddr(CurrencyInfoMessage c, String? addr) {
    if (addr != null && addr.isNotEmpty) c.address = addr;
    return c;
  }

  final currencies = [
    withAddr(_btcCurrency(isTest: isTest), state.btcAddress),
    withAddr(_ethCurrency(isTest: isTest), state.ethAddress),
    withAddr(_trxCurrency(isTest: isTest), state.trxAddress),
    withAddr(_dogeCurrency(isTest: isTest), state.dogeAddress),
  ];

  ctx.dispatch(HomeActionCreator.onLog('正在查询余额…'));
  // 异步触发，结果通过 FlutterClientApi.updateCurrencyInfo 回调
  await ScanUtil.loadCurrencyInfoList(currencies);
}

// ─── 查询交易历史 ─────────────────────────────────────────────
Future<void> _getTxHistory(Action action, Context<HomeState> ctx) async {
  final state = ctx.state;
  final chain = state.chain;
  final isTest = state.isTest;

  final address = switch (chain) {
    'BTC' => state.btcAddress,
    'TRX' => state.trxAddress,
    'DOGE' => state.dogeAddress,
    _ => state.ethAddress,
  };
  if (address == null || address.isEmpty) {
    ctx.dispatch(HomeActionCreator.onLog('请先扫卡获取 $chain 地址'));
    return;
  }

  final currencyInfo = switch (chain) {
    'BTC' => _btcCurrency(isTest: isTest),
    'TRX' => _trxCurrency(isTest: isTest),
    'DOGE' => _dogeCurrency(isTest: isTest),
    _ => _ethCurrency(isTest: isTest),
  };
  currencyInfo.address = address;

  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('查询 $chain 交易记录…'));
  ctx.dispatch(HomeActionCreator.onTxHistory(null)); // 先清空

  final result = await ScanUtil.loadTransactionHistoryList(
    TransactionHistoryRequest(
      address: address,
      page: null,
      type: 0,
      currencyInfo: currencyInfo,
    ),
  );

  if (!result.isSuccess) {
    debugPrint('[getTxHistory] 查询失败: ${result.message}');
    ctx.dispatch(HomeActionCreator.onLog('查询失败: ${result.message}'));
    ctx.dispatch(HomeActionCreator.onLoading(false));
    return;
  }
  final history = result.data ?? [];
  debugPrint('[getTxHistory] 查询到 ${history.length} 条 $chain 记录');
  ctx.dispatch(HomeActionCreator.onTxHistory(history));
  ctx.dispatch(HomeActionCreator.onLog(
    history.isEmpty ? '暂无 $chain 交易记录' : '查询到 ${history.length} 条 $chain 交易记录',
  ));
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

Future<void> _checkLockStatus(Action action, Context<HomeState> ctx) async {
  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('查询锁定状态…（请靠近卡片）'));
  // checkLock=true：若卡片已锁则返回 isCardLocked=true，而不会抛异常
  final result = await ScanUtil.scanOnly(checkLock: false);
  if (result.isCardLocked) {
    ctx.dispatch(HomeActionCreator.onLockStatusChanged(isLocked: true));
    ctx.dispatch(HomeActionCreator.onLog('🔒 卡片已被锁定，PIN 已耗尽，请使用 PUK 解锁'));
  } else if (result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLockStatusChanged(isLocked: false));
    ctx.dispatch(HomeActionCreator.onLog('✅ 卡片未被锁定'));
  } else {
    ctx.dispatch(HomeActionCreator.onLog('查询锁定状态失败: ${result.message}'));
    ScanUtil.showError(ctx.context, result);
  }
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

// ─── 查询 PIN 状态 (INS=0x54) ────────────────────────────────
Future<void> _queryPinStatus(Action action, Context<HomeState> ctx) async {
  ctx.dispatch(HomeActionCreator.onLoading(true));
  ctx.dispatch(HomeActionCreator.onLog('查询 PIN 状态…（请靠近卡片）'));
  final result = await ScanUtil.sendCommand(
    Uint8List.fromList([0x80, 0x54, 0x00, 0x00]),
  );
  if (!result.isSuccess) {
    ctx.dispatch(HomeActionCreator.onLog('查询 PIN 状态失败: ${result.message}'));
    ScanUtil.showError(ctx.context, result);
    ctx.dispatch(HomeActionCreator.onLoading(false));
    return;
  }
  final data = result.data?.data;
  bool isSet = false;
  int retryCount = 3;
  if (data != null && data.length >= 3) {
    isSet = data[2] != 0;
    if (data.length >= 4) retryCount = data[3] & 0xFF;
  }
  ctx.dispatch(HomeActionCreator.onPinStatusChanged(
      isSet: isSet, retryCount: retryCount));
  ctx.dispatch(HomeActionCreator.onLog(
    isSet ? '✅ PIN 状态: 已设置（剩余重试次数: $retryCount）' : '✅ PIN 状态: 未设置',
  ));
  ctx.dispatch(HomeActionCreator.onLoading(false));
}

/// 显示 PUK 弹窗，支持一键复制
Future<void> _showPukDialog(BuildContext context, String puk,
    {required bool isNew}) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.red),
          const SizedBox(width: 8),
          Text(isNew ? '新 PUK 码' : 'PUK 码'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '请务必妥善保存此 PUK 码！\nPUK 用于解锁被锁定的卡片，丢失后无法找回。',
            style: TextStyle(fontSize: 13, color: Colors.red),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: puk));
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                    content: Text('PUK 已复制到剪贴板'),
                    duration: Duration(seconds: 2)),
              );
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                border: Border.all(color: Colors.amber.shade400),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    puk,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 4,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const Icon(Icons.copy, color: Colors.amber),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text('点击上方数字可复制',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: puk));
            Navigator.of(ctx).pop();
          },
          child: const Text('复制并关闭'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('我已保存'),
        ),
      ],
    ),
  );
}
