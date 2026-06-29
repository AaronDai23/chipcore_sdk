# ChipCore SDK — 接入文档

ChipCore SDK 是一个基于 Flutter Plugin 的 NFC 硬件钱包 SDK，适用于集成了安全芯片（Secure Element）的 NFC 智能卡。SDK 的核心功能是通过 ISO 7816 协议与芯片安全通信，在卡内完成私钥生成、多链地址派生及交易签名，私钥**始终不离开硬件**。

支持平台：**iOS 13+** | **Android (API 19+)**

---

## 目录

1. [前置要求](#1-前置要求)
2. [集成步骤](#2-集成步骤)
3. [快速开始](#3-快速开始)
4. [核心 API 参考](#4-核心-api-参考)
   - [扫卡与钱包初始化](#41-扫卡与钱包初始化)
   - [余额查询](#42-余额查询)
   - [手续费查询](#43-手续费查询)
   - [发起交易（签名）](#44-发起交易签名)
   - [原始 APDU 命令](#45-原始-apdu-命令)
   - [PIN 管理](#46-pin-管理)
   - [辅助功能](#47-辅助功能)
5. [数据模型](#5-数据模型)
6. [错误处理](#6-错误处理)
7. [支持的区块链](#7-支持的区块链)
8. [安全说明](#8-安全说明)

---

## 1. 前置要求

### iOS

在 `ios/Runner/Info.plist` 中添加 NFC 权限：

```xml
<key>NFCReaderUsageDescription</key>
<string>This app uses NFC to communicate with your hardware wallet card.</string>
<key>com.apple.developer.nfc.readersession.iso7816.select-identifiers</key>
<array>
    <!-- 填写卡片 Applet AID，例如: -->
    <string>A000000000000000</string>
</array>
```

在 `ios/Runner/Runner.entitlements` 中开启 NFC 能力：

```xml
<key>com.apple.developer.nfc.readersession.formats</key>
<array>
    <string>TAG</string>
</array>
```

> Xcode → Signing & Capabilities → + Capability → Near Field Communication Tag Reading

### Android

在 `android/app/src/main/AndroidManifest.xml` 中声明 NFC 权限：

```xml
<uses-permission android:name="android.permission.NFC" />
<uses-feature android:name="android.hardware.nfc" android:required="true" />
```

---

## 2. 集成步骤

### 2.1 添加依赖

在 `pubspec.yaml` 中引入本地路径或 Git 地址：

```yaml
dependencies:
  chipcore_sdk:
    path: ../chipcore_sdk   # 本地路径
    # 或使用 Git：
    # git:
    #   url: https://your-git-repo/chipcore_sdk.git
```

执行：

```bash
flutter pub get
```

### 2.2 生成 Pigeon 桥接代码（仅 SDK 开发者需要）

如果需要修改消息协议，重新生成双端桥接文件：

```bash
dart run pigeon \
  --input ./pigeons/message.dart \
  --dart_out lib/src/pigeon/messages.dart \
  --swift_out ios/Runner/Messages.swift \
  --java_out android/app/src/main/kotlin/com/chipcore/sdk/flutter/Messages.java \
  --java_package "com.chipcore.sdk.flutter"
```

---

## 3. 快速开始

### 3.1 导入

```dart
import 'package:chipcore_sdk/src/pigeon/messages.dart';
import 'package:chipcore_sdk/src/demo/utils/scan_util.dart';
```

### 3.2 注册余额回调

在应用启动时（如 `initState`）注册一次即可：

```dart
ScanUtil.registerBalanceCallback(
  (Map<String, String?> balances) {
    // balances key 为大写 symbol，如 'BTC' / 'ETH' / 'TRX' / 'DOGE'
    print('BTC 余额: ${balances['BTC']}');
  },
  onError: (String message) {
    print('余额查询出错: $message');
  },
);
```

### 3.3 扫卡并获取地址

```dart
// 构造需要派生的币种列表
final currencies = [
  CurrencyInfoMessage(
    id: 'btc', icon: '', name: 'Bitcoin',
    networkId: 'btc', networkIcon: '', symbol: 'BTC',
    decimalCount: 8, isTest: 0,
  ),
  CurrencyInfoMessage(
    id: 'eth', icon: '', name: 'Ethereum',
    networkId: 'eth', networkIcon: '', symbol: 'ETH',
    decimalCount: 18, isTest: 0,
  ),
];

final result = await ScanUtil.scanCardAndDerive(currencies);

if (result.isSuccess) {
  final card = result.data!;
  print('Card UID: ${card.uid}');
  for (final cur in card.currencyList) {
    if (cur != null) {
      print('${cur.symbol}: ${cur.address}');
    }
  }
} else {
  print('扫卡失败: ${result.message}');
}
```

### 3.4 查询余额

```dart
// 将扫卡得到的地址填入后调用
final currenciesWithAddr = currencies.map((c) {
  c.address = '从扫卡结果中获取的地址';
  return c;
}).toList();

await ScanUtil.loadCurrencyInfoList(currenciesWithAddr);
// 余额异步通过 registerBalanceCallback 返回
```

### 3.5 发送交易

```dart
// Step 1: 查询手续费
final feeResult = await ScanUtil.getFee(FeeMessage(
  symbol: 'ETH',
  blockchain: 'eth',
  currencyType: 'coin',
  receiverAddress: '0xReceiverAddress',
  sumToSend: '0.01',
  isTest: '0',
));

if (!feeResult.isSuccess) return;

final fees = feeResult.data!;
final selectedFee = fees.first; // 选择 low / normal / priority

// Step 2: 靠卡签名并广播（用户需要将卡片靠近手机）
final txResult = await ScanUtil.sendTransaction(SendMessage(
  symbol: 'ETH',
  blockchainId: 'eth',
  currencyType: 'coin',
  walletAddress: '0xMyWalletAddress',
  fee: selectedFee.value,
  sumToSend: '0.01',
  receiverAddress: '0xReceiverAddress',
  gasLimit: selectedFee.gasLimit,
  gasPrice: selectedFee.gasPrice,
  isTest: '0',
));

if (txResult.isSuccess && txResult.data!.isSuccess) {
  print('交易成功 txHash: ${txResult.data!.errorMsg}');
}
```

---

## 4. 核心 API 参考

所有 API 通过 `ScanUtil` 调用，均返回 `ScanResponse<T>`：

```dart
class ScanResponse<T> {
  final bool isSuccess;       // 操作是否成功
  final T? data;              // 成功时的返回数据
  final String? message;      // 失败时的错误描述
  final int? sw1;             // APDU SW1 状态字节（仅 APDU 错误时有值）
  final int? sw2;             // APDU SW2 状态字节
  final String? errorCode;    // 错误码字符串
  
  // 便捷判断
  bool get isCardLocked;      // SW=AA23，卡片被锁
  bool get isPinIncorrect;    // SW=AA21，PIN 错误
  bool get isPukIncorrect;    // SW=AA24，PUK 错误
  bool get isPinRequired;     // SW=AA22，需要 PIN 验证
  bool get isCardExpired;     // SW=AA25，卡片作废
  bool get isCancelled;       // 用户主动取消 NFC 弹层
  bool get isTagLost;         // NFC 连接中断
  bool get isTimeout;         // 等待超时
}
```

---

### 4.1 扫卡与钱包初始化

#### `scanCardAndDerive` — 扫卡并派生地址

适用场景：已激活的卡片（已有密钥对），用于获取各链钱包地址。

```dart
Future<ScanResponse<CardMessage>> scanCardAndDerive(
  List<CurrencyInfoMessage> currencies, {
  String walletName = '',
  String? cardId,      // 传入时强制校验卡片 UID
  String? cardNo,
})
```

| 参数 | 说明 |
|------|------|
| `currencies` | 需要派生的币种列表，每个元素需设置 `networkId`、`symbol` |
| `cardId` | 可选，传入后若扫到的卡 UID 不匹配则返回 `uid-mismatch` 错误 |

返回：`ScanResponse<CardMessage>`，其中 `data.currencyList` 包含各币种地址。

#### `createWalletAndDerive` — 新卡初始化

适用场景：全新未激活卡片，在卡内生成 HD 主密钥并派生地址。**每张卡只能初始化一次**。

```dart
Future<ScanResponse<CardMessage>> createWalletAndDerive(
  List<CurrencyInfoMessage> currencies,
)
```

> ⚠️ 若卡片已有密钥对（`isActivated = true`），本方法会跳过密钥生成，直接进行派生。

---

### 4.2 余额查询

余额查询为**异步非阻塞**设计：先调用 `loadCurrencyInfoList` 触发查询，结果通过回调返回。

#### `loadCurrencyInfoList` — 触发余额查询

```dart
Future<void> loadCurrencyInfoList(List<CurrencyInfoMessage> currencies)
```

每个 `CurrencyInfoMessage` 须包含 `address` 字段。查询结果通过 `registerBalanceCallback` 注册的回调逐条返回。

#### `registerBalanceCallback` — 注册余额更新回调

```dart
static void registerBalanceCallback(
  void Function(Map<String, String?> balances) onUpdate, {
  void Function(String message)? onError,
})
```

| 参数 | 说明 |
|------|------|
| `onUpdate` | 余额更新回调，key 为大写 symbol（如 `'BTC'`），value 为余额字符串（失败时为 `'--'`） |
| `onError` | 可选，某条链查询失败时调用 |

**支持币种类型：**
- 主网币：BTC、ETH、TRX、DOGE
- ERC-20 代币：传入 `contractAddress` + `networkId` 为 `eth` 即可
- TRC-20 代币：传入 `contractAddress` + `networkId` 为 `trx` 即可
- EVM 兼容链（BSC、Polygon 等）：通过 `networkId` 区分

---

### 4.3 手续费查询

```dart
Future<ScanResponse<List<FeeResponse>>> getFee(FeeMessage message)
```

**FeeMessage 字段：**

| 字段 | 类型 | 说明 |
|------|------|------|
| `symbol` | `String` | 币种符号，如 `'ETH'`、`'BTC'` |
| `blockchain` | `String` | 链标识，小写，如 `'eth'`、`'btc'` |
| `currencyType` | `String` | `'coin'`（主币）或 `'token'`（代币） |
| `receiverAddress` | `String` | 收款地址 |
| `sumToSend` | `String` | 发送金额（字符串） |
| `isTest` | `String` | `'0'`（主网）或 `'1'`（测试网） |

**FeeResponse 字段：**

| 字段 | 类型 | 说明 |
|------|------|------|
| `type` | `FeeType` | `low` / `normal` / `priority` |
| `value` | `String` | 手续费数值（单位与链相关） |
| `gasLimit` | `String?` | EVM 链专用 |
| `gasPrice` | `String?` | EVM 链专用（Wei） |

> ETH 手续费乘数：low=1.0x、normal=1.2x、priority=1.5x（参考 Tangem 标准）

---

### 4.4 发起交易（签名）

```dart
Future<ScanResponse<SendTransactionResponse>> sendTransaction(SendMessage message)
```

此操作需要用户**将卡片靠近手机**完成硬件签名。

**SendMessage 主要字段：**

| 字段 | 类型 | 说明 |
|------|------|------|
| `blockchainId` | `String` | 链标识，小写 |
| `currencyType` | `String` | `'coin'` 或 `'token'` |
| `walletAddress` | `String` | 发送方钱包地址 |
| `fee` | `String` | 选择的手续费数值 |
| `sumToSend` | `String` | 发送金额 |
| `receiverAddress` | `String` | 收款地址 |
| `gasLimit` | `String?` | EVM 链：由 getFee 返回 |
| `gasPrice` | `String?` | EVM 链：由 getFee 返回 |
| `contractAddress` | `String?` | ERC-20 / TRC-20 代币合约地址 |
| `isTest` | `String` | `'0'` 或 `'1'` |

**SendTransactionResponse 字段：**

| 字段 | 类型 | 说明 |
|------|------|------|
| `isSuccess` | `bool` | 是否广播成功 |
| `errorMsg` | `String?` | 成功时为 txHash，失败时为错误信息 |

---

### 4.5 原始 APDU 命令

#### `sendCommand` — 发送自定义 APDU

```dart
Future<ScanResponse<CommandResponse>> sendCommand(
  Uint8List command, {
  bool checkLock = false,    // true 时卡片被锁直接报错
  bool needSyncUid = false,  // true 时在发命令前先同步 UID
  String? ndefLink,          // 非空时先写入 NDEF URL
  String? cardId,
})
```

所有 APDU 数据均通过 AES-128-CBC 加密传输。命令格式为标准 ISO 7816：

```
CLA  INS  P1  P2  Lc  Data
0x80 [指令] 0x00 0x00 [数据长度] [数据]
```

**CommandResponse 字段：**

| 字段 | 类型 | 说明 |
|------|------|------|
| `cardId` | `String` | 卡片 UID（十六进制） |
| `appletVersion` | `String` | Applet 版本号 |
| `isActivated` | `bool` | 卡片是否已初始化（有密钥对） |
| `resetCount` | `int` | 卡片重置次数 |
| `data` | `Uint8List?` | AES 解密后的响应数据（不含 SW） |

#### `scanOnly` — 仅扫卡（不发 APDU）

```dart
Future<ScanResponse<CommandResponse>> scanOnly({
  bool checkLock = false,
  bool needSyncUid = false,
  String? ndefLink,
})
```

---

### 4.6 PIN 管理

所有 PIN 操作均需靠卡。PIN 为 **6 位数字**，PUK 为 **8 位数字**（由卡片在设置 PIN 时自动生成）。

#### 设置 PIN（INS=0x50）

```dart
// 构建 APDU 并发送
final apdu = _buildCreatePinApdu('123456');
// 数据格式: [0x95, pinLen, ...digits]
// APDU 格式: [0x80, 0x50, 0x00, 0x00, dataLen, ...data]

final result = await ScanUtil.sendCommand(apdu);
// result.data?.data 中包含 [tag, len, ...pukDigits]，务必展示给用户保存
```

#### 更新 PIN（INS=0x51）

```dart
// 数据格式: [0x95, oldPinLen, ...oldPin, 0x95, newPinLen, ...newPin]
final apdu = Uint8List.fromList([0x80, 0x51, 0x00, 0x00, dataLen, ...data]);
final result = await ScanUtil.sendCommand(apdu, checkLock: false);
```

#### 取消 PIN（INS=0x57）

```dart
// 数据格式: [0x95, pinLen, ...pin, 0x96, pukLen, ...puk]
final apdu = Uint8List.fromList([0x80, 0x57, 0x00, 0x00, dataLen, ...data]);
```

#### 解锁卡片（INS=0x52，PUK 解锁）

```dart
// 数据格式: [0x96, pukLen, ...puk, 0x95, newPinLen, ...newPin]
final apdu = Uint8List.fromList([0x80, 0x52, 0x00, 0x00, dataLen, ...data]);
```

#### 查询 PIN 状态

```dart
// 通过 scanOnly 读取 CardStatus
final result = await ScanUtil.scanOnly(checkLock: false);
if (result.isSuccess) {
  // result.data.isActivated 反映密钥状态
  // PIN 状态、重试次数通过原生 getStatus 指令返回
}
```

**PIN 状态说明：**

| 状态 | pinRetry | pukRetry | 说明 |
|------|----------|----------|------|
| 正常 | > 0 | > 0 | 可正常使用 |
| 已锁 | = 0 | > 0 | 需用 PUK 解锁（INS=0x52） |
| 作废 | = 0 | = 0 | 卡片永久不可用 |

---

### 4.7 辅助功能

#### 地址验证（本地校验，无需靠卡）

```dart
Future<ScanResponse<bool>> validateAddress(ValidateAddressMessage message)
```

```dart
final result = await ScanUtil.validateAddress(ValidateAddressMessage(
  address: '0xAbcd...',
  blockchain: 'eth',
  isTest: '0',
));
// result.data == true 表示地址格式有效
```

#### NDEF URL 写入

```dart
// 写入 URL（卡片会在 URL 末尾自动追加真实 UID）
final result = await ScanUtil.scanOnly(
  ndefLink: 'https://example.com/card?uid=',
);
// result.data?.data 解码为 String 即为卡片存储的完整 URL
```

#### NDEF URL 读取（INS=0x62）

```dart
final result = await ScanUtil.sendCommand(
  Uint8List.fromList([0x80, 0x62, 0x00, 0x00]),
);
// 响应格式: [0x9B, len, ...urlBytes]
if (result.isSuccess) {
  final data = result.data!.data!;
  final len = data[1];
  final url = String.fromCharCodes(data.sublist(2, 2 + len));
}
```

#### UID 同步写入（INS=0x65）

```dart
final result = await ScanUtil.scanOnly(needSyncUid: true);
```

---

## 5. 数据模型

### `CurrencyInfoMessage`

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `String` | 币种唯一标识（如 `'btc'`、`'eth'`） |
| `name` | `String` | 币种名称（如 `'Bitcoin'`） |
| `networkId` | `String` | 网络标识（见[支持的区块链](#7-支持的区块链)） |
| `symbol` | `String` | 符号（如 `'BTC'`、`'USDT'`） |
| `contractAddress` | `String?` | ERC-20/TRC-20 代币合约地址 |
| `decimalCount` | `int?` | 精度位数 |
| `address` | `String?` | 钱包地址（扫卡后由 SDK 填入） |
| `publicKey` | `Uint8List?` | 压缩公钥（33字节） |
| `chainCode` | `Uint8List?` | HD 链码（32字节） |
| `amount` | `String?` | 余额（余额查询后异步填入） |
| `isTest` | `int?` | 0=主网，1=测试网 |

### `CardMessage`

| 字段 | 类型 | 说明 |
|------|------|------|
| `uid` | `String` | 卡片唯一 UID（十六进制） |
| `isPasswordSet` | `bool` | 是否已设置 PIN |
| `publicKey` | `Uint8List?` | BIP32 主公钥（33字节） |
| `currencyList` | `List<CurrencyInfoMessage?>` | 各币种派生结果 |

---

## 6. 错误处理

### 错误码速查表

| 分类 | 错误码 | 说明 | 处理建议 |
|------|--------|------|----------|
| **NFC 层** | `user-cancelled` | 用户关闭 NFC 弹层 | 提示用户重试 |
| | `nfc-timeout` | 等待超时未靠卡 | 提示靠近卡片 |
| | `nfc-tag-lost` | 卡片离开感应区 | 提示保持稳定 |
| | `nfc-unavailable` | 设备不支持 NFC | 提示更换设备 |
| | `nfc-disabled` | NFC 未开启 | 引导进入系统设置 |
| | `nfc-io` | NFC 通信错误 | 提示重试 |
| | `tag-unsupported` | 非 ISO 7816 标签 | 提示使用正确卡片 |
| **卡片状态** | `card-locked` | PIN 耗尽，卡片被锁 | 引导使用 PUK 解锁 |
| | `card-expired` | PUK 也耗尽，卡片作废 | 联系供应商更换 |
| | `card-hardware-error` | 卡片存储故障 | 联系供应商更换 |
| | `uid-mismatch` | 扫到了不同的卡片 | 提示使用同一张卡 |
| | `uid-not-synced` | UID 未同步 | 调用 `scanOnly(needSyncUid: true)` |
| **APDU SW** | `SW=AA21` | PIN 错误 | 提示剩余重试次数 |
| | `SW=AA22` | 需要 PIN 验证 | 引导用户输入 PIN |
| | `SW=AA23` | 卡片已锁 | 引导 PUK 解锁 |
| | `SW=AA24` | PUK 错误 | 提示剩余重试次数 |
| | `SW=AA25` | 卡片作废 | 联系供应商 |
| | `SW=AA30` | 卡片未初始化 | 调用 `createWalletAndDerive` |
| | `SW=AA31` | 密钥对已存在 | 调用 `scanCardAndDerive` 即可 |
| **交易** | `insufficient-funds` | 余额不足 | 提示余额不足 |
| | `fee-error` | 手续费查询失败 | 检查网络后重试 |
| | `broadcast-error` | 广播失败 | 检查网络后重试 |
| | `no-pubkey` | 未派生公钥 | 先扫卡再交易 |

### 错误处理示例

```dart
final result = await ScanUtil.scanCardAndDerive(currencies);

if (!result.isSuccess) {
  if (result.isCancelled) {
    // 用户主动取消，不显示错误
    return;
  }
  if (result.isTagLost) {
    showSnackBar('请保持卡片不动，重试扫描');
    return;
  }
  if (result.isCardLocked) {
    showDialog('卡片已锁，请使用 PUK 解锁');
    return;
  }
  showSnackBar('错误: ${result.message}');
}
```

---

## 7. 支持的区块链

| 链 | `networkId` | 测试网 `networkId` | BIP44 路径 | 地址格式 |
|----|-------------|-------------------|------------|----------|
| Bitcoin | `btc` | `btc/test` | `m/44'/0'/0'/0/0` | Base58Check (P2PKH) |
| Ethereum | `eth` | `ETH/test` | `m/44'/60'/0'/0/0` | EIP-55 Checksum |
| TRON | `trx` | `trx/test` | `m/44'/195'/0'/0/0` | Base58Check (0x41) |
| Dogecoin | `doge` | `doge/test` | `m/44'/3'/0'/0/0` | Base58Check (0x1E) |
| BNB Smart Chain | `binance` | — | `m/44'/60'/0'/0/0` | 同 ETH |
| Polygon | `polygon` | — | `m/44'/60'/0'/0/0` | 同 ETH |

**ERC-20 代币示例：**

```dart
CurrencyInfoMessage(
  id: 'usdt-eth',
  name: 'Tether USD',
  networkId: 'eth',           // 使用以太坊网络
  symbol: 'USDT',
  contractAddress: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
  decimalCount: 6,
  isTest: 0,
)
```

**TRC-20 代币示例：**

```dart
CurrencyInfoMessage(
  id: 'usdt-trx',
  name: 'Tether USD (TRC-20)',
  networkId: 'trx',           // 使用 TRON 网络
  symbol: 'USDT',
  contractAddress: 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
  decimalCount: 6,
  isTest: 0,
)
```

---

## 8. 安全说明

### 私钥安全

- 私钥**在卡片安全芯片内生成，从不导出**。所有签名操作在芯片内完成。
- SDK 仅传递哈希数据给卡片，签名后只返回签名结果。

### 通信安全

- Flutter 与 Native 层通过 **Pigeon** 自动生成的类型安全接口通信。
- Native 层与卡片通过 **AES-128-CBC** 加密的 APDU 通道通信。
- 加密密钥（Session Key）从卡片 SELECT 响应中派生，每次会话独立。

### UID 一致性校验

- 调用 `scanCardAndDerive` 时，若传入 `cardId` 参数，SDK 会校验当前靠近的卡片 UID 是否与期望一致，不匹配时返回 `uid-mismatch` 错误，防止误操作不同卡片。

### PIN 保护

- PIN 为 6 位数字，PUK 为 8 位数字，均在卡内加密存储。
- PIN 最多允许连续错误 3 次，超限后卡片进入锁定状态（SW=AA23），需使用 PUK 解锁。
- PUK 使用次数同样有限制，耗尽后卡片永久作废（SW=AA25）。
- **PUK 在设置 PIN 时由卡片返回，应用层须引导用户妥善备份，SDK 不存储 PUK。**

---

*文档版本：v1.0.0 · 最后更新：2026-06-16*
