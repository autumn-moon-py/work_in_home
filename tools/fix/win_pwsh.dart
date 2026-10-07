// 通过 SSH 在 Windows 上执行 pwsh 脚本。
// 整段脚本按 UTF-16LE base64 经 -EncodedCommand 传入，避免中文与多行块在传输中损坏。
import 'dart:convert';
import 'dart:io';

import 'package:win_share/model.dart';

class WinPwsh {
  static const String _ssh = '/usr/bin/ssh';

  /// 执行脚本，返回退出码与 stdout / stderr。
  /// 会在脚本开头统一切到 UTF-8 输出，避免远端中文结果变成非 UTF-8 字节。
  static Future<({int code, String out, String err})> run(
    PeerTarget target,
    String script,
  ) async {
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
      _encodeUtf16Base64(
        '[Console]::OutputEncoding=[Text.Encoding]::UTF8\n$script',
      ),
    ]);
    await process.stdin.close();
    // 远端偶发非法字节时不要让解码打断流程
    const decoder = Utf8Decoder(allowMalformed: true);
    final outFuture = process.stdout.transform(decoder).join();
    final errFuture = process.stderr.transform(decoder).join();
    final code = await process.exitCode;
    return (code: code, out: await outFuture, err: await errFuture);
  }

  /// pwsh 的 -EncodedCommand 要求 UTF-16LE 的 base64
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
}
