// Mac 挂载路径与 Windows 共享目录之间的映射与安全校验。
import 'package:win_share/model.dart';

import 'win_pwsh.dart';

/// Mac 挂载路径到 Windows 共享路径的映射。
///
/// 同时充当兜底删除的安全边界：无法安全定位时 [relativeOf] /
/// [windowsPathOf] 一律返回 null，调用方据此拒绝执行。
class SharePath {
  SharePath({
    required this.base,
    required this.windowsRoot,
  });

  /// Mac 侧的基准路径：自定义别名优先，其次系统挂载点 /Volumes/<共享名>
  final String base;

  /// Windows 侧的共享根，例如 D:\跑团
  final String windowsRoot;

  /// 把 Mac 路径换算成共享内的相对路径（反斜杠）。
  /// 为空、越界或指向共享根本身时返回 null。
  String? relativeOf(String macPath) {
    final String normalized = _trimSlash(macPath);
    final String root = _trimSlash(base);
    if (root.isEmpty) return null;
    if (normalized == root) return null;
    if (!normalized.startsWith('$root/')) return null;
    final String rel = normalized.substring(root.length + 1);
    if (rel.isEmpty) return null;
    // 反斜杠在 Windows 上是分隔符，含反斜杠的组件会让路径逃出共享根
    if (rel.contains('\\')) return null;
    if (rel.split('/').any((String s) => s.isEmpty || s == '.' || s == '..')) {
      return null;
    }
    return rel.replaceAll('/', '\\');
  }

  /// Windows 绝对路径；越界或为空时返回 null。
  String? windowsPathOf(String macPath) {
    final String? rel = relativeOf(macPath);
    if (rel == null) return null;
    final String root = _trimTrailingSeparators(windowsRoot);
    if (root.isEmpty) return null;
    return '$root\\$rel';
  }

  /// 找到路径所属的共享区；多处命中时取最长基准路径
  static ({ShareLink link, String base})? findOwner(
    List<ShareLink> links,
    String macPath,
  ) {
    final String p = _trimSlash(macPath);
    ({ShareLink link, String base})? best;
    for (final ShareLink link in links) {
      if (link.direction != ShareDirection.windowsToMac) continue;
      final String shareName = link.shareName.trim();
      final Set<String> candidates = <String>{
        if (shareName.isNotEmpty) '/Volumes/$shareName',
        if (link.mountPoint.trim().isNotEmpty) link.mountPoint.trim(),
      };
      for (final String candidate in candidates) {
        final String b = _trimSlash(candidate);
        if (b.isEmpty) continue;
        if (p == b || p.startsWith('$b/')) {
          if (best == null || b.length > best.base.length) {
            best = (link: link, base: b);
          }
        }
      }
    }
    return best;
  }

  /// 查询共享在 Windows 上的真实根路径
  static Future<String?> resolveWindowsRoot(
    PeerTarget target,
    ShareLink link,
  ) async {
    final String name = link.shareName.trim().replaceAll("'", "''");
    final String script = "(Get-SmbShare -Name '$name').Path";
    final ({int code, String out, String err}) result =
        await WinPwsh.run(target, script);
    if (result.code != 0) return null;
    final String value = result.out.trim();
    return value.isEmpty ? null : value;
  }

  static String _trimSlash(String path) {
    String s = path.trim();
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 去掉 Windows 路径末尾的分隔符（反斜杠或正斜杠）
  static String _trimTrailingSeparators(String path) {
    String s = path.trim();
    while (s.length > 1 && (s.endsWith('\\') || s.endsWith('/'))) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}
