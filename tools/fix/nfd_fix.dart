// NFD 文件名修复与兜底删除工具。
// 用法：
//   fvm dart run tools/fix/nfd_fix.dart scan      --share 跑团
//   fvm dart run tools/fix/nfd_fix.dart normalize --share 跑团 [--dry-run]
//   fvm dart run tools/fix/nfd_fix.dart delete    --path /Volumes/跑团/...
import 'dart:convert';
import 'dart:io';

import 'package:win_share/model.dart';

import 'share_path.dart';
import 'win_pwsh.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exit(64);
  }
  final String command = args.first;
  final Map<String, String> opts = _parseOptions(args.skip(1).toList());
  final PeerTarget peer = ConfigStore.loadPeer();
  if (!peer.isComplete) {
    stderr.writeln('Windows 连接信息未配置完整（主机 / SSH 用户 / 私钥）');
    exit(1);
  }
  final List<ShareLink> links = ConfigStore.loadLinks()
      .where((ShareLink l) => l.direction == ShareDirection.windowsToMac)
      .toList();

  if (command == 'scan') {
    exit(await _scan(peer, links, opts));
  }
  if (command == 'normalize') {
    exit(await _normalize(peer, links, opts));
  }
  if (command == 'delete') {
    exit(await _delete(peer, links, opts));
  }
  _usage();
  exit(64);
}

/// 取 `--share`；缺失时打印用法提示并返回 null（调用方以 64 结束）
String? _requireShare(Map<String, String> opts) {
  final String? share = opts['share'];
  if (share == null || share.trim().isEmpty) {
    stderr.writeln('缺少 --share（例：--share 跑团）');
    return null;
  }
  return share;
}

/// 按共享名解析 Windows 根；找不到共享或解析失败时打印原因并返回 null
Future<String?> _sharedRoot(
  PeerTarget peer,
  List<ShareLink> links,
  String share,
) async {
  ShareLink? link;
  for (final ShareLink l in links) {
    if (l.shareName.trim() == share.trim()) {
      link = l;
      break;
    }
  }
  if (link == null) {
    stderr.writeln('未找到 windowsToMac 共享：$share');
    return null;
  }
  final String? root = await SharePath.resolveWindowsRoot(peer, link);
  if (root == null) {
    stderr.writeln('无法解析共享根（Get-SmbShare 查询失败）');
  }
  return root;
}

Future<int> _scan(
  PeerTarget peer,
  List<ShareLink> links,
  Map<String, String> opts,
) async {
  final String? share = _requireShare(opts);
  if (share == null) return 64;
  final String? root = await _sharedRoot(peer, links, share);
  if (root == null) return 1;
  stdout.writeln('共享根：$root');
  final ({int code, String out, String err}) result =
      await WinPwsh.run(peer, _scanScript(root));
  if (result.code != 0) {
    stderr.writeln(result.err.trim());
    return result.code;
  }
  final List<String> items = _parseTagged(result.out, 'NFD');
  stdout.writeln('NFD 条目：${items.length}');
  for (final String p in items) {
    stdout.writeln('  $p');
  }
  return 0;
}

Future<int> _normalize(
  PeerTarget peer,
  List<ShareLink> links,
  Map<String, String> opts,
) async {
  // dry-run 只出清单，行为与 scan 一致
  if (opts.containsKey('dry-run')) return _scan(peer, links, opts);
  final String? share = _requireShare(opts);
  if (share == null) return 64;
  final String? root = await _sharedRoot(peer, links, share);
  if (root == null) return 1;
  stdout.writeln('共享根：$root');

  // 破坏性操作前先出清单
  final ({int code, String out, String err}) preview =
      await WinPwsh.run(peer, _scanScript(root));
  if (preview.code != 0) {
    stderr.writeln(preview.err.trim());
    return preview.code;
  }
  final List<String> planned = _parseTagged(preview.out, 'NFD');
  stdout.writeln('待归一化条目：${planned.length}');
  for (final String p in planned) {
    stdout.writeln('  $p');
  }
  if (planned.isEmpty) {
    stdout.writeln('完成：没有需要归一化的条目');
    return 0;
  }

  final ({int code, String out, String err}) result =
      await WinPwsh.run(peer, _normalizeScript(root));
  if (result.code != 0) {
    stderr.writeln(result.err.trim());
    return result.code;
  }
  for (final String p in _parseTagged(result.out, 'RENAMED')) {
    stdout.writeln('RENAMED  $p');
  }
  for (final String p in _parseTagged(result.out, 'FAILED')) {
    stdout.writeln('FAILED  $p');
  }
  for (final String p in _parseTagged(result.out, 'SKIP')) {
    stdout.writeln('SKIP 撞名  $p');
  }
  final String summary = _lastTagged(result.out, 'SUMMARY');
  stdout.writeln(summary.isEmpty ? '完成' : '完成：$summary');
  final String remoteErr = result.err.trim();
  if (remoteErr.isNotEmpty) stderr.writeln(remoteErr);
  // 有失败时用非零退出码，便于自动化判断
  return _parseTagged(result.out, 'FAILED').isEmpty ? 0 : 3;
}

Future<int> _delete(
  PeerTarget peer,
  List<ShareLink> links,
  Map<String, String> opts,
) async {
  final String? macPath = opts['path'];
  if (macPath == null || macPath.trim().isEmpty) {
    stderr.writeln('缺少 --path（例：--path /Volumes/跑团/某目录）');
    return 64;
  }
  final ({ShareLink link, String base})? owner =
      SharePath.findOwner(links, macPath);
  if (owner == null) {
    stderr.writeln('路径不在任何已挂载的 windowsToMac 共享区内：$macPath');
    return 1;
  }
  final String? root = await SharePath.resolveWindowsRoot(peer, owner.link);
  if (root == null) {
    stderr.writeln('无法解析共享根（Get-SmbShare 查询失败）');
    return 1;
  }
  final SharePath sp =
      SharePath(base: owner.base, windowsRoot: root);
  final String? winPath = sp.windowsPathOf(macPath);
  if (winPath == null) {
    stderr.writeln('拒绝执行：目标为空、越界，或就是共享根');
    return 1;
  }
  stdout.writeln('将删除：$winPath');
  final ({int code, String out, String err}) result =
      await WinPwsh.run(peer, _deleteScript(winPath));
  stdout.write(result.out);
  if (result.code != 0) {
    stderr.writeln(result.err.trim());
  }
  return result.code;
}

String _scanScript(String root) => '''
\$ErrorActionPreference='Continue'
\$root=${_psQuote(root)}
\$plan = @(Get-ChildItem -LiteralPath \$root -Recurse -Force -ErrorAction SilentlyContinue |
  Where-Object { -not [string]::Equals(\$_.Name, \$_.Name.Normalize([Text.NormalizationForm]::FormC), [System.StringComparison]::Ordinal) })
\$plan | ForEach-Object { 'NFD|' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(\$_.FullName)) }
'SUMMARY|' + \$plan.Count
''';

String _normalizeScript(String root) => '''
\$ErrorActionPreference='Continue'
\$root=${_psQuote(root)}
\$plan = @(Get-ChildItem -LiteralPath \$root -Recurse -Force -ErrorAction SilentlyContinue |
  Where-Object { -not [string]::Equals(\$_.Name, \$_.Name.Normalize([Text.NormalizationForm]::FormC), [System.StringComparison]::Ordinal) } |
  Sort-Object { \$_.FullName.Length } -Descending)
\$renamed=0; \$failed=0; \$skipped=0
foreach (\$item in \$plan) {
  \$new = \$item.Name.Normalize([Text.NormalizationForm]::FormC)
  \$dest = Join-Path \$item.DirectoryName \$new
  if (Test-Path -LiteralPath \$dest) {
    \$skipped++
    'SKIP|' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(\$item.FullName))
  } else {
    try {
      Rename-Item -LiteralPath \$item.FullName -NewName \$new -ErrorAction Stop
      \$renamed++
      'RENAMED|' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(\$item.FullName + ' -> ' + \$dest))
    } catch {
      \$failed++
      'FAILED|' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(\$item.FullName + ' :: ' + \$_.Exception.Message))
    }
  }
}
"SUMMARY|重命名 \$renamed，失败 \$failed，跳过 \$skipped"
''';

String _deleteScript(String winPath) {
  final String b64 = base64Encode(utf8.encode(winPath));
  return '''
\$ErrorActionPreference='Stop'
\$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64'))
if (-not (Test-Path -LiteralPath \$p)) { 'RESULT|MISSING'; exit 0 }
Remove-Item -LiteralPath \$p -Recurse -Force
'RESULT|DELETED'
''';
}

/// 拼进 PowerShell 的单引号字符串，内部单引号翻倍
String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

/// 解析形如 `TAG|base64` 的行
List<String> _parseTagged(String out, String tag) {
  final List<String> list = <String>[];
  for (final String line in const LineSplitter().convert(out)) {
    final String t = line.trim();
    if (!t.startsWith('$tag|')) continue;
    try {
      list.add(utf8.decode(base64Decode(t.substring(tag.length + 1))));
    } catch (_) {
      // 非法行忽略
    }
  }
  return list;
}

/// 取形如 `TAG|文本` 中最后一条的文本（原文，不解 base64）
String _lastTagged(String out, String tag) {
  String value = '';
  for (final String line in const LineSplitter().convert(out)) {
    final String t = line.trim();
    if (t.startsWith('$tag|')) value = t.substring(tag.length + 1);
  }
  return value;
}

/// 解析 `--key value` 与 `--flag`；无取值的选项记为空串
Map<String, String> _parseOptions(List<String> args) {
  final Map<String, String> opts = <String, String>{};
  for (int i = 0; i < args.length; i++) {
    final String a = args[i];
    if (!a.startsWith('--')) continue;
    final String key = a.substring(2);
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      opts[key] = args[++i];
    } else {
      opts[key] = '';
    }
  }
  return opts;
}

void _usage() {
  stdout.writeln('用法：');
  stdout.writeln('  nfd_fix.dart scan      --share <共享名>');
  stdout.writeln('  nfd_fix.dart normalize --share <共享名> [--dry-run]');
  stdout.writeln('  nfd_fix.dart delete    --path <Mac 路径>');
}
