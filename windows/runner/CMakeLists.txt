cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "audio_probe.h"
  "audio_probe_bridge.h"
  "flutter_window.cpp"
  "lyric_island.cpp"
  "main.cpp"
  "smtc_bridge.h"
  "system_bridge.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# 源码统一按 UTF-8 读：否则中文注释会触发 C4819，
# 而本目标是 /WX（警告即错误），一个注释就能让编译失败。
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "gdiplus.lib" "shcore.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# ==== SMTC 桥（Windows 系统媒体控件）====
#
# 单独建一个静态库，**不复用** apply_standard_settings：
# 模板给的是 `/W4 /WX`（警告即错误）和 `_HAS_EXCEPTIONS=0`，
# 而 C++/WinRT 是异常驱动的，且它的头文件在 /W4 下有不少第三方警告。
# 混在一个目标里会被 /WX 直接卡死，所以这里自己设一套宽松的编译选项。
add_library(smtc_bridge STATIC "smtc_bridge.cpp")
target_compile_features(smtc_bridge PUBLIC cxx_std_17)
# MSVC 14.51（VS 18）起 <experimental/coroutine> 被判成 C2338 硬错误，
# 而 C++/WinRT 在 C++17 下正是靠它实现协程 —— 不加这个宏，Visual Studio
# 版本比本机新的机器上（GitHub runner 就是）smtc_bridge 会直接编译失败，
# 整个 flutter build 挂掉。
target_compile_definitions(smtc_bridge PUBLIC "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS")
# /utf-8：源码是 UTF-8，不加的话 MSVC 会按系统代码页(936)读，
# 中文注释触发 C4819，在 /WX 的目标里直接变成错误。
target_compile_options(smtc_bridge PRIVATE /W3 /EHsc /utf-8)
target_include_directories(smtc_bridge PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  # 注意要带 ephemeral 这一层：头文件在
  # windows/flutter/ephemeral/cpp_client_wrapper/include/flutter/ 下
  "${FLUTTER_MANAGED_DIR}/ephemeral/cpp_client_wrapper/include"
)
# windowsapp.lib 是 WinRT 激活（RoActivateInstance 等）所需的导入库
target_link_libraries(smtc_bridge PUBLIC windowsapp.lib)
target_link_libraries(${BINARY_NAME} PRIVATE smtc_bridge)

# ==== 首尾无声探测桥（Media Foundation）====
#
# 同样单独建静态库：MF 的头在 /W4 下警告一堆，混进主目标会被 /WX 卡死。
add_library(audio_probe STATIC "audio_probe.cpp" "audio_probe_bridge.cpp")
target_compile_features(audio_probe PUBLIC cxx_std_17)
target_compile_options(audio_probe PRIVATE /W3 /EHsc /utf-8)
target_include_directories(audio_probe PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${FLUTTER_MANAGED_DIR}/ephemeral/cpp_client_wrapper/include"
)
# mfuuid 提供 MF_* 那些 GUID，ole32 提供 PropVariantClear
target_link_libraries(audio_probe PUBLIC
  "mfplat.lib" "mfreadwrite.lib" "mfuuid.lib" "ole32.lib"
)
target_link_libraries(${BINARY_NAME} PRIVATE audio_probe)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# 两个静态库同样要等 flutter_assemble：ephemeral/cpp_client_wrapper
# （flutter/binary_messenger.h 在里面）就是它解包出来的。
# 少了这两行，MSBuild 会并行编译它们与 flutter_assemble —— 干净 checkout
# （CI 每次都是）下会撞上 C1083 找不到 flutter/binary_messenger.h，
# 而本地因为 ephemeral 早就存在，这个顺序问题永远复现不出来。
add_dependencies(smtc_bridge flutter_assemble)
add_dependencies(audio_probe flutter_assemble)
