#include "audio_probe_bridge.h"

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "audio_probe.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                                    nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

/// 同一时刻只有一个探测任务。
///
/// 换歌很快的时候（连着点下一首）会不停来新任务：直接开新线程会积一堆、
/// 每个都在解同一类东西。这里只留「当前这一个 + 最新的那个」，
/// 旧任务靠 [generation] 对不上自己退出。
struct Slot {
  std::mutex mutex;
  std::condition_variable cv;

  bool worker_started = false;

  std::string key;
  std::wstring source;
  bool has_job = false;
  bool done = false;

  /// 每来一个新任务 +1；正在跑的任务发现自己手里那个对不上就放弃
  std::atomic<int> generation{0};

  audio_probe::Silence result;
};

Slot g_slot;

void WorkerLoop() {
  // Media Foundation 的 Source Reader 要求线程先初始化 COM（MTA 就行）
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);

  for (;;) {
    std::string key;
    std::wstring source;
    int token = 0;
    {
      std::unique_lock<std::mutex> lock(g_slot.mutex);
      g_slot.cv.wait(lock, [] { return g_slot.has_job; });
      g_slot.has_job = false;
      g_slot.done = false;
      key = g_slot.key;
      source = g_slot.source;
      token = g_slot.generation.load();
    }

    audio_probe::Silence silence;
    const bool ok = audio_probe::Probe(source.c_str(), &silence,
                                       &g_slot.generation, token);

    {
      std::lock_guard<std::mutex> lock(g_slot.mutex);
      // 已经被更新的任务顶掉了：结果作废，别覆盖别人的状态
      if (g_slot.generation.load() == token) {
        g_slot.result = silence;
        g_slot.done = true;
        if (!ok) g_slot.result.ok = false;
      }
    }
  }
}

void StartJob(const std::string& source) {
  {
    std::lock_guard<std::mutex> lock(g_slot.mutex);
    if (!g_slot.worker_started) {
      g_slot.worker_started = true;
      std::thread(WorkerLoop).detach();
    }
    g_slot.key = source;
    g_slot.source = Utf8ToWide(source);
    g_slot.has_job = true;
    g_slot.done = false;
    g_slot.generation.fetch_add(1);
  }
  g_slot.cv.notify_one();
}

std::string GetString(const EncodableMap* args, const char* key) {
  if (!args) return std::string();
  const auto it = args->find(EncodableValue(key));
  if (it == args->end()) return std::string();
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? *s : std::string();
}

void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());

  if (method == "start") {
    const std::string source = GetString(args, "source");
    if (source.empty()) {
      result->Success(EncodableValue(false));
      return;
    }
    StartJob(source);
    result->Success(EncodableValue(true));
    return;
  }

  if (method == "poll") {
    std::lock_guard<std::mutex> lock(g_slot.mutex);
    if (!g_slot.done) {
      result->Success(EncodableValue());
      return;
    }
    EncodableMap out;
    out[EncodableValue("source")] = EncodableValue(g_slot.key);
    out[EncodableValue("ok")] = EncodableValue(g_slot.result.ok);
    out[EncodableValue("durationMs")] =
        EncodableValue(static_cast<int64_t>(g_slot.result.duration_ms));
    out[EncodableValue("startMs")] =
        EncodableValue(static_cast<int64_t>(g_slot.result.start_ms));
    out[EncodableValue("endMs")] =
        EncodableValue(static_cast<int64_t>(g_slot.result.end_ms));
    result->Success(EncodableValue(out));
    return;
  }

  result->NotImplemented();
}

}  // namespace

void RegisterAudioProbe(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "elia/audio_probe", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(HandleCall);
}
