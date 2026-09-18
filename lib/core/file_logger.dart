import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 文件日志器 —— `electron/service/logger.js` 的 Dart 移植。
///
/// 行为保持一致：
/// - 按天分文件：`logs/YYYY-MM-DD.log`
/// - 行格式：`[HH:mm:ss.SSS] [LEVEL] [Category] message`
///
/// ⚠️ 与早期实现的关键差别：**同步写入 + 每行 flush**。
/// 早期用 `File.openWrite()` 得到的 `IOSink` 是**带缓冲**的，且从不 flush：
/// 进程被强杀（窗口关闭时我们就是直接 `exit(0)`）或崩溃时，最近的日志会整段丢失，
/// 导致「发行版出问题时日志里什么都没有」。日志量很小（每次操作几行），
/// 同步写 + flushSync 的开销可以忽略。
class FileLogger {
  FileLogger._();

  static final FileLogger instance = FileLogger._();

  RandomAccessFile? _raf;
  String? _currentDate;
  bool _disabled = false;

  String _dateStr() {
    final n = DateTime.now();
    return '${n.year}-${_two(n.month)}-${_two(n.day)}';
  }

  String _timeStr() {
    final n = DateTime.now();
    return '${_two(n.hour)}:${_two(n.minute)}:${_two(n.second)}'
        '.${n.millisecond.toString().padLeft(3, '0')}';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  void _write(String level, String category, String message) {
    if (_disabled) return;
    try {
      final date = _dateStr();
      if (_raf == null || _currentDate != date) {
        _raf?.closeSync();
        _raf = null;
        final file = File(p.join(AppPaths.logsDir, '$date.log'));
        file.parent.createSync(recursive: true);
        _raf = file.openSync(mode: FileMode.append);
        _currentDate = date;
      }
      _raf!.writeStringSync('[${_timeStr()}] [$level] [$category] $message\n');
      _raf!.flushSync(); // 保证进程被强杀时日志仍在磁盘上
    } catch (e) {
      // 日志失败不能影响主流程
      _disabled = true;
      stderr.writeln('[FileLogger] write failed: $e');
    }
  }

  void info(String category, String message) => _write('INFO', category, message);
  void warn(String category, String message) => _write('WARN', category, message);
  void error(String category, String message) => _write('ERROR', category, message);
  void debug(String category, String message) => _write('DEBUG', category, message);

  /// 同步落盘（同步写已经保证落盘，这里只用于关闭句柄）
  Future<void> close() async {
    try {
      _raf?.flushSync();
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;
  }
}

/// 便捷别名，对应原 `fileLogger`
final FileLogger fileLogger = FileLogger.instance;
