#include "window_chrome.h"

namespace chrome {

namespace {

/// 逻辑像素 → 物理像素（按窗口当前 DPI）
int Dp(int value, int dpi) {
  if (dpi <= 0) dpi = 96;
  return ::MulDiv(value, dpi, 96);
}

}  // namespace

int CaptionButtonsLeft(int w, int dpi) {
  return w - Dp(kCaptionButtonWidth * 3, dpi);
}

LRESULT HitTestCode(int x, int y, int w, int h, bool thick_frame, int dpi) {
  // 全屏（WS_POPUP、没有可调边框）：沉浸态没有 chrome，全都交回 Flutter
  if (!thick_frame) return HTCLIENT;

  const int border = Dp(kResizeBorder, dpi);
  const int titlebar = Dp(kTitlebarHeight, dpi);
  const int buttons_left = CaptionButtonsLeft(w, dpi);

  const bool left = x < border;
  const bool right = x >= w - border;
  const bool top = y < border;
  const bool bottom = y >= h - border;

  // 角优先（外圈 6px 里四角要先判，否则会被边吃掉）
  if (top && left) return HTTOPLEFT;
  if (top && right) return HTTOPRIGHT;
  if (bottom && left) return HTBOTTOMLEFT;
  if (bottom && right) return HTBOTTOMRIGHT;
  if (left) return HTLEFT;
  if (right) return HTRIGHT;
  if (top) return HTTOP;
  if (bottom) return HTBOTTOM;

  // 标题栏空白处：交给系统「拖动移动窗口 / 双击最大化」——
  // 那比我们自己 `startDragging()` 更顺，而且双击最大化、贴边分屏都是白送的。
  // ⚠️ 右上角三个按钮那一整片**要留给 Flutter**：它自己画悬停反馈、自己处理点击，
  // 一旦这里返回 HTCAPTION，那些鼠标消息就变成非客户区消息，Flutter 再也收不到，
  // 按钮的悬停变色会当场失灵。
  if (y < titlebar && x < buttons_left) return HTCAPTION;

  return HTCLIENT;
}

}  // namespace chrome
