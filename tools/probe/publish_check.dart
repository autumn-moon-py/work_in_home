// 反向共享链路的自检脚本：只跑不涉及管理员授权与密码的那部分真实调用。
// 用法：fvm dart run tools/probe/publish_check.dart
import 'dart:io';

import 'package:win_share/model.dart';
import 'package:win_share/publish_mac.dart';

Future<void> main() async {
  stdout.writeln('macAccount = ${MacPublish.macAccount}');

  final host = await MacPublish.localHostForWindows();
  stdout.writeln('localHostForWindows = ${host.isEmpty ? '(空)' : host}');

  final points = await MacPublish.listSharePoints();
  stdout.writeln('sharePoints = ${points.length}');
  points.forEach((String record, Map<String, dynamic> info) {
    stdout.writeln('  record="$record" smb_name="${info['smb_name']}" '
        'shared=${info['smb_shared']} path=${info['path']}');
  });

  final target = PeerTarget(
    host: '10.174.206.199',
    sshUser: 'Administrator',
    sshKey: '~/.ssh/id_ed25519_windows',
  );

  final free = await MacPublish.detectDriveLetter(target);
  stdout.writeln('detectDriveLetter = ${free ?? '(未探到可用盘符)'}');

  final mapping = await MacPublish.currentMapping(target);
  stdout.writeln('currentMapping = ${mapping ?? '(未映射)'}');

  // --- 容器判定（不需要提权，可本地验证）---
  // 已实测：符号链接在 Windows 侧无法解析，所以共享区必须是容器内的真实目录
  final root = Directory.systemTemp.createTempSync('win_share_probe_root');
  final inside = Directory('${root.path}/sub')..createSync();
  final settings = PublishSettings(
    rootPath: root.path,
    shareName: 'probe_share',
    driveLetter: free ?? 'Z',
  );
  stdout.writeln('container = ${settings.effectiveRootPath}');

  ShareLink linkOf(String sourcePath) => ShareLink(
        id: 'probe',
        direction: ShareDirection.macToWindows,
        shareName: '',
        sourcePath: sourcePath,
      );

  final cases = <String, String>{
    '容器本身上级(容器外)': '/tmp',
    '目录不存在': '${root.path}/not-exists',
    '容器内子目录': inside.path,
    '就是容器本身': root.path,
  };
  cases.forEach((String label, String path) {
    final link = linkOf(path);
    stdout.writeln('$label: state=${MacPublish.folderState(link, settings)} '
        'relativePath="${MacPublish.relativePath(link, settings)}"');
  });

  root.deleteSync(recursive: true);
}
