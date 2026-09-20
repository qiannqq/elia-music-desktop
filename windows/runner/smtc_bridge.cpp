#include "smtc_bridge.h"

#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
// Windows.Foundation.h 要显式包含：IClosable::Close() 是返回 auto 的模板，
// 定义不在 base.h 里，缺了会报 C3779。
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/base.h>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
namespace Media = winrt::Windows::Media;
namespace Streams = winrt::Windows::Storage::Streams;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;

/// SMTC 会话。
///
/// 事件订阅必须留着 token、退出前 revoke：回调是异步投递的，
/// 不 revoke 就可能落在已经析构的对象上。
struct Session {
  Media::Playback::MediaPlayer player{nullptr};
  Media::SystemMediaTransportControls smtc{nullptr};
  winrt::event_token button_token{};
  winrt::event_token seek_token{};
  bool button_hooked = false;
  bool seek_hooked = false;

  /// 缩略图流的引用要留住：SMTC 是异步去读这个流的，
  /// 立刻析构的话封面会变成空白。
  Streams::InMemoryRandomAccessStream thumbnail{nullptr};

  bool valid() const { return smtc != nullptr; }
};

Session g_session;

// ---------------------------------------------------------------- 工具

std::string GetString(const EncodableMap* args, const char* key) {
  if (!args) return {};
  const auto it = args->find(EncodableValue(key));
  if (it == args->end()) return {};
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? *s : std::string();
}

int64_t GetInt(const EncodableMap* args, const char* key) {
  if (!args) return 0;
  const auto it = args->find(EncodableValue(key));
  if (it == args->end()) return 0;
  if (const auto* v = std::get_if<int32_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<int64_t>(&it->second)) return *v;
  return 0;
}

bool GetBool(const EncodableMap* args, const char* key) {
  if (!args) return false;
  const auto it = args->find(EncodableValue(key));
  if (it == args->end()) return false;
  const auto* v = std::get_if<bool>(&it->second);
  return v ? *v : false;
}

winrt::Windows::Foundation::TimeSpan ToTimeSpan(int64_t ms) {
  return winrt::Windows::Foundation::TimeSpan{std::chrono::milliseconds(ms)};
}

int64_t ToMs(winrt::Windows::Foundation::TimeSpan ts) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(ts).count();
}

void SendEvent(const char* name, int64_t position_ms = -1) {
  if (!g_channel) return;
  EncodableMap payload;
  payload[EncodableValue("event")] = EncodableValue(name);
  if (position_ms >= 0) {
    payload[EncodableValue("positionMs")] = EncodableValue(position_ms);
  }
  g_channel->InvokeMethod("onEvent",
                          std::make_unique<EncodableValue>(payload));
}

// ---------------------------------------------------------------- 会话

void CloseSession() {
  if (g_session.button_hooked) {
    g_session.smtc.ButtonPressed(g_session.button_token);
    g_session.button_hooked = false;
  }
  if (g_session.seek_hooked) {
    g_session.smtc.PlaybackPositionChangeRequested(g_session.seek_token);
    g_session.seek_hooked = false;
  }
  if (g_session.smtc) {
    g_session.smtc.IsEnabled(false);
    g_session.smtc = nullptr;
  }
  g_session.thumbnail = nullptr;
  if (g_session.player) {
    g_session.player.CommandManager().IsEnabled(true);
    g_session.player.Close();
    g_session.player = nullptr;
  }
}

/// 建会话。
///
/// 用 `MediaPlayer` 当宿主取它的 `SystemMediaTransportControls`：
/// 这条路不需要窗口句柄，于是与窗口创建时序、窗口重建都无关。
/// 把宿主的 CommandManager 关掉，免得它自己去抢按钮事件。
bool OpenSession() {
  if (g_session.valid()) return true;
  try {
    g_session.player = Media::Playback::MediaPlayer();
    g_session.player.CommandManager().IsEnabled(false);

    g_session.smtc = g_session.player.SystemMediaTransportControls();
    if (!g_session.smtc) return false;

    // 面板上要显示哪些按钮。seek 由进度条承担，不需要快进/快退键。
    g_session.smtc.IsPlayEnabled(true);
    g_session.smtc.IsPauseEnabled(true);
    g_session.smtc.IsNextEnabled(true);
    g_session.smtc.IsPreviousEnabled(true);
    g_session.smtc.IsStopEnabled(true);
    g_session.smtc.PlaybackStatus(Media::MediaPlaybackStatus::Closed);

    // 平台线程是 STA，事件会回到这个线程，所以可以直接往通道里发。
    g_session.button_token = g_session.smtc.ButtonPressed(
        [](const Media::SystemMediaTransportControls&,
           const Media::SystemMediaTransportControlsButtonPressedEventArgs&
               args) {
          switch (args.Button()) {
            case Media::SystemMediaTransportControlsButton::Play:
              SendEvent("play");
              break;
            case Media::SystemMediaTransportControlsButton::Pause:
              SendEvent("pause");
              break;
            case Media::SystemMediaTransportControlsButton::Next:
              SendEvent("next");
              break;
            case Media::SystemMediaTransportControlsButton::Previous:
              SendEvent("previous");
              break;
            case Media::SystemMediaTransportControlsButton::Stop:
              SendEvent("stop");
              break;
            default:
              break;
          }
        });
    g_session.button_hooked = true;

    // 系统面板上拖动进度条。要回一个 timeline 才算确认，
    // 否则面板上的游标会弹回原位。
    g_session.seek_token = g_session.smtc.PlaybackPositionChangeRequested(
        [](const Media::SystemMediaTransportControls&,
           const Media::PlaybackPositionChangeRequestedEventArgs& args) {
          SendEvent("seek", ToMs(args.RequestedPlaybackPosition()));
        });
    g_session.seek_hooked = true;

    return true;
  } catch (const winrt::hresult_error&) {
    CloseSession();
    return false;
  }
}

void UpdateMetadata(const std::string& title, const std::string& artist,
                    const std::string& album) {
  if (!g_session.valid()) return;
  auto updater = g_session.smtc.DisplayUpdater();
  updater.Type(Media::MediaPlaybackType::Music);
  auto music = updater.MusicProperties();
  music.Title(winrt::to_hstring(title));
  music.Artist(winrt::to_hstring(artist));
  if (!album.empty()) music.AlbumTitle(winrt::to_hstring(album));
  updater.Update();
}

/// 封面走**内存流**而不是 URL。
///
/// SMTC 只接受 IRandomAccessStreamReference，在线图片得让系统自己去拉；
/// 而封面在本地已经有一份（走应用自己的图片代理），直接喂字节最稳，
/// 也避免系统进程去访问 127.0.0.1 上的本地服务。
void UpdateThumbnail(const std::vector<uint8_t>& bytes) {
  if (!g_session.valid() || bytes.empty()) return;
  try {
    Streams::InMemoryRandomAccessStream stream;
    Streams::DataWriter writer(stream);
    writer.WriteBytes(winrt::array_view<const uint8_t>(bytes));
    // 内存流的 Store/Flush 是本地操作，不会回到 UI 线程，.get() 不会死锁；
    // 换成 StorageFile 那种碰文件系统的异步操作就不能这么写了。
    writer.StoreAsync().get();
    writer.FlushAsync().get();
    writer.DetachStream();
    stream.Seek(0);

    g_session.thumbnail = stream;
    auto updater = g_session.smtc.DisplayUpdater();
    updater.Thumbnail(Streams::RandomAccessStreamReference::CreateFromStream(stream));
    updater.Update();
  } catch (const winrt::hresult_error&) {
    // 封面失败不影响其余信息，忽略
  }
}

void UpdateStatus(const std::string& status) {
  if (!g_session.valid()) return;
  Media::MediaPlaybackStatus value = Media::MediaPlaybackStatus::Closed;
  if (status == "playing") {
    value = Media::MediaPlaybackStatus::Playing;
  } else if (status == "paused") {
    value = Media::MediaPlaybackStatus::Paused;
  } else if (status == "stopped") {
    value = Media::MediaPlaybackStatus::Stopped;
  }
  g_session.smtc.PlaybackStatus(value);
}

void UpdateTimeline(int64_t position_ms, int64_t duration_ms) {
  if (!g_session.valid()) return;
  Media::SystemMediaTransportControlsTimelineProperties props;
  props.StartTime(ToTimeSpan(0));
  props.MinSeekTime(ToTimeSpan(0));
  props.Position(ToTimeSpan(position_ms < 0 ? 0 : position_ms));
  props.EndTime(ToTimeSpan(duration_ms < 0 ? 0 : duration_ms));
  props.MaxSeekTime(ToTimeSpan(duration_ms < 0 ? 0 : duration_ms));
  g_session.smtc.UpdateTimelineProperties(props);
}

void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());

  if (method == "init") {
    result->Success(EncodableValue(OpenSession()));
    return;
  }
  if (method == "dispose") {
    CloseSession();
    result->Success();
    return;
  }
  if (method == "metadata") {
    UpdateMetadata(GetString(args, "title"), GetString(args, "artist"),
                   GetString(args, "album"));
    result->Success();
    return;
  }
  if (method == "thumbnail") {
    if (const auto* bytes =
            std::get_if<std::vector<uint8_t>>(call.arguments())) {
      UpdateThumbnail(*bytes);
    }
    result->Success();
    return;
  }
  if (method == "status") {
    UpdateStatus(GetString(args, "status"));
    result->Success();
    return;
  }
  if (method == "timeline") {
    UpdateTimeline(GetInt(args, "positionMs"), GetInt(args, "durationMs"));
    result->Success();
    return;
  }
  if (method == "enabled") {
    if (g_session.valid()) g_session.smtc.IsEnabled(GetBool(args, "enabled"));
    result->Success();
    return;
  }

  result->NotImplemented();
}

}  // namespace

void RegisterSmtcBridge(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "elia/smtc", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(HandleCall);
}
