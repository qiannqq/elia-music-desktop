#ifndef RUNNER_LYRIC_ISLAND_H_
#define RUNNER_LYRIC_ISLAND_H_

#include <windows.h>

#include <flutter/binary_messenger.h>

// 屏幕顶部的歌词胶囊。通道名 `elia/lyric_island`。
//
// 在 FlutterWindow::OnCreate 里、插件注册之后调用一次。
// `host` 用来判断胶囊该贴在哪块屏幕上（主窗口所在的那块）。
void RegisterLyricIsland(flutter::BinaryMessenger* messenger, HWND host);

// 主窗口挪到另一块屏幕时，胶囊跟着挪。隐藏时是空操作。
void LyricIslandOnHostMoved();

// 关掉胶囊并释放通道。要在 Flutter 引擎销毁之前调用。
void LyricIslandShutdown();

#endif  // RUNNER_LYRIC_ISLAND_H_
