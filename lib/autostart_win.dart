import 'dart:io';

import 'log.dart';

/// Windows 侧的开机自启动：登录后自动拉起本应用。
///
/// 写的是注册表 Run 键（当前用户 HKCU），原因有两个：
/// 1. HKCU 不需要管理员权限，应用自己就能改，不弹 UAC；
/// 2. 启动文件夹要创建 .lnk，得走 COM，Dart 侧做不了。
///
/// 与 Mac 侧同一套约定：登记状态以系统为唯一真相，不在 shares.json 里另存。
class AutostartWin {
  static const String _key =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _name = 'win_share';

  /// 是否已登记。记录的是旧路径（构建产物换过位置）也算已登记，
  /// 界面只表达开关；重新开启时会把值刷成当前路径。
  ///
  /// 这个方法会被每轮巡检调用（约 15 秒一次），成功路径不写日志。
  static Future<bool> isEnabled() async {
    if (!Platform.isWindows) return false;
    final result = await Process.run(
      'reg',
      <String>['query', _key, '/v', _name],
    );
    return result.exitCode == 0;
  }

  /// 登记/取消登记，返回 null 表示成功，否则是给用户看的错误详情
  static Future<String?> setEnabled(bool value) async {
    if (!Platform.isWindows) return '开机自启动只在 Windows 上有效';
    // 路径带空格时必须加引号，否则 Windows 启动时会把路径截断
    final String exe = '"${Platform.resolvedExecutable}"';
    final result = await Process.run(
      'reg',
      value
          ? <String>['add', _key, '/v', _name, '/t', 'REG_SZ', '/d', exe, '/f']
          : <String>['delete', _key, '/v', _name, '/f'],
    );
    final detail = '${result.stdout}\n${result.stderr}'.trim();
    if (result.exitCode != 0) {
      Log.e('login', '${value ? '登记' : '取消'} Windows 自启失败：$detail');
      return detail.isEmpty ? 'reg 退出码 ${result.exitCode}' : detail;
    }
    Log.i('login', '${value ? '登记' : '取消'} Windows 自启成功：$exe');
    return null;
  }
}
