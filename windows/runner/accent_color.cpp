#include "accent_color.h"

#include <roapi.h>
#include <windows.h>

// ABI 头之间**不互相包含**，顺序也不能反：Foundation 要在前。
#include <Windows.Foundation.h>
#include <Windows.UI.ViewManagement.h>
#include <Windows.UI.h>

#include <dwmapi.h>

namespace {

/// 官方那条路：`UISettings.GetColorValue(UIColorType.Accent)`。
///
/// 不需要 C++/WinRT 的投影与协程 —— 直接用 SDK 里的 ABI 头 +
/// `RoInitialize` / `RoActivateInstance`（本机实测编过跑通）。三个坑：
///   * `WindowsCreateString` 的**长度必须精确**（写错会得到 0x80070057）；
///   * `GetColorValue` 在 **`IUISettings3`** 上，`IUISettings` 没有；
///   * `RoInitialize` 的返回值不能当失败判据 —— 线程若已经进过 STA，
///     它会返回 `RPC_E_CHANGED_MODE`（0x80010106），但**取值照样成功**。
bool FromUISettings(uint32_t* out_rgb) {
  ::RoInitialize(RO_INIT_MULTITHREADED);

  const wchar_t* kClassName = L"Windows.UI.ViewManagement.UISettings";
  HSTRING class_name = nullptr;
  if (FAILED(::WindowsCreateString(kClassName,
                                   static_cast<UINT32>(wcslen(kClassName)),
                                   &class_name))) {
    return false;
  }
  IInspectable* instance = nullptr;
  const HRESULT activated = ::RoActivateInstance(class_name, &instance);
  ::WindowsDeleteString(class_name);
  if (FAILED(activated) || instance == nullptr) return false;

  ABI::Windows::UI::ViewManagement::IUISettings3* settings = nullptr;
  const HRESULT queried = instance->QueryInterface(
      __uuidof(ABI::Windows::UI::ViewManagement::IUISettings3),
      reinterpret_cast<void**>(&settings));
  instance->Release();
  if (FAILED(queried) || settings == nullptr) return false;

  ABI::Windows::UI::Color color{};
  const HRESULT got = settings->GetColorValue(
      ABI::Windows::UI::ViewManagement::UIColorType_Accent, &color);
  settings->Release();
  if (FAILED(got)) return false;

  *out_rgb = (0xFFu << 24) | (static_cast<uint32_t>(color.R) << 16) |
             (static_cast<uint32_t>(color.G) << 8) | static_cast<uint32_t>(color.B);
  return true;
}

/// 退路一：`Explorer\Accent\AccentPalette` 的第 4 个槽位（索引 3）= 主题色本体。
///
/// 8 个槽位是 `light3, light2, light1, accent, dark1, dark2, dark3, ?`，
/// 每个 4 字节、`0xAABBGGRR`（本机实测与官方 API 逐条一致）。
/// ⚠️ 这个键**可能陈旧**（换主题色不一定马上重写它），所以只当退路。
bool FromAccentPalette(uint32_t* out_rgb) {
  BYTE palette[32] = {};
  DWORD size = sizeof(palette);
  if (::RegGetValueW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent",
          L"AccentPalette", RRF_RT_REG_BINARY, nullptr, palette,
          &size) != ERROR_SUCCESS ||
      size < 16) {
    return false;
  }
  const BYTE r = palette[12], g = palette[13], b = palette[14];
  if ((r | g | b) == 0) return false;
  *out_rgb = (0xFFu << 24) | (static_cast<uint32_t>(r) << 16) |
             (static_cast<uint32_t>(g) << 8) | b;
  return true;
}

/// 退路二：`Themes\History\Colors\ColorHistory0` —— 用户最近选过的色，
/// 也是主题色网格里排第一格的那个（低三字节就是 RGB）。
bool FromColorHistory(uint32_t* out_rgb) {
  DWORD value = 0;
  DWORD size = sizeof(value);
  if (::RegGetValueW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\History\\Colors",
          L"ColorHistory0", RRF_RT_REG_DWORD, nullptr, &value,
          &size) != ERROR_SUCCESS) {
    return false;
  }
  const DWORD r = value & 0xFF;
  const DWORD g = (value >> 8) & 0xFF;
  const DWORD b = (value >> 16) & 0xFF;
  if ((r | g | b) == 0) return false;
  *out_rgb = 0xFF000000u | (r << 16) | (g << 8) | b;
  return true;
}

}  // namespace

bool GetSystemAccentColor(uint32_t* out_rgb) {
  if (out_rgb == nullptr) return false;
  if (FromUISettings(out_rgb)) return true;
  if (FromAccentPalette(out_rgb)) return true;
  if (FromColorHistory(out_rgb)) return true;
  return false;
}
