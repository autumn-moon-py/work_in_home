import 'dart:io';

import 'package:flutter/services.dart';

import 'log.dart';

/// 登录项在系统里的真实状态。勾选以它为准，不在本地配置里另存一份，
/// 否则用户在「系统设置 > 通用 > 登录项」里手动关掉后两边会对不上。
enum LoginItemStatus {
  /// 已注册且已启用
  enabled,

  /// 未注册
  notRegistered,

  /// 系统里还有记录，但已被用户在系统设置里关掉，需要重新允许
  requiresApproval,

  /// 系统找不到对应项，多为 bundle 被移动或删除
  notFound,

  /// macOS 13 以下没有 SMAppService
  unsupported;

  bool get isOn => this == LoginItemStatus.enabled;

  String get label => switch (this) {
        LoginItemStatus.enabled => '已开启',
        LoginItemStatus.notRegistered => '未开启',
        LoginItemStatus.requiresApproval => '待批准',
        LoginItemStatus.notFound => '系统未找到',
        LoginItemStatus.unsupported => '当前系统不支持',
      };
}

/// 开机自启动（macOS 登录项）的 Dart 侧封装，原生实现见 MainFlutterWindow.swift。
///
/// 走 [SMAppService.mainApp]：注册的是应用自身，不需要额外的 helper bundle，
/// 也不依赖代码签名之外的任何东西；代价是要求 macOS 13 及以上。
class LoginItem {
  static const MethodChannel _channel = MethodChannel('win_share/login_item');

  /// 读系统里的当前状态。失败一律降级为 [LoginItemStatus.unsupported]，
  /// 界面据此把开关置灰而不是弹一堆错误。
  static Future<LoginItemStatus> status() async {
    if (!Platform.isMacOS) return LoginItemStatus.unsupported;
    try {
      return _parse(await _channel.invokeMethod<String>('status'));
    } on PlatformException catch (e) {
      Log.w('login', '读取登录项状态失败：${e.code} ${e.message}');
      return LoginItemStatus.unsupported;
    } on MissingPluginException {
      Log.w('login', '当前构建没有登录项原生实现');
      return LoginItemStatus.unsupported;
    }
  }

  /// 注册/注销登录项，返回 null 表示成功，否则是给用户看的错误详情
  static Future<String?> setEnabled(bool value) async {
    if (!Platform.isMacOS) return '开机自启动只在 macOS 上有效';
    try {
      final raw =
          await _channel.invokeMethod<String>('setEnabled', <String, dynamic>{
        'value': value,
      });
      Log.i('login', '${value ? '注册' : '注销'}登录项，结果=${_parse(raw).name}');
      return null;
    } on PlatformException catch (e) {
      final detail = <String>[
        if (e.code.isNotEmpty) e.code,
        e.message ?? '',
        (e.details ?? '').toString(),
      ].where((String s) => s.trim().isNotEmpty).join(' · ');
      Log.e('login', '${value ? '注册' : '注销'}登录项失败：$detail');
      return detail;
    } on MissingPluginException {
      return '当前构建没有登录项原生实现，请重新构建 macOS 端';
    }
  }

  /// 打开「系统设置 > 通用 > 登录项」，用于需要用户手动允许时
  static Future<void> openSystemSettings() async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<void>('openSystemSettings');
    } on PlatformException catch (e) {
      Log.w('login', '打开登录项设置失败：${e.code} ${e.message}');
    } on MissingPluginException {
      // 旧构建没有这个方法，忽略
    }
  }

  static LoginItemStatus _parse(String? raw) => switch (raw) {
        'enabled' => LoginItemStatus.enabled,
        'requiresApproval' => LoginItemStatus.requiresApproval,
        'notFound' => LoginItemStatus.notFound,
        'unsupported' => LoginItemStatus.unsupported,
        _ => LoginItemStatus.notRegistered,
      };
}
