#ifndef RUNNER_AUDIO_PROBE_H_
#define RUNNER_AUDIO_PROBE_H_

#include <atomic>
#include <cstdint>
#include <vector>

// 音频探测：一趟解码同时给出三样东西。
//
//   * **首尾无声**：按 20ms 窗口算 RMS，找出「开头静了多久、结尾静了多久」，
//     用来跳过歌曲前后的空白；
//   * **响度包络**：按 20ms 一格记录整首歌的能量（播放页的压暗层用）；
//   * **低频包络**：同一格里再过一道 80~120Hz 带通、单独记「鼓点」的能量 ——
//     背景「跟着鼓点轻轻放大」用的就是它。
//
// 界面层拿不到解码后的采样（audioplayers 只给播放控制、不给 PCM），所以交给
// Media Foundation 的 Source Reader。
//
// ⚠️ 只在**本地文件**上做：MF 走 http 时每定位一次就把剩下的部分重下一遍。
//
// 这个文件**不引 Flutter 头**：可以单独编成一个控制台程序在真实音频上验证算法
// （见 bridge 那个文件的说明）。
namespace audio_probe {

/// 两种包络共用的一格有多长（毫秒）。
///
/// **20ms 一格**：鼓点本身只有几十毫秒，100ms 一格会把它们糊成一团 ——
/// 低频那条要的就是这个分辨率。5 分钟的歌约 15000 格（base64 后 20KB），可以接受。
constexpr int64_t kLevelStepMs = 20;

struct Silence {
  /// 能不能给出结论。打不开源、解不出 PCM 都是 false。
  bool ok = false;

  int64_t duration_ms = 0;

  /// 第一声之前静了多久 —— 播放时要从这里开始。
  int64_t start_ms = 0;

  /// 最后一声在哪儿结束。等于 duration_ms 表示尾巴不用剪。
  int64_t end_ms = 0;

  /// 整首歌的响度包络，每 [kLevelStepMs] 一格、0~255（−50dB 记 0、0dB 记 255）。
  std::vector<uint8_t> levels;

  /// 低频（80~120Hz 带通）的能量包络，编码与 [levels] 相同。
  /// 背景「跟着鼓点轻轻放大」用的就是它 —— 和 AMLL 取的是同一个频段。
  std::vector<uint8_t> bass;
};

/// 解一遍这个音频，给出首尾静音与两份包络（响度 / 低频）。
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
