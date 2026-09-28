#ifndef RUNNER_ACCENT_COLOR_H_
#define RUNNER_ACCENT_COLOR_H_

#include <cstdint>

/// 取 Windows 里用户设置的那个**主题色（强调色）**，写成 `0xFFRRGGBB`。
///
/// 为什么要单开一个静态库：`GetColorValue` 是 WinRT，而它的头在 `/W4 /WX`
/// 下警告一堆（主 runner 就是那个配置）—— 和 `smtc_bridge` 同一个理由，
/// 这里用自己一套宽松的编译选项。
///
/// 取值顺序（详见 `temp/win11-ui/accent-research.md` 的实测对照表）：
///   1. `UISettings.GetColorValue(UIColorType.Accent)` —— 官方 API、活的；
///   2. `Explorer\Accent\AccentPalette` 的第 4 个槽位 —— 与 1 逐条一致；
///   3. `Themes\History\Colors\ColorHistory0` —— 用户最近选过的色；
/// ⚠️ **不要**改用 `DWM\AccentColor` / `DwmGetColorizationColor`：那是「窗口玻璃色」
/// 那一套，实测与用户挑的主题色可以完全不同（本机是紫色 vs 红色）。
///
/// 全部失败返回 false，`*out_rgb` 不动。
bool GetSystemAccentColor(uint32_t* out_rgb);

#endif  // RUNNER_ACCENT_COLOR_H_
