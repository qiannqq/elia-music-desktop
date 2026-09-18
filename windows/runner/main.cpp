#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <dwmapi.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Rounded window corners (Windows 11).
//
// A frameless window is square by default, which looks noticeably sharper than
// the original Electron build. Setting DWMWA_WINDOW_CORNER_PREFERENCE to
// DWMWCP_ROUND makes DWM round the window (and its shadow) natively.
// This is a window-level DWM attribute, so the later SWP_FRAMECHANGED issued by
// window_manager's setAsFrameless() does not clear it.
//
// NOTE: keep this file ASCII-only. MSVC compiles with code page 936 here and
// treats C4819 (unrepresentable characters) as an error, so non-ASCII comments
// break the build unless the file is saved as UTF-8 with BOM.
void EnableRoundedCorners(HWND hwnd) {
  constexpr DWORD kWindowCornerPreference = 33;  // DWMWA_WINDOW_CORNER_PREFERENCE
  constexpr int kRound = 2;                      // DWMWCP_ROUND
  ::DwmSetWindowAttribute(hwnd, kWindowCornerPreference, &kRound, sizeof(kRound));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"elia_music", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Rounded corners; must be applied after the window is created.
  EnableRoundedCorners(window.GetHandle());

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
