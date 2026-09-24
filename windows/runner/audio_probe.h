#ifndef RUNNER_AUDIO_PROBE_H_
#define RUNNER_AUDIO_PROBE_H_

#include <atomic>
#include <cstdint>

// 首尾无声探测。
//
// 界面层拿不到解码后的采样（audioplayers 只给播放控制，不给 PCM），所以交给
// Media Foundation 的 Source Reader 解成 PCM，按 20ms 窗口算 RMS，找出
// 「开头静了多久、结尾静了多久」。
//
// 这个文件**不引 Flutter 头**：可以单独编成一个控制台程序在真实音频上验证算法
// （见 bridge 那个文件的说明）。
namespace audio_probe {

struct Silence {
  /// 能不能给出结论。打不开源、解不出 PCM 都是 false。
  bool ok = false;

  int64_t duration_ms = 0;

  /// 第一声之前静了多久 —— 播放时要从这里开始。
  int64_t start_ms = 0;

  /// 最后一声在哪儿结束。等于 duration_ms 表示尾巴不用剪。
  int64_t end_ms = 0;
};

/// 探测一个音频源的首尾静音。
///
/// [source] 可以是本地文件路径，也可以是本地代理的 http 地址 ——
/// `MFCreateSourceReaderFromURL` 两种都吃。
///
/// ⚠️ 上游 CDN 的地址**不能**直接喂进来：B站那些要带 Referer，这里给不了，
/// 必须走 `http_server.dart` 那个会补请求头的本地代理。
///
/// [cancel] 不为空时每读一块比对一次 [token]：对不上说明有更新的任务把它顶掉了，
/// 立刻放弃（返回 false）。
bool Probe(const wchar_t* source, Silence* out, const std::atomic<int>* cancel,
           int token);

}  // namespace audio_probe

#endif  // RUNNER_AUDIO_PROBE_H_
