#include "lyric_island.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <gdiplus.h>
#include <objidl.h>
#include <shellscalingapi.h>

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "shcore.lib")
#pragma comment(lib, "ole32.lib")

// 桌面顶部的歌词胶囊。
//
// 不另起 Flutter engine：资源路径一旦相对着进程工作目录找，
// 第二个引擎会找不到 data\flutter_assets，窗口就是一块空白。
// 这里用 GDI+ 画进 32 位 DIB，再 UpdateLayeredWindow。胶囊以外 alpha 为 0。
//
// 逐字进度不跟播放器的位置事件走。Dart 只在拖动进度时校正一次锚点，
// 两帧之间用 GetTickCount64 把时间补上。
//
// 缩起和展开改的是胶囊真实的宽高，不做整体缩放 —— 缩放会把圆角和字号
// 一起拉扁，看起来像被压过。文字始终按原尺寸画，靠胶囊自己裁。

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace Gdiplus;

constexpr UINT_PTR kAnimTimer = 1;

/// 逐字高亮的两端颜色，取深色主题的 textTertiary 与 accent ——
/// 胶囊底色本来就是深的，用浅色主题那对（accent 是深蓝）会糊在底上。
constexpr BYTE kIdleR = 112, kIdleG = 112, kIdleB = 112;

/// 逐字高亮色。初值就是深色主题的 accent（`#60CDFF`），
/// 用户改了主题色之后由 Dart 经 `accent` 方法推过来覆盖。
BYTE g_hot_r = 96, g_hot_g = 205, g_hot_b = 255;

/// 翻译的灰。应用里翻译用的是 textTertiary，在深色底上偏暗；
/// 这里提亮一档：能看清，又压得住，不会把原词盖过去。
constexpr BYTE kTransGray = 153;

/// 换行时上下平移的时长（秒）。
///
/// 与应用内播放栏的 400ms 对齐。原先的 230ms 只有它的一半多，
/// 同样的位移走得更快，看起来就是被弹了一下。
constexpr float kSlideSeconds = 0.4f;

/// 指数逼近的速率（每秒吃掉剩余距离的比例）。
///
/// 动画一律按**真实经过的时间**推进，不用「每帧固定走一步」——
/// 这个重绘跑在平台线程上，Flutter 一滚动它就会漏帧；
/// 固定步长下漏帧 = 动画变慢且一顿一顿，按 dt 算则只是少画几帧。
constexpr float kPresenceRate = 11.f;
constexpr float kSizeRate = 17.f;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
HWND g_host = nullptr;
HWND g_hwnd = nullptr;
ULONG_PTR g_gdi_token = 0;
bool g_gdi = false;

bool g_enabled = false;
bool g_timer = false;
bool g_playing = false;
bool g_have_live = false;
bool g_measured = false;
bool g_swapping = false;
bool g_has_queue = false;
bool g_hover = false;

float g_presence = 0.f;
float g_w = 0.f;
float g_h = 0.f;
float g_target_w = 0.f;
float g_target_h = 0.f;
int g_dpi = 96;

int64_t g_position_ms = 0;
ULONGLONG g_position_tick = 0;

RECT g_full_hit{};
RECT g_latch{};

struct Word {
  int64_t t = 0;
  int64_t d = 0;
  std::wstring text;
  float width = 0.f;
};

struct Line {
  std::wstring text;
  std::wstring trans;
  std::vector<Word> words;
  int64_t start_ms = 0;
  int64_t end_ms = 0;
  bool sweep = false;
  float text_w = 0.f;
  float trans_w = 0.f;
};

struct Snapshot {
  std::string song;
  Line line;
};

Snapshot g_live;
Snapshot g_queue;

/// 上一句。换行时它往上走，新句从下面进来 —— 与应用内播放栏一致。
Line g_prev;
bool g_have_prev = false;
float g_slide = 1.f;
int64_t g_prev_ms = 0;

std::string g_cover_song;
std::unique_ptr<Bitmap> g_cover;

int Dp(int px) { return MulDiv(px, g_dpi, 96); }

float Smooth(float t) {
  if (t < 0.f) t = 0.f;
  if (t > 1.f) t = 1.f;
  return t * t * (3.f - 2.f * t);
}

/// 上下平移的缓出，与应用内播放栏滚动用的 `easeOutCubic` 一致。
float SlideEase(float t) {
  if (t < 0.f) t = 0.f;
  if (t > 1.f) t = 1.f;
  const float u = 1.f - t;
  return 1.f - u * u * u;
}

BYTE Alpha(int base, float a) {
  int v = static_cast<int>(base * a);
  if (v < 0) v = 0;
  if (v > 255) v = 255;
  return static_cast<BYTE>(v);
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                                     nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

const EncodableMap* ArgsOf(const flutter::MethodCall<EncodableValue>& call) {
  return std::get_if<EncodableMap>(call.arguments());
}

std::string GetString(const EncodableMap* args, const char* key) {
  if (!args) return {};
  const auto it = args->find(EncodableValue(key));
  if (it == args->end()) return {};
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? *s : std::string();
}

bool GetBool(const EncodableMap* args, const char* key) {
  if (!args) return false;
  const auto it = args->find(EncodableValue(key));
  if (it == args->end()) return false;
  const auto* v = std::get_if<bool>(&it->second);
  return v && *v;
}

int64_t GetInt(const EncodableMap* args, const char* key) {
  if (!args) return 0;
  const auto it = args->find(EncodableValue(key));
  if (it == args->end()) return 0;
  if (const auto* v = std::get_if<int32_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<int64_t>(&it->second)) return *v;
  return 0;
}

const WCHAR* Face() {
  FontFamily yahei(L"Microsoft YaHei UI");
  if (yahei.GetLastStatus() == Ok) return L"Microsoft YaHei UI";
  return L"Segoe UI";
}

struct Screen {
  RECT rc{};
  int dpi = 96;
};

Screen HostScreen() {
  Screen s;
  s.rc.right = GetSystemMetrics(SM_CXSCREEN);
  s.rc.bottom = GetSystemMetrics(SM_CYSCREEN);
  HMONITOR mon = nullptr;
  if (g_host && IsWindow(g_host)) {
    mon = MonitorFromWindow(g_host, MONITOR_DEFAULTTONEAREST);
  }
  if (!mon) {
    POINT origin{0, 0};
    mon = MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
  }
  MONITORINFO mi{sizeof(mi)};
  if (mon && GetMonitorInfoW(mon, &mi)) s.rc = mi.rcMonitor;
  UINT dpi_x = 96, dpi_y = 96;
  if (mon && SUCCEEDED(GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y)) &&
      dpi_x > 0) {
    s.dpi = static_cast<int>(dpi_x);
  }
  return s;
}

void AddCapsule(GraphicsPath* path, const RectF& rc) {
  const float d = rc.Height;
  if (rc.Width <= d + 0.5f) {
    path->AddEllipse(rc);
    return;
  }
  path->AddArc(rc.X, rc.Y, d, d, 90.f, 180.f);
  path->AddArc(rc.GetRight() - d, rc.Y, d, d, 270.f, 180.f);
  path->CloseFigure();
}

void AddRoundedRect(GraphicsPath* path, const RectF& rc, float radius) {
  float r = radius;
  if (r > rc.Width / 2.f) r = rc.Width / 2.f;
  if (r > rc.Height / 2.f) r = rc.Height / 2.f;
  const float d = r * 2.f;
  if (d <= 1.f) {
    path->AddRectangle(rc);
    return;
  }
  path->AddArc(rc.X, rc.Y, d, d, 180.f, 90.f);
  path->AddArc(rc.GetRight() - d, rc.Y, d, d, 270.f, 90.f);
  path->AddArc(rc.GetRight() - d, rc.GetBottom() - d, d, d, 0.f, 90.f);
  path->AddArc(rc.X, rc.GetBottom() - d, d, d, 90.f, 90.f);
  path->CloseFigure();
}

int64_t Playhead() {
  if (!g_playing) return g_position_ms;
  return g_position_ms + static_cast<int64_t>(GetTickCount64() - g_position_tick);
}

void NoteClock(int64_t ms) {
  g_position_ms = ms;
  g_position_tick = GetTickCount64();
}

float MeasureText(Graphics& g, Font& font, const std::wstring& s) {
  if (s.empty()) return 0.f;
  StringFormat fmt;
  fmt.SetFormatFlags(StringFormatFlagsNoWrap | StringFormatFlagsMeasureTrailingSpaces);
  RectF box;
  g.MeasureString(s.c_str(), static_cast<INT>(s.size()), &font, PointF(0.f, 0.f), &fmt,
                  &box);
  return std::max(0.f, box.Width);
}

void MeasureWords(Graphics& g, Font& font, Line* line) {
  const int n = static_cast<int>(line->words.size());
  if (n <= 0) {
    line->text_w = MeasureText(g, font, line->text);
    return;
  }

  std::vector<int> starts(static_cast<size_t>(n));
  std::vector<int> counts(static_cast<size_t>(n));
  int pos = 0;
  for (int i = 0; i < n; ++i) {
    starts[static_cast<size_t>(i)] = pos;
    counts[static_cast<size_t>(i)] =
        static_cast<int>(line->words[static_cast<size_t>(i)].text.size());
    pos += counts[static_cast<size_t>(i)];
  }

  bool ok = pos > 0;
  StringFormat fmt;
  fmt.SetFormatFlags(StringFormatFlagsNoWrap | StringFormatFlagsMeasureTrailingSpaces);
  const RectF layout(0.f, 0.f, 10000.f, 400.f);
  for (int base = 0; ok && base < n;) {
    const int batch = std::min(32, n - base);
    CharacterRange ranges[32];
    for (int i = 0; i < batch; ++i) {
      const size_t k = static_cast<size_t>(base + i);
      ranges[i] = CharacterRange(starts[k], std::max(counts[k], 0));
    }
    if (fmt.SetMeasurableCharacterRanges(batch, ranges) != Ok) {
      ok = false;
      break;
    }
    Region regions[32];
    if (g.MeasureCharacterRanges(line->text.c_str(), static_cast<INT>(line->text.size()),
                                 &font, layout, &fmt, batch, regions) != Ok) {
      ok = false;
      break;
    }
    for (int i = 0; i < batch; ++i) {
      RectF bounds;
      regions[i].GetBounds(&bounds, &g);
      line->words[static_cast<size_t>(base + i)].width = std::max(0.f, bounds.Width);
    }
    base += batch;
  }

  if (!ok) {
    for (Word& w : line->words) w.width = MeasureText(g, font, w.text);
  } else {
    for (Word& w : line->words) {
      if (w.width < 0.5f && !w.text.empty()) w.width = MeasureText(g, font, w.text);
    }
  }

  float total = 0.f;
  for (const Word& w : line->words) total += w.width;
  line->text_w = total > 0.f ? total : MeasureText(g, font, line->text);
}

void MeasureLine(Line* line) {
  if (line->text.empty() && line->trans.empty()) {
    line->text_w = 0.f;
    line->trans_w = 0.f;
    return;
  }
  Bitmap bmp(1, 1, PixelFormat32bppPARGB);
  Graphics g(&bmp);
  g.SetTextRenderingHint(TextRenderingHintAntiAlias);
  g.SetPageUnit(UnitPixel);
  FontFamily family(Face());
  if (family.GetLastStatus() != Ok) return;
  Font lyric(&family, static_cast<REAL>(Dp(20)), FontStyleRegular, UnitPixel);
  Font trans(&family, static_cast<REAL>(Dp(12)), FontStyleRegular, UnitPixel);
  MeasureWords(g, lyric, line);
  line->trans_w = MeasureText(g, trans, line->trans);
}

struct Box {
  float w;
  float h;
};

bool ShowCover() {
  return g_cover && g_cover_song == g_live.song && g_cover->GetWidth() > 0 &&
         g_cover->GetLastStatus() == Ok;
}

float BlockHeight(const Line& line) {
  float h = static_cast<float>(Dp(26));
  if (!line.trans.empty()) h += static_cast<float>(Dp(18));
  return h;
}

Box LayoutOf(const Line& line, bool cover, float max_w) {
  const float pad_x = static_cast<float>(Dp(20));
  const float pad_y = static_cast<float>(Dp(8));
  const float cover_d = cover ? static_cast<float>(Dp(44)) : 0.f;
  const float gap = cover ? static_cast<float>(Dp(12)) : 0.f;
  const float text_w = std::max(line.text_w, line.trans_w);
  const float inner_h = std::max(BlockHeight(line), cover_d);
  Box box;
  box.h = std::max(inner_h + pad_y * 2.f, static_cast<float>(Dp(48)));
  box.w = pad_x + text_w + gap + cover_d + pad_x;
  // 下限比高还宽一些：很短的一句也不该变成一个圆球。
  const float min_w = std::max(static_cast<float>(Dp(132)), box.h);
  if (box.w < min_w) box.w = min_w;
  if (max_w > min_w && box.w > max_w) box.w = max_w;
  return box;
}

void RecomputeTarget() {
  const Screen screen = HostScreen();
  g_dpi = screen.dpi;
  const float max_w = static_cast<float>(screen.rc.right - screen.rc.left - Dp(64));
  const bool cover = ShowCover();
  const Box box = LayoutOf(g_live.line, cover, max_w);
  g_target_w = box.w;
  g_target_h = box.h;
  if (g_w < 1.f) {
    g_w = g_target_w;
    g_h = g_target_h;
  }
}

void EnsureMeasure() {
  const Screen screen = HostScreen();
  if (screen.dpi != g_dpi) g_measured = false;
  if (g_measured) return;
  g_dpi = screen.dpi;
  MeasureLine(&g_live.line);
  g_measured = true;
  RecomputeTarget();
}

/// 这个字唱到几分了（0~1）。与应用内一致：按字自己的时长插值，
/// 时长过短时给个下限，否则一闪而过还是像硬切。
float WordProgress(const Word& w, int64_t now) {
  const int64_t dur = w.d < 120 ? 120 : w.d;
  const float t = static_cast<float>(now - w.t) / static_cast<float>(dur);
  if (t < 0.f) return 0.f;
  if (t > 1.f) return 1.f;
  return t;
}

Color LerpColor(BYTE r1, BYTE g1, BYTE b1, BYTE r2, BYTE g2, BYTE b2, float t) {
  const auto mix = [t](BYTE a, BYTE b) {
    return static_cast<BYTE>(a + (static_cast<float>(b) - a) * t);
  };
  return Color(255, mix(r1, r2), mix(g1, g2), mix(b1, b2));
}

void DrawWord(Graphics& g, Font& font, const std::wstring& text, const RectF& rc,
              StringFormat& fmt, Brush* brush) {
  if (text.empty()) return;
  g.DrawString(text.c_str(), static_cast<INT>(text.size()), &font, rc, &fmt, brush);
}

/// [dy] 是这一行整体上下的位移，换行时用它做平移切换。
void DrawLine(Graphics& g, Font& lyric, Font& trans, const Line& line, const RectF& column,
              float alpha, int64_t now, float dy) {
  if (line.text.empty() || alpha < 0.02f) return;

  const float lh = static_cast<float>(Dp(26));
  const float block = BlockHeight(line);
  const float top = column.Y + std::max(0.f, (column.Height - block) / 2.f) + dy;
  const bool overflow = line.text_w > column.Width + 0.5f;
  // 放不下就从左边开始排，右边被胶囊裁掉；放得下就居中。
  const float x = overflow ? column.X : column.X + (column.Width - line.text_w) / 2.f;

  StringFormat fmt;
  fmt.SetAlignment(StringAlignmentNear);
  fmt.SetLineAlignment(StringAlignmentCenter);
  fmt.SetFormatFlags(StringFormatFlagsNoWrap);
  fmt.SetTrimming(StringTrimmingNone);

  const bool karaoke = line.sweep && !line.words.empty();

  if (!karaoke) {
    // 没有逐字时间：整句直接用高亮色，与应用内选中行的处理一致。
    SolidBrush br(Color(Alpha(255, alpha), g_hot_r, g_hot_g, g_hot_b));
    const RectF rc(x, top, std::max(line.text_w, 1.f), lh);
    DrawWord(g, lyric, line.text, rc, fmt, &br);
  } else {
    float pen = x;
    for (const Word& w : line.words) {
      if (w.text.empty() || w.width <= 0.f) continue;
      // 逐字只做一件事：这个字从暗色渐变到高亮色，走完就停在那儿。
      // 不描边、不加光晕 —— 加亮之外的任何效果都会让「正在唱的这个字」
      // 看起来和前面已经唱完的字不一样亮。
      const float t = WordProgress(w, now);
      const Color col = LerpColor(kIdleR, kIdleG, kIdleB, g_hot_r, g_hot_g, g_hot_b, t);
      SolidBrush brush(Color(Alpha(255, alpha), col.GetR(), col.GetG(), col.GetB()));
      const RectF rc(pen, top, w.width + 2.f, lh);
      DrawWord(g, lyric, w.text, rc, fmt, &brush);
      pen += w.width;
    }
  }

  if (line.trans.empty()) return;
  SolidBrush br(Color(Alpha(255, alpha), kTransGray, kTransGray, kTransGray));
  const float tw = line.trans_w;
  const float tx = tw > column.Width ? column.X : column.X + (column.Width - tw) / 2.f;
  const RectF rc(tx, top + lh + static_cast<float>(Dp(1)), std::max(tw, 1.f),
                 static_cast<float>(Dp(16)));
  g.DrawString(line.trans.c_str(), static_cast<INT>(line.trans.size()), &trans, rc, &fmt,
               &br);
}

void FadeBits(void* bits, int count, float a) {
  if (a >= 0.999f) return;
  auto* p = static_cast<BYTE*>(bits);
  int ia = static_cast<int>(a * 256.f);
  if (ia < 0) ia = 0;
  if (ia > 256) ia = 256;
  for (int i = 0; i < count; ++i) {
    p[0] = static_cast<BYTE>((p[0] * ia) >> 8);
    p[1] = static_cast<BYTE>((p[1] * ia) >> 8);
    p[2] = static_cast<BYTE>((p[2] * ia) >> 8);
    p[3] = static_cast<BYTE>((p[3] * ia) >> 8);
    p += 4;
  }
}

void Paint() {
  if (!g_hwnd || g_presence <= 0.01f) return;
  if (g_live.line.text.empty()) return;

  EnsureMeasure();
  const Screen screen = HostScreen();
  g_dpi = screen.dpi;

  const int margin = Dp(20);
  const float k = Smooth(g_presence);
  // 收起时缩成一小条，展开时按真实内容撑开 —— 不做整体缩放，
  // 否则圆角和字号会被一起压扁。
  //
  // 这里必须用**缓动中的** g_w / g_h，不能用 g_target_*：
  // 目标值是换行那一瞬间就跳过去的，拿它算等于把伸缩动画抹掉。
  const float col_w = static_cast<float>(Dp(56));
  const float col_h = static_cast<float>(Dp(26));
  int pill_w = static_cast<int>(std::lround(col_w + (g_w - col_w) * k));
  int pill_h = static_cast<int>(std::lround(col_h + (g_h - col_h) * k));
  if (pill_w < static_cast<int>(col_w)) pill_w = static_cast<int>(col_w);
  if (pill_h < static_cast<int>(col_h)) pill_h = static_cast<int>(col_h);

  const int win_w = pill_w + margin * 2;
  const int win_h = pill_h + margin * 2;
  const int mon_w = screen.rc.right - screen.rc.left;
  const int x = screen.rc.left + (mon_w - win_w) / 2;
  const int y = screen.rc.top + Dp(8) - margin;

  g_full_hit.left = x + margin;
  g_full_hit.top = y + margin;
  g_full_hit.right = g_full_hit.left + pill_w;
  g_full_hit.bottom = g_full_hit.top + pill_h;

  // 内容先退场，胶囊再收完 —— 收到一半字被切一半最难看。
  const float content = std::clamp((k - 0.35f) / 0.65f, 0.f, 1.f);

  HDC screen_dc = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen_dc);
  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = win_w;
  bmi.bmiHeader.biHeight = -win_h;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP dib = CreateDIBSection(screen_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!dib || !bits) {
    DeleteDC(mem);
    ReleaseDC(nullptr, screen_dc);
    return;
  }
  HGDIOBJ old = SelectObject(mem, dib);

  {
    Bitmap bmp(win_w, win_h, win_w * 4, PixelFormat32bppPARGB, static_cast<BYTE*>(bits));
    Graphics g(&bmp);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    g.SetPixelOffsetMode(PixelOffsetModeHalf);
    g.SetCompositingMode(CompositingModeSourceOver);
    g.SetCompositingQuality(CompositingQualityHighQuality);
    g.SetTextRenderingHint(TextRenderingHintAntiAlias);
    g.SetPageUnit(UnitPixel);
    g.Clear(Color(0, 0, 0, 0));

    const RectF pill(static_cast<REAL>(margin), static_cast<REAL>(margin),
                     static_cast<REAL>(pill_w), static_cast<REAL>(pill_h));

    RectF shadow = pill;
    shadow.Y += static_cast<REAL>(Dp(3));
    shadow.Inflate(static_cast<REAL>(Dp(2)), static_cast<REAL>(Dp(1)));
    GraphicsPath shadow_path;
    AddCapsule(&shadow_path, shadow);
    SolidBrush shadow_brush(Color(72, 0, 0, 0));
    g.FillPath(&shadow_brush, &shadow_path);

    GraphicsPath path;
    AddCapsule(&path, pill);
    SolidBrush fill(Color(242, 28, 28, 30));
    g.FillPath(&fill, &path);
    Pen edge(Color(48, 255, 255, 255), 1.f);
    edge.SetAlignment(PenAlignmentInset);
    g.DrawPath(&edge, &path);

    const GraphicsState content_state = g.Save();
    g.SetClip(&path);

    const float pad_x = static_cast<float>(Dp(20));
    const float pad_y = static_cast<float>(Dp(8));
    const bool cover = ShowCover() && content > 0.6f;
    const float cover_d = cover ? static_cast<float>(Dp(44)) : 0.f;
    const float gap = cover ? static_cast<float>(Dp(12)) : 0.f;
    const RectF column(pill.X + pad_x, pill.Y + pad_y,
                       std::max(8.f, pill.Width - pad_x * 2.f - gap - cover_d),
                       std::max(8.f, pill.Height - pad_y * 2.f));

    FontFamily family(Face());
    if (family.GetLastStatus() == Ok) {
      Font lyric(&family, static_cast<REAL>(Dp(20)), FontStyleRegular, UnitPixel);
      Font trans(&family, static_cast<REAL>(Dp(12)), FontStyleRegular, UnitPixel);
      // 换行时旧句往上走、新句从下面进来。平移量取「刚好走完一整块」——
      // 少了会在胶囊边上留半行残影，多了则是白白多等一截。
      const float block = BlockHeight(g_live.line);
      const float inner = std::max(8.f, pill.Height - pad_y * 2.f);
      const float travel = (block + inner) / 2.f;
      if (g_have_prev && g_slide < 1.f) {
        const float slide = SlideEase(g_slide);
        DrawLine(g, lyric, trans, g_prev, column, content, g_prev_ms, -travel * slide);
        DrawLine(g, lyric, trans, g_live.line, column, content, Playhead(),
                 travel * (1.f - slide));
      } else {
        DrawLine(g, lyric, trans, g_live.line, column, content, Playhead(), 0.f);
      }
    }

    if (cover) {
      const float cd = cover_d * (0.7f + 0.3f * content);
      const RectF cvr(pill.GetRight() - pad_x - cover_d,
                      pill.Y + (pill.Height - cover_d) / 2.f, cover_d, cover_d);
      const RectF scaled(cvr.X + (cvr.Width - cd) / 2.f, cvr.Y + (cvr.Height - cd) / 2.f,
                         cd, cd);
      GraphicsPath clip;
      AddRoundedRect(&clip, scaled, static_cast<float>(Dp(10)));
      const GraphicsState saved = g.Save();
      g.SetClip(&clip, CombineModeIntersect);
      g.SetInterpolationMode(InterpolationModeHighQualityBicubic);
      // 从源图里取居中的正方形再填进来。B站的封面常是 16:9 的横幅，
      // 直接按目标框拉伸会把画面压扁。
      const int iw = static_cast<int>(g_cover->GetWidth());
      const int ih = static_cast<int>(g_cover->GetHeight());
      const int side = iw < ih ? iw : ih;
      const int sx = (iw - side) / 2;
      const int sy = (ih - side) / 2;
      // 源矩形那几个参数显式转成 REAL：直接传 int 会匹配到 REAL 的重载，
      // 而本目标是 /WX，C4244 会直接把编译拦下。
      g.DrawImage(g_cover.get(), scaled, static_cast<REAL>(sx), static_cast<REAL>(sy),
                  static_cast<REAL>(side), static_cast<REAL>(side), UnitPixel);
      g.Restore(saved);
      Pen ring(Color(Alpha(56, content), 255, 255, 255), 1.f);
      GraphicsPath outline;
      AddRoundedRect(&outline, scaled, static_cast<float>(Dp(10)));
      g.DrawPath(&ring, &outline);
    }

    g.Restore(content_state);
  }

  FadeBits(bits, win_w * win_h, content);

  POINT dst{x, y};
  SIZE size{win_w, win_h};
  POINT src{0, 0};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(g_hwnd, screen_dc, &dst, &size, mem, &src, 0, &blend, ULW_ALPHA);

  SelectObject(mem, old);
  DeleteObject(dib);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen_dc);

  if (!IsWindowVisible(g_hwnd)) {
    ShowWindow(g_hwnd, SW_SHOWNOACTIVATE);
    SetWindowPos(g_hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  }
}

void StopTimer() {
  if (g_timer && g_hwnd) KillTimer(g_hwnd, kAnimTimer);
  g_timer = false;
}

bool WantShow() {
  if (!g_enabled || g_hover || g_swapping || !g_playing) return false;
  return !g_live.line.text.empty();
}

bool NeedTimer() {
  if (!g_enabled || !g_hwnd) return false;
  if (g_hover || g_swapping) return true;
  if (g_presence > 0.01f || WantShow()) return true;
  if (std::fabs(g_w - g_target_w) > 0.8f || std::fabs(g_h - g_target_h) > 0.8f) {
    return true;
  }
  return false;
}

void StartTimer() {
  if (g_timer || !g_hwnd) return;
  SetTimer(g_hwnd, kAnimTimer, 16, nullptr);
  g_timer = true;
}

void UpdateHover() {
  POINT pt;
  if (!GetCursorPos(&pt)) return;
  if (!g_hover) {
    if (g_presence < 0.85f) return;
    if (g_full_hit.right <= g_full_hit.left) return;
    if (PtInRect(&g_full_hit, pt)) {
      g_hover = true;
      g_latch = g_full_hit;
    }
    return;
  }
  // 胶囊一缩，光标就「不在上面了」，会立刻弹回来 —— 记住离开前那一块。
  if (!PtInRect(&g_latch, pt)) g_hover = false;
}

void CommitQueue() {
  g_live = g_queue;
  g_has_queue = false;
  g_swapping = false;
  g_have_live = true;
  g_measured = false;
  // 换歌时胶囊本身正在展开，这一句不再另外平移一次。
  g_have_prev = false;
  g_slide = 1.f;
  g_w = 0.f;
  g_h = 0.f;
}

void Step() {
  UpdateHover();
  if (g_swapping && g_has_queue && g_presence < 0.03f) CommitQueue();

  if (g_have_prev && g_slide < 1.f) {
    g_slide += kSlideStep;
    if (g_slide >= 1.f) {
      g_slide = 1.f;
      g_have_prev = false;
    }
  }

  EnsureMeasure();
  const float target = WantShow() ? 1.f : 0.f;
  const float pd = target - g_presence;
  if (std::fabs(pd) < 0.012f) {
    g_presence = target;
  } else {
    g_presence += pd * 0.17f;
  }

  const float wd = g_target_w - g_w;
  if (std::fabs(wd) < 0.8f) g_w = g_target_w;
  else g_w += wd * 0.24f;
  const float hd = g_target_h - g_h;
  if (std::fabs(hd) < 0.8f) g_h = g_target_h;
  else g_h += hd * 0.24f;

  if (g_presence > 0.01f) {
    Paint();
  } else if (g_hwnd && IsWindowVisible(g_hwnd)) {
    ShowWindow(g_hwnd, SW_HIDE);
  }

  if (!NeedTimer()) StopTimer();
}

void EnsureWindow() {
  if (g_hwnd) return;
  WNDCLASSEXW wc{sizeof(wc)};
  wc.lpfnWndProc = [](HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) -> LRESULT {
    if (msg == WM_TIMER && wp == kAnimTimer) {
      Step();
      return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  };
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"EliaLyricIsland";
  RegisterClassExW(&wc);

  // TRANSPARENT：点击直接落到下面的窗口。悬浮消失靠轮询光标，不靠鼠标消息。
  g_hwnd = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
          WS_EX_TRANSPARENT,
      L"EliaLyricIsland", L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, wc.hInstance,
      nullptr);
}

Snapshot Parse(const EncodableMap* args) {
  Snapshot snap;
  snap.song = GetString(args, "song");
  snap.line.text = Utf8ToWide(GetString(args, "text"));
  snap.line.trans = Utf8ToWide(GetString(args, "trans"));
  snap.line.sweep = GetBool(args, "sweep");
  snap.line.start_ms = GetInt(args, "startMs");
  snap.line.end_ms = GetInt(args, "endMs");
  if (args) {
    const auto it = args->find(EncodableValue("words"));
    if (it != args->end()) {
      if (const auto* list = std::get_if<EncodableList>(&it->second)) {
        for (const EncodableValue& item : *list) {
          const auto* m = std::get_if<EncodableMap>(&item);
          if (!m) continue;
          Word w;
          w.t = GetInt(m, "t");
          w.d = GetInt(m, "d");
          w.text = Utf8ToWide(GetString(m, "s"));
          if (w.text.empty()) continue;
          snap.line.words.push_back(std::move(w));
        }
      }
    }
  }
  // 逐字的宽度是按这些字拼起来量的，画的也必须是同一串。
  if (!snap.line.words.empty()) {
    snap.line.text.clear();
    for (const Word& w : snap.line.words) snap.line.text += w.text;
  }
  return snap;
}

void ApplyLine(const Snapshot& next) {
  if (!g_have_live) {
    g_live = next;
    g_have_live = true;
    g_have_prev = false;
    g_slide = 1.f;
    g_measured = false;
    return;
  }
  // 暂停时 Dart 会送一个空句子。胶囊正在退场，屏幕上还留着上一句。
  if (next.line.text.empty() && next.song == g_live.song) return;

  const bool changed =
      next.line.text != g_live.line.text || next.line.trans != g_live.line.trans;
  if (changed) {
    // 上一句留着往上走。位置也一起冻住 —— 平移期间进度还在走，
    // 不冻的话旧句会在往上飞的时候继续高亮。
    g_prev = g_live.line;
    g_prev_ms = Playhead();
    g_have_prev = true;
    g_slide = 0.f;
  }
  g_live.song = next.song;
  g_live.line = next.line;
  g_measured = false;
}

void OnUpdate(const EncodableMap* args) {
  NoteClock(GetInt(args, "positionMs"));
  g_playing = GetBool(args, "playing");
  const Snapshot next = Parse(args);
  if (g_swapping && g_has_queue) {
    g_queue = next;
    return;
  }
  if (g_have_live && next.song != g_live.song && g_presence > 0.04f) {
    g_queue = next;
    g_has_queue = true;
    g_swapping = true;
    return;
  }
  ApplyLine(next);
}

std::unique_ptr<Bitmap> LoadImage(const std::vector<uint8_t>& bytes) {
  if (bytes.empty()) return nullptr;
  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (!mem) return nullptr;
  void* dest = GlobalLock(mem);
  if (!dest) {
    GlobalFree(mem);
    return nullptr;
  }
  memcpy(dest, bytes.data(), bytes.size());
  GlobalUnlock(mem);
  IStream* stream = nullptr;
  if (FAILED(CreateStreamOnHGlobal(mem, TRUE, &stream))) {
    GlobalFree(mem);
    return nullptr;
  }
  Bitmap src(stream, FALSE);
  std::unique_ptr<Bitmap> copy;
  if (src.GetLastStatus() == Ok && src.GetWidth() > 0 && src.GetHeight() > 0) {
    copy.reset(src.Clone(0, 0, src.GetWidth(), src.GetHeight(), PixelFormat32bppPARGB));
  }
  stream->Release();
  if (copy && copy->GetLastStatus() != Ok) copy.reset();
  return copy;
}

void OnCover(const EncodableMap* args) {
  const std::string song = GetString(args, "song");
  std::vector<uint8_t> bytes;
  if (args) {
    const auto it = args->find(EncodableValue("bytes"));
    if (it != args->end()) {
      if (const auto* v = std::get_if<std::vector<uint8_t>>(&it->second)) bytes = *v;
    }
  }
  g_cover_song = song;
  g_cover = LoadImage(bytes);
  g_measured = false;
}

void SetEnabled(bool on) {
  g_enabled = on;
  if (!on) {
    g_hover = false;
    return;
  }
  if (!g_gdi) return;
  EnsureWindow();
}

void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto& method = call.method_name();
  const auto* args = ArgsOf(call);
  if (method == "setEnabled") {
    SetEnabled(GetBool(args, "enabled"));
    if (g_hwnd) StartTimer();
    result->Success(EncodableValue(g_enabled && g_hwnd != nullptr));
    return;
  }
  if (method == "update") {
    OnUpdate(args);
    if (g_hwnd) StartTimer();
    result->Success();
    return;
  }
  if (method == "accent") {
    // 逐字高亮色。先钳到 0~255 再存 —— 通道那头算错了也不该画出一个越界的颜色。
    g_hot_r = static_cast<BYTE>(std::clamp<int64_t>(GetInt(args, "r"), 0, 255));
    g_hot_g = static_cast<BYTE>(std::clamp<int64_t>(GetInt(args, "g"), 0, 255));
    g_hot_b = static_cast<BYTE>(std::clamp<int64_t>(GetInt(args, "b"), 0, 255));
    // 静态画面重绘一百遍还是同一张，所以颜色变了得主动重画一次 ——
    // 光靠定时器的话，一句唱完停在那儿时换了色是看不到变化的。
    if (g_hwnd && g_presence > 0.01f) Paint();
    result->Success();
    return;
  }
  if (method == "accent") {
    // 逐字高亮色。先钳到 0~255 再存 —— 通道那头算错了也不该画出一个越界的颜色。
    g_hot_r = static_cast<BYTE>(std::clamp<int64_t>(GetInt(args, "r"), 0, 255));
    g_hot_g = static_cast<BYTE>(std::clamp<int64_t>(GetInt(args, "g"), 0, 255));
    g_hot_b = static_cast<BYTE>(std::clamp<int64_t>(GetInt(args, "b"), 0, 255));
    // 静态画面重绘一百遍还是同一张，所以颜色变了得主动重画一次 ——
    // 光靠定时器的话，一句唱完停在那儿时换了色是看不到变化的。
    if (g_hwnd && g_presence > 0.01f) Paint();
    result->Success();
    return;
  }
  if (method == "clock") {
    // 只校正时间。播放/暂停以 update 为准，不然迟到的 clock 会把已经暂停的胶囊又打开。
    NoteClock(GetInt(args, "positionMs"));
    if (g_hwnd && g_presence > 0.01f) StartTimer();
    result->Success();
    return;
  }
  if (method == "cover") {
    OnCover(args);
    if (g_hwnd) StartTimer();
    result->Success();
    return;
  }
  result->NotImplemented();
}

}  // namespace

void RegisterLyricIsland(flutter::BinaryMessenger* messenger, HWND host) {
  g_host = host;
  if (!g_gdi) {
    GdiplusStartupInput input;
    if (GdiplusStartup(&g_gdi_token, &input, nullptr) == Ok) g_gdi = true;
  }
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "elia/lyric_island", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(HandleCall);
}

void LyricIslandOnHostMoved() {
  if (!g_enabled || !g_hwnd || !IsWindowVisible(g_hwnd)) return;
  g_measured = false;
  Paint();
}

void LyricIslandShutdown() {
  StopTimer();
  g_cover.reset();
  if (g_hwnd) {
    DestroyWindow(g_hwnd);
    g_hwnd = nullptr;
  }
  g_channel.reset();
  if (g_gdi) {
    GdiplusShutdown(g_gdi_token);
    g_gdi = false;
  }
}
