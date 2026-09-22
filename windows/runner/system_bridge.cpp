#include "system_bridge.h"

#include <windows.h>

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

void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() != "diskInfo") {
    result->NotImplemented();
    return;
  }

  std::wstring path;
  if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
    const auto it = args->find(EncodableValue("path"));
    if (it != args->end()) {
      if (const auto* s = std::get_if<std::string>(&it->second)) {
        path = Utf8ToWide(*s);
      }
    }
  }

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
