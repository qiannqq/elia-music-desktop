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
  // 端口被占用说明已有实例在运行 —— 等价原 `singleLock: true`。
  // 注意：Flutter 3.47 在 Windows 上关闭窗口后引擎会卡在关闭流程，
  // 进程可能残留并继续占用端口，因此这里先重试等待，再明确报错。
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      await httpServerService.start(kHttpPort);
      break;
    } on SocketException catch (e) {
      if (attempt == 2) {
        fileLogger.error('App', 'port $kHttpPort unavailable: $e');
        stderr.writeln('端口 $kHttpPort 被占用（可能已有实例在运行），本次启动退出。');
        _forceExit(0);
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }

  // ---- 窗口（无边框 + 自绘标题栏，等价 frame:false）----
  await windowManager.ensureInitialized();
  windowManager.addListener(_AppLifecycle());
  const windowOptions = WindowOptions(
    size: Size(1100, 720),
    minimumSize: Size(800, 560),
    center: true,
    backgroundColor: Color(0xFFF3F3F3),
    title: 'Elia Music',
    windowButtonVisibility: false,
  );

  // 无边框走 setAsFrameless()，**不使用** TitleBarStyle.hidden。
  // TitleBarStyle.hidden 会让 WM_NCCALCSIZE 把客户区左右/下各内缩 8px、上偏移 1px，
  // 实测该路径下窗口虽然可见且 WM_NCHITTEST 返回 HTCLIENT，但引擎收不到指针事件
  // （界面完全点不动）。setAsFrameless() 对应的是「客户区 = 整个窗口」这条经典路径。
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setAsFrameless();
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const EliaMusicApp());
}

/// 窗口关闭时做清理并**强制结束进程**。
///
/// 背景：Flutter 3.47.4 在 Windows 上关闭窗口后，引擎的关闭流程会卡住
/// （实测原生 `flutter create` 模板应用同样如此），进程残留且继续占用
/// 17071 端口，导致下一次启动因端口冲突而直接退出（表现为「程序打不开」）。
/// 因此这里在窗口关闭时先落盘、停服务，再显式 exit。
class _AppLifecycle with WindowListener {
  @override
  void onWindowClose() {
    fileLogger.info('App', 'window close requested, shutting down');
    _forceExit(0);
  }
}

/// 窗口关闭时**同步**强制结束进程。
///
/// 背景：Flutter 3.47.4 在 Windows 上关闭窗口后，引擎的关闭流程会卡住
/// （实测原生 `flutter create` 模板应用同样如此），进程残留且继续占用
/// 17071 端口，导致下一次启动因端口冲突而直接退出（表现为「程序打不开」）。
///
/// 注意：这里**绝不能 await 任何异步操作** —— 窗口关闭时引擎已在拆除，
/// `await` 可能永远不会返回，导致 `exit()` 执行不到（实测端口已释放但进程仍残留）。
/// 只做同步落盘，然后立刻 exit；socket 由操作系统回收。
void _forceExit(int code) {
  try {
    LocalStore.flush();
  } catch (_) {}
  exit(code);
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
