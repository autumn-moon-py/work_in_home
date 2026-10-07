import 'dart:convert';
import 'dart:io';

import 'model.dart';

/// Mac 侧对外共享的编排层。
///
/// 一个盘符只能映射一个共享根，所以只发布一个容器目录：
/// 每个共享区以子文件夹（必要时是符号链接）出现在这个容器里，
/// Windows 侧用一个盘符访问整个容器。
///
/// 注册共享点统一走系统授权框提权，应用不保存管理员密码；
/// 驱动 Windows 侧则通过 SSH，密码经 stdin 传递。
class MacPublish {
  static const String _sharing = '/usr/sbin/sharing';
  static const String _osascript = '/usr/bin/osascript';
  static const String _security = '/usr/bin/security';
  static const String _ssh = '/usr/bin/ssh';
  static const String _keychainService = 'win_share.smb';

  /// 已注册的共享点：记录名 -> 配置信息
  static Future<Map<String, Map<String, dynamic>>> listSharePoints() async {
    final result = await Process.run(_sharing, <String>['-l', '-f', 'json']);
    if (result.exitCode != 0) return <String, Map<String, dynamic>>{};
    try {
      final data = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      return data.map(
        (String key, dynamic value) =>
            MapEntry<String, Map<String, dynamic>>(key, value as Map<String, dynamic>),
      );
    } catch (_) {
      return <String, Map<String, dynamic>>{};
    }
  }

  /// 注册共享点（容器目录），成功返回 null。会弹出系统授权框要求输入管理员密码
  static Future<String?> publishRoot(PublishSettings settings) async {
    final root = settings.effectiveRootPath;
    final name = settings.shareName.trim();
    if (name.isEmpty) return '共享名不能为空';
    if (!Directory(root).existsSync()) {
      try {
        Directory(root).createSync(recursive: true);
      } catch (error) {
        return '无法创建容器目录 $root：$error';
      }
    }
    // 同名共享点可能已经存在（比如换了容器目录），先移除再创建，避免残留旧路径。
    // 两条命令放在同一次提权调用里，只弹一次授权框
    // -s 001 只启用 SMB（afp/ftp 已废弃），-g 000 关闭来宾访问
    final String command = '$_sharing -r ${_quote(name)} >/dev/null 2>&1; '
        '$_sharing -a ${_quote(root)} -n ${_quote(name)} '
        '-S ${_quote(name)} -s 001 -g 000';
    return _withAdmin(command);
  }

  static Future<String?> unpublishRoot(PublishSettings settings) async {
    final name = settings.shareName.trim();
    if (name.isEmpty) return '共享名为空';
    return _withAdmin('$_sharing -r ${_quote(name)}');
  }

  /// 共享区在容器里的状态：
  /// ready = 目录在容器内、Windows 侧可见；outside = 目录存在但在容器外；missing = 目录不存在
  ///
  /// 已实测：macOS 的 SMB 服务会把符号链接原样交给 Windows（reparse point + 服务端绝对路径），
  /// Windows 无法解析，所以共享区必须是容器内的真实目录，不能用链接挂入。
  static String folderState(ShareLink link, PublishSettings settings) {
    final source = link.sourcePath.trim();
    if (source.isEmpty) return 'missing';
    if (!Directory(source).existsSync()) return 'missing';
    return _sameOrInside(settings.effectiveRootPath, source) ? 'ready' : 'outside';
  }

  /// 共享区相对容器的路径，也就是 Windows 侧盘符后面的那一段
  static String relativePath(ShareLink link, PublishSettings settings) {
    final root = settings.effectiveRootPath;
    final source = link.sourcePath.trim();
    if (!_sameOrInside(root, source)) return '';
    final normalized = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    if (source == normalized) return '';
    return source.substring(normalized.length + 1);
  }

  /// 用系统原生目录选择框，省掉一个文件选择依赖
  static Future<String?> pickFolder({String prompt = '选择目录'}) async {
    final script = 'POSIX path of (choose folder with prompt ${_appleScriptString(prompt)})';
    final result = await Process.run(_osascript, <String>['-e', script]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    if (path.isEmpty) return null;
    return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }

  /// 通过系统授权框以 root 执行一段 shell 命令
  static Future<String?> _withAdmin(String shellCommand) async {
    final script =
        'do shell script ${_appleScriptString(shellCommand)} with administrator privileges';
    final result = await Process.run(_osascript, <String>['-e', script]);
    if (result.exitCode == 0) return null;
    final message = (result.stderr as String).trim();
    return message.isEmpty ? '执行失败（可能是授权被取消）' : message;
  }

  /// 拼成 AppleScript 字符串字面量：反斜杠与双引号都要转义
  static String _appleScriptString(String value) =>
      '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  /// shell 单引号包裹，内部单引号按 POSIX 规则转义
  static String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  /// 当前登录的 macOS 账户名，Windows 侧认证用的就是它
  static String get macAccount => Platform.environment['USER'] ?? '';

  static Future<String?> readStoredPassword() async {
    final result = await Process.run(_security, <String>[
      'find-generic-password',
      '-a',
      macAccount,
      '-s',
      _keychainService,
      '-w',
    ]);
    if (result.exitCode != 0) return null;
    final value = (result.stdout as String).trim();
    return value.isEmpty ? null : value;
  }

  static Future<String?> storePassword(String password) async {
    final result = await Process.run(_security, <String>[
      'add-generic-password',
      '-a',
      macAccount,
      '-s',
      _keychainService,
      '-w',
      password,
      '-U',
    ]);
    if (result.exitCode == 0) return null;
    return (result.stderr as String).trim();
  }

  /// Windows 该连 Mac 的哪个地址：ZeroTier 在 macOS 上是 feth* 虚拟网卡，优先取它
  static Future<String> localHostForWindows() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      if (interface.name.startsWith('feth') && interface.addresses.isNotEmpty) {
        return interface.addresses.first.address;
      }
    }
    for (final interface in interfaces) {
      if (interface.addresses.isNotEmpty) return interface.addresses.first.address;
    }
    return '';
  }

  /// 在 Windows 上探测一个可用盘符。从 Z 往下找，跳过已占用的
  static Future<String?> detectDriveLetter(PeerTarget target) async {
    final result = await _runOnWindows(
      target,
      "(Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name) -join ','",
    );
    if (result.code != 0) return null;
    final used = result.out
        .trim()
        .split(',')
        .map((String e) => e.trim().toUpperCase())
        .where((String e) => e.isNotEmpty)
        .toSet();
    for (int code = 90; code >= 72; code--) {
      final letter = String.fromCharCode(code);
      if (letter == 'C') continue;
      if (!used.contains(letter)) return letter;
    }
    return null;
  }

  /// 把容器共享映射成 Windows 上的盘符。密码经 stdin 传入
  static Future<String?> mapOnWindows({
    required PublishSettings settings,
    required PeerTarget target,
    required String password,
  }) async {
    // 注意：这里要访问的是 Mac 自己，不能用 SSH 目标地址 target.host
    final host = await localHostForWindows();
    if (host.isEmpty) return '没能确定本机在虚拟网络里的地址';
    final share = settings.shareName.trim();
    final drive = settings.driveLetter.trim().toUpperCase();
    if (drive.isEmpty) return '盘符未确定';
    // 注意两件事：
    // 1. 不要用 cmdkey：SSH 属于非交互登录会话，cmdkey 会拒绝保存凭据。
    // 2. 脚本里的中文提示不要出现全角括号。PowerShell 的分词器会在表达式上下文
    //    把全角括号当成真括号，导致解析失败（错报 MissingEndParenthesis）。
    final String script = '''
\$ErrorActionPreference = 'Continue'
\$pw = [Console]::In.ReadLine()
\$out = (net use $drive: "\\\\$host\\$share" "/user:$macAccount" \$pw /persistent:yes 2>&1 | Out-String).Trim()
if (\$LASTEXITCODE -ne 0) {
  \$msg = "net use 失败，退出码 \$LASTEXITCODE。"
  \$msg += " 如果提示密码不正确或拒绝访问，通常是 macOS 还没有允许账户 $macAccount 通过 SMB 登录，"
  \$msg += "请在 系统设置 - 通用 - 共享 - 文件共享 - 选项 中勾选该账户。"
  \$msg += " 原始信息：" + \$out
  throw \$msg
}
'OK'
''';
    final result = await _runOnWindows(target, script, stdinLine: password);
    if (result.code != 0) return _failureOf(result);
    return null;
  }

  static Future<String?> unmapOnWindows({
    required PublishSettings settings,
    required PeerTarget target,
  }) async {
    final drive = settings.driveLetter.trim().toUpperCase();
    if (drive.isEmpty) return '盘符未确定';
    final String script = '''
net use $drive: /delete /y 2>&1 | Out-Null
if (Get-SmbMapping -LocalPath '$drive:' -ErrorAction SilentlyContinue) {
  throw '盘符 $drive: 仍然处于映射状态'
}
'OK'
''';
    final result = await _runOnWindows(target, script);
    if (result.code != 0) return _failureOf(result);
    return null;
  }

  /// Windows 上已登记的持久盘符映射（登录时恢复），形如 "Z:=\\\\host\\share"；没有则返回 null
  ///
  /// 不能用 Get-SmbMapping 查询：SSH 是独立的登录会话，看不到别的会话里建的盘符。
  static Future<String?> currentMapping(PeerTarget target) async {
    final result = await _runOnWindows(
      target,
      r"(Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue | ForEach-Object "
      r"{ $_.PSChildName + '=' + (Get-ItemProperty $_.PSPath).RemotePath }) -join ';'",
    );
    if (result.code != 0) return null;
    final value = result.out.trim();
    return value.isEmpty ? null : value;
  }

  /// 从 Windows 侧验证共享区是否真的能读到。
  ///
  /// 同样不能用盘符：SSH 会话里没有映射盘符。这里用「无盘符连接 + 直连 UNC」，
  /// 既验证凭据，也验证目录可见性。目录名与密码一起经 stdin 传入。
  static Future<String?> checkFolderOnWindows({
    required PublishSettings settings,
    required PeerTarget target,
    required String folderName,
    required String password,
  }) async {
    // 同样要连 Mac 自己，而不是 SSH 目标地址
    final host = await localHostForWindows();
    if (host.isEmpty) return null;
    final share = settings.shareName.trim();
    final String script = '''
\$f = [Console]::In.ReadLine()
\$pw = [Console]::In.ReadLine()
net use "\\\\$host\\$share" "/user:$macAccount" \$pw 2>&1 | Out-Null
if (\$LASTEXITCODE -ne 0) { 'UNREACHABLE' }
else {
  if (Test-Path -LiteralPath ("\\\\$host\\$share\\" + \$f)) { 'OK' } else { 'MISSING' }
  net use "\\\\$host\\$share" /delete /y 2>&1 | Out-Null
}
''';
    final result = await _runOnWindows(
      target,
      script,
      stdinLine: '$folderName\n$password',
    );
    if (result.code != 0) return null;
    final value = result.out;
    if (value.contains('OK')) return 'ok';
    if (value.contains('MISSING')) return 'missing';
    if (value.contains('UNREACHABLE')) return 'unreachable';
    return null;
  }

  static String _failureOf(({int code, String out, String err}) result) {
    final detail = _readable('${result.err}\n${result.out}'.trim());
    return detail.isEmpty ? '在 Windows 上执行失败（退出码 ${result.code}）' : detail;
  }

  /// Windows 上的 PowerShell 在非交互环境会把错误序列化成 CLIXML，
  /// 这里把它还原成可读文本，否则用户只能看到一堆转义乱码
  static String _readable(String raw) {
    if (!raw.contains('#< CLIXML')) return raw;
    final matches = RegExp(r'<S S="Error">(.*?)</S>', dotAll: true).allMatches(raw);
    if (matches.isEmpty) return raw;
    final buffer = StringBuffer();
    for (final match in matches) {
      buffer.writeln(
        (match.group(1) ?? '')
            .replaceAll('_x000D_', '')
            .replaceAll('_x000A_', '\n')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&apos;', "'")
            .replaceAll('&amp;', '&'),
      );
    }
    return buffer.toString().trim();
  }

  /// 把一段 PowerShell 脚本编码后交给 Windows 执行。
  /// 用 -EncodedCommand 传递，绕开 ssh→cmd→powershell 三层的引号转义问题。
  ///
  /// 两个必须遵守的点（都是实测踩出来的，改回去必炸）：
  /// 1. 用 pwsh 7，不用 Windows PowerShell 5.1：后者作为 ssh 的直接子进程执行
  ///    -EncodedCommand 时会被静默杀掉（无输出、ssh 返回 255）。
  /// 2. 绝不能带 -ExecutionPolicy Bypass：它与 -EncodedCommand 同时出现时会被
  ///    本机安全策略整条杀掉，两个解释器都一样。
  static Future<({int code, String out, String err})> _runOnWindows(
    PeerTarget target,
    String script, {
    String? stdinLine,
  }) async {
    if (!target.isComplete) {
      return (code: -1, out: '', err: 'Windows 侧连接信息未配置完整（主机 / SSH 用户 / 私钥）');
    }
    // 远端默认按系统 ANSI 编码输出，中文会变成非 UTF-8 字节，开头先把它切成 UTF-8
    final encoded = _encodeUtf16Base64(
      '[Console]::OutputEncoding=[Text.Encoding]::UTF8\n$script',
    );
    final process = await Process.start(_ssh, <String>[
      '-i',
      _expandHome(target.sshKey.trim()),
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=12',
      '-o',
      'StrictHostKeyChecking=accept-new',
      '${target.sshUser.trim()}@${target.host.trim()}',
      'pwsh',
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      encoded,
    ]);
    if (stdinLine != null) process.stdin.write('$stdinLine\n');
    await process.stdin.close();
    // 兜底：即使仍有非法字节，也不要让解码把整个流程打断
    const decoder = Utf8Decoder(allowMalformed: true);
    final outFuture = process.stdout.transform(decoder).join();
    final errFuture = process.stderr.transform(decoder).join();
    final code = await process.exitCode;
    return (code: code, out: await outFuture, err: await errFuture);
  }

  /// PowerShell 的 -EncodedCommand 要求 UTF-16LE 的 base64
  static String _encodeUtf16Base64(String script) {
    final bytes = <int>[];
    for (final int unit in script.codeUnits) {
      bytes.add(unit & 0xFF);
      bytes.add((unit >> 8) & 0xFF);
    }
    return base64Encode(bytes);
  }

  static String _expandHome(String path) {
    if (!path.startsWith('~')) return path;
    return '${Platform.environment['HOME'] ?? ''}${path.substring(1)}';
  }

  /// path 是否就是 base，或位于 base 之内
  static bool _sameOrInside(String base, String path) {
    final normalizedBase = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return path == normalizedBase || path.startsWith('$normalizedBase/');
  }
}
