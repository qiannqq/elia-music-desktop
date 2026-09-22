#include "system_bridge.h"

#include <windows.h>
#include <shellapi.h>

#include <memory>
#include <string>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                                    nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

std::wstring GetWide(const EncodableMap* args, const char* key) {
  if (!args) return std::wstring();
  const auto it = args->find(EncodableValue(key));
  if (it == args->end()) return std::wstring();
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? Utf8ToWide(*s) : std::wstring();
}

void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());

  if (method == "openUrl") {
    const std::wstring url = GetWide(args, "url");
    if (url.empty()) {
      result->Success(EncodableValue(false));
      return;
    }
    // 交给系统按默认程序打开，别自己拼命令行 ——
    // URL 里带 `&` 和空格，套进 cmd 会被拆成好几段。
    const HINSTANCE opened = ShellExecuteW(nullptr, L"open", url.c_str(), nullptr,
                                          nullptr, SW_SHOWNORMAL);
    // ShellExecuteW 的返回值大于 32 才算成功（小于等于 32 是错误码）
    result->Success(EncodableValue(reinterpret_cast<INT_PTR>(opened) > 32));
    return;
  }

  if (method != "diskInfo") {
    result->NotImplemented();
    return;
  }

  const std::wstring path = GetWide(args, "path");

  // 不给路径就不猜 —— GetDiskFreeSpaceExW 不接受空指针，猜错还会问到别的卷上。
  if (path.empty()) {
    result->Success(EncodableValue());
    return;
  }

  ULARGE_INTEGER free_bytes{};
  ULARGE_INTEGER total_bytes{};
  ULARGE_INTEGER total_free{};
  if (!GetDiskFreeSpaceExW(path.c_str(), &free_bytes, &total_bytes,
                           &total_free)) {
    // 拿不到不是错误 —— 调用方只是不显示百分比而已。
    result->Success(EncodableValue());
    return;
  }

  EncodableMap out;
  out[EncodableValue("freeBytes")] =
      EncodableValue(static_cast<int64_t>(free_bytes.QuadPart));
  out[EncodableValue("totalBytes")] =
      EncodableValue(static_cast<int64_t>(total_bytes.QuadPart));
  result->Success(EncodableValue(out));
}

}  // namespace

void RegisterSystemBridge(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "elia/system", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(HandleCall);
}
