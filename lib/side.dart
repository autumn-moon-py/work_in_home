import 'model.dart';

/// 卡片状态的语义，UI 只负责把它翻译成颜色
enum LinkState { ok, idle, warn }

/// 卡片主操作
enum LinkPrimary {
  none,

  /// 本机作为访问方：挂载/映射对端的共享
  mount,

  /// 打开本机已经可用的路径
  open,

  /// 本机作为提供方：把这条目录共享出去（Windows 建 SMB 共享）
  publish,
}

/// 一条共享区在本机视角下要展示的信息
class LinkView {
  const LinkView({
    required this.state,
    required this.location,
    this.reason,
    this.primary = LinkPrimary.none,
    this.primaryLabel,
    this.published = false,
  });

  final LinkState state;

  /// 次要行：目标端位置，例如 '/Volumes/跑团' 或 'Z:\work_in_home'
  final String location;

  /// 仅在异常时给一行原因
  final String? reason;

  /// 主操作
  final LinkPrimary primary;

  /// 主操作文案，例如 '挂载' / '打开'
  final String? primaryLabel;

  /// 本机已把这条共享区作为独立的 SMB 共享对外发布；
  /// 容器模型下共享区都挂在同一个容器共享里，恒为 false
  final bool published;
}

/// 全局通道（本机作为源端发布容器 → 对端映射盘符）的展示信息
class ChannelView {
  const ChannelView({
    required this.text,
    this.actionLabel,
    this.ready = false,
    this.published = false,
  });

  /// 例如 'Z: 已就绪' / '还未映射'
  final String text;

  /// 需要用户点一下时的按钮文案，null 表示不需要按钮
  final String? actionLabel;

  /// 通道已经打通（盘符映射就绪）
  final bool ready;

  /// 容器共享已发布；UI 用它决定按钮的强调程度
  final bool published;
}

/// 本机在共享关系里的动作集。两端界面完全共用，差异全部收敛在实现里。
abstract class LocalSide {
  String get sideName; // 'Mac' / 'Windows'
  String get peerName; // 'Windows' / 'Mac'

  /// 本机作为源端时是否采用"单一容器共享 + 子文件夹"模型
  /// （Mac 必须如此：一个盘符只能映射一个共享根）
  bool get usesSourceContainer;

  /// 是否需要用户在设置里指定容器目录（Mac 是；Windows 作为访问方时不需要）
  bool get needsContainerPath;

  /// 本机是否能管理"容器共享"的发布（只有容器持有方需要发布/取消发布）
  bool get canPublishContainer;

  /// 本机是否能、且需要用 SSH 驱动对端（Mac 是；Windows 驱动不了 Mac）
  /// → 决定连接设置对话框里是否出现 SSH 字段
  bool get usesSshToPeer;

  /// 用系统文件管理器打开本机路径时，菜单里的文案
  String get openWithLabel;

  /// 全局共享信息设置的菜单项文案（Mac 设的是自己的容器，Windows 设的是要映射的 Mac 共享）
  String get shareSettingsLabel;

  /// 该设置对话框的标题
  String get shareSettingsTitle;

  /// 本机作为源端需要用户手工配置时给的说明；没有则为 null
  String? get accountHint;

  /// 本机在这条关系里是不是"把目录共享出去"的一方
  bool localIsSource(ShareDirection direction);

  // ---- 全局通道 ----
  /// 对端地址，未配置返回空串
  Future<String> peerHost();

  /// 全局行状态（同步读，数据来自 refresh）
  ChannelView get channel;

  /// 一键达成可用（内部按需先发布再映射）
  Future<String?> connectChannel();

  /// 断开映射
  Future<String?> disconnectChannel();

  /// 仅发布（Mac）
  Future<String?> publishOnly();

  /// 仅取消发布（Mac）
  Future<String?> unpublishOnly();

  // ---- 本机作为访问方 ----
  /// 重新探测本机挂载/映射/共享与对端可达性；[full] 为 true 时同时探对端（SSH，较慢）
  Future<void> refresh({bool full = false});

  /// 周期性健康检查：清掉掉线后卡死的挂载点，并尝试恢复自动挂载项。
  /// [initial] 为 true 时是启动或刚改完配置的首轮，允许发起自动挂载
  Future<void> checkHealth({bool initial = false});

  LinkView viewOf(ShareLink link);

  Future<String?> mount(ShareLink link);

  Future<String?> unmount(ShareLink link);

  /// 用系统方式打开本机访问路径
  Future<String?> open(ShareLink link);

  // ---- 本机作为提供方 ----
  /// 让这条共享区对端可见（Windows 建共享）；Mac 走容器，返回 null
  Future<String?> publishLink(ShareLink link);

  Future<String?> unpublishLink(ShareLink link);

  // ---- 源端编辑辅助 ----
  /// 目录是否可用；返回 null 表示可用，否则是给用户看的原因
  String? validateSourcePath(String sourcePath, PublishSettings settings);

  /// 源端目录 → 对端看到的名字（Mac 用容器相对路径；Windows 用目录名）
  String deriveShareName(String sourcePath, PublishSettings settings);

  // ---- 通用 ----
  Future<String?> pickFolder(String prompt);

  /// 读已保存的凭据
  Future<String?> readSecret();

  Future<String?> storeSecret(String secret);

  /// 本机在虚拟网络里的地址
  Future<String> localAddress();
}
