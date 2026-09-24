import 'dart:io';

import 'model.dart';
import 'side.dart';
import 'smb_win.dart';

/// Windows 侧的动作实现。
///
/// 与 Mac 侧的角色正好相反：
/// - Windows → Mac 方向本机是源端，用 SMB 共享把本机目录共享出去（建/删共享走 UAC 提权）；
/// - Mac → Windows 方向本机是访问方，把 Mac 的容器共享映射成本机一个盘符。
///
/// 界面只通过 [LocalSide] 调用这里，不认识任何命令细节。
class WindowsSide implements LocalSide {
  /// 专用共享账户的创建脚本：Windows 空密码账户无法从网络登录 SMB
  static const String _accountHint = '''
\$u = 'winshare'
\$p = Read-Host -AsSecureString '设置共享账户密码'
New-LocalUser -Name \$u -Password \$p -PasswordNeverExpires -UserMayNotChangePassword -Description 'Win Share 文件共享专用账户'
''';

  PeerTarget _peer = ConfigStore.loadPeer();
  PublishSettings _publish = ConfigStore.loadPublishSettings();

  Map<String, String?> _sharePaths = <String, String?>{}; // linkId -> 本机共享的实际路径
  Map<String, bool> _folderAccess = <String, bool>{}; // linkId -> 盘符下能否看到该文件夹
  String? _containerMapping; // Mac 容器共享在本机映射到的远端路径
  List<String> _addresses = <String>[];

  /// 本次运行里用户输入的 Mac 账户密码。Windows 凭据管理器读不回密码，
  /// 只能记在内存里；真正登记由 [WinSmb.mapContainer] 交给 cmdkey 完成
  String? _secret;

  @override
  String get sideName => 'Windows';

  @override
  String get peerName => 'Mac';

  @override
  bool get usesSourceContainer => false;

  @override
  bool get needsContainerPath => false;

  @override
  bool get canPublishContainer => false;

  @override
  bool get usesSshToPeer => false;

  @override
  String get openWithLabel => '在资源管理器中打开';

  @override
  String get shareSettingsLabel => '设置 Mac 共享…';

  @override
  String get shareSettingsTitle => 'Mac 共享信息';

  @override
  String? get accountHint => _accountHint;

  @override
  bool localIsSource(ShareDirection direction) =>
      direction == ShareDirection.windowsToMac;

  /// 本机作为访问方时，这条共享区落在本机的路径；盘符没映射就返回空串
  String _localFolderPath(ShareLink link) {
    final drive = _publish.driveLetter.trim().toUpperCase();
    if (drive.isEmpty || _containerMapping == null) return '';
    return '$drive:\\${link.shareName.trim()}';
  }

  // ---------- 全局通道 ----------

  @override
  Future<String> peerHost() async => _peer.host.trim();

  @override
  ChannelView get channel {
    if (!_peer.hasHost) return ChannelView(text: '$peerName 连接未配置');
    if (_containerMapping == null) {
      return const ChannelView(text: '尚未映射', actionLabel: '映射到本机');
    }
    final drive = _publish.driveLetter.trim().toUpperCase();
    return ChannelView(
      text: drive.isEmpty ? '已就绪' : '$drive: 已就绪',
      ready: true,
      published: true,
    );
  }

  /// 盘符优先用设置里指定的，留空时自动探测一个并记下来
  Future<String?> _ensureDriveLetter() async {
    final current = _publish.driveLetter.trim().toUpperCase();
    if (current.isNotEmpty) return current;
    final detected = await WinSmb.detectDriveLetter();
    if (detected == null) return null;
    _publish.driveLetter = detected;
    ConfigStore.savePublishSettings(_publish);
    return detected;
  }

  /// 把 Mac 的容器共享映射成本机盘符
  Future<String?> _mapContainer() async {
    final host = _peer.host.trim();
    final user = _peer.smbUser.trim();
    final share = _publish.shareName.trim();
    if (host.isEmpty) return '请先配置 $peerName 侧连接信息';
    if (user.isEmpty) return '请先在「设置 $peerName 连接」里填 $peerName 上的账户';
    if (share.isEmpty) return '$peerName 侧共享名为空';

    final drive = await _ensureDriveLetter();
    if (drive == null) return '没能探测到可用盘符';
    return WinSmb.mapContainer(
      host: host,
      user: user,
      shareName: share,
      driveLetter: drive,
      password: _secret,
    );
  }

  Future<String?> _unmapLocal() async {
    final drive = _publish.driveLetter.trim().toUpperCase();
    if (drive.isEmpty) return '盘符未确定';
    return WinSmb.unmapDrive(drive);
  }

  @override
  Future<String?> connectChannel() async {
    final error = await _mapContainer();
    await refresh();
    return error;
  }

  @override
  Future<String?> disconnectChannel() async {
    final error = await _unmapLocal();
    await refresh();
    return error;
  }

  /// Windows 侧没有容器共享，发布是按共享区逐条做的（见 [publishLink]）
  @override
  Future<String?> publishOnly() async => null;

  @override
  Future<String?> unpublishOnly() async => null;

  // ---------- 探测 ----------

  @override
  Future<void> refresh({bool full = false}) async {
    _peer = ConfigStore.loadPeer();
    _publish = ConfigStore.loadPublishSettings();
    final links = ConfigStore.loadLinks();
    _addresses = await WinSmb.localAddresses();

    final paths = <String, String?>{};
    for (final ShareLink link in links) {
      if (!localIsSource(link.direction)) continue;
      paths[link.id] = await WinSmb.sharePath(link.shareName);
    }

    final drive = _publish.driveLetter.trim().toUpperCase();
    String? mapping;
    final access = <String, bool>{};
    if (drive.isNotEmpty) {
      mapping = await WinSmb.mappingTarget(drive);
      if (mapping != null) {
        for (final ShareLink link in links) {
          if (localIsSource(link.direction)) continue;
          if (link.shareName.trim().isEmpty) continue;
          access[link.id] = await WinSmb.folderVisible(drive, link.shareName);
        }
      }
    }

    _sharePaths = paths;
    _containerMapping = mapping;
    _folderAccess = access;
  }

  /// Windows 侧没有 Mac 那种"对端掉线留下卡死挂载点"需要清理，
  /// 状态探测全部由随后的 [refresh] 完成
  @override
  Future<void> checkHealth({bool initial = false}) async {}

  // ---------- 本机作为访问方 ----------

  @override
  LinkView viewOf(ShareLink link) {
    if (localIsSource(link.direction)) {
      // 本机是源端：目录共享出去了没有
      final created = _sharePaths[link.id] != null;
      final source = link.sourcePath.trim();
      LinkState state = LinkState.idle;
      String? reason;
      if (created) {
        state = LinkState.ok;
      } else if (source.isEmpty || !Directory(source).existsSync()) {
        state = LinkState.warn;
        reason = source.isEmpty ? '还没选要共享出去的目录' : '目录不存在';
      }
      return LinkView(
        state: state,
        location: source.isEmpty ? '未设置共享目录' : source,
        reason: reason,
        published: created,
        primary: created ? LinkPrimary.none : LinkPrimary.publish,
        primaryLabel: created ? null : '创建共享',
      );
    }

    // 本机是访问方：Mac 的容器共享映射到本机盘符下的子文件夹
    final drive = _publish.driveLetter.trim().toUpperCase();
    final mapped = _containerMapping != null;
    final visible = _folderAccess[link.id];
    LinkState state = LinkState.idle;
    String? reason;
    if (mapped && visible == true) {
      state = LinkState.ok;
    } else if (mapped) {
      state = LinkState.warn;
      reason = '盘符下看不到该文件夹（可能被 macOS 的链接策略拦截）';
    }
    return LinkView(
      state: state,
      location:
          drive.isEmpty ? '盘符未探测' : '$drive:\\${link.shareName.trim()}',
      reason: reason,
      primary: mapped ? LinkPrimary.open : LinkPrimary.mount,
      primaryLabel: mapped ? '打开' : '映射',
    );
  }

  @override
  Future<String?> mount(ShareLink link) async {
    // 源端方向没有"挂载"这一步，卡片主操作是创建共享
    if (localIsSource(link.direction)) return null;
    final error = await _mapContainer();
    await refresh();
    if (error != null && _secret == null) {
      return '$error\n\n本机还没登记过 $peerName 的凭据，'
          '先用顶部的「映射到本机」输入一次密码。';
    }
    return error;
  }

  @override
  Future<String?> unmount(ShareLink link) async {
    if (localIsSource(link.direction)) return null;
    final error = await _unmapLocal();
    await refresh();
    return error;
  }

  @override
  Future<String?> open(ShareLink link) async {
    if (localIsSource(link.direction)) {
      final path = link.sourcePath.trim();
      if (path.isEmpty) return '还没设置要共享的目录';
      await Process.run('explorer', <String>[path]);
      return null;
    }
    final path = _localFolderPath(link);
    if (path.isEmpty) return '尚未映射到本机';
    await Process.run('explorer', <String>[path]);
    return null;
  }

  // ---------- 本机作为提供方 ----------

  @override
  Future<String?> publishLink(ShareLink link) async {
    final error = await WinSmb.createShare(
      shareName: link.shareName,
      localPath: link.sourcePath,
      grantAccount: link.grantAccount,
    );
    await refresh();
    return error;
  }

  @override
  Future<String?> unpublishLink(ShareLink link) async {
    final error = await WinSmb.removeShare(link.shareName);
    await refresh();
    return error;
  }

  // ---------- 源端编辑辅助 ----------

  @override
  String? validateSourcePath(String sourcePath, PublishSettings settings) {
    final path = sourcePath.trim();
    if (path.isEmpty) return '请选择要共享出去的目录';
    if (!Directory(path).existsSync()) return '目录不存在：$path';
    return null;
  }

  @override
  String deriveShareName(String sourcePath, PublishSettings settings) {
    final segments = sourcePath
        .trim()
        .split(RegExp(r'[\\/]+'))
        .where((String e) => e.isNotEmpty)
        .toList();
    return segments.isEmpty ? '' : segments.last;
  }

  // ---------- 通用 ----------

  @override
  Future<String?> pickFolder(String prompt) => WinSmb.pickFolder();

  @override
  Future<String?> readSecret() async => _secret;

  @override
  Future<String?> storeSecret(String secret) async {
    _secret = secret;
    return null;
  }

  @override
  Future<String> localAddress() async {
    if (_addresses.isEmpty) _addresses = await WinSmb.localAddresses();
    return _addresses.isEmpty ? '' : _addresses.first;
  }
}
