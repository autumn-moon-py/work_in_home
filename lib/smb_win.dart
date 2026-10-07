import 'dart:convert';
import 'dart:io';

/// Windows 侧的 SMB 管理。
///
/// 建共享、改权限这类系统级动作走 UAC 提权，应用本身不必以管理员身份运行；
/// 映射盘符则是当前登录会话的行为，直接在本机执行即可。
///
/// Mac 只发布一个容器共享，因此映射是全局的：一个盘符对应整个容器，
/// 各共享区以子文件夹形式出现在该盘符下。
class WinSmb {
  /// PowerShell 的 -EncodedCommand 需要 UTF-16LE 的 base64，可彻底避开引号转义问题
  static String _encode(String script) {
    final bytes = <int>[];
    for (final int unit in script.codeUnits) {
      bytes.add(unit & 0xFF);
      bytes.add((unit >> 8) & 0xFF);
    }
    return base64Encode(bytes);
  }

  /// 在本机当前会话执行 PowerShell，可选把一行文本（密码）从 stdin 送进脚本。
  /// 脚本开头先切到 UTF-8 输出，否则中文路径会按系统 ANSI 编码输出而乱码。
  ///
  /// 用 pwsh 7 且不带 -ExecutionPolicy：后者与 -EncodedCommand 同时出现会被本机
  /// 安全策略整条杀掉（无输出、退出码 -1），Windows PowerShell 5.1 同样中招。
  static Future<({int code, String out, String err})> _runLocal(
    String script, {
    String? stdinLine,
  }) async {
    final process = await Process.start('pwsh', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      _encode('[Console]::OutputEncoding=[Text.Encoding]::UTF8\n$script'),
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

  static String _failureOf(({int code, String out, String err}) result) {
    final detail = '${result.err}\n${result.out}'.trim();
    return detail.isEmpty ? '执行失败（退出码 ${result.code}）' : detail;
  }

  /// 提权执行脚本片段；成功返回 null，失败返回错误原因
  static Future<String?> _runElevated(String body) async {
    final dir = Directory.systemTemp.createTempSync('win_share');
    try {
      final out = File('${dir.path}\\result.txt');
      final inner = "\$ErrorActionPreference = 'Stop'\n"
          'try {\n'
          '$body\n'
          "  'OK' | Out-File -Encoding utf8 -FilePath '${out.path}'\n"
          '} catch {\n'
          "  ('ERR ' + \$_.Exception.Message) | Out-File -Encoding utf8 -FilePath '${out.path}'\n"
          '}\n';

      final launch = 'Start-Process pwsh -Verb RunAs -Wait -WindowStyle Hidden '
          "-ArgumentList '-NoProfile','-NonInteractive','-EncodedCommand','${_encode(inner)}'";
      final result = await _runLocal(launch);
      if (result.code != 0) {
        return '提权调用失败：${result.err.trim()}';
      }
      if (!out.existsSync()) {
        return '没有拿到执行结果，通常是 UAC 授权被取消';
      }
      final text = out.readAsStringSync().replaceAll('\uFEFF', '').trim();
      return text == 'OK' ? null : text;
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录清理失败不影响主流程
      }
    }
  }

  /// 返回共享已存在时的本地路径，不存在返回 null
  static Future<String?> sharePath(String shareName) async {
    if (shareName.trim().isEmpty) return null;
    final safe = shareName.trim().replaceAll("'", "''");
    final result = await _runLocal(
      "(Get-SmbShare -Name '$safe' -ErrorAction SilentlyContinue).Path",
    );
    final text = result.out.replaceAll('\uFEFF', '').trim();
    return text.isEmpty ? null : text;
  }

  /// 创建共享：同时授予共享级权限与 NTFS 权限。
  /// 只给共享权限是不够的——被共享目录若在用户目录下，NTFS 会拦住其他账户。
  static Future<String?> createShare({
    required String shareName,
    required String localPath,
    required String grantAccount,
  }) {
    final path = localPath.trim().replaceAll("'", "''");
    final name = shareName.trim().replaceAll("'", "''");
    final account = grantAccount.trim();
    if (path.isEmpty || name.isEmpty || account.isEmpty) {
      return Future<String?>.value('本地目录、共享名、授权账户都不能为空');
    }
    final safeAccount = account.replaceAll("'", "''");
    return _runElevated(
      "if (-not (Test-Path -LiteralPath '$path')) { throw '目录不存在：$path' }\n"
      "New-SmbShare -Name '$name' -Path '$path' -FullAccess '$safeAccount'\n"
      "icacls '$path' /grant '$safeAccount:(OI)(CI)M' | Out-Null",
    );
  }

  static Future<String?> removeShare(String shareName) {
    final name = shareName.trim().replaceAll("'", "''");
    if (name.isEmpty) return Future<String?>.value('共享名为空');
    return _runElevated("Remove-SmbShare -Name '$name' -Force");
  }

  /// 本机一个可用盘符：从 Z 往下找第一个没被占用的，跳过 C。
  /// 探测失败（比如 PowerShell 被策略拦住）返回 null
  static Future<String?> detectDriveLetter() async {
    final result = await _runLocal(
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

  /// 把 Mac 的容器共享映射成本机一个盘符，成功返回 null。
  ///
  /// [password] 为空时直接连接，走 Windows 凭据管理器里已登记过的凭据；
  /// 传了密码则先经 cmdkey 登记再连接。密码由 stdin 交给脚本，不进入命令行。
  static Future<String?> mapContainer({
    required String host,
    required String user,
    required String shareName,
    required String driveLetter,
    String? password,
  }) async {
    final target = host.trim();
    final share = shareName.trim();
    final account = user.trim();
    final drive = driveLetter.trim().toUpperCase();
    if (target.isEmpty || share.isEmpty || drive.isEmpty) {
      return 'Mac 地址、共享名、盘符都不能为空';
    }
    if (account.isEmpty) return '请先填写 Mac 上的账户名';
    // UNC 路径在 Dart 侧拼好，脚本里用单引号包住，省掉多层反斜杠转义
    final unc = '\\\\$target\\$share';
    final credential = password == null
        ? ''
        : '\$pw = [Console]::In.ReadLine()\n'
            '& cmdkey "/add:$target" "/user:$account" "/pass:\$pw" | Out-Null\n';
    final String script = '''
\$ErrorActionPreference = 'Stop'
${credential}net use $drive: '$unc' /persistent:yes 2>&1 | Out-Null
if (\$LASTEXITCODE -ne 0) { throw "net use 失败，退出码 \$LASTEXITCODE" }
(Get-SmbMapping -LocalPath '$drive:').RemotePath
''';
    // 不带密码时也给一行空输入，避免 net use 的交互式提问把流程挂住
    final result = await _runLocal(script, stdinLine: password ?? '');
    return result.code == 0 ? null : _failureOf(result);
  }

  /// 本机是否真的能在盘符下看到某个文件夹。
  /// 文件夹名经 stdin 传入，避开命令行引号问题
  static Future<bool> folderVisible(String driveLetter, String folderName) async {
    final drive = driveLetter.trim().toUpperCase();
    final folder = folderName.trim();
    if (drive.isEmpty || folder.isEmpty) return false;
    final String script = '''
\$f = [Console]::In.ReadLine()
Test-Path -LiteralPath ('$drive:\\' + \$f)
''';
    final result = await _runLocal(script, stdinLine: folder);
    return result.out.replaceAll('\uFEFF', '').trim().toLowerCase() == 'true';
  }

  /// 断开盘符映射；映射本就不存在时也视为成功
  static Future<String?> unmapDrive(String driveLetter) async {
    final drive = driveLetter.trim().toUpperCase();
    if (drive.isEmpty) return '盘符为空';
    // net use /delete 失败不会改退出码，删完再查一次，避免把失败报成成功
    final result = await _runLocal(
      "net use $drive: /delete /y 2>&1 | Out-Null\n"
      "if (Get-SmbMapping -LocalPath '$drive:' -ErrorAction SilentlyContinue) "
      "{ throw '盘符 $drive: 仍处于映射状态，可能被其他程序占用' }\n"
      "'OK'",
    );
    return result.code == 0 ? null : _failureOf(result);
  }

  /// 盘符当前映射到的远端路径；未映射返回 null
  static Future<String?> mappingTarget(String driveLetter) async {
    final drive = driveLetter.trim().toUpperCase();
    if (drive.isEmpty) return null;
    final result = await _runLocal(
      "(Get-SmbMapping -LocalPath '$drive:' -ErrorAction SilentlyContinue).RemotePath",
    );
    final text = result.out.replaceAll('\uFEFF', '').trim();
    return text.isEmpty ? null : text;
  }

  /// 用系统原生目录选择框，省掉一个文件选择依赖
  static Future<String?> pickFolder() async {
    const String script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = '选择要共享的目录'
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  Write-Output $dialog.SelectedPath
}
''';
    final result = await _runLocal(script);
    final path = result.out.replaceAll('\uFEFF', '').trim();
    return path.isEmpty ? null : path;
  }

  /// 本机所有可用 IPv4 地址（不含回环），供 Mac 端填写
  static Future<List<String>> localAddresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final list = <String>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!list.contains(address.address)) list.add(address.address);
      }
    }
    return list;
  }
}
