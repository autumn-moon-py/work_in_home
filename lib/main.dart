import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'log.dart';
import 'model.dart';
import 'side_mac.dart';
import 'side_win.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动锚点：把 pid 与日志路径写进日志，方便和系统挂载表按时间对齐
  Log.i('app',
      '启动 pid=$pid 平台=${Platform.operatingSystem} 日志=${Log.filePath}');
  if (Platform.isMacOS) {
    await windowManager.ensureInitialized();
    // 作为登录项常驻时不要弹出窗口
    if (ConfigStore.loadStartHidden()) {
      await windowManager.hide();
    }
  }
  runApp(const WinShareApp());
}

/// 同一个工程同时承载两端：界面完全共用，平台差异由各自的 LocalSide 承担。
class WinShareApp extends StatelessWidget {
  const WinShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 收敛的中性蓝，避免高饱和填充色铺满界面
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3F6E9E));
    return MaterialApp(
      title: 'Win Share',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        // 桌面应用信息密度更高，整体收紧一档
        visualDensity: VisualDensity.compact,
        appBarTheme: AppBarTheme(
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: scheme.surface,
        ),
        cardTheme: CardTheme(
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        dividerTheme: const DividerThemeData(space: 1),
        inputDecorationTheme: InputDecorationTheme(
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      home: WinShareHome(
        side: Platform.isWindows ? WindowsSide() : MacSide(),
      ),
    );
  }
}
