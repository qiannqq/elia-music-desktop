import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 窗口层那些动作的共享状态，以及**全屏 / 最大化**的实际调用。
///
/// 为什么全屏要交给原生（`windows/runner/window_fx.cpp`）而不是在 Dart 里
/// `windowManager.setBounds`：
///
///   `setBounds` 走 `SetWindowPos`。窗口在「正常」状态下被改尺寸时，Windows 会
///   **顺手更新它的「还原尺寸」** —— 于是「铺满显示器」之后系统的最大化/还原
///   语义全乱了：点最大化看起来没变化（还原尺寸已经等于显示器）、再点还原回到
///   「显示器大小」且能拖、拖过之后还原尺寸被永久改掉。
///
///   原生那边改成「进全屏时切 `WS_POPUP`（系统层面就无法最大化/还原），
///   退出时用 `SetWindowPlacement` 连位置、尺寸和最大化状态一起还回去」——
///   完全不去动那个还原尺寸。

/// 当前是不是全屏。标题栏、播放页、窗口事件三处看同一份。
final ValueNotifier<bool> appFullscreen = ValueNotifier<bool>(false);

/// 窗口是不是最大化。
///
/// 自绘标题栏要靠它**区分「最大化」和「还原」两个图标/行为** ——
/// 之前只有一个「最大化」图标，最大化之后还显示「最大化」，
/// 点了到底是要最大化还是还原全靠猜。
final ValueNotifier<bool> appMaximized = ValueNotifier<bool>(false);

/// 我们正在自己操作窗口（切全屏的整个过程）。
///
/// ⚠️ 期间可能收到窗口事件（系统在切状态时会发），那些**不是**用户在动窗口，
/// 不能拿来当作「状态失效」的证据 —— 所以监听侧要先看这个标志。
bool windowFxBusy = false;

const MethodChannel _channel = MethodChannel('elia/window_fx');

/// 切全屏（两边都会用：播放页的按钮、外壳里的 Esc）。
///
/// 图标先换，再等原生把窗口摆好 —— 那一步是同步的（见文件头），返回时窗口已经变了。
/// 失败就回滚图标状态。
Future<void> toggleFullscreen() async {
  if (windowFxBusy) return; // 正在切换，忽略连点
  final next = !appFullscreen.value;

  appFullscreen.value = next;
  windowFxBusy = true;
  try {
    final ok = await _setFullscreen(next);
    if (!ok) appFullscreen.value = !next; // 失败就回滚
  } finally {
    windowFxBusy = false;
  }
}

/// 退出全屏（Esc 在全屏时走这条，而不是收起播放页）
Future<void> exitFullscreen() async {
  if (windowFxBusy || !appFullscreen.value) return;
  appFullscreen.value = false;
  windowFxBusy = true;
  try {
    final ok = await _setFullscreen(false);
    if (!ok) appFullscreen.value = true;
  } finally {
    windowFxBusy = false;
  }
}

Future<bool> _setFullscreen(bool value) async {
  try {
    final res = await _channel
        .invokeMethod<Map<Object?, Object?>>('setFullscreen', {'value': value});
    if (res == null) return false;
    appMaximized.value = res['maximized'] == true;
    return res['ok'] == true;
  } catch (_) {
    return false;
  }
}

/// 最大化 / 还原。
///
/// ⚠️ **全屏时不给动**：那会儿窗口是 `WS_POPUP`，最大化会把它变成一坨
/// （而且状态也还不了原）。原生侧会直接拒绝。
Future<void> toggleMaximize() async {
  if (windowFxBusy || appFullscreen.value) return;
  try {
    final res =
        await _channel.invokeMethod<Map<Object?, Object?>>('toggleMaximize');
    if (res != null) appMaximized.value = res['maximized'] == true;
  } catch (_) {
    // 失败不影响别的
  }
}

/// 问一下原生当前的状态（启动时同步一次）。
Future<void> syncWindowFxState() async {
  try {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('query');
    if (res == null) return;
    appFullscreen.value = res['fullscreen'] == true;
    appMaximized.value = res['maximized'] == true;
  } catch (_) {
    // 通道还没就绪之类，忽略
  }
}
