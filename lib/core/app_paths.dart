import 'dart:io';

import 'package:path/path.dart' as p;

/// 全局路径管理。
///
/// 设计原则（对应需求「开发环境与临时文件全部放在 D 盘，禁止写入 C 盘」）：
/// 所有运行时数据（data / logs / temp）都锚定在**可执行文件所在目录**下，
/// 便携式布局，绝不会写到 `C:\Users\...\AppData`。
class AppPaths {
  AppPaths._();

  static bool _inited = false;

  /// 应用根目录（exe 所在目录）
  static late final String appDir;

  /// 数据目录（等价于原 localStorage 持久化位置）
  static late final String dataDir;

  /// 日志目录
  static late final String logsDir;

  /// 临时目录（下载中转等）
  static late final String tempDir;

  static void init() {
    if (_inited) return;
    _inited = true;

    String base;
    try {
      base = File(Platform.resolvedExecutable).parent.path;
    } catch (_) {
      base = Directory.current.path;
    }

    // 调试运行时 exe 位于 build/windows/x64/runner/Debug，
    // 向上回溯到工程根目录，便于开发期查看产物。
    base = _resolveRoot(base);

    appDir = base;
    dataDir = p.join(base, 'data');
    logsDir = p.join(base, 'logs');
    tempDir = p.join(base, 'temp');

    for (final dir in [dataDir, logsDir, tempDir]) {
      try {
        Directory(dir).createSync(recursive: true);
      } catch (e) {
        stderr.writeln('[AppPaths] mkdir failed: $dir -> $e');
      }
    }
  }

  /// 若 exe 位于 Flutter 调试输出目录，则回溯到包含 `pubspec.yaml` 的工程根。
  static String _resolveRoot(String exeDir) {
    var dir = exeDir;
    for (var i = 0; i < 6; i++) {
      if (File(p.join(dir, 'pubspec.yaml')).existsSync()) return dir;
      final parent = p.dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
    return exeDir;
  }

  static String get storageFile => p.join(dataDir, 'local_storage.json');
}
