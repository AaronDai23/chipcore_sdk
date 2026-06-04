import 'package:fish_redux/fish_redux.dart';
import 'package:flutter/material.dart';

import '../../pigeon/messages.dart';
import 'action.dart';
import 'state.dart';

Widget buildView(HomeState state, Dispatch dispatch, ViewService service) {
  return Scaffold(
    appBar: AppBar(
      title: const Text('ChipCore SDK Demo'),
      backgroundColor: Colors.indigo,
      foregroundColor: Colors.white,
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardSection(state: state, dispatch: dispatch),
          const SizedBox(height: 16),
          _FormSection(state: state, dispatch: dispatch),
          const SizedBox(height: 16),
          _FeeSection(state: state, dispatch: dispatch),
          const SizedBox(height: 16),
          _TxHistorySection(state: state, dispatch: dispatch),
          const SizedBox(height: 16),
          _LogSection(state: state),
        ],
      ),
    ),
  );
}

// ─── 卡片信息区 ───────────────────────────────────────────────
class _CardSection extends StatelessWidget {
  const _CardSection({required this.state, required this.dispatch});
  final HomeState state;
  final Dispatch dispatch;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.credit_card, color: Colors.indigo),
                const SizedBox(width: 8),
                const Text('卡片操作',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                if (state.isLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const Divider(),
            if (state.cardId != null) ...[
              _InfoRow('卡片 UID', state.cardId!),
              _InfoRow('已设置 PIN', state.isPasswordSet == true ? '是' : '否'),
              if (state.masterPublicKey != null)
                _InfoRow('主公钥', state.masterPublicKey!),
              if (state.btcAddress != null) ...[
                _InfoRow('BTC 地址', state.btcAddress!),
                if (state.btcBalance != null)
                  _InfoRow('BTC 余额', '${state.btcBalance} BTC'),
              ],
              if (state.ethAddress != null) ...[
                _InfoRow('ETH 地址', state.ethAddress!),
                if (state.ethBalance != null)
                  _InfoRow('ETH 余额', '${state.ethBalance} ETH'),
              ],
              if (state.trxAddress != null) ...[
                _InfoRow('TRX 地址', state.trxAddress!),
                if (state.trxBalance != null)
                  _InfoRow('TRX 余额', '${state.trxBalance} TRX'),
              ],
              if (state.dogeAddress != null) ...[
                _InfoRow('DOGE 地址', state.dogeAddress!),
                if (state.dogeBalance != null)
                  _InfoRow('DOGE 余额', '${state.dogeBalance} DOGE'),
              ],
              if (state.rtapAddress != null) ...[
                _InfoRow('RTAP 地址', state.rtapAddress!),
                if (state.rtapBalance != null)
                  _InfoRow('RTAP 余额', '${state.rtapBalance} RTAP'),
              ],
              if (state.ndefLink != null) ...[
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.teal.shade50,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.teal.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('NDEF Link',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.teal,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      SelectableText(
                        state.ndefLink!,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
            ],
            // 测试网开关
            Row(
              children: [
                const Text('使用测试网'),
                const SizedBox(width: 8),
                Switch(
                  value: state.isTest,
                  onChanged: (v) =>
                      dispatch(HomeActionCreator.onIsTestChanged(v)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // ── 扫卡 / 派生 ──
            const Text('扫卡 & 派生',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.nfc),
                  label: const Text('扫卡 & 派生'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.indigo,
                      foregroundColor: Colors.white),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.scanCard()),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.add_card),
                  label: const Text('创建钱包'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.createWallet()),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.vpn_key),
                  label: const Text('生成密钥对'),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.generateKey()),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // ── NDEF & UID ──
            const Text('NDEF & UID',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.link),
                  label: const Text('写 NDEF'),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.writeNdef()),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.link_off),
                  label: const Text('读 NDEF'),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.readNdef()),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.sync),
                  label: const Text('UID 同步'),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.syncUid()),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // ── 地址工具 ──
            const Text('地址工具',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.verified),
                  label: const Text('验证地址'),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.validateAddr()),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.account_balance_wallet),
                  label: const Text('查询余额'),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.getBalance()),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // ── PIN 管理 ──
            _PinSection(state: state, dispatch: dispatch),
          ],
        ),
      ),
    );
  }
}

// ─── PIN 管理区 ──────────────────────────────────────────────
class _PinSection extends StatelessWidget {
  const _PinSection({required this.state, required this.dispatch});
  final HomeState state;
  final Dispatch dispatch;

  @override
  Widget build(BuildContext context) {
    final pinIsSet = state.pinIsSet;
    final isLocked = state.isCardLocked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('PIN 管理',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            if (pinIsSet != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: pinIsSet
                      ? Colors.deepPurple.shade50
                      : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: pinIsSet ? Colors.deepPurple : Colors.grey,
                  ),
                ),
                child: Text(
                  pinIsSet ? '已设置 剩余:${state.pinRetryCount}' : '未设置',
                  style: TextStyle(
                    fontSize: 11,
                    color: pinIsSet ? Colors.deepPurple : Colors.grey,
                  ),
                ),
              ),
            if (isLocked != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isLocked ? Colors.red.shade50 : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(4),
                  border:
                      Border.all(color: isLocked ? Colors.red : Colors.green),
                ),
                child: Text(
                  isLocked ? '🔒 已锁定' : '🔓 未锁定',
                  style: TextStyle(
                    fontSize: 11,
                    color: isLocked ? Colors.red : Colors.green,
                  ),
                ),
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.search, size: 14),
              label: const Text('查询PIN状态', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
              onPressed: state.isLoading
                  ? null
                  : () => dispatch(HomeActionCreator.queryPinStatus()),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.lock_outline, size: 14),
              label: const Text('查询是否被锁', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
              onPressed: state.isLoading
                  ? null
                  : () => dispatch(HomeActionCreator.checkLockStatus()),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 未设置：显示新增 PIN 区
        if (pinIsSet == null || pinIsSet == false) ...[
          _LabeledTextField(
            label: '新 PIN（6位数字）',
            value: state.pinInput,
            hint: '例：123456',
            keyboardType: TextInputType.number,
            onChanged: (v) => dispatch(HomeActionCreator.onPinInputChanged(v)),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.lock_outline),
            label: const Text('新增 PIN'),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple,
                foregroundColor: Colors.white),
            onPressed: state.isLoading
                ? null
                : () => dispatch(HomeActionCreator.setPin()),
          ),
          if (pinIsSet == true) ...[
            const SizedBox(height: 12),
            const Divider(),
            const Text('解锁卡片（PIN 耗尽时）',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 6),
            _LabeledTextField(
              label: 'PUK（8位数字）',
              value: state.pukInput,
              hint: '例：12345678',
              keyboardType: TextInputType.number,
              onChanged: (v) =>
                  dispatch(HomeActionCreator.onPukInputChanged(v)),
            ),
            const SizedBox(height: 6),
            _LabeledTextField(
              label: '新 PIN（6位数字）',
              value: state.pinInput,
              hint: '例：123456',
              keyboardType: TextInputType.number,
              onChanged: (v) =>
                  dispatch(HomeActionCreator.onPinInputChanged(v)),
            ),
            const SizedBox(height: 6),
            ElevatedButton.icon(
              icon: const Icon(Icons.lock_reset),
              label: const Text('解锁卡片'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white),
              onPressed: state.isLoading
                  ? null
                  : () => dispatch(HomeActionCreator.unlockCard()),
            ),
          ],
        ],
        // 已设置：显示更新 PIN / 取消 PIN
        if (pinIsSet == true) ...[
          // 更新 PIN 区
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.deepPurple.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('更新 PIN',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepPurple)),
                const SizedBox(height: 8),
                _LabeledTextField(
                  label: '旧 PIN（6位）',
                  value: state.updateOldPin,
                  hint: '请输入当前 PIN',
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      dispatch(HomeActionCreator.onUpdateOldPinChanged(v)),
                ),
                const SizedBox(height: 6),
                _LabeledTextField(
                  label: '新 PIN（6位）',
                  value: state.updateNewPin,
                  hint: '请输入新 PIN',
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      dispatch(HomeActionCreator.onUpdateNewPinChanged(v)),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.update),
                  label: const Text('更新 PIN'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.updatePin()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 取消 PIN 区
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('取消 PIN',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.red)),
                const SizedBox(height: 8),
                _LabeledTextField(
                  label: 'PIN（6位）',
                  value: state.pinInput,
                  hint: '请输入当前 PIN',
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      dispatch(HomeActionCreator.onPinInputChanged(v)),
                ),
                const SizedBox(height: 6),
                _LabeledTextField(
                  label: 'PUK（8位）',
                  value: state.pukInput,
                  hint: '请输入 PUK 码',
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      dispatch(HomeActionCreator.onPukInputChanged(v)),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.lock_open, color: Colors.red),
                  label:
                      const Text('取消 PIN', style: TextStyle(color: Colors.red)),
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red)),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.cancelPin()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 解锁卡片区（PIN 耗尽时）
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('解锁卡片（PIN 耗尽时）',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.orange)),
                const SizedBox(height: 8),
                _LabeledTextField(
                  label: 'PUK（8位）',
                  value: state.pukInput,
                  hint: '请输入 PUK 码',
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      dispatch(HomeActionCreator.onPukInputChanged(v)),
                ),
                const SizedBox(height: 6),
                _LabeledTextField(
                  label: '新 PIN（6位）',
                  value: state.pinInput,
                  hint: '解锁后使用的新 PIN',
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      dispatch(HomeActionCreator.onPinInputChanged(v)),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.lock_reset),
                  label: const Text('解锁卡片'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.unlockCard()),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ─── 转账表单区 ──────────────────────────────────────────────
class _FormSection extends StatelessWidget {
  const _FormSection({required this.state, required this.dispatch});
  final HomeState state;
  final Dispatch dispatch;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.send, color: Colors.indigo),
                SizedBox(width: 8),
                Text('转账参数',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(),
            // 链选择
            Row(
              children: [
                const Text('链：'),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: state.chain,
                  items: const ['ETH', 'BTC', 'TRX', 'DOGE']
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) =>
                      dispatch(HomeActionCreator.onChainChanged(v!)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _LabeledTextField(
              label: '收款地址',
              value: state.toAddress,
              hint: switch (state.chain) {
                'ETH' => '0x...',
                'BTC' => state.isTest ? 'tb1...' : 'bc1...',
                'TRX' => 'T...',
                'DOGE' => state.isTest ? 'n...' : 'D...',
                _ => '',
              },
              onChanged: (v) =>
                  dispatch(HomeActionCreator.onToAddressChanged(v)),
            ),
            const SizedBox(height: 10),
            _LabeledTextField(
              label: '金额 (${state.chain})',
              value: state.amount,
              hint: '如 0.001',
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (v) => dispatch(HomeActionCreator.onAmountChanged(v)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 手续费 & 发送区 ─────────────────────────────────────────
class _FeeSection extends StatelessWidget {
  const _FeeSection({required this.state, required this.dispatch});
  final HomeState state;
  final Dispatch dispatch;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.local_gas_station, color: Colors.indigo),
                SizedBox(width: 8),
                Text('手续费 & 发送',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(),
            // 手续费档位选择
            if (state.fees != null && state.fees!.isNotEmpty) ...[
              const Text('选择速度档位：'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: state.fees!
                    .whereType<FeeResponse>()
                    .map((fee) => _FeeChip(
                          fee: fee,
                          isSelected: state.selectedFee?.type == fee.type,
                          onTap: () =>
                              dispatch(HomeActionCreator.onFeeSelected(fee)),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 10),
            ],
            if (state.txResult != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.green.shade300),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle,
                        color: Colors.green, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(state.txResult!,
                            style: const TextStyle(fontSize: 12))),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('查询手续费'),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.getFee()),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.send),
                  label: const Text('发送交易 (靠卡签名)'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white),
                  onPressed: (state.isLoading || state.selectedFee == null)
                      ? null
                      : () => dispatch(HomeActionCreator.sendTransaction()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 交易历史区 ──────────────────────────────────────────────
class _TxHistorySection extends StatelessWidget {
  const _TxHistorySection({required this.state, required this.dispatch});
  final HomeState state;
  final Dispatch dispatch;

  @override
  Widget build(BuildContext context) {
    final history = state.txHistory;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.history, color: Colors.indigo),
                const SizedBox(width: 8),
                Text('${state.chain} 交易记录',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('查询', style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4)),
                  onPressed: state.isLoading
                      ? null
                      : () => dispatch(HomeActionCreator.getTxHistory()),
                ),
              ],
            ),
            const Divider(),
            if (history == null)
              const Text('点击"查询"获取交易记录',
                  style: TextStyle(color: Colors.grey, fontSize: 12))
            else if (history.isEmpty)
              const Text('暂无交易记录',
                  style: TextStyle(color: Colors.grey, fontSize: 12))
            else
              ...history.map((tx) => _TxRow(tx: tx, chain: state.chain)),
          ],
        ),
      ),
    );
  }
}

class _TxRow extends StatelessWidget {
  const _TxRow({required this.tx, required this.chain});
  final TransactionsHistory tx;
  final String chain;

  @override
  Widget build(BuildContext context) {
    final isOut = tx.direction == 0;
    final isConfirmed = tx.status == 1;
    final isFailed = tx.status == -1;

    final dateStr = tx.time > 0
        ? DateTime.fromMillisecondsSinceEpoch(tx.time * 1000)
            .toLocal()
            .toString()
            .substring(0, 19)
        : '--';

    final amountStr =
        '${isOut ? '-' : '+'}${tx.value.toStringAsFixed(tx.decimals.clamp(0, 8))} $chain';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isOut ? Colors.orange.shade50 : Colors.green.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isOut ? Colors.orange.shade200 : Colors.green.shade200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isOut ? Icons.arrow_upward : Icons.arrow_downward,
                size: 16,
                color: isOut ? Colors.orange : Colors.green,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  amountStr,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color:
                        isOut ? Colors.orange.shade800 : Colors.green.shade800,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isFailed
                      ? Colors.red.shade100
                      : isConfirmed
                          ? Colors.blue.shade50
                          : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isFailed
                      ? '失败'
                      : isConfirmed
                          ? '已确认'
                          : '待确认',
                  style: TextStyle(
                    fontSize: 10,
                    color: isFailed
                        ? Colors.red
                        : isConfirmed
                            ? Colors.blue
                            : Colors.grey,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(dateStr,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          if (tx.txHash != null && tx.txHash!.isNotEmpty)
            SelectableText(
              'Hash: ${tx.txHash!}',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
              maxLines: 1,
            ),
          if (tx.fromAddress != null && tx.fromAddress!.isNotEmpty)
            Text(
              '从: ${_short(tx.fromAddress!)}',
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          if (tx.toAddress != null && tx.toAddress!.isNotEmpty)
            Text(
              '至: ${_short(tx.toAddress!)}',
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  String _short(String addr) => addr.length > 20
      ? '${addr.substring(0, 10)}…${addr.substring(addr.length - 8)}'
      : addr;
}

// ─── 日志区 ─────────────────────────────────────────────────
class _LogSection extends StatelessWidget {
  const _LogSection({required this.state});
  final HomeState state;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.terminal, color: Colors.indigo),
                SizedBox(width: 8),
                Text('操作日志',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(),
            if (state.log.isEmpty)
              const Text('暂无日志', style: TextStyle(color: Colors.grey))
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.shade900,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  state.log,
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── 共用小部件 ────────────────────────────────────────────
class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 80,
              child: Text('$label:',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 12))),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 12), softWrap: true),
          ),
        ],
      ),
    );
  }
}

class _LabeledTextField extends StatelessWidget {
  const _LabeledTextField({
    required this.label,
    required this.value,
    required this.hint,
    required this.onChanged,
    this.keyboardType,
  });

  final String label;
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: value,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      style: const TextStyle(fontSize: 13),
      onChanged: onChanged,
    );
  }
}

class _FeeChip extends StatelessWidget {
  const _FeeChip({
    required this.fee,
    required this.isSelected,
    required this.onTap,
  });

  final FeeResponse fee;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = _feeName(fee.type);
    return GestureDetector(
      onTap: onTap,
      child: Chip(
        avatar: isSelected
            ? const Icon(Icons.check, size: 16, color: Colors.white)
            : null,
        label: Text('$label\n${fee.value}',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12, color: isSelected ? Colors.white : null)),
        backgroundColor: isSelected ? Colors.indigo : Colors.grey.shade200,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      ),
    );
  }

  static String _feeName(FeeType type) {
    switch (type) {
      case FeeType.low:
        return '慢速';
      case FeeType.normal:
        return '正常';
      case FeeType.priority:
        return '快速';
    }
  }
}
