#ifndef RUNNER_SYSTEM_BRIDGE_H_
#define RUNNER_SYSTEM_BRIDGE_H_

#include <flutter/binary_messenger.h>

// 系统信息桥。通道名 `elia/system`。
//
// 只有一件事 Dart 自己做不到：问某个盘还剩多少空间。
// 缓存占用要算「占总容量百分之几」，没有这个数字就只能干瞪眼。
//
// 在 FlutterWindow::OnCreate 里、插件注册之后调用一次。
void RegisterSystemBridge(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_SYSTEM_BRIDGE_H_
