#include "audio_probe.h"

#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <cmath>
#include <cstring>
#include <mutex>

namespace audio_probe {
namespace {

constexpr DWORD kStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
constexpr int64_t kHnsPerMs = 10000;  // Media Foundation 的时间单位是 100ns
constexpr double kPi = 3.14159265358979323846;

/// -50 dBFS。数字静音（无损转有损之后的底噪）一般低到 -70dB 以下，
/// 而房间环境噪声、磁带底噪大多在 -40dB 以上，取中间值能把两者分开。
constexpr double kSilenceRms = 0.0031623;

constexpr int64_t kWindowMs = 20;

/// 短于这个的静音不值得动 —— 那多半是正常的起拍留白或淡出尾巴。
constexpr int64_t kMinSilenceMs = 300;

/// 单侧最多跳这么多。防止整首都是环境底噪的曲目被裁空。
constexpr int64_t kMaxTrimMs = 20000;

/// 连续两个窗口有声才算「开始了」：单个窗口的瞬时噪声（咔哒、编码毛刺）
/// 不该把整段前奏判成「已经开唱」。
constexpr int kLoudRunNeeded = 2;

template <class T>
class Com {
 public:
  Com() = default;
  ~Com() {
    if (p_) p_->Release();
  }
  Com(const Com&) = delete;
  Com& operator=(const Com&) = delete;

  T** put() {
    reset();
    return &p_;
  }
  T* get() const { return p_; }
  T* operator->() const { return p_; }
  explicit operator bool() const { return p_ != nullptr; }
  void reset() {
    if (p_) {
      p_->Release();
      p_ = nullptr;
    }
  }

 private:
  T* p_ = nullptr;
};

/// RBJ cookbook 的 biquad。两级级联（高通 80Hz + 低通 120Hz）就是一个
/// 24dB/oct 的带通 —— 拿它量「鼓点」那一档能量（和 AMLL 取的频段一致）。
struct Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  double x1 = 0, x2 = 0, y1 = 0, y2 = 0;

  void SetHighPass(double f0, double q, double rate) {
    const double w0 = 2.0 * kPi * f0 / rate;
    const double cs = std::cos(w0);
    const double alpha = std::sin(w0) / (2.0 * q);
    const double a0 = 1.0 + alpha;
    b0 = ((1.0 + cs) / 2.0) / a0;
    b1 = (-(1.0 + cs)) / a0;
    b2 = b0;
    a1 = (-2.0 * cs) / a0;
    a2 = (1.0 - alpha) / a0;
  }

  void SetLowPass(double f0, double q, double rate) {
    const double w0 = 2.0 * kPi * f0 / rate;
    const double cs = std::cos(w0);
    const double alpha = std::sin(w0) / (2.0 * q);
    const double a0 = 1.0 + alpha;
    b0 = ((1.0 - cs) / 2.0) / a0;
    b1 = (1.0 - cs) / a0;
    b2 = b0;
    a1 = (-2.0 * cs) / a0;
    a2 = (1.0 - alpha) / a0;
  }

  double Process(double x) {
    const double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1;
    x1 = x;
    y2 = y1;
    y1 = y;
    return y;
  }
};

/// 把 PCM 按 20ms 分窗累加能量，记下第一个和最后一个「有声」窗口。
struct WindowScan {
  int channels = 1;
  int bits = 16;
  int rate = 44100;
  bool is_float = false;
  int64_t window_frames = 1;
  int64_t base_ms = 0;

  int64_t frames_total = 0;
  int64_t frames_in_window = 0;
  double sumsq = 0;
  int loud_run = 0;

  int64_t first_loud_ms = -1;
  int64_t last_loud_end_ms = -1;

  /// 响度包络（每 kLevelStepMs 一格）。为空就不记。
  std::vector<uint8_t>* levels = nullptr;
  int64_t level_frames = 1;
  int64_t frames_in_level = 0;
  double level_sumsq = 0;

  /// 低频（80~120Hz）包络，与 [levels] 同一套窗口。为空就不记。
  std::vector<uint8_t>* bass = nullptr;
  double bass_sumsq = 0;
  Biquad bass_hp;
  Biquad bass_lp;

  WindowScan(int sample_rate, int ch, int bit_depth, bool float_samples) {
    channels = ch > 0 ? ch : 1;
    bits = bit_depth > 0 ? bit_depth : 16;
    rate = sample_rate > 0 ? sample_rate : 44100;
    is_float = float_samples;
    window_frames = (int64_t)rate * kWindowMs / 1000;
    if (window_frames < 1) window_frames = 1;
    level_frames = (int64_t)rate * kLevelStepMs / 1000;
    if (level_frames < 1) level_frames = 1;
    bass_hp.SetHighPass(80.0, 0.7071, (double)rate);
    bass_lp.SetLowPass(120.0, 0.7071, (double)rate);
  }

  /// RMS → 0~255：−50dB 记 0、0dB 记 255。
  /// 音乐段一般落在 −20~−10dB，也就是 150~200 —— 用 0~50dB 这一档才有分辨率。
  static uint8_t ToByte(double rms) {
    if (rms <= 0) return 0;
    const double db = 20.0 * std::log10(rms);
    const double v = (db + 50.0) / 50.0;
    if (v <= 0) return 0;
    if (v >= 1) return 255;
    return (uint8_t)(v * 255.0);
  }

  double Sample(const BYTE* p) const {
    if (bits == 16) {
      int16_t v = 0;
      std::memcpy(&v, p, sizeof(v));
      return v / 32768.0;
    }
    if (bits == 32) {
      if (is_float) {
        float f = 0;
        std::memcpy(&f, p, sizeof(f));
        return f;
      }
      int32_t v = 0;
      std::memcpy(&v, p, sizeof(v));
      return v / 2147483648.0;
    }
    if (bits == 8) return (p[0] - 128) / 128.0;
    return 0;
  }

  void Feed(const BYTE* data, size_t len, int64_t base) {
    base_ms = base;
    const int bytes_per_sample = bits / 8;
    const size_t frame_bytes = (size_t)bytes_per_sample * channels;
    if (frame_bytes == 0) return;
    const size_t frames = len / frame_bytes;
    for (size_t i = 0; i < frames; ++i) {
      const BYTE* f = data + i * frame_bytes;
      double sum = 0;
      double mix = 0;
      for (int ch = 0; ch < channels; ++ch) {
        const double v = Sample(f + (size_t)ch * bytes_per_sample);
        sum += v * v;
        mix += v;
      }
      sumsq += sum / channels;
      level_sumsq += sum / channels;
      if (bass != nullptr) {
        const double y = bass_lp.Process(bass_hp.Process(mix / channels));
        bass_sumsq += y * y;
      }
      ++frames_in_window;
      ++frames_in_level;
      ++frames_total;
      if (frames_in_window >= window_frames) FlushWindow();
      if (frames_in_level >= level_frames) FlushLevel();
    }
  }

  /// 收尾：最后不足一格的那点也记一格，免得包络比歌短一截。
  void FlushTail() {
    if (frames_in_level > 0) FlushLevel();
  }

  void FlushLevel() {
    if (frames_in_level > 0) {
      if (levels != nullptr) {
        levels->push_back(ToByte(std::sqrt(level_sumsq / (double)frames_in_level)));
      }
      if (bass != nullptr) {
        bass->push_back(ToByte(std::sqrt(bass_sumsq / (double)frames_in_level)));
      }
    }
    frames_in_level = 0;
    level_sumsq = 0;
    bass_sumsq = 0;
  }

  void FlushWindow() {
    const double rms = std::sqrt(sumsq / (double)frames_in_window);
    const int64_t start = WindowStartMs();
    if (rms >= kSilenceRms) {
      ++loud_run;
      // 只在**第一次**连续两个窗口有声时记起点。
      // ⚠️ 不能写成 `loud_run == kLoudRunNeeded`：一趟解到底时，中间每出现一段
      // 新的有声区间都会把 first_loud_ms 冲掉，最后取到的是**最后一段**的起点
      // （以前头趟一找到就 break，把这个错盖住了）。
      if (loud_run >= kLoudRunNeeded && first_loud_ms < 0) {
        first_loud_ms = start - kWindowMs * (kLoudRunNeeded - 1);
      }
      last_loud_end_ms = start + kWindowMs;
    } else {
      loud_run = 0;
    }
    frames_in_window = 0;
    sumsq = 0;
  }

  int64_t WindowStartMs() const {
    return base_ms + (frames_total - frames_in_window) * 1000 / rate;
  }
};

bool ReadFormat(IMFSourceReader* reader, int* channels, int* rate, int* bits,
                bool* is_float) {
  Com<IMFMediaType> got;
  if (FAILED(reader->GetCurrentMediaType(kStream, got.put())) || !got) return false;

  UINT32 ch = 0, sr = 0, bps = 0;
  if (FAILED(got->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &ch)) || ch == 0) return false;
  if (FAILED(got->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &sr)) || sr == 0) {
    return false;
  }
  if (FAILED(got->GetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, &bps)) || bps == 0) {
    bps = 16;
  }

  GUID sub = GUID_NULL;
  got->GetGUID(MF_MT_SUBTYPE, &sub);
  *is_float = (sub == MFAudioFormat_Float);
  *channels = (int)ch;
  *rate = (int)sr;
  *bits = (int)bps;
  return true;
}

/// 读一块 PCM 喂给扫描器。
enum class Step { kOk, kEnd, kAbort };

Step Pump(IMFSourceReader* reader, WindowScan* scan, bool* have_base,
          const std::atomic<int>* cancel, int token) {
  if (cancel && cancel->load() != token) return Step::kAbort;

  DWORD flags = 0;
  LONGLONG ts = 0;
  Com<IMFSample> sample;
  const HRESULT hr = reader->ReadSample(kStream, 0, nullptr, &flags, &ts, sample.put());
  if (FAILED(hr)) return Step::kEnd;
  if (flags & MF_SOURCE_READERF_ENDOFSTREAM) return Step::kEnd;
  // 流切换（音频流上极少见）时 sample 是空的，跳过这一块继续读
  if (!sample) return Step::kOk;

  if (!*have_base) {
    scan->base_ms = (int64_t)(ts / kHnsPerMs);
    *have_base = true;
  }

  Com<IMFMediaBuffer> buf;
  if (SUCCEEDED(sample->ConvertToContiguousBuffer(buf.put())) && buf) {
    BYTE* data = nullptr;
    DWORD len = 0;
    if (SUCCEEDED(buf->Lock(&data, nullptr, &len))) {
      scan->Feed(data, len, scan->base_ms);
      buf->Unlock();
    }
  }
  return Step::kOk;
}

std::once_flag g_mf_once;

}  // namespace

bool Probe(const wchar_t* source, Silence* out, const std::atomic<int>* cancel,
           int token) {
  if (!source || !*source || !out) return false;
  *out = Silence();

  std::call_once(g_mf_once, [] { MFStartup(MF_VERSION); });

  Com<IMFSourceReader> reader;
  if (FAILED(MFCreateSourceReaderFromURL(source, nullptr, reader.put())) || !reader) {
    return false;
  }

  // 让 MF 解成 16bit PCM（要位数是为了省掉一层自己做的转换；
  // 它不给 16 位也能用，下面按协商结果处理）
  Com<IMFMediaType> want;
  if (FAILED(MFCreateMediaType(want.put())) || !want) return false;
  want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  want->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  want->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  if (FAILED(reader->SetCurrentMediaType(kStream, nullptr, want.get()))) return false;

  int channels = 0, rate = 0, bits = 16;
  bool is_float = false;
  if (!ReadFormat(reader.get(), &channels, &rate, &bits, &is_float)) return false;

  int64_t duration_ms = 0;
  PROPVARIANT var;
  std::memset(&var, 0, sizeof(var));
  if (SUCCEEDED(reader->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE,
                                                 MF_PD_DURATION, &var))) {
    if (var.vt == VT_UI8) duration_ms = (int64_t)(var.uhVal.QuadPart / kHnsPerMs);
  }
  PropVariantClear(&var);

  out->duration_ms = duration_ms;
  out->end_ms = duration_ms;

  // 一趟解到底。以前是「头一趟找第一声 + 尾一趟跳到最后」，但那两趟都拿不到
  // 中间的响度；而背景要跟着节奏呼吸，就得有整首歌的包络。反正现在只解本地文件，
  // 全解一趟的代价（几分钟的歌 1~2 秒，跑在 worker 线程上）是可以接受的。
  WindowScan scan(rate, channels, bits, is_float);
  scan.levels = &out->levels;
  scan.bass = &out->bass;
  bool have_base = false;
  for (;;) {
    const Step s = Pump(reader.get(), &scan, &have_base, cancel, token);
    if (s == Step::kAbort) return false;
    if (s == Step::kEnd) break;
  }
  scan.FlushTail();

  // -1 = 整段都没声：不做任何裁剪（没声可跳，也说不清该跳哪）
  if (scan.first_loud_ms > kMinSilenceMs) {
    out->start_ms =
        scan.first_loud_ms < kMaxTrimMs ? scan.first_loud_ms : kMaxTrimMs;
  }
  if (scan.last_loud_end_ms >= 0) {
    const int64_t silence = duration_ms - scan.last_loud_end_ms;
    if (silence > kMinSilenceMs) {
      const int64_t floor = duration_ms - kMaxTrimMs;
      out->end_ms = scan.last_loud_end_ms > floor ? scan.last_loud_end_ms : floor;
    }
  }

  // 裁完剩不到一秒：判断大概率出错了（或者这首歌本来就是纯静音），
  // 宁可什么都不做
  if (out->end_ms - out->start_ms < 1000) {
    out->start_ms = 0;
    out->end_ms = duration_ms;
  }

  out->ok = true;
  return true;
}

}  // namespace audio_probe
