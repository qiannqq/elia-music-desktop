#include "flutter_window.h"

#include <commctrl.h>  // SetWindowSubclass / DefSubclassProc
#include <optional>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"
#include "audio_probe_bridge.h"
#include "lyric_island.h"
#include "smtc_bridge.h"
#include "system_bridge.h"
#include "window_chrome.h"
#include "window_fx.h"

namespace {

/// Flutter 视图的子类化窗口过程：让**窗口 chrome** 那几块从 Flutter 视角「透明」。
///
/// Flutter 的视图铺满整个客户区，鼠标命中的是**它** —— 顶层窗口永远收不到
/// `WM_NCHITTEST`，于是「拖标题栏移动窗口、双击最大化、四条边拉伸窗口」全都没了
/// （千奈报的「系统缩放边不可用」，从 Flutter 重构起就这样）。
///
/// 这里在 chrome 区域返回 `HTTRANSPARENT`：按 MSDN，同一线程里会继续往下问别的
/// 窗口 —— 于是顶层窗口的 `WM_NCHITTEST` 拿到机会，由它给出真正的
/// `HTLEFT` / `HTTOP` / `HTCAPTION`（见 `window_chrome.cpp`）。
/// 其余地方一律 `HTCLIENT`，Flutter 该收的事件一个不少。
LRESULT CALLBACK FlutterViewProc(HWND hwnd, UINT message, WPARAM wparam,
                                 LPARAM lparam, UINT_PTR id, DWORD_PTR ref) {
  if (message == WM_NCHITTEST) {
    auto* self = reinterpret_cast<FlutterWindow*>(ref);
    HWND top = self != nullptr ? self->GetHandle() : hwnd;
    RECT rect{};
    ::GetClientRect(top, &rect);
    POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    ::ScreenToClient(top, &pt);
    const bool thick =
        (::GetWindowLongPtr(top, GWL_STYLE) & WS_THICKFRAME) != 0;
    const LRESULT code = chrome::HitTestCode(
        pt.x, pt.y, rect.right - rect.left, rect.bottom - rect.top, thick,
        static_cast<int>(::GetDpiForWindow(top)));
    // 不是客户区 → 让系统接着问顶层窗口；是客户区 → 正常交回 Flutter
    return code == HTCLIENT ? HTCLIENT : HTTRANSPARENT;
  }
  if (message == WM_NCDESTROY) {
    ::RemoveWindowSubclass(hwnd, FlutterViewProc, id);
  }
  return ::DefSubclassProc(hwnd, message, wparam, lparam);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterSmtcBridge(flutter_controller_->engine()->messenger(), GetHandle());
  RegisterLyricIsland(flutter_controller_->engine()->messenger(), GetHandle());
  RegisterSystemBridge(flutter_controller_->engine()->messenger());
  RegisterAudioProbe(flutter_controller_->engine()->messenger());
  RegisterWindowFx(flutter_controller_->engine()->messenger(), GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // 子窗口要装子类化窗口过程：窗口 chrome 那几块得从 Flutter 视角「透明」出去，
  // 顶层窗口才有机会回答 WM_NCHITTEST（见 FlutterViewProc 的说明）。
  ::SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                      FlutterViewProc, 1, reinterpret_cast<DWORD_PTR>(this));

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // 通道挂在引擎的 messenger 上，要先拆掉再销毁引擎。
  LyricIslandShutdown();
  WindowFxShutdown();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 自绘标题栏的命中测试：拖标题栏移动窗口、双击最大化、四条边拉伸窗口 —— 全在
  // 这一条上。⚠️ **必须放在 `HandleTopLevelWindowProc` 之前**：那是 window_manager
  // 装在控制器里的钩子（无边框窗口的 `WM_NCCALCSIZE` 那套就在里面），
  // 让它先看到的话，我们就没机会给答案了。
  if (message == WM_NCHITTEST) {
    RECT rect{};
    ::GetClientRect(hwnd, &rect);
    POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    ::ScreenToClient(hwnd, &pt);
    const bool thick = (::GetWindowLongPtr(hwnd, GWL_STYLE) & WS_THICKFRAME) != 0;
    const LRESULT code = chrome::HitTestCode(
        pt.x, pt.y, rect.right - rect.left, rect.bottom - rect.top, thick,
        static_cast<int>(::GetDpiForWindow(hwnd)));
    // 客户区里的事照旧往下走（交给 Flutter）
    if (code != HTCLIENT) return code;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_WINDOWPOSCHANGED: {
      // 主窗口换屏幕时，胶囊还停在原来那块的顶部正中。
      const auto* pos = reinterpret_cast<const WINDOWPOS*>(lparam);
      if (pos != nullptr && (pos->flags & SWP_NOMOVE) == 0) {
        LyricIslandOnHostMoved();
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
