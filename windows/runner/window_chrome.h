#ifndef RUNNER_WINDOW_CHROME_H_
#define RUNNER_WINDOW_CHROME_H_

#include <windows.h>

/// 自绘标题栏 / 无边框窗口的「命中测试」分区。
///
/// 为什么需要它：Flutter 的视图是一个**铺满客户区的子窗口**，鼠标命中的是它 ——
/// 顶层窗口永远收不到 `WM_NCHITTEST`。于是系统的「拖标题栏移动窗口、双击最大化、
/// 四条边拉伸窗口」全都失效（千奈报的「系统缩放边不可用」，从 Flutter 重构起就这样）。
///
/// Win32 自绘标题栏的标准两步：
///   1. **子窗口**（Flutter 视图）在这些区域返回 `HTTRANSPARENT` —— 按 MSDN，
///      同一线程里会继续往下问别的窗口；
///   2. **顶层窗口**收到 `WM_NCHITTEST` 后，在这些区域返回真正的
///      `HTLEFT` / `HTTOP` / `HTCAPTION` …
///
/// 两边必须用同一份几何判断，所以放在这里。
namespace chrome {

/// 拉伸边的宽度（逻辑像素，按窗口 DPI 折算成物理像素）
constexpr int kResizeBorder = 6;

/// 标题栏高度（逻辑像素）—— 必须与 Dart 侧的 `kTitlebarHeight` 一致
constexpr int kTitlebarHeight = 32;

/// 一个窗口按钮的宽度（逻辑像素）—— 与 Dart 侧 `kWindowButtonWidth` 一致。
/// 右上角那三个按钮所在的一整片要**留给 Flutter**（它自己画悬停、自己处理点击）。
constexpr int kCaptionButtonWidth = 40;

/// 返回该点应该给的 `WM_NCHITTEST` 结果。
///
/// [x] / [y] 是**客户区坐标**（物理像素），[w] / [h] 是客户区尺寸，
/// [dpi] 传窗口自己的 DPI（`GetDpiForWindow`）—— 里面的 6px / 32px 是逻辑值。
/// [thick_frame] 为假（全屏那种 `WS_POPUP`）时一律返回 `HTCLIENT` ——
/// 全屏是沉浸态，不该有拉伸边，标题栏也不画。
LRESULT HitTestCode(int x, int y, int w, int h, bool thick_frame, int dpi);

/// 右上角三个窗口按钮所覆盖的 x 区间起点（客户区坐标，物理像素）
int CaptionButtonsLeft(int w, int dpi);

}  // namespace chrome

#endif  // RUNNER_WINDOW_CHROME_H_
