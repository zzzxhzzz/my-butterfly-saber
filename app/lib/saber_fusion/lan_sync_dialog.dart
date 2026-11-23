import 'dart:async';

import 'package:butterfly/api/open.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lw_file_system/lw_file_system.dart';
import 'package:material_ui/material_ui.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'lan_sync_cubit.dart';
import 'lan_sync_models.dart';
import 'lan_sync_service.dart';

Future<void> showLanSyncDialog(BuildContext context) async {
  final cubit = maybeLanSyncCubit(context);
  if (cubit == null) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => BlocProvider.value(
      value: cubit,
      child: LanSyncDialog(hostContext: context),
    ),
  );
}

class LanSyncDialog extends StatefulWidget {
  final BuildContext hostContext;

  const LanSyncDialog({super.key, required this.hostContext});

  @override
  State<LanSyncDialog> createState() => _LanSyncDialogState();
}

class _LanSyncDialogState extends State<LanSyncDialog> {
  final TextEditingController _userCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();
  final TextEditingController _deviceCtrl = TextEditingController();
  final TextEditingController _portCtrl = TextEditingController();
  final TextEditingController _peerAddrCtrl = TextEditingController();
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final account = context.read<LanSyncCubit>().state.account;
    _userCtrl.text = account.username;
    _passCtrl.text = account.passphrase;
    _deviceCtrl.text = account.deviceName;
    _portCtrl.text = account.port.toString();
    _peerAddrCtrl.text = account.manualPeerAddress;
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    _deviceCtrl.dispose();
    _portCtrl.dispose();
    _peerAddrCtrl.dispose();
    super.dispose();
  }

  String _formatRelativeTime(int epochMs) {
    if (epochMs <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$mm-$dd $hh:$min';
  }

  Future<void> _submitLogin(LanSyncCubit cubit) async {
    final port =
        int.tryParse(_portCtrl.text.trim()) ?? LanSyncService.defaultHttpPort;
    await cubit.login(
      username: _userCtrl.text,
      passphrase: _passCtrl.text,
      deviceName: _deviceCtrl.text,
      port: port,
    );
  }

  Future<void> _connectPeer(LanSyncCubit cubit) async {
    final ok = await cubit.connectManualPeer(_peerAddrCtrl.text);
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已连接对方设备并完成双向同步')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
        child: BlocBuilder<LanSyncCubit, LanSyncState>(
          builder: (context, state) {
            final cubit = context.read<LanSyncCubit>();
            final account = state.account;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
                  child: Row(
                    children: [
                      PhosphorIcon(
                        account.isSignedIn
                            ? PhosphorIconsLight.wifiHigh
                            : PhosphorIconsLight.cloud,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '双端局域网同步账号',
                          style: TextTheme.of(context).titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const PhosphorIcon(PhosphorIconsLight.x),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: account.isSignedIn
                        ? _buildSignedInBody(context, cubit, state)
                        : _buildLoginBody(context, cubit, state),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildLoginBody(
    BuildContext context,
    LanSyncCubit cubit,
    LanSyncState state,
  ) {
    final colorScheme = ColorScheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card.outlined(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(PhosphorIconsLight.wifiHigh, color: colorScheme.primary),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '无需任何第三方云盘或外网服务器。\n'
                    '只需在 Windows 电脑与 Android 平板/手机连入同一 Wi-Fi（或热点），'
                    '并登录相同的「同步账号名 + 同步密码」，任意一端修改批注、翻页或存入错题本，另一端都会自动双向同步，并记住每本教材上次读到的页数。',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _userCtrl,
          decoration: const InputDecoration(
            labelText: '同步账号名（两端填写一致）',
            hintText: '例如：study2026',
            prefixIcon: PhosphorIcon(PhosphorIconsLight.user),
            filled: true,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _passCtrl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '同步密码（用于局域网双向加密校验）',
            prefixIcon: PhosphorIcon(PhosphorIconsLight.lock),
            filled: true,
          ),
          onSubmitted: (_) => unawaited(_submitLogin(cubit)),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: TextField(
                controller: _deviceCtrl,
                decoration: const InputDecoration(
                  labelText: '本机名称',
                  filled: true,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _portCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '端口',
                  filled: true,
                ),
              ),
            ),
          ],
        ),
        if (state.lastError != null && state.lastError!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Card(
            color: colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                state.lastError!,
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => unawaited(_submitLogin(cubit)),
          icon: const PhosphorIcon(PhosphorIconsLight.wifiHigh),
          label: const Text('登录并开启局域网双向同步'),
        ),
        if (state.readingHistory.isNotEmpty) ...[
          const SizedBox(height: 18),
          _buildReadingHistorySection(context, state),
        ],
      ],
    );
  }

  Widget _buildSignedInBody(
    BuildContext context,
    LanSyncCubit cubit,
    LanSyncState state,
  ) {
    final colorScheme = ColorScheme.of(context);
    final account = state.account;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card.outlined(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    PhosphorIcon(
                      PhosphorIconsLight.user,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${account.username} · ${account.deviceName}',
                        style: TextTheme.of(context).titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: state.serverRunning
                            ? colorScheme.primaryContainer
                            : colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        state.serverRunning
                            ? '监听中 :${state.listeningPort}'
                            : '未监听',
                        style: TextTheme.of(context).labelSmall?.copyWith(
                          color: state.serverRunning
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (state.localAddresses.isEmpty)
                  Text(
                    '本机局域网 IP 获取中，请确认已接入 Wi-Fi / 局域网',
                    style: TextTheme.of(context).bodySmall,
                  )
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('本机地址：', style: TextTheme.of(context).bodySmall),
                      for (final ip in state.localAddresses)
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          avatar: const PhosphorIcon(
                            PhosphorIconsLight.copy,
                            size: 14,
                          ),
                          label: Text('$ip:${state.listeningPort}'),
                          onPressed: () {
                            final addr = '$ip:${state.listeningPort}';
                            Clipboard.setData(ClipboardData(text: addr));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('已复制本机同步地址：$addr')),
                            );
                          },
                        ),
                    ],
                  ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: state.syncing
                          ? null
                          : () => unawaited(cubit.syncNow()),
                      icon: state.syncing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const PhosphorIcon(
                              PhosphorIconsLight.arrowsClockwise,
                              size: 18,
                            ),
                      label: Text(state.syncing ? '正在同步...' : '立即双向同步'),
                    ),
                    OutlinedButton.icon(
                      onPressed: state.syncing
                          ? null
                          : () => unawaited(cubit.logout()),
                      icon: const PhosphorIcon(
                        PhosphorIconsLight.signOut,
                        size: 18,
                      ),
                      label: const Text('退出账号'),
                    ),
                  ],
                ),
                if (state.lastSyncSummary.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${state.lastSyncSummary}'
                    '${state.lastSyncAt != null ? '（${_formatRelativeTime(state.lastSyncAt!.millisecondsSinceEpoch)}）' : ''}',
                    style: TextTheme.of(context).bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (state.lastError != null && state.lastError!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Card(
            color: colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                state.lastError!,
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
            ),
          ),
        ],
        const SizedBox(height: 14),
        Text('同账号在线设备', style: TextTheme.of(context).titleSmall),
        const SizedBox(height: 6),
        if (state.peers.isEmpty)
          Card.outlined(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '正在通过 UDP 广播自动搜寻同 Wi-Fi 下登录「${account.username}」的设备…\n'
                '若跨网段或路由器拦截广播，可直接输入另一台设备上显示的「IP:端口」连接。',
                style: TextTheme.of(context).bodySmall,
              ),
            ),
          )
        else
          for (final peer in state.peers)
            Card.outlined(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                dense: true,
                leading: PhosphorIcon(
                  peer.platform.toLowerCase().contains('android')
                      ? PhosphorIconsLight.phone
                      : PhosphorIconsLight.desktop,
                ),
                title: Text('${peer.deviceName} (${peer.platform})'),
                subtitle: Text(
                  '${peer.address}${peer.isManual ? ' · 手动绑定' : ' · 自动发现'}',
                ),
                trailing: IconButton(
                  tooltip: '仅与此设备同步',
                  onPressed: state.syncing
                      ? null
                      : () => unawaited(cubit.syncNow(peer: peer)),
                  icon: const PhosphorIcon(
                    PhosphorIconsLight.arrowsClockwise,
                    size: 18,
                  ),
                ),
              ),
            ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _peerAddrCtrl,
                decoration: InputDecoration(
                  hintText: '手动连接 IP:端口（如 192.168.1.8:47832）',
                  isDense: true,
                  filled: true,
                  prefixIcon: const PhosphorIcon(
                    PhosphorIconsLight.link,
                    size: 16,
                  ),
                  suffixIcon: account.manualPeerAddress.isNotEmpty
                      ? IconButton(
                          tooltip: '清除手动地址',
                          onPressed: () {
                            _peerAddrCtrl.clear();
                            unawaited(cubit.clearManualPeer());
                          },
                          icon: const PhosphorIcon(
                            PhosphorIconsLight.trash,
                            size: 16,
                          ),
                        )
                      : null,
                ),
                onSubmitted: (_) => unawaited(_connectPeer(cubit)),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: state.syncing ? null : () => unawaited(_connectPeer(cubit)),
              child: const Text('连接并同步'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text('同步策略', style: TextTheme.of(context).titleSmall),
        const SizedBox(height: 4),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: account.autoSyncOnEdit,
          onChanged: (v) => unawaited(cubit.updateOptions(autoSyncOnEdit: v)),
          title: const Text('修改批注 / 保存笔记后自动同步'),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: account.syncReadingProgress,
          onChanged: (v) =>
              unawaited(cubit.updateOptions(syncReadingProgress: v)),
          title: const Text('自动记住并同步每本教材上次页数与视野'),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: account.followRemotePage,
          onChanged: (v) =>
              unawaited(cubit.updateOptions(followRemotePage: v)),
          title: const Text('双端同时打开同一教材时，自动跳转到最新翻到的页数'),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: account.syncMistakeBank,
          onChanged: (v) =>
              unawaited(cubit.updateOptions(syncMistakeBank: v)),
          title: const Text('同步本地错题本（自动按题号合并）'),
        ),
        const SizedBox(height: 10),
        _buildReadingHistorySection(context, state),
      ],
    );
  }

  Widget _buildReadingHistorySection(
    BuildContext context,
    LanSyncState state,
  ) {
    final colorScheme = ColorScheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const PhosphorIcon(PhosphorIconsLight.bookOpen, size: 18),
            const SizedBox(width: 6),
            Text(
              '上次阅读页数历史记忆 (${state.readingHistory.length})',
              style: TextTheme.of(context).titleSmall,
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (state.readingHistory.isEmpty)
          Card.outlined(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '打开并翻阅任意教材/试卷后，系统会自动记住你最后阅读的页数与位置并跨端同步。',
                style: TextTheme.of(context).bodySmall,
              ),
            ),
          )
        else
          for (final entry in state.readingHistory.take(15))
            Card.outlined(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                dense: true,
                leading: PhosphorIcon(
                  PhosphorIconsLight.cloudArrowUp,
                  color: colorScheme.primary,
                  size: 18,
                ),
                title: Text(
                  entry.docName.isEmpty ? entry.docPath : entry.docName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '第 ${entry.pageIndex}/${entry.totalPages} 页'
                  '${entry.pageName.isNotEmpty ? ' (${entry.pageName})' : ''} · '
                  '${entry.deviceName} · ${_formatRelativeTime(entry.updatedAtMs)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: '打开并继续刷题',
                  onPressed: () {
                    final navContext = widget.hostContext;
                    Navigator.of(context).pop();
                    if (navContext.mounted) {
                      unawaited(
                        openFile(
                          navContext,
                          false,
                          AssetLocation(path: entry.docPath),
                        ),
                      );
                    }
                  },
                  icon: const PhosphorIcon(
                    PhosphorIconsLight.arrowSquareIn,
                    size: 18,
                  ),
                ),
                onTap: () {
                  final navContext = widget.hostContext;
                  Navigator.of(context).pop();
                  if (navContext.mounted) {
                    unawaited(
                      openFile(
                        navContext,
                        false,
                        AssetLocation(path: entry.docPath),
                      ),
                    );
                  }
                },
              ),
            ),
      ],
    );
  }
}
