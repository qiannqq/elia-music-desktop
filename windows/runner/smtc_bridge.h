#ifndef RUNNER_SMTC_BRIDGE_H_
#define RUNNER_SMTC_BRIDGE_H_

#include <windows.h>

#include <flutter/binary_messenger.h>

// 注册 SMTC 桥。
//
// 通道名 `elia/smtc`（Dart → 原生），在 FlutterWindow::OnCreate 里、
// 插件注册之后调用一次。
//
// `hwnd` 是宿主窗口：SMTC 会话要挂在它上面，系统才能识别出是哪个应用
// 在播放（否则媒体面板上显示「未知应用」）。
void RegisterSmtcBridge(flutter::BinaryMessenger* messenger, HWND hwnd);

#endif  // RUNNER_SMTC_BRIDGE_H_
