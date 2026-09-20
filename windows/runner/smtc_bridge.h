#ifndef RUNNER_SMTC_BRIDGE_H_
#define RUNNER_SMTC_BRIDGE_H_

#include <flutter/binary_messenger.h>

// 注册 SMTC 桥。
//
// 通道名 `elia/smtc`（Dart → 原生），在 FlutterWindow::OnCreate 里、
// 插件注册之后调用一次。
void RegisterSmtcBridge(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_SMTC_BRIDGE_H_
