import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'log.dart';
import 'model.dart';
import 'side.dart';
import 'sync.dart';

/// 两端共用的主界面。平台差异全部由 [LocalSide] 承担，这里只负责展示与编排。
class WinShareHome extends StatefulWidget {
  const WinShareHome({super.key, required this.side});

  final LocalSide side;

  @override
  State<WinShareHome> createState() => _WinShareHomeState();
}

class _WinShareHomeState extends State<WinShareHome>
    with TrayListener {
  List<ShareLink> _links = <ShareLink>[];
  String _host = '';
  bool _globalBusy = false;
  final Set<String> _busy = <String>{};
  Timer? _timer;
  late final LinkSync _sync;

  LocalSide get side => widget.side;

  @override
  void initState() {
    super.initState();
    _links = ConfigStore.loadLinks();
    _sync = LinkSync(
      end: side.sideName.toLowerCase(),
      localIsSource: side.localIsSource,
      peerHost: side.peerHost,
    );
    unawaited(_sync.start());
    if (Platform.isMacOS) {
      trayManager.addListener(this);
      unawaited(_initTray());
    }
    // 启动即处理一次；配合 macOS 登录项即可实现开机自动挂载
    unawaited(_tick(initial: true));
    _timer =
        Timer.periodic(const Duration(seconds: 15), (_) => unawaited(_tick()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_sync.stop());
    if (Platform.isMacOS) {
      trayManager.removeListener(this);
      unawaited(trayManager.destroy());
    }
    super.dispose();
  }

  // ---------- macOS 菜单栏常驻 ----------

  /// 顶部菜单栏图标与菜单
  Future<void> _initTray() async {
    await trayManager.setIcon('assets/tray_icon.png',
        isTemplate: true, iconSize: 18);
    await trayManager.setToolTip('Win Share');
    await _syncTrayMenu();
  }

  /// 共享区当前状态的文字，和界面上的圆点同源
  String _stateText(ShareLink link) {
    final view = side.viewOf(link);
    return switch (view.state) {
      LinkState.ok => '已就绪',
      LinkState.idle => '未就绪',
      LinkState.warn => view.reason ?? '异常',
    };
  }

  /// 按当前状态重建菜单栏菜单，让菜单里的摘要与勾选保持最新
  Future<void> _syncTrayMenu() async {
    if (!Platform.isMacOS) return;
    final List<MenuItem> items = <MenuItem>[
      MenuItem(key: 'show', label: '打开主窗口'),
      MenuItem.separator(),
    ];
    // 本机作为源端时，容器共享这条全局通道放在摘要最前面
    if (_links.any((ShareLink e) => side.localIsSource(e.direction))) {
      items.add(MenuItem(
        label: '${side.peerName} · ${side.channel.text}',
        disabled: true,
      ));
    }
    for (final ShareLink link in _links) {
      items.add(MenuItem(
        label: '${link.displayName} · ${_stateText(link)}',
        disabled: true,
      ));
    }
    if (_links.isEmpty) {
      items.add(MenuItem(label: '还没有共享区', disabled: true));
    }
    items.addAll(<MenuItem>[
      MenuItem.separator(),
      MenuItem(key: 'refresh', label: '立即刷新'),
      MenuItem.checkbox(
        key: 'starthidden',
        label: '启动时隐藏窗口',
        checked: ConfigStore.loadStartHidden(),
      ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]);
    await trayManager.setContextMenu(Menu(items: items));
  }

  @override
  void onTrayIconMouseDown() {
    // tray_manager 的 macOS 实现不会把菜单常驻在状态栏图标上，
    // 必须在图标被按下时主动弹出（菜单关闭后原生侧会自行摘掉）
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await windowManager.show();
        await windowManager.focus();
      case 'refresh':
        await _refresh(full: true);
      case 'starthidden':
        ConfigStore.saveStartHidden(!ConfigStore.loadStartHidden());
        await _syncTrayMenu();
      case 'quit':
        await trayManager.destroy();
        await windowManager.destroy();
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 错误弹窗。详情可选中，并提供一键复制，方便用户把完整报错贴出来
  Future<void> _showError(String title, String detail) async {
    if (!mounted) return;
    // 先取好 Navigator，避免 await 之后再用 context
    final navigator = Navigator.of(context);
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(detail.trim().isEmpty ? '(空)' : detail),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: detail)));
              navigator.pop();
            },
            child: const Text('复制到剪贴板'),
          ),
          TextButton(
            onPressed: () => navigator.pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 动作收尾：有错误弹窗展示，否则轻提示成功
  Future<void> _finish(String? error, String successMessage,
      {String title = '操作失败'}) async {
    if (error != null) {
      await _showError(title, error.trim());
    } else {
      _toast(successMessage);
    }
  }

  /// 周期性健康检查 + 状态刷新。对端探测（SSH）较慢，只在启动与手动刷新时做
  Future<void> _tick({bool initial = false}) async {
    await side.checkHealth(initial: initial);
    // 与对端交换共享区数据；对端地址未配置时会直接跳过
    await _sync.push();

    // 被对端删掉的共享区：本机记录已消失，挂载点不能留成孤儿
    for (final ShareLink link in _sync.takeRemoval()) {
      Log.w('sync', '卸载被对端删除的共享区：${link.displayName}');
      await side.unmount(link);
    }

    // 数据刚被对端改写：重跑一轮首轮探测，让新增条目按 autoMount 立刻就绪
    if (_sync.takeChanged()) {
      await side.checkHealth(initial: true);
    }
    await _refresh(full: initial);
  }

  /// 重新探测本机状态（必要时含对端）后重建界面
  Future<void> _refresh({bool full = false}) async {
    final host = await side.peerHost();
    await side.refresh(full: full);
    if (!mounted) return;
    setState(() {
      _host = host;
      // 列表以磁盘为准：同步可能刚在别处改过这份数据
      _links = ConfigStore.loadLinks();
    });
    await _syncTrayMenu();
  }

  // ---------- 全局通道 ----------

  /// 取本机账户密码：优先用已保存的凭据，没有就让用户输一次并保存
  Future<bool> _ensureSecret() async {
    if (await side.readSecret() != null) return true;
    if (!mounted) return false;
    final peer = side.peerName;
    final account = _secretAccount;
    final entered = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _PasswordDialog(
        peerName: peer,
        account: account,
        // 两端要的都是 Mac 账户的密码，只是登记位置不同
        hint: side.usesSshToPeer
            ? '$peer 将以本机账户「$account」的身份连接，请输入它的密码。'
                '密码只存进 macOS 钥匙串，用于在 $peer 上登记凭据。'
            : '将以 $peer 上的账户「$account」连接，请输入它的密码。'
                '密码只交给 Windows 凭据管理器登记，之后可复用。',
      ),
    );
    if (entered == null || entered.isEmpty) return false;
    final error = await side.storeSecret(entered);
    if (error != null) await _showError('密码未能保存', error);
    return true;
  }

  /// 本机账户名
  String get _localAccount =>
      (Platform.environment['USER'] ?? Platform.environment['USERNAME'] ?? '')
          .trim();

  /// 密码弹窗里展示的账户名：Mac 侧就是本机账户（它同时也是 Mac 上的共享账户），
  /// Windows 侧则是全局对端设置里填的 Mac 账户
  String get _secretAccount {
    if (side.usesSshToPeer) return _localAccount;
    final smbUser = ConfigStore.loadPeer().smbUser.trim();
    return smbUser.isEmpty ? _localAccount : smbUser;
  }

  Future<void> _connectChannel() async {
    final peer = ConfigStore.loadPeer();
    // Windows 端驱动不了对端，只要有地址；Mac 端还要 SSH 用户与私钥
    if (side.usesSshToPeer ? !peer.isComplete : !peer.hasHost) {
      _toast('请先配置 ${side.peerName} 侧连接信息');
      return;
    }
    if (!await _ensureSecret()) return;
    _globalBusy = true;
    setState(() {});
    try {
      final error = await side.connectChannel();
      final drive = ConfigStore.loadPublishSettings().driveLetter.trim();
      // Mac 侧是把共享映射到对端，Windows 侧是把对端的共享映射到本机
      final where = side.usesSshToPeer ? '在 ${side.peerName} 上' : '在本机';
      await _finish(
        error,
        '已$where映射 $drive:',
        title: side.canPublishContainer ? '发布并映射失败' : '映射失败',
      );
    } finally {
      _globalBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _disconnectChannel() async {
    _globalBusy = true;
    setState(() {});
    try {
      final error = await side.disconnectChannel();
      await _finish(error, '已断开 ${side.peerName} 上的映射', title: '断开映射失败');
    } finally {
      _globalBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _republish() async {
    final shareName = ConfigStore.loadPublishSettings().shareName;
    _globalBusy = true;
    setState(() {});
    try {
      final error = await side.publishOnly();
      await _finish(error, '已重新发布共享 $shareName', title: '发布共享失败');
    } finally {
      _globalBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _unpublish() async {
    _globalBusy = true;
    setState(() {});
    try {
      final error = await side.unpublishOnly();
      await _finish(error, '已取消发布', title: '取消发布失败');
    } finally {
      _globalBusy = false;
      if (mounted) setState(() {});
    }
  }

  // ---------- 共享区动作 ----------

  Future<void> _mount(ShareLink link) async {
    // 用词跟着本机的做法走：Mac 是卷挂载，Windows 是盘符映射
    final label = side.viewOf(link).primaryLabel ?? '挂载';
    _busy.add(link.id);
    setState(() {});
    try {
      final error = await side.mount(link);
      if (error == null) {
        _toast('${link.displayName} 已$label');
      } else {
        await _showError('$label失败', error);
      }
    } finally {
      _busy.remove(link.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _unmount(ShareLink link) async {
    _busy.add(link.id);
    setState(() {});
    try {
      final error = await side.unmount(link);
      if (error != null) await _showError('卸载失败', error);
    } finally {
      _busy.remove(link.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _open(ShareLink link) async {
    final error = await side.open(link);
    if (error != null) _toast(error);
  }

  /// 本机作为源端：把这条共享区共享出去（Windows 会弹 UAC 提权框）
  Future<void> _publish(ShareLink link) async {
    _busy.add(link.id);
    setState(() {});
    try {
      final error = await side.publishLink(link);
      if (error == null) {
        _toast('共享 ${link.shareName} 已创建');
      } else {
        await _showError('创建共享失败', error);
      }
    } finally {
      _busy.remove(link.id);
      if (mounted) setState(() {});
    }
  }

  /// 撤销本机为这条共享区建的共享
  Future<void> _removeShare(ShareLink link) async {
    _busy.add(link.id);
    setState(() {});
    try {
      final error = await side.unpublishLink(link);
      if (error == null) {
        _toast('共享 ${link.shareName} 已移除（NTFS 权限未回收）');
      } else {
        await _showError('移除共享失败', error);
      }
    } finally {
      _busy.remove(link.id);
      if (mounted) setState(() {});
    }
  }

  // ---------- 设置 ----------

  Future<void> _editPeer() async {
    final result = await showDialog<PeerTarget>(
      context: context,
      builder: (BuildContext context) => _TargetDialog(
        side: side,
        original: ConfigStore.loadPeer(),
      ),
    );
    if (result == null) return;
    ConfigStore.savePeer(result);
    setState(() {
      // 源端地址与账户都是从全局对端设置派生的，这里同步一遍，避免两处不一致
      for (final ShareLink link in _links) {
        link.sourceHost = result.host.trim();
        link.sourceUser = result.smbUser.trim();
      }
    });
    ConfigStore.saveLinks(_links);
    await _refresh(full: true);
  }

  Future<void> _editPublish() async {
    final result = await showDialog<PublishSettings>(
      context: context,
      builder: (BuildContext context) => _PublishSettingsDialog(
        side: side,
        original: ConfigStore.loadPublishSettings(),
      ),
    );
    if (result == null) return;
    ConfigStore.savePublishSettings(result);
    await _refresh(full: true);
  }

  Future<void> _edit([ShareLink? original]) async {
    final result = await showDialog<ShareLink>(
      context: context,
      builder: (BuildContext context) => _LinkEditorDialog(
        side: side,
        original: original,
        settings: ConfigStore.loadPublishSettings(),
        peer: ConfigStore.loadPeer(),
      ),
    );
    if (result == null) return;
    // 本地改动必须带时间戳，否则同步时会被对端的旧数据盖回去
    result.touch();
    setState(() {
      final index = _links.indexWhere((ShareLink e) => e.id == result.id);
      if (index >= 0) {
        _links[index] = result;
      } else {
        _links.add(result);
      }
    });
    ConfigStore.saveLinks(_links);
    await _tick(initial: true);
  }

  /// 删除共享区：本机记录去掉并留墓碑（让对端跟随删除），已挂载的先卸掉
  Future<void> _remove(ShareLink link) async {
    setState(() {
      _links = _links.where((ShareLink e) => e.id != link.id).toList();
    });
    ConfigStore.markDeleted(link);
    await side.unmount(link);
    await _sync.push();
  }

  Future<void> _showAccountHint() async {
    final hint = side.accountHint;
    if (hint == null) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('共享账户说明'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: SelectableText(hint)),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // 状态圆点用色。M3 没有语义化的成功色，这里统一约定
  static final Color _stateOk = Colors.green.shade600;
  static final Color _stateWarn = Colors.amber.shade700;
  static const Color _stateIdle = Colors.grey;

  static Color _dotColor(LinkState state) => switch (state) {
        LinkState.ok => _stateOk,
        LinkState.warn => _stateWarn,
        LinkState.idle => _stateIdle,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 本机作为访问方的方向才有全局通道（Mac 是 windowsToMac，Windows 是 macToWindows）
    final hasLocalTarget =
        _links.any((ShareLink e) => !side.localIsSource(e.direction));
    return Scaffold(
      appBar: AppBar(
        title: Text('Win Share · ${side.sideName} 端'),
        actions: <Widget>[
          IconButton(
            onPressed: () => unawaited(_refresh(full: true)),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新状态',
          ),
          IconButton(
            onPressed: () => unawaited(_edit()),
            icon: const Icon(Icons.add),
            tooltip: '添加共享区',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
        children: <Widget>[
          if (hasLocalTarget) _buildStatusRow(theme),
          if (_links.isEmpty)
            const SizedBox(height: 240, child: _EmptyHint())
          else
            ..._links.map(_buildCard),
        ],
      ),
    );
  }

  /// 列表顶部的全局状态行：只表达本机 → 对端这一个方向的整体进度
  Widget _buildStatusRow(ThemeData theme) {
    final muted = theme.colorScheme.onSurfaceVariant;
    final channel = side.channel;

    Widget? action;
    if (channel.actionLabel != null) {
      final label = Text(channel.actionLabel!);
      action = channel.published
          ? OutlinedButton(
              onPressed: _globalBusy ? null : () => unawaited(_connectChannel()),
              child: label,
            )
          : FilledButton.tonal(
              onPressed: _globalBusy ? null : () => unawaited(_connectChannel()),
              child: label,
            );
    }

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 0, 2),
          child: Row(
            children: <Widget>[
              Icon(Icons.lan_outlined, size: 16, color: muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _host.isEmpty
                      ? '${side.peerName} 未配置'
                      : '${side.peerName} $_host',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: muted, fontSize: 13),
                ),
              ),
              // 共享区数据的同步状态：失败时靠它一眼看出来
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  _sync.statusText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    color: _sync.statusText == '同步失败' ? _stateWarn : muted,
                  ),
                ),
              ),
              if (action != null) action,
              if (action == null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    channel.text,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 13,
                      color: channel.ready ? _stateOk : muted,
                    ),
                  ),
                ),
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: const Icon(Icons.more_horiz, size: 18),
                onSelected: (String value) {
                  switch (value) {
                    case 'target':
                      unawaited(_editPeer());
                    case 'container':
                      unawaited(_editPublish());
                    case 'republish':
                      unawaited(_republish());
                    case 'unpublish':
                      unawaited(_unpublish());
                    case 'unmap':
                      unawaited(_disconnectChannel());
                    case 'hint':
                      unawaited(_showAccountHint());
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'target',
                    child: Text('设置 ${side.peerName} 连接…'),
                  ),
                  // 两端都要能改共享名与盘符：Mac 改的是自己的容器，Windows 改的是要映射的 Mac 共享
                  PopupMenuItem<String>(
                    value: 'container',
                    child: Text(side.shareSettingsLabel),
                  ),
                  if (side.canPublishContainer) ...<PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                      value: 'republish',
                      enabled: channel.published && !_globalBusy,
                      child: const Text('重新发布'),
                    ),
                    PopupMenuItem<String>(
                      value: 'unpublish',
                      enabled: channel.published && !_globalBusy,
                      child: const Text('取消发布'),
                    ),
                  ],
                  PopupMenuItem<String>(
                    value: 'unmap',
                    enabled: channel.ready && !_globalBusy,
                    child: Text('断开 ${side.peerName} 映射'),
                  ),
                  if (side.accountHint != null)
                    const PopupMenuItem<String>(
                      value: 'hint',
                      child: Text('共享账户说明…'),
                    ),
                ],
              ),
            ],
          ),
        ),
        const Divider(),
      ],
    );
  }

  Widget _buildCard(ShareLink link) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final busy = _busy.contains(link.id);
    // 本机是源端时箭头朝上（本机把目录共享出去），是访问方时朝下
    final localIsSource = side.localIsSource(link.direction);
    final view = side.viewOf(link);

    return Card(
      margin: const EdgeInsets.only(top: 5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  localIsSource ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 16,
                  color: muted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    link.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _dotColor(view.state),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (view.primary != LinkPrimary.none)
                  TextButton(
                    onPressed: () => unawaited(_primary(link, view.primary)),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(view.primaryLabel ?? ''),
                  ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  icon: const Icon(Icons.more_horiz, size: 18),
                  onSelected: (String value) {
                    switch (value) {
                      case 'unmount':
                        unawaited(_unmount(link));
                      case 'unshare':
                        unawaited(_removeShare(link));
                      case 'open':
                        unawaited(_open(link));
                      case 'edit':
                        unawaited(_edit(link));
                      case 'remove':
                        unawaited(_remove(link));
                    }
                  },
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<String>>[
                    // 卸载只在确实挂着的时候出现，避免菜单里常驻一条不可用的项
                    if (view.primary == LinkPrimary.open)
                      PopupMenuItem<String>(
                        value: 'unmount',
                        enabled: !busy,
                        child: const Text('卸载'),
                      ),
                    // 本机建过的共享，撤销入口放菜单里（主按钮只在没建时出现）
                    if (view.published)
                      PopupMenuItem<String>(
                        value: 'unshare',
                        enabled: !busy,
                        child: const Text('移除共享'),
                      ),
                    // 主按钮「打开」做的就是这个方向自己的事，菜单里不再重复
                    if (localIsSource)
                      PopupMenuItem<String>(
                        value: 'open',
                        enabled: link.sourcePath.trim().isNotEmpty && !busy,
                        child: Text(side.sideName == 'Windows'
                            ? '在资源管理器中打开'
                            : '在 Finder 中打开'),
                      ),
                    PopupMenuItem<String>(
                      value: 'edit',
                      enabled: !busy,
                      child: const Text('编辑…'),
                    ),
                    PopupMenuItem<String>(
                      value: 'remove',
                      enabled: !busy,
                      child: const Text('移除'),
                    ),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text(
                view.location,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: muted, fontSize: 12.5),
              ),
            ),
            if (view.reason != null)
              Padding(
                padding: const EdgeInsets.only(left: 24, top: 2),
                child: Text(
                  view.reason!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: _stateWarn, fontSize: 12.5),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _primary(ShareLink link, LinkPrimary primary) async {
    switch (primary) {
      case LinkPrimary.mount:
        await _mount(link);
      case LinkPrimary.open:
        await _open(link);
      case LinkPrimary.publish:
        await _publish(link);
      case LinkPrimary.none:
        break;
    }
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        '还没有共享区，点右上角 + 添加',
        style: theme.textTheme.bodySmall?.copyWith(
          fontSize: 13,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 添加/编辑共享区。方向与本机在两个方向上的角色共同决定要填哪些字段。
class _LinkEditorDialog extends StatefulWidget {
  const _LinkEditorDialog({
    required this.side,
    this.original,
    required this.settings,
    required this.peer,
  });

  final LocalSide side;
  final ShareLink? original;

  /// 对外共享设置，用来判断目录是否落在容器内、以及算出相对路径
  final PublishSettings settings;

  /// 全局的对端连接信息；源端地址与账户都由它派生
  final PeerTarget peer;

  @override
  State<_LinkEditorDialog> createState() => _LinkEditorDialogState();
}

class _LinkEditorDialogState extends State<_LinkEditorDialog> {
  late final TextEditingController _label;
  late final TextEditingController _share;
  late final TextEditingController _sourcePath;
  late final TextEditingController _mountPoint;
  late final TextEditingController _grantAccount;
  late ShareDirection _direction;
  late bool _autoMount;

  /// 对端是否用容器共享模型。容器只出现在 Mac 那一侧，
  /// 所以本机就是容器持有方时，对端必然不是
  bool get _peerUsesContainer => !widget.side.usesSourceContainer;

  @override
  void initState() {
    super.initState();
    final ShareLink? origin = widget.original;
    _label = TextEditingController(text: origin?.label ?? '');
    _share = TextEditingController(text: origin?.shareName ?? '');
    _sourcePath = TextEditingController(text: origin?.sourcePath ?? '');
    _mountPoint = TextEditingController(text: origin?.mountPoint ?? '');
    _grantAccount = TextEditingController(text: origin?.grantAccount ?? 'winshare');
    _direction = origin?.direction ?? ShareDirection.windowsToMac;
    _autoMount = origin?.autoMount ?? true;
  }

  @override
  void dispose() {
    _label.dispose();
    _share.dispose();
    _sourcePath.dispose();
    _mountPoint.dispose();
    _grantAccount.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final picked = await widget.side
        .pickFolder('选择要共享给 ${widget.side.peerName} 的目录');
    if (picked == null || !mounted) return;
    setState(() => _sourcePath.text = picked);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _submit() {
    final side = widget.side;
    final localIsSource = side.localIsSource(_direction);
    String shareName;
    if (localIsSource) {
      final source = _sourcePath.text.trim();
      if (source.isEmpty) {
        _toast('${side.sideName} → ${side.peerName} 方向需要选一个目录');
        return;
      }
      final problem = side.validateSourcePath(source, widget.settings);
      if (problem != null) {
        _toast(problem);
        return;
      }
      // Mac 侧的共享名就是容器内的相对路径（那种关系里不显示共享名输入框）；
      // Windows 侧可以自己取名，留空就用目录名
      final typed = side.usesSourceContainer ? '' : _share.text.trim();
      shareName =
          typed.isNotEmpty ? typed : side.deriveShareName(source, widget.settings);
      if (shareName.isEmpty) {
        _toast('请填共享名');
        return;
      }
    } else {
      // 对端上的名字，允许中文等字符
      shareName = _share.text.trim();
      // 对端逐条发布共享时名字必须填；对端用容器时留空表示容器根目录
      if (shareName.isEmpty && !_peerUsesContainer) {
        _toast('请填 ${side.peerName} 上的共享名');
        return;
      }
      if (widget.peer.host.trim().isEmpty) {
        _toast('请先在「设置 ${side.peerName} 连接」里填好 ${side.peerName} 的地址');
        return;
      }
    }

    final ShareLink? origin = widget.original;
    Navigator.of(context).pop(
      ShareLink(
        id: origin?.id ?? ShareLink.newId(),
        direction: _direction,
        label: _label.text.trim(),
        shareName: shareName,
        sourcePath: _sourcePath.text.trim(),
        // 源端地址与账户来自全局的对端连接设置，改全局后所有共享区一起生效
        sourceHost: widget.peer.host.trim(),
        sourceUser: widget.peer.smbUser.trim(),
        mountPoint: _mountPoint.text.trim(),
        autoMount: _autoMount,
        grantAccount: _grantAccount.text.trim().isEmpty
            ? 'winshare'
            : _grantAccount.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final side = widget.side;
    final peer = side.peerName;
    final localIsSource = side.localIsSource(_direction);
    return AlertDialog(
      title: Text(widget.original == null ? '添加共享区' : '编辑共享区'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('方向'),
              const SizedBox(height: 8),
              SegmentedButton<ShareDirection>(
                segments: const <ButtonSegment<ShareDirection>>[
                  ButtonSegment<ShareDirection>(
                    value: ShareDirection.windowsToMac,
                    label: Text('Windows → Mac'),
                    icon: Icon(Icons.cloud_download_outlined, size: 16),
                  ),
                  ButtonSegment<ShareDirection>(
                    value: ShareDirection.macToWindows,
                    label: Text('Mac → Windows'),
                    icon: Icon(Icons.cloud_upload_outlined, size: 16),
                  ),
                ],
                selected: <ShareDirection>{_direction},
                onSelectionChanged: (Set<ShareDirection> value) =>
                    setState(() => _direction = value.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _label,
                decoration: const InputDecoration(labelText: '名称（可留空）'),
              ),
              // 输入框在 compact 密度下浮动 label 会略微溢出，相邻输入框之间留出间距
              if (localIsSource) ...<Widget>[
                // 容器模型下共享名由容器相对路径决定，不需要用户取名
                if (!side.usesSourceContainer) ...<Widget>[
                  const SizedBox(height: 14),
                  TextField(
                    controller: _share,
                    decoration: const InputDecoration(
                      labelText: '共享名',
                      hintText: '例如 跑团',
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _sourcePath,
                        decoration: const InputDecoration(labelText: '要共享的目录'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                        onPressed: _pickFolder, child: const Text('选择')),
                  ],
                ),
                if (!side.usesSourceContainer) ...<Widget>[
                  const SizedBox(height: 14),
                  TextField(
                    controller: _grantAccount,
                    decoration: const InputDecoration(
                      labelText: '授权账户',
                      hintText: '默认 winshare',
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  side.usesSourceContainer
                      ? '该目录必须位于容器目录（${widget.settings.effectiveRootPath}）内，'
                          '$peer 侧通过 <盘符>:\\<相对路径> 访问它，不需要另外取名。'
                      : '共享名就是 $peer 侧看到的 SMB 共享名，'
                          '授权账户是 $peer 用来登录的那一个。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ] else ...<Widget>[
                const SizedBox(height: 14),
                TextField(
                  controller: _share,
                  decoration: _peerUsesContainer
                      ? const InputDecoration(
                          labelText: '容器内的相对路径（可留空）',
                          hintText: '留空为容器根目录',
                        )
                      : InputDecoration(
                          labelText: '$peer 上的共享名',
                          hintText: '例如 跑团',
                        ),
                ),
                if (!_peerUsesContainer) ...<Widget>[
                  const SizedBox(height: 14),
                  TextField(
                    controller: _mountPoint,
                    decoration: const InputDecoration(
                      labelText: '本机挂载点（可留空）',
                      hintText: '留空则使用 /Volumes/<共享名>',
                    ),
                  ),
                  const SizedBox(height: 14),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _autoMount,
                    onChanged: (bool value) => setState(() => _autoMount = value),
                    title: const Text('启动时自动挂载到本机'),
                  ),
                ],
                if (_peerUsesContainer) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    '该路径是 $peer 容器共享内的相对位置，'
                    '本机路径为 <盘符>:\\<相对路径>。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}

/// 对外共享的全局设置：容器目录、共享名、盘符
class _PublishSettingsDialog extends StatefulWidget {
  const _PublishSettingsDialog({required this.side, required this.original});

  final LocalSide side;
  final PublishSettings original;

  @override
  State<_PublishSettingsDialog> createState() => _PublishSettingsDialogState();
}

class _PublishSettingsDialogState extends State<_PublishSettingsDialog> {
  late final TextEditingController _root;
  late final TextEditingController _share;
  late final TextEditingController _drive;

  @override
  void initState() {
    super.initState();
    _root = TextEditingController(text: widget.original.effectiveRootPath);
    _share = TextEditingController(text: widget.original.shareName);
    _drive = TextEditingController(text: widget.original.driveLetter);
  }

  @override
  void dispose() {
    _root.dispose();
    _share.dispose();
    _drive.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked =
        await widget.side.pickFolder('选择对外共享的容器目录');
    if (picked != null && mounted) setState(() => _root.text = picked);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.side.shareSettingsTitle),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '一个盘符只能映射一个共享根，所以 ${widget.side.sideName} 侧只发布一个容器目录，'
              '各共享区以子文件夹形式出现在它下面。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            // 容器目录只有容器持有方（Mac）需要填
            if (widget.side.needsContainerPath) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _root,
                      decoration: const InputDecoration(labelText: '容器目录'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: _pick, child: const Text('选择')),
                ],
              ),
              const SizedBox(height: 14),
            ],
            TextField(
              controller: _share,
              decoration: const InputDecoration(
                labelText: 'SMB 共享名',
                hintText: 'ASCII，例如 macshare',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _drive,
              decoration: InputDecoration(
                labelText: '${widget.side.peerName} 盘符（留空自动探测）',
                hintText: '单个字母',
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            PublishSettings(
              rootPath: _root.text.trim(),
              shareName:
                  _share.text.trim().isEmpty ? 'macshare' : _share.text.trim(),
              driveLetter: _drive.text.trim().toUpperCase(),
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _TargetDialog extends StatefulWidget {
  const _TargetDialog({required this.side, required this.original});

  final LocalSide side;
  final PeerTarget original;

  @override
  State<_TargetDialog> createState() => _TargetDialogState();
}

class _TargetDialogState extends State<_TargetDialog> {
  late final TextEditingController _host;
  late final TextEditingController _user;
  late final TextEditingController _smbUser;
  late final TextEditingController _key;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.original.host);
    _user = TextEditingController(text: widget.original.sshUser);
    _smbUser = TextEditingController(text: widget.original.smbUser);
    _key = TextEditingController(text: widget.original.sshKey);
  }

  @override
  void dispose() {
    _host.dispose();
    _user.dispose();
    _smbUser.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.side.peerName;
    // 只有本机能用 SSH 驱动对端时才需要填 SSH 项
    final needsSsh = widget.side.usesSshToPeer;
    return AlertDialog(
      title: Text('$peer 侧连接'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _host,
              decoration: InputDecoration(
                labelText: '主机 IP',
                hintText: '$peer 的 ZeroTier 地址',
              ),
            ),
            if (needsSsh) ...<Widget>[
              const SizedBox(height: 14),
              TextField(
                controller: _user,
                decoration: const InputDecoration(labelText: 'SSH 用户'),
              ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _smbUser,
              decoration: InputDecoration(
                labelText: 'SMB 账户',
                hintText: '$peer 上用于文件共享的账户，例如 winshare',
              ),
            ),
            if (needsSsh) ...<Widget>[
              const SizedBox(height: 14),
              TextField(
                controller: _key,
                decoration: const InputDecoration(
                  labelText: 'SSH 私钥路径',
                  hintText: '例如 ~/.ssh/id_ed25519_windows',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            PeerTarget(
              host: _host.text.trim(),
              sshUser: _user.text.trim(),
              sshKey: _key.text.trim(),
              smbUser: _smbUser.text.trim(),
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({
    required this.peerName,
    required this.account,
    required this.hint,
  });

  final String peerName;
  final String account;

  /// 提示语由调用方给：两端要的都是 Mac 账户的密码，但登记位置不同
  final String hint;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final TextEditingController _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peerName;
    return AlertDialog(
      title: Text('$peer 需要登录凭据'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(widget.hint),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: '密码'),
              onSubmitted: (String value) => Navigator.of(context).pop(value),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_password.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
