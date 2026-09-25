#ifndef RUNNER_WINDOW_FX_H_
#define RUNNER_WINDOW_FX_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// 全屏切换桥。通道名 `elia/window_fx`。
//
// 为什么必须由原生来做（而不是在 Dart 里 `windowManager.setBounds`）：
//
//   `setBounds` 走的是 `SetWindowPos`。窗口在「正常」状态下被改大小/位置时，
//   Windows 会**顺手更新它的「还原尺寸」（`WINDOWPLACEMENT.rcNormalPosition`）** ——
//   于是「铺满显示器」之后，系统的最大化/还原语义就全乱了：
//
//     * 点「最大化」→ 记住的还原尺寸 = 整块显示器 → 看起来没变化；
//     * 再点一次「还原」→ 回到「显示器大小」，比最大化还大、还能拖；
//     * 拖过之后还原尺寸被永久改掉，只能重启恢复。
//
//   所以这里**不去动尺寸**，而是把它交给系统的窗口状态机：
//   进全屏时换成 `WS_POPUP`（没有 `WS_MAXIMIZEBOX` / `WS_THICKFRAME`，
//   系统层面就无法最大化/还原/分屏，也就不会再改坏还原尺寸），
//   退出时用 `SetWindowPlacement` 把样式、位置**和最大化状态**一起还回去。
//
// 在 FlutterWindow::OnCreate 里、插件注册之后调用一次。
void RegisterWindowFx(flutter::BinaryMessenger* messenger, HWND window);

/// 窗口销毁前调用：清掉句柄，避免消息回调打到已销毁的窗口上。
void WindowFxShutdown();

#endif  // RUNNER_WINDOW_FX_H_
