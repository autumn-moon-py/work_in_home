// 局域网广播探针（Mac 侧）
//
// 目的：验证 ZeroTier 虚拟网内 UDP 广播能否双向到达。
// 用法：
//   fvm dart run tools/probe/mac_probe.dart --seconds 60
//   fvm dart run tools/probe/mac_probe.dart --to 10.174.206.199 --seconds 30
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int kDefaultPort = 47823;
const String kMagic = 'work_in_home-probe-v1';

Future<void> main(List<String> args) async {
  final port = _intArg(args, '--port') ?? kDefaultPort;
  final seconds = _intArg(args, '--seconds') ?? 60;
  final extraTargets = _listArg(args, '--to');

  final socket = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4,
    port,
    reuseAddress: true,
  );
  socket.broadcastEnabled = true;

  // dart:io 不暴露子网掩码，这里按 /24 推导广播地址；接口列表需与 ifconfig 结果交叉核对
  final targets = <String>{'255.255.255.255'};
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  stdout.writeln('[IFACES]');
  for (final itf in interfaces) {
    for (final addr in itf.addresses) {
      stdout.writeln('  ${itf.name.padRight(10)} ${addr.address}');
      targets.add(_broadcastOf24(addr.address));
    }
  }
  targets.addAll(extraTargets);
  stdout.writeln('[TARGETS] ${targets.join(', ')}');

  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    stdout.writeln(
      '[RECV] ${DateTime.now().toIso8601String()} '
      'from=${datagram.address.address}:${datagram.port} '
      '${utf8.decode(datagram.data, allowMalformed: true)}',
    );
  });

  final payload = utf8.encode(jsonEncode({
    'magic': kMagic,
    'host': Platform.localHostname,
    'os': Platform.operatingSystem,
    'ts': DateTime.now().toIso8601String(),
  }));

  final timer = Timer.periodic(const Duration(seconds: 2), (_) {
    for (final target in targets) {
      socket.send(payload, InternetAddress(target), port);
    }
    stdout.writeln('[SEND] ${DateTime.now().toIso8601String()}');
  });

  stdout.writeln('[LISTEN] port=$port seconds=$seconds');
  await Future<void>.delayed(Duration(seconds: seconds));
  timer.cancel();
  socket.close();
  stdout.writeln('[DONE]');
}

String _broadcastOf24(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return ip;
  return '${parts[0]}.${parts[1]}.${parts[2]}.255';
}

int? _intArg(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return int.tryParse(args[index + 1]);
}

List<String> _listArg(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return const [];
  return args[index + 1].split(',').where((e) => e.isNotEmpty).toList();
}
