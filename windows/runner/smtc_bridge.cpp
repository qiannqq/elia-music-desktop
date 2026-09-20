#include "smtc_bridge.h"

#include <chrono>
#include <cstdint>
#include <cwctype>
#include <memory>
#include <string>
#include <vector>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
// ISystemMediaTransportControlsInterop 是经典 COM 接口，在这个头里。
#include <systemmediatransportcontrolsinterop.h>
// Windows.Foundation.h 要显式包含：IClosable::Close() 是返回 auto 的模板，
// 定义不在 base.h 里，缺了会报 C3779。
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
// 控制**别的应用**的媒体会话（媒体键接管要用）
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/base.h>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
namespace Media = winrt::Windows::Media;
namespace MediaControl = winrt::Windows::Media::Control;
namespace Streams = winrt::Windows::Storage::Streams;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;

/// 宿主窗口。SMTC 会话要挂在它上面，见 OpenSession 里的说明。
HWND g_hwnd = nullptr;

/// SMTC 会话。
///
/// 事件订阅必须留着 token、退出前 revoke：回调是异步投递的，
/// 不 revoke 就可能落在已经析构的对象上。
struct Session {
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

// ------------------------------------------------------------ 媒体键接管
//
// 媒体键有两条到达路径，这里必须先分清：
//
//   * **走 SMTC 会话路由** —— 系统挑一个「当前会话」发给它（启发式：前台应用优先，
//     否则最近活跃的）。这条路上才有「优先级」可言。
//   * **被某个程序用 `RegisterHotKey` 注册成全局热键** —— 独占、先到先得。
//     它会在系统做会话路由**之前**把键截走，于是媒体面板里选哪个会话都没用。
//
// 实测（`RegisterHotKey` 对同一个键是独占的，后来者拿到 1409）：
// 四个媒体键全被某个播放器占着 —— 也就是说媒体键根本没到过 SMTC 那一层。
//
// 低级键盘钩子（`WH_KEYBOARD_LL`）的调用时机在热键分发之前，所以这里挂一个钩子
// 把媒体键接过来自己分派，再按下面的规则决定给谁。**判断不出来就放行**，
// 交给系统按老规矩处理 —— 吞掉一个自己处理不了的键，比不接管更糟。
//
// 分派规则：
//   播放/暂停 ① 有会话在播 → 全部暂停（无论它是谁）
//             ② 否则焦点窗口那个播放器 → 播放它
//             ③ 否则我们自己 → 控制自己的播放器
//             ④ 都没有 → 恢复最近被暂停的那个
//   上一首/下一首 优先发给焦点窗口那个会话，其次正在播放的，最后我们自己。

MediaControl::GlobalSystemMediaTransportControlsSessionManager g_manager{nullptr};
HHOOK g_keyboard_hook = nullptr;

/// 上一次「被我们暂停」的会话 AUMID。
///
/// 规则④恢复暂停时优先恢复它 —— 同一个键按两下是「暂停 / 恢复」的往复，
/// 如果去恢复列表里碰巧排在前面的别的应用（比如浏览器里的视频），会很突兀。
std::wstring g_last_paused_aumid;

/// 会话状态用的是 Windows.Media.Control 下的枚举，与自家 SMTC 的
/// `MediaPlaybackStatus` 是两个类型，别混用。
using SessionStatus =
    MediaControl::GlobalSystemMediaTransportControlsSessionPlaybackStatus;

/// 本应用的 AUMID，与 `main.cpp` 里声明的一致
constexpr wchar_t kOurAumid[] = L"com.elia.music.desktop";

struct SessionSnap {
  MediaControl::GlobalSystemMediaTransportControlsSession session{nullptr};
  SessionStatus status{SessionStatus::Closed};
  bool ours = false;
  bool focused = false;
  bool can_play = false;
  bool can_pause = false;
  bool can_next = false;
  bool can_prev = false;
};

std::wstring ToLower(std::wstring s) {
  for (auto& c : s) c = static_cast<wchar_t>(towlower(c));
  return s;
}

/// 这个会话是否「确实有歌可播」。
///
/// 不能只判 `!= Closed` —— Opened / Changing / Stopped 同样属于"没有在放的东西"，
/// 只判 Closed 会把它们当成有歌，于是吞掉媒体键却什么也没发生。
bool HasSong(const SessionSnap& s) {
  return s.status == SessionStatus::Playing ||
         s.status == SessionStatus::Paused;
}

/// 前台窗口所属进程的完整 exe 路径
std::wstring ForegroundProcessPath() {
  HWND fg = ::GetForegroundWindow();
  if (!fg) return {};
  DWORD pid = 0;
  ::GetWindowThreadProcessId(fg, &pid);
  if (!pid) return {};
  HANDLE proc = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!proc) return {};
  wchar_t buf[MAX_PATH * 2]{};
  DWORD size = static_cast<DWORD>(std::size(buf));
  std::wstring path;
  if (::QueryFullProcessImageNameW(proc, 0, buf, &size)) path.assign(buf, size);
  ::CloseHandle(proc);
  return path;
}

/// 会话的 AUMID 是否就是这个 exe。
///
/// 未打包应用的 AUMID 可能是完整 exe 路径，也可能只是 exe 文件名
/// （取决于它怎么注册的），所以两种都比一遍。
bool AumidMatchesExe(const std::wstring& aumid, const std::wstring& exe_path) {
  if (aumid.empty() || exe_path.empty()) return false;
  const std::wstring a = ToLower(aumid);
  const std::wstring b = ToLower(exe_path);
  if (a == b) return true;
  const size_t slash = b.find_last_of(L"\\/");
  const std::wstring base = slash == std::wstring::npos ? b : b.substr(slash + 1);
  return a.size() >= base.size() &&
         a.compare(a.size() - base.size(), base.size(), base) == 0;
}

/// 给钩子里做决策用的一次性快照（`GetSessions()` / `GetPlaybackInfo()` 都是同步的，
/// 可以放心在钩子里调；**不要**在钩子里 await 异步操作）
std::vector<SessionSnap> SnapshotSessions() {
  std::vector<SessionSnap> out;
  if (!g_manager) return out;
  const std::wstring fg_exe = ForegroundProcessPath();
  try {
    for (auto const& s : g_manager.GetSessions()) {
      SessionSnap snap;
      snap.session = s;
      const auto aumid = s.SourceAppUserModelId();
      snap.ours = AumidMatchesExe(kOurAumid, std::wstring(aumid.c_str())) ||
                  std::wstring(aumid.c_str()).find(L"elia_music") !=
                      std::wstring::npos;
      snap.focused = !fg_exe.empty() && AumidMatchesExe(std::wstring(aumid.c_str()), fg_exe);
      try {
        const auto info = s.GetPlaybackInfo();
        snap.status = info.PlaybackStatus();
        const auto controls = info.Controls();
        snap.can_play = controls.IsPlayEnabled();
        snap.can_pause = controls.IsPauseEnabled();
        snap.can_next = controls.IsNextEnabled();
        snap.can_prev = controls.IsPreviousEnabled();
      } catch (const winrt::hresult_error&) {
        // 拿不到播放信息就当作「不可控」，别让它影响决策
      }
      out.push_back(snap);
    }
  } catch (const winrt::hresult_error&) {
  }
  return out;
}

void LogKeyDecision(const char* what, const std::string& detail) {
  if (!g_channel) return;
  EncodableMap payload;
  payload[EncodableValue("event")] = EncodableValue("keylog");
  payload[EncodableValue("what")] = EncodableValue(std::string(what));
  payload[EncodableValue("detail")] = EncodableValue(detail);
  g_channel->InvokeMethod("onEvent", std::make_unique<EncodableValue>(payload));
}

/// 处理一个媒体键。返回 true 表示已接管（吞掉这个键）。
bool HandleMediaKey(DWORD vk) {
  if (!g_manager) return false;
  auto snaps = SnapshotSessions();
  if (snaps.empty()) return false;

  SessionSnap* focused = nullptr;
  SessionSnap* ours = nullptr;
  SessionSnap* playing = nullptr;
  for (auto& s : snaps) {
    if (s.focused && !focused) focused = &s;
    if (s.ours && !ours) ours = &s;
    if (s.status == SessionStatus::Playing && !playing) playing = &s;
  }

  const auto describe = [&]() {
    std::string d = "会话数=" + std::to_string(snaps.size());
    for (auto& s : snaps) {
      d += " [";
      d += s.ours ? "ours" : (s.focused ? "focused" : "other");
      d += "/";
      d += s.status == SessionStatus::Playing ? "playing"
           : s.status == SessionStatus::Paused ? "paused" : "idle";
      // 带上 exe 名，排查时能一眼看出是哪个应用
      std::wstring aumid = s.session.SourceAppUserModelId().c_str();
      const size_t slash = aumid.find_last_of(L"\\/");
      if (slash != std::wstring::npos) aumid = aumid.substr(slash + 1);
      d += " " + winrt::to_string(aumid) + "#" +
           std::to_string(static_cast<int>(s.status)) + "]";
    }
    return d;
  };

  if (vk == VK_MEDIA_PLAY_PAUSE) {
    // ① 有在播的 → 全部暂停，并记住是哪个（下次按播放优先恢复它）
    bool paused_any = false;
    g_last_paused_aumid.clear();
    for (auto& s : snaps) {
      if (s.status == SessionStatus::Playing) {
        if (g_last_paused_aumid.empty()) {
          g_last_paused_aumid = s.session.SourceAppUserModelId().c_str();
        }
        s.session.TryPauseAsync();
        paused_any = true;
      }
    }
    if (paused_any) {
      LogKeyDecision("pause-all", describe());
      return true;
    }

    // ② 焦点窗口那个播放器
    if (focused) {
      if (focused->ours) {
        if (HasSong(*focused)) {
          SendEvent("play");
          LogKeyDecision("play-ours(focused)", describe());
          return true;
        }
      } else if (focused->can_play) {
        focused->session.TryPlayAsync();
        LogKeyDecision("play-focused", describe());
        return true;
      }
    }
    // ③ 我们自己 —— 但要确认自己**确实有东西可播**（status 为 Closed 表示
    //    还没载入任何歌曲）。否则吞掉这个键、却谁也没响应，比不接管更糟。
    if (ours && HasSong(*ours) && ours->can_play) {
      SendEvent("play");
      LogKeyDecision("play-ours", describe());
      return true;
    }
    // ④ 恢复「刚才被我们暂停的那个」；记不住才退回列表里第一个可播的
    for (auto& s : snaps) {
      if (s.status != SessionStatus::Paused || !s.can_play) continue;
      if (!g_last_paused_aumid.empty() &&
          std::wstring(s.session.SourceAppUserModelId().c_str()) !=
              g_last_paused_aumid) {
        continue;
      }
      s.session.TryPlayAsync();
      g_last_paused_aumid.clear();
      LogKeyDecision("play-resume", describe());
      return true;
    }
    for (auto& s : snaps) {
      if (s.status == SessionStatus::Paused && s.can_play) {
        s.session.TryPlayAsync();
        g_last_paused_aumid.clear();
        LogKeyDecision("play-resume(first)", describe());
        return true;
      }
    }
    return false;  // 判断不出来 → 放行
  }

  if (vk == VK_MEDIA_NEXT_TRACK || vk == VK_MEDIA_PREV_TRACK) {
    const bool next = (vk == VK_MEDIA_NEXT_TRACK);
    const auto dispatch = [&](SessionSnap* s) -> bool {
      if (!s) return false;
      if (s->ours) {
        // 自己没载入歌曲时不要吞键：handleEndedAction 会直接返回，
        // 等于这个键被吃掉了却什么都没发生。
        if (!HasSong(*s)) return false;
        SendEvent(next ? "next" : "previous");
        return true;
      }
      if (next ? s->can_next : s->can_prev) {
        if (next) {
          s->session.TrySkipNextAsync();
        } else {
          s->session.TrySkipPreviousAsync();
        }
        return true;
      }
      return false;
    };
    const char* tag = next ? "next" : "prev";
    if (dispatch(focused)) {
      LogKeyDecision(tag, std::string("focused; ") + describe());
      return true;
    }
    if (dispatch(playing)) {
      LogKeyDecision(tag, std::string("playing; ") + describe());
      return true;
    }
    if (dispatch(ours)) {
      LogKeyDecision(tag, std::string("ours; ") + describe());
      return true;
    }
    return false;
  }

  if (vk == VK_MEDIA_STOP) {
    for (auto& s : snaps) {
      if (s.status == SessionStatus::Playing) {
        s.session.TryStopAsync();
        LogKeyDecision("stop", describe());
        return true;
      }
    }
    return false;
  }

  return false;
}

LRESULT CALLBACK MediaKeyHookProc(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HC_ACTION && (wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN)) {
    const auto* info = reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam);
    switch (info->vkCode) {
      case VK_MEDIA_PLAY_PAUSE:
      case VK_MEDIA_NEXT_TRACK:
      case VK_MEDIA_PREV_TRACK:
      case VK_MEDIA_STOP:
        // 处理不了就往下传（`CallNextHookEx`），不要吞
        if (HandleMediaKey(info->vkCode)) return 1;
        break;
      default:
        break;
    }
  }
  return ::CallNextHookEx(g_keyboard_hook, code, wparam, lparam);
}

/// 挂上媒体键钩子（必须在有消息循环的线程上调，也就是平台线程）
void InstallMediaKeyHook() {
  if (!g_manager) {
    try {
      // 会话管理器只取一次；`GetSessions()` 是同步的，钩子里直接用它
      g_manager = MediaControl::GlobalSystemMediaTransportControlsSessionManager::
          RequestAsync()
              .get();
    } catch (const winrt::hresult_error& e) {
      LogKeyDecision("manager-failed", winrt::to_string(e.message()));
      g_manager = nullptr;
    }
  }
  if (!g_keyboard_hook) {
    // 低级键盘钩子：hMod 传 NULL 即可（回调在本进程，不需要注入 DLL）
    g_keyboard_hook = ::SetWindowsHookExW(WH_KEYBOARD_LL, MediaKeyHookProc,
                                          nullptr, 0);
    LogKeyDecision("hook-installed",
                   g_keyboard_hook ? "ok" : "SetWindowsHookEx 失败");
  }
}

void UninstallMediaKeyHook() {
  if (g_keyboard_hook) {
    ::UnhookWindowsHookEx(g_keyboard_hook);
    g_keyboard_hook = nullptr;
  }
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
}

/// 建会话。
///
/// 走 `ISystemMediaTransportControlsInterop::GetForWindow`，把会话挂到窗口上。
/// 这样系统才知道是「谁」在放 —— 媒体面板上显示的就是本应用的名称与图标。
///
/// 另一条路是建一个 `MediaPlayer` 当宿主、取它的 `SystemMediaTransportControls`：
/// 那条路不需要窗口句柄，但**系统认不出调用者**，面板上会显示成「未知应用」
/// （没有合法的窗口句柄时，Windows 拒绝显示调用方信息）。
bool OpenSession() {
  if (g_session.valid()) return true;
  if (!g_hwnd) return false;

  try {
    auto interop = winrt::get_activation_factory<
        Media::SystemMediaTransportControls,
        ISystemMediaTransportControlsInterop>();
    Media::SystemMediaTransportControls smtc{nullptr};
    winrt::check_hresult(interop->GetForWindow(
        g_hwnd, winrt::guid_of<Media::SystemMediaTransportControls>(),
        winrt::put_abi(smtc)));
    if (!smtc) return false;
    g_session.smtc = smtc;

    // 面板上要显示哪些按钮。seek 由进度条承担，不需要快进/快退键。
    smtc.IsPlayEnabled(true);
    smtc.IsPauseEnabled(true);
    smtc.IsNextEnabled(true);
    smtc.IsPreviousEnabled(true);
    smtc.IsStopEnabled(true);
    smtc.PlaybackStatus(Media::MediaPlaybackStatus::Closed);
    smtc.IsEnabled(true);

    // 平台线程是 STA，事件会回到这个线程，所以可以直接往通道里发。
    g_session.button_token = smtc.ButtonPressed(
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
    g_session.seek_token = smtc.PlaybackPositionChangeRequested(
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
///
/// 返回一段状态文本给 Dart 记日志 —— 封面失败是「静默」的，
/// 面板上只是空白，不给回执就没法查。
std::string UpdateThumbnail(const std::vector<uint8_t>& bytes) {
  if (!g_session.valid()) return "no-session";
  if (bytes.empty()) return "empty";
  try {
    Streams::InMemoryRandomAccessStream stream;
    Streams::DataWriter writer(stream);
    writer.WriteBytes(winrt::array_view<const uint8_t>(bytes));
    // 内存流的 Store/Flush 是本地操作，不会回到 UI 线程，.get() 不会死锁；
    // 换成 StorageFile 那种碰文件系统的异步操作就不能这么写了。
    writer.StoreAsync().get();
    writer.FlushAsync().get();
    // 必须 detach：DataWriter 析构时会把自己的输出流关掉，
    // 那样 SMTC 拿到的就是个已经关闭的流。
    writer.DetachStream();
    stream.Seek(0);

    g_session.thumbnail = stream;
    auto updater = g_session.smtc.DisplayUpdater();
    updater.Type(Media::MediaPlaybackType::Music);
    updater.Thumbnail(
        Streams::RandomAccessStreamReference::CreateFromStream(stream));
    updater.Update();
    return "ok:" + std::to_string(bytes.size());
  } catch (const winrt::hresult_error& e) {
    return "fail:" + winrt::to_string(e.message());
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
    const bool ok = OpenSession();
    // 会话建起来之后再挂媒体键钩子：钩子的分派逻辑要读会话状态
    if (ok) InstallMediaKeyHook();
    result->Success(EncodableValue(ok));
    return;
  }
  if (method == "dispose") {
    UninstallMediaKeyHook();
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
      result->Success(EncodableValue(UpdateThumbnail(*bytes)));
    } else {
      result->Success(EncodableValue(std::string("not-bytes")));
    }
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

void RegisterSmtcBridge(flutter::BinaryMessenger* messenger, HWND hwnd) {
  g_hwnd = hwnd;
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "elia/smtc", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(HandleCall);
}
