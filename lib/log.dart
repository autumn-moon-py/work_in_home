import 'dart:io';

/// 挂载流程的追踪日志：按天分文件，写入失败一律吞掉。
///
/// 这个应用是后台常驻的，出问题时没人盯着终端，所以证据必须落在文件里；
/// 反过来，日志本身不能影响挂载，任何异常都只丢弃这一行。
class Log {
  /// 日志保留天数，过期文件在进程首次写日志时清理
  static const int keepDays = 7;

  static const String _tag = 'win_share';

  static bool _prepared = false;
  static String? _directory;

  static String get directory {
    final cached = _directory;
    if (cached != null) return cached;
    final String base;
    if (Platform.isWindows) {
      base = '${Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'] ??
          Directory.current.path}\\win_share\\logs';
    } else {
      final home = Platform.environment['HOME'] ?? Directory.current.path;
      base = '$home/Library/Logs/win_share';
    }
    return _directory = base;
  }

  static String get filePath =>
      '$directory${Platform.pathSeparator}$_tag-${_dayStamp(DateTime.now())}.log';

  static void i(String tag, String message) => _write('I', tag, message);

  static void w(String tag, String message) => _write('W', tag, message);

  static void e(String tag, String message) => _write('E', tag, message);

  /// 耗时统一按毫秒记录，便于事后看某次挂载到底卡在哪一步
  static int ms(DateTime from) =>
      DateTime.now().difference(from).inMilliseconds;

  static void _write(String level, String tag, String message) {
    final now = DateTime.now();
    try {
      _prepare(now);
      final line = '${now.toIso8601String()} $level [$tag] $message\n';
      File(filePath).writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // 磁盘满、目录无权限等情况下放弃这一行，不向上抛
    }
  }

  static void _prepare(DateTime now) {
    if (_prepared) return;
    _prepared = true;
    try {
      final dir = Directory(directory);
      dir.createSync(recursive: true);
      final deadline = now.subtract(const Duration(days: keepDays));
      for (final entity in dir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.log')) continue;
        if (entity.statSync().modified.isBefore(deadline)) entity.deleteSync();
      }
    } catch (_) {
      // 清理失败不影响本次写入
    }
  }

  static String _dayStamp(DateTime now) => '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}
