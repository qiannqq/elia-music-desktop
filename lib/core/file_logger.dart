import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 文件日志器 —— `electron/service/logger.js` 的 Dart 移植。
///
/// 行为保持一致：
/// - 按天分文件：`logs/YYYY-MM-DD.log`
/// - 行格式：`[HH:mm:ss.SSS] [LEVEL] [Category] message`
/// - 首次写入时惰性创建目录与文件流
class FileLogger {
  FileLogger._();

  static final FileLogger instance = FileLogger._();

  IOSink? _sink;
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
      if (_sink == null || _currentDate != date) {
        _sink?.close();
        _sink = null;
        final file = File(p.join(AppPaths.logsDir, '$date.log'));
        _sink = file.openWrite(mode: FileMode.append);
        _currentDate = date;
      }
      _sink!.writeln('[${_timeStr()}] [$level] [$category] $message');
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

  Future<void> close() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
  }
}

/// 便捷别名，对应原 `fileLogger`
final FileLogger fileLogger = FileLogger.instance;
