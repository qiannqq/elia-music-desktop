#ifndef RUNNER_AUDIO_PROBE_BRIDGE_H_
#define RUNNER_AUDIO_PROBE_BRIDGE_H_

#include <flutter/binary_messenger.h>

// 首尾无声探测的通道桥。通道名 `elia/audio_probe`。
//
// 只有两个方法：
//   start {source}  —— 起一个后台探测任务（同一时刻只留一个，新的顶掉旧的）
//   poll  {}        —— 还没好返回 null，好了返回
//                      {source, ok, durationMs, startMs, endMs}
//
// 为什么是「起任务 + 轮询」而不是回调：method result 必须在平台线程上回，
// 而探测要解音频、只能放在 worker 线程 —— 跨线程回传得再搭一层消息泵。
// 轮询把这层省掉了，代价是几十毫秒的延迟，对「跳过开头几秒静音」完全够。
//
// 在 FlutterWindow::OnCreate 里、插件注册之后调用一次。
void RegisterAudioProbe(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_AUDIO_PROBE_BRIDGE_H_
