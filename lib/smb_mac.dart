import 'dart:io';

import 'log.dart';
import 'model.dart';

/// macOS 侧的 SMB 编排层。
///
/// 挂载与认证全部交给系统自带的 SMB 客户端：应用只负责发起、监控与清理，
/// 因此不接触也不保存任何密码（首次挂载由系统弹窗认证，凭据存入钥匙串）。
/// 一次挂载表快照。
///
/// 除了"主机/共享 -> 挂载点"，还标出其中由系统按需建立的子挂载：共享内的目录
/// 联接点（junction）被访问时 macOS 会给它单独挂一条，条目数会随遍历爆炸
class SmbMountTable {
  const SmbMountTable(this.points, this.submounts);

  final Map<String, String> points;
  final Set<String> submounts;
}

class MacSmb {
  static const String _open = '/usr/bin/open';
  static const String _mount = '/sbin/mount';
  static const String _diskutil = '/usr/sbin/diskutil';

  /// 上一次告警过的重复挂载组合，避免每轮巡检都刷同样的行
  static String _lastDuplicate = '';

  /// 对端 SMB 端口是否可达，用于区分"未挂载"与"对端掉线"
  static Future<bool> hostReachable(
    String host, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final target = host.trim();
    if (target.isEmpty) return false;
    try {
      final socket = await Socket.connect(target, 445, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static String keyOf(ShareLink link) =>
      '${link.sourceHost.trim()}/${link.shareName.trim()}'.toLowerCase();

  /// 解析 mount 输出，返回 "主机/共享名" -> 系统挂载点。
  /// 每行形如：//user@host/share on /Volumes/share (smbfs, nodev, ...)
  static Future<SmbMountTable> smbMounts() async {
    final result = await Process.run(_mount, const <String>[]);
    final mounts = <String, String>{};
    final submounts = <String>{};
    // 同一共享被挂多次时系统会造出 "名字 1" 这样的挂载点，
    // 这里先按共享分组，输出后统一告警一次
    final pointsOfKey = <String, List<String>>{};
    for (final line in (result.stdout as String).split('\n')) {
      if (!line.contains('(smbfs')) continue;
      final onIndex = line.indexOf(' on ');
      if (onIndex < 0) continue;
      var source = line.substring(0, onIndex).trim();
      final rest = line.substring(onIndex + 4);
      final pathEnd = rest.indexOf(' (');
      if (pathEnd < 0) continue;
      if (source.startsWith('//')) source = source.substring(2);
      final at = source.indexOf('@');
      if (at >= 0) source = source.substring(at + 1);
      final key = _decodePercent(source).toLowerCase();
      final point = rest.substring(0, pathEnd);
      mounts[key] = point;
      // 按需建立的子挂载带 automounted 选项，据此与正常挂载区分
      if (rest.substring(pathEnd).contains('automounted')) submounts.add(key);
      (pointsOfKey[key] ??= <String>[]).add(point);
    }
    _reportDuplicates(pointsOfKey);
    return SmbMountTable(mounts, submounts);
  }

  /// 同一个共享对应多个挂载点就是重复挂载，组合变化时才记一次日志
  static void _reportDuplicates(Map<String, List<String>> pointsOfKey) {
    final duplicates = pointsOfKey.entries
        .where((MapEntry<String, List<String>> e) => e.value.length > 1)
        .map((MapEntry<String, List<String>> e) =>
            '${e.key} -> ${e.value.join(', ')}')
        .join('; ');
    if (duplicates == _lastDuplicate) return;
    _lastDuplicate = duplicates;
    if (duplicates.isNotEmpty) {
      Log.w('smb', '同一共享存在多个挂载点：$duplicates');
    }
  }

  /// mount 输出里的共享名是百分号编码的（中文共享名一定如此），比对前必须还原
  static String _decodePercent(String source) {
    return source.split('/').map((String part) {
      try {
        return Uri.decodeComponent(part);
      } catch (_) {
        return part;
      }
    }).join('/');
  }

  /// 挂载成功返回 null，失败返回可展示的错误原因
  static Future<String?> mount(
    ShareLink link, {
    Duration timeout = const Duration(seconds: 40),
  }) async {
    final started = DateTime.now();
    final who = '${link.displayName} (${keyOf(link)})';
    if (link.sourceHost.trim().isEmpty || link.shareName.trim().isEmpty) {
      Log.w('mount', '参数不完整，放弃挂载：$who');
      return '源端地址或共享名未填写完整';
    }

    final existing = (await smbMounts()).points[keyOf(link)];
    if (existing != null) {
      Log.i('mount', '$who 系统中已存在挂载点 $existing，只同步访问路径');
      await _syncAlias(link, existing);
      return null;
    }

    if (!await hostReachable(link.sourceHost)) {
      Log.w('mount',
          '$who 源端 ${link.sourceHost} 的 445 端口不可达，放弃挂载');
      return '源端 ${link.sourceHost} 的 445 端口不可达，请确认对端在线且共享已开启';
    }

    final userPart = link.sourceUser.trim().isEmpty
        ? ''
        : '${Uri.encodeComponent(link.sourceUser.trim())}@';
    final url = 'smb://$userPart${link.sourceHost.trim()}'
        '/${Uri.encodeComponent(link.shareName.trim())}';
    Log.i('mount', '$who 发起系统挂载：$url');
    await Process.run(_open, <String>[url]);

    // 系统挂载是异步的，这里轮询到出现为止
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final point = (await smbMounts()).points[keyOf(link)];
      if (point != null) {
        Log.i('mount', '$who 挂载完成 -> $point，耗时 ${Log.ms(started)}ms');
        await _syncAlias(link, point);
        return null;
      }
    }
    Log.e('mount',
        '$who 等待系统挂载超时（${timeout.inSeconds}s），耗时 ${Log.ms(started)}ms');
    return '等待系统挂载超时；若弹出了认证窗口，请完成登录后重试';
  }

  /// 卸载成功返回 null，失败返回错误原因
  static Future<String?> unmount(ShareLink link) async {
    final started = DateTime.now();
    final who = '${link.displayName} (${keyOf(link)})';
    final point = (await smbMounts()).points[keyOf(link)];
    if (point == null) {
      Log.i('unmount', '$who 系统中查无挂载点，只清理访问路径');
      await _removeAlias(link);
      return null;
    }
    // 对端掉线后留下的挂载点会假死，普通卸载可能卡住，失败即转强制卸载
    var result = await Process.run(_diskutil, <String>['unmount', point]);
    if (result.exitCode != 0) {
      Log.w('unmount',
          '$who 常规卸载 $point 失败（exit=${result.exitCode}），转强制卸载');
      result = await Process.run(_diskutil, <String>['unmount', 'force', point]);
    }
    if (result.exitCode != 0) {
      Log.e('unmount',
          '$who 卸载 $point 失败：${(result.stderr as String).trim()}');
      return (result.stderr as String).trim();
    }
    Log.i('unmount', '$who 已卸载 $point，耗时 ${Log.ms(started)}ms');
    await _removeAlias(link);
    return null;
  }

  /// 自定义访问路径靠符号链接指向系统挂载点，避免 /Volumes 下的重名后缀污染路径
  static Future<void> _syncAlias(ShareLink link, String realPoint) async {
    final target = link.mountPoint.trim();
    if (target.isEmpty || target == realPoint) return;
    if (FileSystemEntity.isDirectorySync(target)) return;

    if (FileSystemEntity.isLinkSync(target)) {
      if (Link(target).targetSync() == realPoint) return;
      Link(target).deleteSync();
      Log.i('alias', '访问路径 $target 指向已失效，重建为 $realPoint');
    }
    File(target).parent.createSync(recursive: true);
    Link(target).createSync(realPoint);
    Log.i('alias', '访问路径 $target -> $realPoint');
  }

  static Future<void> _removeAlias(ShareLink link) async {
    final target = link.mountPoint.trim();
    if (target.isEmpty) return;
    if (FileSystemEntity.isLinkSync(target)) {
      Link(target).deleteSync();
    }
  }
}
