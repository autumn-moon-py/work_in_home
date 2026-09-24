import 'dart:convert';
import 'dart:io';

/// 共享关系的方向：哪一端的目录，共享给哪一端使用。
enum ShareDirection {
  /// Windows 上的目录共享给 Mac，由 Mac 侧挂载
  windowsToMac,

  /// Mac 上的目录共享给 Windows，由 Windows 侧通过一个盘符访问
  macToWindows;

  String get label => this == ShareDirection.windowsToMac ? 'Windows → Mac' : 'Mac → Windows';

  static ShareDirection fromName(String? name) =>
      name == 'macToWindows' ? ShareDirection.macToWindows : ShareDirection.windowsToMac;
}

/// 一条共享关系。两端应用共用同一结构，各端只填写并使用自己这一侧的字段。
///
/// [shareName] 是"目标端看到的名字"：Windows 作为源端时它是 SMB 共享名；
/// Mac 作为源端时它是共享根目录下的文件夹名（Windows 侧表现为 `<盘符>:\<shareName>`）。
class ShareLink {
  ShareLink({
    required this.id,
    required this.direction,
    required this.shareName,
    this.label = '',
    this.sourcePath = '',
    this.sourceHost = '',
    this.sourceUser = '',
    this.mountPoint = '',
    this.autoMount = true,
    this.grantAccount = 'winshare',
    this.updatedAt = 0,
    this.deleted = false,
  });

  final String id;
  ShareDirection direction;
  String label;

  /// 目标端看到的名字
  String shareName;

  /// 源端被共享的目录
  String sourcePath;

  /// 源端主机地址；本机就是源端时留空
  String sourceHost;

  /// 连接源端所用的账户名
  String sourceUser;

  /// 目标端是 Mac 时的挂载目录
  String mountPoint;

  /// 目标端开机自动挂载（Mac 侧）
  bool autoMount;

  /// Windows 作为源端时，共享授权给的账户
  String grantAccount;

  /// 最近一次本地修改时间（毫秒），两端同步时用于判定谁更新
  int updatedAt;

  /// 删除墓碑：条目本身保留在配置文件里随快照广播，
  /// 否则对端的旧快照会把它"复活"；列表与业务逻辑都看不到它
  bool deleted;

  /// 进程内自增序号：Windows 的时钟精度不足以为连续调用给出不同的微秒，
  /// 同一轮同步里新建多条记录时纯时间戳会撞 id（而 id 被用作各处状态表的键）
  static int _idSeq = 0;

  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${(_idSeq++).toRadixString(36)}';

  /// 跨端身份：两端的 id 各自生成、互不相同，只能靠"方向 + 共享名"对齐
  String get syncKey => '${direction.name}|${shareName.trim()}';

  /// 本地改动后调用，让同步时本机能胜出
  void touch() => updatedAt = DateTime.now().millisecondsSinceEpoch;

  /// 本机是 Mac 时，这条关系里 Mac 扮演的角色
  bool get macIsTarget => direction == ShareDirection.windowsToMac;
  bool get macIsSource => direction == ShareDirection.macToWindows;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'direction': direction.name,
        'label': label,
        'shareName': shareName,
        'sourcePath': sourcePath,
        'sourceHost': sourceHost,
        'sourceUser': sourceUser,
        'mountPoint': mountPoint,
        'autoMount': autoMount,
        'grantAccount': grantAccount,
        'updatedAt': updatedAt,
        'deleted': deleted,
      };

  factory ShareLink.fromJson(Map<String, dynamic> json) => ShareLink(
        id: json['id'] as String? ?? newId(),
        direction: ShareDirection.fromName(json['direction'] as String?),
        label: json['label'] as String? ?? '',
        shareName: json['shareName'] as String? ?? '',
        sourcePath: json['sourcePath'] as String? ?? '',
        sourceHost: json['sourceHost'] as String? ?? '',
        sourceUser: json['sourceUser'] as String? ?? '',
        mountPoint: json['mountPoint'] as String? ?? '',
        autoMount: json['autoMount'] as bool? ?? true,
        grantAccount: json['grantAccount'] as String? ?? 'winshare',
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
        deleted: json['deleted'] as bool? ?? false,
      );

  String get displayName =>
      label.trim().isEmpty ? (shareName.trim().isEmpty ? sourcePath : shareName.trim()) : label.trim();
}

/// Mac 端对外共享的全局设置。
///
/// 一个盘符只能映射一个共享根，所以 Mac 侧只发布一个容器目录，
/// 各共享区以子文件夹形式出现在该盘符下，而不是每个共享区一个盘符。
class PublishSettings {
  PublishSettings({
    this.rootPath = '',
    this.shareName = 'macshare',
    this.driveLetter = '',
  });

  /// 容器目录；留空则用默认的 ~/WinShare
  String rootPath;

  /// SMB 共享名，必须 ASCII
  String shareName;

  /// 映射到 Windows 的盘符；留空表示自动探测
  String driveLetter;

  static const String defaultFolderName = 'WinShare';

  String get effectiveRootPath {
    final custom = rootPath.trim();
    if (custom.isNotEmpty) return custom;
    return '${Platform.environment['HOME'] ?? ''}/$defaultFolderName';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'rootPath': rootPath,
        'shareName': shareName,
        'driveLetter': driveLetter,
      };

  factory PublishSettings.fromJson(Map<String, dynamic> json) => PublishSettings(
        rootPath: json['rootPath'] as String? ?? '',
        shareName: json['shareName'] as String? ?? 'macshare',
        driveLetter: json['driveLetter'] as String? ?? '',
      );
}

/// 对端连接信息：Mac 上指 Windows，Windows 上指 Mac。
///
/// 两端共用同一份结构，只有 Mac 用得上 SSH（Windows 驱动不了 Mac）。
class PeerTarget {
  PeerTarget({
    this.host = '',
    this.sshUser = 'Administrator',
    this.sshKey = '',
    this.smbUser = 'winshare',
  });

  String host;
  String sshUser;

  /// SSH 私钥路径，允许以 ~ 开头
  String sshKey;

  /// 对端上用于 SMB 认证的账户，本机挂载/映射共享时使用
  String smbUser;

  /// 至少填了地址，够 Windows 端使用
  bool get hasHost => host.trim().isNotEmpty;

  /// 地址、SSH 用户、私钥齐备，Mac 端才能驱动对端
  bool get isComplete =>
      hasHost && sshUser.trim().isNotEmpty && sshKey.trim().isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'host': host,
        'sshUser': sshUser,
        'sshKey': sshKey,
        'smbUser': smbUser,
      };

  factory PeerTarget.fromJson(Map<String, dynamic> json) => PeerTarget(
        host: json['host'] as String? ?? '',
        sshUser: json['sshUser'] as String? ?? 'Administrator',
        sshKey: json['sshKey'] as String? ?? '',
        smbUser: json['smbUser'] as String? ?? 'winshare',
      );
}

/// 配置的本地持久化。用系统约定的应用数据目录，避免依赖 path_provider。
class ConfigStore {
  static String get directory {
    if (Platform.isWindows) {
      final base = Platform.environment['APPDATA'] ?? Directory.current.path;
      return '$base\\win_share';
    }
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return '$home/Library/Application Support/win_share';
  }

  static String get filePath =>
      Platform.isWindows ? '$directory\\shares.json' : '$directory/shares.json';

  static Map<String, dynamic> _readAll() {
    final file = File(filePath);
    if (!file.existsSync()) return <String, dynamic>{};
    try {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      // 配置损坏时退回空配置，避免应用起不来
      return <String, dynamic>{};
    }
  }

  static void _writeAll(Map<String, dynamic> data) {
    final file = File(filePath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  }

  /// 全部条目，含删除墓碑。只有同步流程需要它
  static List<ShareLink> loadAllLinks() =>
      ((_readAll()['links'] as List<dynamic>?) ?? <dynamic>[])
          .map((dynamic e) => ShareLink.fromJson(e as Map<String, dynamic>))
          .toList();

  /// 业务视角的条目：墓碑对界面与挂载逻辑一律不可见
  static List<ShareLink> loadLinks() =>
      loadAllLinks().where((ShareLink e) => !e.deleted).toList();

  static void saveLinks(List<ShareLink> links) {
    // 墓碑不在任何列表里，落盘时要单独捡回来，否则"对端复活"防线就断了
    final kept = loadAllLinks()
        .where((ShareLink e) =>
            e.deleted &&
            !links.any((ShareLink n) => n.syncKey == e.syncKey))
        .toList();
    _writeLinks(<ShareLink>[...links, ...kept]);
  }

  /// 连同墓碑一起覆盖写入，供同步合并使用
  static void saveAllLinks(List<ShareLink> links) => _writeLinks(links);

  /// 记墓碑：条目从列表消失，但对端要靠它得知"这条被删了"
  static void markDeleted(ShareLink link) {
    link.deleted = true;
    link.touch();
    final all = loadAllLinks();
    final index = all.indexWhere((ShareLink e) => e.syncKey == link.syncKey);
    if (index >= 0) {
      all[index] = link;
    } else {
      all.add(link);
    }
    _writeLinks(all);
  }

  static void _writeLinks(List<ShareLink> links) {
    final data = _readAll();
    data['links'] = links.map((ShareLink e) => e.toJson()).toList();
    _writeAll(data);
  }

  static PublishSettings loadPublishSettings() => PublishSettings.fromJson(
        (_readAll()['publishSettings'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      );

  static void savePublishSettings(PublishSettings settings) {
    final data = _readAll();
    data['publishSettings'] = settings.toJson();
    _writeAll(data);
  }

  static PeerTarget loadPeer() {
    final data = _readAll();
    // 兼容旧配置：早期版本把这份连接信息存在 windowsTarget 键下，
    // 读不到新键 peerTarget 时回落到它，保证升级后用户已填的内容不丢
    final raw = (data['peerTarget'] ?? data['windowsTarget']) as Map<String, dynamic>?;
    return PeerTarget.fromJson(raw ?? <String, dynamic>{});
  }

  static void savePeer(PeerTarget peer) {
    final data = _readAll();
    data['peerTarget'] = peer.toJson();
    _writeAll(data);
  }

  /// 启动时直接隐藏主窗口，便于作为登录项常驻菜单栏
  static bool loadStartHidden() => _readAll()['startHidden'] as bool? ?? false;

  static void saveStartHidden(bool value) {
    final data = _readAll();
    data['startHidden'] = value;
    _writeAll(data);
  }
}
