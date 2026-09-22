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
import 'services/audio_cache.dart';
import 'services/player_controller.dart';
import 'services/lyric_island_service.dart';
import 'services/smtc_service.dart';
import 'state/app_state.dart';
import 'state/theme_controller.dart';
import 'ui/app_shell.dart';

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

  // ---- 单实例：用**独占文件锁**，不用端口 ----
  // 早期版本靠「固定端口 17071 绑定失败」判定单实例，结果与原版 Electron
  // 互相抢占：打开重构版后，原版渲染进程加载页面时报 Not Found。
  // 现在两者各用各的锁/端口，可以同时运行。
  if (!await _acquireSingleInstanceLock()) {
    fileLogger.info('App', 'another instance is already running, exit');
    stderr.writeln('Elia Music 已在运行，本次启动退出。');
    _forceExit(0);
  }

  themeController.init();

  // ---- 本地 HTTP API 服务 ----
  // 必须在 app.init() **之前**启动：
  // app.init() 会读取 Cookie 并发起「后台校验」，而校验是走本地 API 的。
  // 之前服务在 app.init() 之后才起，校验请求打到了默认端口（17071）而失败，
  // 于是每次启动都提示「Cookie 已失效」，手动点【验证】又正常
  // （那时服务已就绪）—— 表现就是启动时的这次误报。
  // 端口由系统分配空闲端口（不再固定 17071），避免与原版 Electron 冲突。
  final apiPort = await httpServerService.start();
  setApiPort(apiPort);
  fileLogger.info('App', 'local API listening on $apiPort');

  await app.init();
  await player.init();

  // 系统媒体控件：播放栏之外的第二个出口（媒体面板 / 锁屏 / 硬件媒体键）
  await smtc.init();

  // 桌面顶部的歌词胶囊。默认关，只有设置里打开过才会显示。
  await lyricIsland.init();

  // 按策略清理音频缓存：不在歌单里的留 24h、在歌单里但 30 天没听的删掉
  AudioDiskCache.prune(playlistMids: app.songs.map((s) => s.mid).toSet());

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

/// 单实例锁（独占文件锁）。
///
/// 返回 false 表示已有实例在运行。
/// 用文件锁而不用端口，是为了不与原版 Electron 的固定 17071 端口互相干扰。
/// 持有单实例锁的文件句柄。
/// **必须保持打开**：句柄一旦关闭锁就释放了（进程退出时由系统自动释放）。
RandomAccessFile? instanceLockFile;

Future<bool> _acquireSingleInstanceLock() async {
  try {
    final f = File('${AppPaths.dataDir}${Platform.pathSeparator}.instance.lock');
    await f.parent.create(recursive: true);
    // 用 append 打开，避免 FileMode.write 把锁文件截断
    final raf = await f.open(mode: FileMode.append);
    if (await raf.length() == 0) {
      await raf.writeString('lock');
      await raf.flush();
    }
    // 必须显式给出字节范围。`lock()` 的 end 默认是 -1（= 锁到文件末尾），
    // 对**空文件**会退化成「锁 0 个字节」—— 等于完全没锁，
    // 两个实例都能拿到锁（实测踩过）。这里固定锁 offset 0 的 1 个字节。
    await raf.lock(FileLock.exclusive, 0, 1);
    instanceLockFile = raf;
    return true;
  } on FileSystemException {
    return false; // 锁被占用 —— 已有实例
  } catch (e) {
    // 其它异常（如权限）不应阻止启动
    fileLogger.error('App', 'instance lock error: $e');
    return true;
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
