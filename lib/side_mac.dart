import 'dart:io';

import 'log.dart';
import 'model.dart';
import 'publish_mac.dart';
import 'side.dart';
import 'smb_mac.dart';

/// macOS 侧的动作实现。
///
/// 挂载交给系统 SMB 客户端，发布交给系统共享服务，驱动 Windows 走 SSH；
/// 界面只通过 [LocalSide] 调用这里，不认识任何命令细节。
class MacSide implements LocalSide {
  PublishSettings _publish = ConfigStore.loadPublishSettings();
  PeerTarget _peer = ConfigStore.loadPeer();

  Map<String, String> _macMounts = <String, String>{}; // linkId -> 系统挂载点
  Map<String, String> _sharePoints = <String, String>{}; // 共享名 -> 共享点路径
  Map<String, String> _folderAccess =
      <String, String>{}; // linkId -> ok/missing/unreachable
  Set<String> _mountIssues = <String>{}; // linkId，已挂载但配置的访问路径不可用
  final Set<String> _unreachable = <String>{}; // linkId，对端探测不可达
  String? _windowsMapping;

  final Set<String> _busy = <String>{};
  /// 已经尝试过自动挂载的共享区：linkId -> 尝试时的配置指纹。
  /// 配置改过就当没试过，用户改完配置能立刻重挂一次
  final Map<String, String> _attempted = <String, String>{};
  final Map<String, bool> _prevMounted = <String, bool>{};
  final Map<String, DateTime> _retryAfter = <String, DateTime>{};

  /// 已告警过的"无配置归属"挂载点；挂载消失后会移除，再次出现可重新告警
  final Set<String> _loggedOrphans = <String>{};
  /// linkId -> 已记过的自动挂载跳过原因，避免每轮巡检刷同样的行
  final Map<String, String> _skipLogged = <String, String>{};

  @override
  String get sideName => 'Mac';

  @override
  String get peerName => 'Windows';

  @override
  bool get usesSourceContainer => true;

  @override
  bool get needsContainerPath => true;

  @override
  bool get canPublishContainer => true;

  @override
  bool get usesSshToPeer => true;

  @override
  String get openWithLabel => '在 Finder 中打开';

  @override
  String get shareSettingsLabel => '设置容器目录…';

  @override
  String get shareSettingsTitle => '对外共享设置';

  @override
  String? get accountHint => null;

  @override
  bool localIsSource(ShareDirection direction) =>
      direction == ShareDirection.macToWindows;

  /// 共享名对应的共享点当前实际路径；未注册时为 null
  String? get _sharePointPath => _sharePoints[_publish.shareName.trim()];

  /// 共享点存在且路径与当前配置的容器一致，才算已发布
  bool get _published => _sharePointPath == _publish.effectiveRootPath;

  // ---------- 全局通道 ----------

  @override
  Future<String> peerHost() async => _peer.host.trim();

  @override
  ChannelView get channel {
    if (!_peer.isComplete) return ChannelView(text: '$peerName 连接未配置');
    if (!_published) {
      return const ChannelView(
        text: '尚未发布',
        actionLabel: '发布并映射',
      );
    }
    if (_windowsMapping == null) {
      return ChannelView(
        text: '已发布',
        actionLabel: '映射到 $peerName',
        published: true,
      );
    }
    final drive = _publish.driveLetter.trim().toUpperCase();
    return ChannelView(
      text: drive.isEmpty ? '已就绪' : '$drive: 已就绪',
      ready: true,
      published: true,
    );
  }

  /// 发布与映射合成一步：没发布就先发布，随后按需探测盘符并映射到 Windows
  @override
  Future<String?> connectChannel() async {
    if (!_peer.isComplete) return '请先配置 $peerName 侧连接信息';
    final started = DateTime.now();
    Log.i('channel',
        '发布并映射：peer=${_peer.host} share=${_publish.shareName} root=${_publish.effectiveRootPath} drive=${_publish.driveLetter}');
    try {
      if (!_published) {
        final error = await MacPublish.publishRoot(_publish);
        if (error != null) {
          Log.e('channel', '发布共享失败：$error');
          return error;
        }
        await refresh();
      }
      if (_publish.driveLetter.trim().isEmpty) {
        final detected = await MacPublish.detectDriveLetter(_peer);
        if (detected == null) {
          Log.e('channel', '没能在 $peerName 上探测到可用盘符');
          return '没能探测到 $peerName 上的可用盘符';
        }
        _publish.driveLetter = detected;
        ConfigStore.savePublishSettings(_publish);
        Log.i('channel', '探测到可用盘符：$detected');
      }
      final password = await readSecret();
      if (password == null) {
        Log.w('channel', '缺少凭据，无法在 $peerName 上登记映射');
        return '需要本机账户密码，用于在 $peerName 上登记凭据';
      }

      final error = await MacPublish.mapOnWindows(
        settings: _publish,
        target: _peer,
        password: password,
      );
      await refresh(full: true);
      Log.i('channel',
          error == null ? '映射完成，耗时 ${Log.ms(started)}ms' : '映射失败：$error');
      return error;
    } finally {
      // 盘符可能刚被探测出来，落盘一次，界面下次读到的就是新值
      ConfigStore.savePublishSettings(_publish);
    }
  }

  @override
  Future<String?> disconnectChannel() async {
    Log.i('channel', '断开 ${_peer.host} 上的盘符映射');
    final error =
        await MacPublish.unmapOnWindows(settings: _publish, target: _peer);
    await refresh(full: true);
    if (error != null) Log.e('channel', '断开映射失败：$error');
    return error;
  }

  @override
  Future<String?> publishOnly() async {
    Log.i('channel', '重新发布共享 ${_publish.shareName}');
    final error = await MacPublish.publishRoot(_publish);
    await refresh();
    if (error != null) Log.e('channel', '发布共享失败：$error');
    return error;
  }

  @override
  Future<String?> unpublishOnly() async {
    Log.i('channel', '取消发布共享 ${_publish.shareName}');
    final error = await MacPublish.unpublishRoot(_publish);
    await refresh();
    if (error != null) Log.e('channel', '取消发布失败：$error');
    return error;
  }

  // ---------- 探测 ----------

  @override
  Future<void> refresh({bool full = false}) async {
    _publish = ConfigStore.loadPublishSettings();
    _peer = ConfigStore.loadPeer();
    final links = ConfigStore.loadLinks();

    final mounts = await MacSmb.smbMounts();
    final points = await MacPublish.listSharePoints();

    final macMounts = <String, String>{};
    final mountIssues = <String>{};
    for (final ShareLink link in links) {
      if (!link.macIsTarget) continue;
      final path = mounts[MacSmb.keyOf(link)];
      if (path == null) continue;
      macMounts[link.id] = path;
      if (_aliasBroken(link, path)) mountIssues.add(link.id);
    }

    final sharePoints = <String, String>{};
    points.forEach((String record, Map<String, dynamic> info) {
      if ((info['smb_shared'] as num?)?.toInt() != 1) return;
      final name = (info['smb_name'] as String?)?.trim() ?? record;
      sharePoints[name] = (info['path'] as String? ?? '').trim();
    });

    String? mapping;
    Map<String, String>? folderAccess;
    if (full && _peer.isComplete) {
      mapping = await MacPublish.currentMapping(_peer);
      // 可见性验证需要凭据；钥匙串里没有就跳过，不弹窗打扰
      final password = await MacPublish.readStoredPassword();
      if (password != null) {
        folderAccess = <String, String>{};
        for (final ShareLink link in links) {
          if (!link.macIsSource) continue;
          final state = await MacPublish.checkFolderOnWindows(
            settings: _publish,
            target: _peer,
            folderName: MacPublish.relativePath(link, _publish),
            password: password,
          );
          if (state != null) folderAccess[link.id] = state;
        }
      }
    }

    _macMounts = macMounts;
    _mountIssues = mountIssues;
    _sharePoints = sharePoints;
    if (full) {
      _windowsMapping = mapping;
      if (folderAccess != null) _folderAccess = folderAccess;
    }
  }

  @override
  Future<void> checkHealth({bool initial = false}) async {
    final links = ConfigStore.loadLinks();
    final mounts = await MacSmb.smbMounts();
    final targets =
        links.where((ShareLink e) => e.macIsTarget).toList(growable: false);
    // 每轮巡检留一张挂载表快照，出问题时能定位"哪一轮之后东西变了"
    Log.i('tick',
        '挂载表：${mounts.isEmpty ? '无可用的 SMB 挂载' : mounts.entries.map((MapEntry<String, String> e) => '${e.key} -> ${e.value}').join(' | ')}');
    _reportOrphans(mounts, targets);
    for (final ShareLink link in targets) {
      if (_busy.contains(link.id)) continue;
      final mounted = mounts.containsKey(MacSmb.keyOf(link));
      final previous = _prevMounted[link.id];
      final reachable = await MacSmb.hostReachable(
        link.sourceHost,
        timeout: const Duration(seconds: 3),
      );
      if (previous != null && previous != mounted) {
        Log.i('health',
            '${link.displayName} 挂载状态翻转：${previous ? '已挂载' : '未挂载'} -> ${mounted ? '已挂载' : '未挂载'}（对端可达=$reachable）');
      }
      // 只用于界面上的状态提示，不影响挂载决策
      if (reachable) {
        _unreachable.remove(link.id);
      } else {
        _unreachable.add(link.id);
      }

      if (mounted && !reachable) {
        // 对端掉线留下的挂载点必须先清掉，否则 Finder 会一直转圈
        Log.w('health', '${link.displayName} 对端不可达但仍有挂载，先清理残留挂载点');
        _busy.add(link.id);
        await MacSmb.unmount(link);
        _busy.remove(link.id);
        _retryAfter[link.id] = DateTime.now().add(const Duration(seconds: 10));
      } else if (!mounted && reachable && link.autoMount) {
        // 只在启动首轮或"原本已挂载但掉线"时自动重挂，
        // 避免认证失败后反复弹出系统登录窗
        final fingerprint = _fingerprintOf(link);
        final shouldTry = (initial && _attempted[link.id] != fingerprint) ||
            _prevMounted[link.id] == true;
        final retryAt = _retryAfter[link.id];
        final ready = retryAt == null || DateTime.now().isAfter(retryAt);
        final skipReason = !shouldTry
            ? '非启动首轮且配置未变'
            : (!ready ? '处于上次失败的退避期内' : null);
        if (skipReason == null) {
          _skipLogged.remove(link.id);
        } else if (_skipLogged[link.id] != skipReason) {
          _skipLogged[link.id] = skipReason;
          Log.i('health', '${link.displayName} 跳过自动挂载：$skipReason');
        }
        if (shouldTry && ready) {
          Log.i('health', '${link.displayName} 触发自动挂载（首轮=$initial）');
          _busy.add(link.id);
          final error = await MacSmb.mount(link);
          _busy.remove(link.id);
          _attempted[link.id] = fingerprint;
          Log.i('health',
              error == null ? '${link.displayName} 自动挂载成功' : '${link.displayName} 自动挂载失败：$error');
          // ponytail: 固定 30 秒退避，够用；若认证频繁失败再考虑指数退避
          _retryAfter[link.id] =
              DateTime.now().add(Duration(seconds: error == null ? 0 : 30));
        }
      }
      _prevMounted[link.id] = mounted;
    }
  }

  /// 系统里还挂着、但配置中已没有对应共享区的挂载点：应用不会去卸载它，只会在这里报一次
  void _reportOrphans(Map<String, String> mounts, List<ShareLink> targets) {
    final claimed = targets.map(MacSmb.keyOf).toSet();
    for (final MapEntry<String, String> entry in mounts.entries) {
      if (claimed.contains(entry.key)) continue;
      if (!_loggedOrphans.add(entry.key)) continue;
      Log.w('orphan',
          '无配置归属的挂载点：${entry.key} -> ${entry.value}，不会被应用自动卸载');
    }
    _loggedOrphans.removeWhere((String key) => !mounts.containsKey(key));
  }

  /// 配置指纹：只关心挂载行为会用到的那几项，改过才允许再试一次自动挂载
  static String _fingerprintOf(ShareLink link) => <String>[
        link.sourceHost.trim(),
        link.shareName.trim(),
        link.sourceUser.trim(),
        link.mountPoint.trim(),
        link.autoMount.toString(),
      ].join('|');

  /// 配置了自定义访问路径时它是个符号链接，挂载成功但链接缺失或指向别处，Finder 里就点不开
  static bool _aliasBroken(ShareLink link, String realPoint) {
    final alias = link.mountPoint.trim();
    if (alias.isEmpty || alias == realPoint) return false;
    if (FileSystemEntity.isLinkSync(alias)) {
      return Link(alias).targetSync() != realPoint;
    }
    // 该路径本身就是个真实目录时，效果与符号链接等价，不算异常
    return !Directory(alias).existsSync();
  }

  // ---------- 本机作为访问方 ----------

  @override
  LinkView viewOf(ShareLink link) {
    final macIsTarget = link.macIsTarget;
    final mountPath = _macMounts[link.id];
    final drive = _publish.driveLetter.trim().toUpperCase();

    LinkState state = LinkState.idle;
    String? reason;
    LinkPrimary primary = LinkPrimary.none;
    String? primaryLabel;

    if (macIsTarget) {
      if (_mountIssues.contains(link.id)) {
        state = LinkState.warn;
        reason = '挂载点异常';
      } else if (_unreachable.contains(link.id)) {
        state = LinkState.warn;
        reason = '对端不可达';
      } else if (mountPath != null) {
        state = LinkState.ok;
      }
      primary = mountPath == null ? LinkPrimary.mount : LinkPrimary.open;
      primaryLabel = mountPath == null ? '挂载' : '打开';
    } else {
      final folderState = MacPublish.folderState(link, _publish);
      final access = _folderAccess[link.id];
      if (folderState != 'ready') {
        state = LinkState.warn;
        reason = folderState == 'missing' ? '目录不存在' : '目录不在容器内';
      } else if (!_published || _windowsMapping == null) {
        state = LinkState.idle;
      } else if (access == 'ok') {
        state = LinkState.ok;
      } else {
        state = LinkState.warn;
        reason = access == 'missing'
            ? 'Windows 侧看不到该目录'
            : access == 'unreachable'
                ? '对端不可达'
                : 'Windows 侧未验证';
      }
    }

    // 次要行只说明"目标端在哪"
    final relative = macIsTarget ? '' : MacPublish.relativePath(link, _publish);
    final location = macIsTarget
        ? (mountPath ?? '未挂载')
        : (drive.isEmpty ? '盘符未探测' : '$drive:\\$relative');

    return LinkView(
      state: state,
      location: location,
      reason: reason,
      primary: primary,
      primaryLabel: primaryLabel,
    );
  }

  @override
  Future<String?> mount(ShareLink link) async {
    _busy.add(link.id);
    try {
      final error = await MacSmb.mount(link);
      _attempted[link.id] = _fingerprintOf(link);
      if (error == null) _retryAfter[link.id] = DateTime.now();
      return error;
    } finally {
      _busy.remove(link.id);
      await refresh();
    }
  }

  @override
  Future<String?> unmount(ShareLink link) async {
    _busy.add(link.id);
    try {
      return await MacSmb.unmount(link);
    } finally {
      _busy.remove(link.id);
      await refresh();
    }
  }

  @override
  Future<String?> open(ShareLink link) async {
    if (link.macIsTarget) {
      final real = _macMounts[link.id];
      if (real == null) return '尚未挂载';
      final path = link.mountPoint.trim().isEmpty ? real : link.mountPoint.trim();
      await Process.run('/usr/bin/open', <String>[path]);
      return null;
    }
    await Process.run('/usr/bin/open', <String>[link.sourcePath]);
    return null;
  }

  // ---------- 本机作为提供方 ----------

  @override
  Future<String?> publishLink(ShareLink link) async => null; // Mac 走容器共享

  @override
  Future<String?> unpublishLink(ShareLink link) async => null;

  // ---------- 源端编辑辅助 ----------

  @override
  String? validateSourcePath(String sourcePath, PublishSettings settings) {
    final probe = ShareLink(
      id: '',
      direction: ShareDirection.macToWindows,
      shareName: '',
      sourcePath: sourcePath,
    );
    final state = MacPublish.folderState(probe, settings);
    if (state == 'missing') return '目录不存在：$sourcePath';
    if (state != 'ready') {
      return '该目录不在容器内（当前容器：${settings.effectiveRootPath}），'
          '请在「设置」里把容器目录改成它的父目录';
    }
    return null;
  }

  @override
  String deriveShareName(String sourcePath, PublishSettings settings) {
    final probe = ShareLink(
      id: '',
      direction: ShareDirection.macToWindows,
      shareName: '',
      sourcePath: sourcePath,
    );
    return MacPublish.relativePath(probe, settings);
  }

  // ---------- 通用 ----------

  @override
  Future<String?> pickFolder(String prompt) => MacPublish.pickFolder(prompt: prompt);

  @override
  Future<String?> readSecret() => MacPublish.readStoredPassword();

  @override
  Future<String?> storeSecret(String secret) => MacPublish.storePassword(secret);

  @override
  Future<String> localAddress() => MacPublish.localHostForWindows();
}
