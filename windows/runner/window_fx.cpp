#include "window_fx.h"

#include <dwmapi.h>
#include <windows.h>

#include <memory>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
HWND g_hwnd = nullptr;

/// 进全屏前的窗口状态。退出时逐项还原 —— 尤其是 `placement.showCmd`（最大化还是正常）
/// 与 `placement.rcNormalPosition`（决定「点最大化再还原」回到哪、什么尺寸）。
struct SavedState {
  LONG_PTR style = 0;
  LONG_PTR ex_style = 0;
  WINDOWPLACEMENT placement{};
  bool valid = false;
};

SavedState g_saved;
bool g_fullscreen = false;

// DWM 圆角（Windows 11 才有；旧系统上调用会失败，忽略即可）
constexpr DWORD kCornerPreferenceAttr = 33;  // DWMWA_WINDOW_CORNER_PREFERENCE
constexpr int kCornerRound = 2;              // DWMWCP_ROUND
constexpr int kCornerDoNotRound = 1;         // DWMWCP_DONOTROUND

void SetRoundedCorners(bool round) {
  if (g_hwnd == nullptr) return;
  int pref = round ? kCornerRound : kCornerDoNotRound;
  ::DwmSetWindowAttribute(g_hwnd, kCornerPreferenceAttr, &pref, sizeof(pref));
}

/// 让 Flutter 的子窗口跟上新的客户区。
///
/// 常规路径上 `win32_window.cpp` 的 `WM_SIZE` 会做这件事，但改窗口样式
/// （`SWP_FRAMECHANGED`）之后那一次尺寸变化不一定发 `WM_SIZE`，
/// 这里显式同步一次，免得画面里残留一块没刷新的区域。
void SyncFlutterView() {
  if (g_hwnd == nullptr) return;
  HWND view = ::FindWindowEx(g_hwnd, nullptr, L"FLUTTERVIEW", nullptr);
  if (view == nullptr) return;
  RECT rect{};
  ::GetClientRect(g_hwnd, &rect);
  ::SetWindowPos(view, nullptr, rect.left, rect.top, rect.right - rect.left,
                 rect.bottom - rect.top, SWP_NOACTIVATE | SWP_NOZORDER);
}

bool EnterFullscreen() {
  if (g_hwnd == nullptr) return false;
  if (g_fullscreen) return true;

  g_saved.style = ::GetWindowLongPtr(g_hwnd, GWL_STYLE);
  g_saved.ex_style = ::GetWindowLongPtr(g_hwnd, GWL_EXSTYLE);
  g_saved.placement.length = sizeof(WINDOWPLACEMENT);
  if (!::GetWindowPlacement(g_hwnd, &g_saved.placement)) return false;
  // 最小化状态下取到的位置没有意义，归一化成「正常」——
  // 否则退出全屏时窗口会以最小化状态回来。
  if (g_saved.placement.showCmd == SW_SHOWMINIMIZED) {
    g_saved.placement.showCmd = SW_SHOWNORMAL;
  }
  g_saved.valid = true;

  HMONITOR monitor = ::MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(MONITORINFO);
  if (!::GetMonitorInfo(monitor, &info)) return false;

  // `WS_POPUP`：没有 `WS_MAXIMIZEBOX` / `WS_THICKFRAME` / 标题栏 ——
  // 系统层面就无法最大化、还原、拖动或贴边分屏，也就不会再把还原尺寸改坏。
  // `WS_EX_APPWINDOW`：popup 窗口默认不进任务栏，补上它保住任务栏按钮。
  //
  // ⚠️⚠️ **这一步同时负责「取消最大化」，不要再调 `ShowWindow(SW_RESTORE)`**：
  // `WS_MAXIMIZE` 是 style 里的一位，整体替换 style 就把它清掉了；而
  // `SetWindowLongPtr` 只改样式、**不重绘也不改尺寸**，紧接着的 `SetWindowPos`
  // 再把位置尺寸一步摆到显示器矩形 —— 两步在同一次重排里完成，
  // 屏幕上不会出现「先缩回正常大小」的中间态。
  // 之前用 `ShowWindow(SW_RESTORE)` 是错的：它会**立刻**把窗口缩回正常尺寸并重绘，
  // 用户看到的就是「先缩小一遍再全屏」。
  ::SetWindowLongPtr(g_hwnd, GWL_STYLE,
                     WS_POPUP | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS);
  ::SetWindowLongPtr(g_hwnd, GWL_EXSTYLE, g_saved.ex_style | WS_EX_APPWINDOW);

  ::SetWindowPos(g_hwnd, HWND_TOP, info.rcMonitor.left, info.rcMonitor.top,
                 info.rcMonitor.right - info.rcMonitor.left,
                 info.rcMonitor.bottom - info.rcMonitor.top,
                 SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
  SyncFlutterView();
  // 全屏贴着屏幕边，圆角会把四个角露出后面的桌面
  SetRoundedCorners(false);
  ::SetForegroundWindow(g_hwnd);
  g_fullscreen = true;
  return true;
}

bool ExitFullscreen() {
  if (g_hwnd == nullptr) return false;
  if (!g_fullscreen) return true;

  ::SetWindowLongPtr(g_hwnd, GWL_STYLE, g_saved.style);
  ::SetWindowLongPtr(g_hwnd, GWL_EXSTYLE, g_saved.ex_style);

  // `SetWindowPlacement` 会把**位置、尺寸和最大化状态**一起恢复 ——
  // 「从全屏退回来仍然是最大化」靠的就是它（不用自己判断再 maximize）。
  if (g_saved.valid) {
    g_saved.placement.length = sizeof(WINDOWPLACEMENT);
    ::SetWindowPlacement(g_hwnd, &g_saved.placement);
  }
  ::SetWindowPos(g_hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);
  SyncFlutterView();
  SetRoundedCorners(true);
  g_fullscreen = false;
  g_saved.valid = false;
  return true;
}

EncodableMap StateMap() {
  EncodableMap out;
  out[EncodableValue("fullscreen")] = EncodableValue(g_fullscreen);
  out[EncodableValue("maximized")] =
      EncodableValue(g_hwnd != nullptr && ::IsZoomed(g_hwnd) != FALSE);
  return out;
}

void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());

  if (method == "setFullscreen") {
    bool value = false;
    if (args != nullptr) {
      const auto it = args->find(EncodableValue("value"));
      if (it != args->end()) {
        if (const auto* b = std::get_if<bool>(&it->second)) value = *b;
      }
    }
    const bool ok = value ? EnterFullscreen() : ExitFullscreen();
    EncodableMap out = StateMap();
    out[EncodableValue("ok")] = EncodableValue(ok);
    result->Success(EncodableValue(out));
    return;
  }

  if (method == "query") {
    EncodableMap out = StateMap();
    out[EncodableValue("ok")] = EncodableValue(true);
    result->Success(EncodableValue(out));
    return;
  }

  // 最大化 / 还原：交给系统自己做（跟自绘标题栏那个按钮同一套语义）。
  // 这里只是不走 Dart 的 window_manager 通道，省一次平台往返。
  if (method == "toggleMaximize") {
    if (g_hwnd == nullptr) {
      result->Success(EncodableValue(false));
      return;
    }
    // 全屏时不给动 —— 那时候窗口是 WS_POPUP，最大化会把它变成一坨。
    if (g_fullscreen) {
      result->Success(EncodableValue(false));
      return;
    }
    if (::IsZoomed(g_hwnd)) {
      ::ShowWindow(g_hwnd, SW_RESTORE);
    } else {
      ::ShowWindow(g_hwnd, SW_MAXIMIZE);
    }
    EncodableMap out = StateMap();
    out[EncodableValue("ok")] = EncodableValue(true);
    result->Success(EncodableValue(out));
    return;
  }

  result->NotImplemented();
}

}  // namespace

void RegisterWindowFx(flutter::BinaryMessenger* messenger, HWND window) {
  g_hwnd = window;
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "elia/window_fx", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(HandleCall);
}

void WindowFxShutdown() {
  g_channel = nullptr;
  g_hwnd = nullptr;
  g_fullscreen = false;
  g_saved = SavedState();
}
