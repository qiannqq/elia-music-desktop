import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_paths.dart';

/// `localStorage` 的等价实现。
///
/// 键值全部以字符串存储（与原前端保持一致，JSON 由调用方自行编解码），
/// 落盘到 `<appDir>/data/local_storage.json`，不写 C 盘。
class LocalStore {
  LocalStore._();

  static final Map<String, String> _mem = <String, String>{};
  static bool _loaded = false;
  static Timer? _flushTimer;

  static void init() {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(AppPaths.storageFile);
      if (f.existsSync()) {
        final raw = f.readAsStringSync();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            decoded.forEach((k, v) {
              if (v is String) _mem[k.toString()] = v;
            });
          }
        }
      }
    } catch (e) {
      stderr.writeln('[LocalStore] load failed: $e');
    }
  }

  static String? get(String key) => _mem[key];

  static String getOr(String key, String fallback) => _mem[key] ?? fallback;

  static bool has(String key) => _mem.containsKey(key);

  static void set(String key, String value) {
    _mem[key] = value;
    _scheduleFlush();
  }

  static void remove(String key) {
    _mem.remove(key);
    _scheduleFlush();
  }

  static void clear() {
    _mem.clear();
    _scheduleFlush();
  }

  /// 读取 JSON 数组 / 对象，失败时返回 fallback
  static T readJson<T>(String key, T fallback) {
    final raw = _mem[key];
    if (raw == null || raw.isEmpty) return fallback;
    try {
      final v = jsonDecode(raw);
      if (v is T) return v;
      return fallback;
    } catch (_) {
      return fallback;
    }
  }

  static void writeJson(String key, Object? value) {
    set(key, jsonEncode(value));
  }

  /// 合并写入（用于 downloaded_paths 这类字典）
  static Map<String, dynamic> readMap(String key) {
    return readJson<Map<String, dynamic>>(key, <String, dynamic>{});
  }

  static void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 120), flush);
  }

  static void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    try {
      final f = File(AppPaths.storageFile);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(_mem), flush: true);
    } catch (e) {
      stderr.writeln('[LocalStore] flush failed: $e');
    }
  }
}
