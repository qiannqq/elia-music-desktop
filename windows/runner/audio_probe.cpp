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

/// -50 dBFS。数字静音（无损转有损之后的底噪）一般低到 -70dB 以下，
/// 而房间环境噪声、磁带底噪大多在 -40dB 以上，取中间值能把两者分开。
constexpr double kSilenceRms = 0.0031623;

constexpr int64_t kWindowMs = 20;

/// 短于这个的静音不值得动 —— 那多半是正常的起拍留白或淡出尾巴。
constexpr int64_t kMinSilenceMs = 300;

/// 单侧最多跳这么多。防止整首都是环境底噪的曲目被裁空。
constexpr int64_t kMaxTrimMs = 20000;

/// 开头最多找这么久（都是静音就别找了）。
constexpr int64_t kHeadScanMs = 60000;

/// 尾巴只往回扫这么多。
constexpr int64_t kTailScanMs = 20000;

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

  WindowScan(int sample_rate, int ch, int bit_depth, bool float_samples) {
    channels = ch > 0 ? ch : 1;
    bits = bit_depth > 0 ? bit_depth : 16;
    rate = sample_rate > 0 ? sample_rate : 44100;
    is_float = float_samples;
    window_frames = (int64_t)rate * kWindowMs / 1000;
    if (window_frames < 1) window_frames = 1;
  }

  /// 已经喂进去的帧数换算成毫秒（相对本趟的起点）
  int64_t PositionMs() const { return base_ms + frames_total * 1000 / rate; }

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
      for (int ch = 0; ch < channels; ++ch) {
        const double v = Sample(f + (size_t)ch * bytes_per_sample);
        sum += v * v;
      }
      sumsq += sum / channels;
      ++frames_in_window;
      ++frames_total;
      if (frames_in_window >= window_frames) FlushWindow();
    }
  }

  void FlushWindow() {
    const double rms = std::sqrt(sumsq / (double)frames_in_window);
    const int64_t start = WindowStartMs();
    if (rms >= kSilenceRms) {
      ++loud_run;
      if (loud_run == kLoudRunNeeded) first_loud_ms = start - kWindowMs * (kLoudRunNeeded - 1);
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

  // ---- 头：从 0 开始解，直到找到第一声 ----
  //
  // 短曲目（比尾巴窗口还短）这一趟就会读到流尾，那尾巴的信息顺手也拿到了，
  // 不用再跳一次。
  WindowScan scan(rate, channels, bits, is_float);
  bool reached_end = false;
  {
    bool have_base = false;
    while (scan.first_loud_ms < 0) {
      const Step s = Pump(reader.get(), &scan, &have_base, cancel, token);
      if (s == Step::kAbort) return false;
      if (s == Step::kEnd) {
        reached_end = true;
        break;
      }
      if (scan.PositionMs() > kHeadScanMs) break;
    }
    // -1 = 整段都没声：不做任何裁剪（没声可跳，也说不清该跳哪）
    if (scan.first_loud_ms > kMinSilenceMs) {
      out->start_ms =
          scan.first_loud_ms < kMaxTrimMs ? scan.first_loud_ms : kMaxTrimMs;
    }
  }

  // ---- 尾：跳到最后一段再解到结束，找最后一声 ----
  //
  // 跳不过去（网络流不支持 range）就只报开头那一段 —— 少剪一半，
  // 总比把整首歌从头解一遍（等于多下一遍）强。
  if (!reached_end) {
    WindowScan tail(rate, channels, bits, is_float);
    bool have_base = false;
    int64_t from = duration_ms - kTailScanMs;
    if (from < 0) from = 0;

    PROPVARIANT pos;
    std::memset(&pos, 0, sizeof(pos));
    pos.vt = VT_I8;
    pos.hVal.QuadPart = from * kHnsPerMs;
    const HRESULT seek = reader->SetCurrentPosition(GUID_NULL, pos);
    PropVariantClear(&pos);

    if (SUCCEEDED(seek)) {
      for (;;) {
        const Step s = Pump(reader.get(), &tail, &have_base, cancel, token);
        if (s == Step::kAbort) return false;
        if (s == Step::kEnd) break;
      }
    }
    if (tail.last_loud_end_ms >= 0) {
      const int64_t silence = duration_ms - tail.last_loud_end_ms;
      if (silence > kMinSilenceMs) {
        const int64_t floor = duration_ms - kMaxTrimMs;
        out->end_ms = tail.last_loud_end_ms > floor ? tail.last_loud_end_ms : floor;
      }
    }
  } else if (scan.last_loud_end_ms >= 0) {
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
