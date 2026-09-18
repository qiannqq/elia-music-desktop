import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'core/app_paths.dart';
import 'core/file_logger.dart';
import 'core/local_store.dart';
import 'services/api_client.dart';
import 'services/http_server.dart';
import 'services/player_controller.dart';
import 'state/app_state.dart';
import 'state/theme_controller.dart';
import 'ui/app_shell.dart';

const int kHttpPort = 17071;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---- 路径 / 存储 / 日志（全部锚定在 D 盘可执行目录下）----
  AppPaths.init();
  LocalStore.init();
  fileLogger.info('App', 'start, appDir=${AppPaths.appDir}');
  debugPrint('[App] appDir   = ${AppPaths.appDir}');
  debugPrint('[App] dataDir  = ${AppPaths.dataDir}');
  debugPrint('[App] logsDir  = ${AppPaths.logsDir}');

  _setupErrorLogging();

  themeController.init();
  await app.init();
  await player.init();

  // ---- 本地 HTTP API 服务（等价原 `httpServerService.start(port)`）----
  // 端口被占用说明已有实例在运行 —— 等价原 `singleLock: true`
  try {
    await httpServerService.start(kHttpPort);
  } on SocketException catch (e) {
    fileLogger.error('App', 'port $kHttpPort unavailable: $e');
    stderr.writeln('Elia Music 已在运行（端口 $kHttpPort 被占用），本次启动退出。');
    exit(0);
  }

  // ---- 窗口（无边框 + 自绘标题栏，等价 frame:false）----
  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(1100, 720),
    minimumSize: Size(800, 560),
    center: true,
    backgroundColor: Color(0xFFF3F3F3),
    titleBarStyle: TitleBarStyle.hidden,
    title: 'Elia Music',
    windowButtonVisibility: false,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const EliaMusicApp());
}

/// 渲染层错误上报 —— 等价原 `setupErrorLogging()`（转发到 `/api/log`）
void _setupErrorLogging() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    fileLogger.error('Flutter', '${details.exception}\n${details.stack}');
    ApiClient.sendErrorLog(
      message: '${details.exception}',
      stack: '${details.stack ?? ''}',
      url: details.library ?? '',
    );
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    fileLogger.error('Platform', '$error\n$stack');
    ApiClient.sendErrorLog(message: '$error', stack: '$stack');
    return true;
  };
}
