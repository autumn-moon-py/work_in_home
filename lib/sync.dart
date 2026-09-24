import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'log.dart';
import 'model.dart';

/// 一次合并的结果
class SyncOutcome {
  const SyncOutcome({this.changed = false, this.removed = const <ShareLink>[]});

  /// 本机共享区数据是否被改写
  final bool changed;

  /// 因对端墓碑而在本机消失、且本机处于访问方的条目：调用方需要把挂载点卸掉
  final List<ShareLink> removed;
}

/// 快照合并。纯函数，不碰磁盘也不碰系统，便于单独推演
class LinkMerge {
  /// 把对端快照 [remote] 合并进本机条目 [local]（就地修改）
  ///
  /// 对齐靠 [ShareLink.syncKey]（两端的 id 各自生成，不可比）；
  /// 新旧靠 [ShareLink.updatedAt]；本机更新则完全不动。
  static SyncOutcome apply({
    required List<ShareLink> local,
    required List<ShareLink> remote,
    required bool Function(ShareDirection direction) localIsSource,
  }) {
    final removed = <ShareLink>[];
    var changed = false;

    for (final ShareLink incoming in remote) {
      final index =
          local.indexWhere((ShareLink e) => e.syncKey == incoming.syncKey);
      if (index < 0) {
        // 对端新增的共享区：本机补一条，本机这一侧的字段留空由用户再填
        if (incoming.deleted) continue;
        final json = incoming.toJson();
        json['id'] = ShareLink.newId();
        local.add(ShareLink.fromJson(json));
        changed = true;
        continue;
      }

      final mine = local[index];
      if (incoming.updatedAt <= mine.updatedAt) continue;

      if (incoming.deleted) {
        if (mine.deleted) continue;
        mine.deleted = true;
        mine.updatedAt = incoming.updatedAt;
        // 本机是访问方时，记录没了挂载点就成了孤儿，得交给调用方卸载
        if (!localIsSource(mine.direction)) removed.add(mine);
        changed = true;
        continue;
      }

      // 对端把已删的条目又重建了，按较新的这一侧复活
      mine.deleted = false;
      _fill(localIsSource: localIsSource, mine: mine, incoming: incoming);
      mine.updatedAt = incoming.updatedAt;
      changed = true;
    }

    return SyncOutcome(changed: changed, removed: removed);
  }

  /// 按角色归属补齐字段：源端保留自己的目录，访问方保留自己的挂载偏好
  static void _fill({
    required bool Function(ShareDirection direction) localIsSource,
    required ShareLink mine,
    required ShareLink incoming,
  }) {
    mine.label = incoming.label;
    if (localIsSource(mine.direction)) {
      // 源端：sourcePath / grantAccount 属于本机，其余取对端
      mine.mountPoint = incoming.mountPoint;
      mine.autoMount = incoming.autoMount;
    } else {
      // 访问方：mountPoint / autoMount / 连接来源属于本机，目录取对端
      mine.sourcePath = incoming.sourcePath;
      mine.grantAccount = incoming.grantAccount;
    }
  }
}

/// 双端共享区数据的同步。
///
/// 两端各起一个同端口 HTTP 服务，用一次 POST 完成双向交换：
/// 发起方把自己的快照发过去，对端合并后把对端快照同包回给发起方。
/// 因此只有"知道对端地址"的那一端需要主动发起，另一端收到即可，无需反向可达。
class LinkSync {
  LinkSync({
    required this.end,
    required this.localIsSource,
    required this.peerHost,
  });

  /// 两端固定同一端口，谁先发起都落到同一个路径
  static const int port = 47824;
  static const Duration _timeout = Duration(seconds: 5);

  /// 本端标识，仅用于日志与协议里区分来源
  final String end;

  /// 本机在该方向是不是源端（决定合并时字段归属）
  final bool Function(ShareDirection direction) localIsSource;

  /// 对端地址；为空表示本机只能被动接收
  final Future<String> Function() peerHost;

  HttpServer? _server;
  DateTime? _lastOk;
  String? _lastError;
  String? _peer;
  List<ShareLink> _pendingRemoval = <ShareLink>[];
  bool _changed = false;
  bool _settled = false;

  /// 界面上的同步状态文案
  String get statusText {
    if (_lastError != null) return '同步失败';
    if (_lastOk != null) return '已同步';
    if ((_peer ?? '').isEmpty) return '同步未配置';
    return '待同步';
  }

  /// 取走"因对端删除而需要在本机卸载"的条目
  List<ShareLink> takeRemoval() {
    final list = _pendingRemoval;
    _pendingRemoval = <ShareLink>[];
    return list;
  }

  /// 取走"本机共享区刚被对端改写"的标记，调用方据此重新探测并自动就绪
  bool takeChanged() {
    final value = _changed;
    _changed = false;
    return value;
  }

  Future<void> start() async {
    if (_server != null) return;
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _server = server;
      Log.i('sync', '同步服务已监听 :$port');
      server.listen(
        (HttpRequest request) => unawaited(_handle(request)),
        onError: (Object error) => Log.w('sync', '同步服务异常：$error'),
      );
    } catch (error) {
      // 端口被占或没权限时不影响挂载本身，本机仍可主动向对端同步
      Log.e('sync', '同步服务无法监听 :$port（$error），本机仍可主动同步');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// 主动发起一次交换（带出本机快照，带回对端快照）
  Future<void> push() async {
    final host = (await peerHost()).trim();
    _peer = host;
    if (host.isEmpty) return;

    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client
          .postUrl(Uri.parse('http://$host:$port/sync'))
          .timeout(_timeout);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(_snapshot()));
      final response = await request.close().timeout(_timeout);
      final body = await utf8.decoder.bind(response).join().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        _markFailed('对端 $host 返回 HTTP ${response.statusCode}');
        return;
      }
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final remote = ((payload['links'] as List<dynamic>?) ?? <dynamic>[])
          .map((dynamic e) => ShareLink.fromJson(e as Map<String, dynamic>))
          .toList();
      final recovering = _lastError != null;
      _merge(remote, via: '对端 $host');
      _lastOk = DateTime.now();
      _lastError = null;
      // 只记首次成功与恢复，否则 15 秒一轮会把日志刷满
      if (!_settled) {
        _settled = true;
        Log.i('sync', '与 $host 完成首次数据交换');
      } else if (recovering) {
        Log.i('sync', '与 $host 的同步已恢复');
      }
    } catch (error) {
      _markFailed('与 $host 同步失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  /// 失败只在状态翻转时记一次，避免对端离线时每 15 秒刷一行
  void _markFailed(String message) {
    if (_lastError == null) Log.w('sync', message);
    _lastError = message;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method != 'POST' || request.uri.path != '/sync') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final remoteEnd = payload['end'] as String? ?? '?';
      final remote = ((payload['links'] as List<dynamic>?) ?? <dynamic>[])
          .map((dynamic e) => ShareLink.fromJson(e as Map<String, dynamic>))
          .toList();
      final from = request.connectionInfo?.remoteAddress.address ?? '';
      _merge(remote, via: '来自 $remoteEnd($from)');
      _lastOk = DateTime.now();
      _lastError = null;

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(_snapshot()));
      await request.response.close();
    } catch (error) {
      Log.e('sync', '处理对端快照失败：$error');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {
        // 连接已断，忽略
      }
    }
  }

  Map<String, dynamic> _snapshot() => <String, dynamic>{
        'end': end,
        'at': DateTime.now().toIso8601String(),
        'links':
            ConfigStore.loadAllLinks().map((ShareLink e) => e.toJson()).toList(),
      };

  void _merge(List<ShareLink> remote, {required String via}) {
    final local = ConfigStore.loadAllLinks();
    final outcome = LinkMerge.apply(
      local: local,
      remote: remote,
      localIsSource: localIsSource,
    );
    if (outcome.changed) {
      _fillConnectionInfo(local);
      ConfigStore.saveAllLinks(local);
      _changed = true;
      Log.i('sync', '$via：本机共享区已更新（对端 ${remote.length} 条）');
    }
    if (outcome.removed.isNotEmpty) {
      _pendingRemoval.addAll(outcome.removed);
      Log.w('sync',
          '$via：对端删除了 ${outcome.removed.length} 条本机在用的共享区，待卸载并同步删除');
    }
  }

  /// 跨端来的条目只有对端那一侧的字段：本机作为访问方时，
  /// 连接信息（地址与账户）要从全局对端配置派生，和改对端设置时的做法保持一致
  void _fillConnectionInfo(List<ShareLink> links) {
    final peer = ConfigStore.loadPeer();
    if (!peer.hasHost) return;
    for (final ShareLink link in links) {
      if (link.deleted || localIsSource(link.direction)) continue;
      if (link.sourceHost.trim().isEmpty) link.sourceHost = peer.host.trim();
      if (link.sourceUser.trim().isEmpty) link.sourceUser = peer.smbUser.trim();
    }
  }
}
