import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/file_logger.dart';

/// 封面磁盘缓存。
///
/// 封面是所有网络请求里重复率最高的：每次启动，歌单 / 搜索 / 播放栏 / 播放队列
/// 都要把可见的封面重新拉一遍 —— Flutter 的 `NetworkImage` 只在**内存**里缓存
/// （`ImageCache`），进程一退就没了，所以重启一次就等于把封面全下一遍。
///
/// 这里按 URL 存一份原始字节，命中就直接回、不再打上游。挂在**图片代理**那一层
/// （见 `http_server.dart` 的 `_apiProxyImage`），所以对调用方完全透明 ——
/// 不用改任何一处 `Image.network`。
class CoverCache {
  CoverCache._();

  static const int maxFiles = 800;

  /// 每写这么多张才检查一次上限 —— 每次写盘都扫一遍目录没必要
  static const int _enforceEvery = 64;

  static int _writes = 0;
  static Directory? _dir;

  static Directory get dir {
    final cached = _dir;
    if (cached != null) return cached;
    final made = Directory(p.join(AppPaths.dataDir, 'covers'));
    if (!made.existsSync()) made.createSync(recursive: true);
    return _dir = made;
  }

  /// 文件名用 URL 的哈希 —— 直接把 URL 塞进文件名会被非法字符和长度卡住。
  ///
  /// 这里自己写 FNV-1a：`String.hashCode` 不保证跨进程稳定，
  /// 而这份缓存是**要活过重启**的，键必须每次都算得一样。
  ///
  /// 用 32 位而不是 64 位：Dart 的 int 是有符号 64 位，乘法溢出成负数之后
  /// `toRadixString(16)` 会带一个负号，键的长度就变了。32 位配 `& 0xFFFFFFFF`
  /// 永远是 8 位十六进制。几百张封面的碰撞概率在万分之一量级，够用。
  static String keyOf(String url) {
    var hash = 0x811c9dc5;
    for (final unit in url.codeUnits) {
      hash = (hash ^ unit) & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static const List<String> _exts = ['.jpg', '.png', '.webp', '.gif', '.img'];

  /// 命中就返回文件，否则 null
  static File? find(String url) {
    if (url.isEmpty) return null;
    final key = keyOf(url);
    for (final ext in _exts) {
      final f = File(p.join(dir.path, '$key$ext'));
      if (f.existsSync() && f.lengthSync() > 0) return f;
    }
    return null;
  }

  /// 存一份。先写 `.part` 再改名：被杀在半路时不会留下一个「看起来命中、
  /// 其实只有半张」的文件 —— 那种文件解码出来是花屏。
  static void put(String url, Uint8List bytes, String contentType) {
    if (url.isEmpty || bytes.isEmpty) return;
    final ext = _extFor(contentType);
    final target = File(p.join(dir.path, '${keyOf(url)}$ext'));
    final part = File('${target.path}.part');
    try {
      part.writeAsBytesSync(bytes, flush: true);
      if (target.existsSync()) target.deleteSync();
      part.renameSync(target.path);
    } catch (e) {
      fileLogger.warn('CoverCache', '写入失败: $e');
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
      return;
    }
    if (++_writes % _enforceEvery == 0) enforceLimit();
  }

  static String _extFor(String contentType) {
    final t = contentType.toLowerCase();
    if (t.contains('png')) return '.png';
    if (t.contains('webp')) return '.webp';
    if (t.contains('gif')) return '.gif';
    if (t.contains('jpeg') || t.contains('jpg')) return '.jpg';
    return '.img';
  }

  /// 回给客户端时的 Content-Type。后缀是我们自己按类型写的，反推得回来。
  static String contentTypeOf(String path) => switch (p.extension(path)) {
        '.png' => 'image/png',
        '.webp' => 'image/webp',
        '.gif' => 'image/gif',
        '.jpg' => 'image/jpeg',
        _ => 'application/octet-stream',
      };

  static List<File> _files() {
    try {
      return dir.listSync().whereType<File>().where((f) {
        // 半成品不算
        return !f.path.endsWith('.part');
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  static int sizeOnDisk() {
    var total = 0;
    for (final f in _files()) {
      try {
        total += f.lengthSync();
      } catch (_) {}
    }
    return total;
  }

  /// 超过条数上限就按「最久没用过」删（mtime 最早的先走）。
  /// 返回删掉的条数。
  static int enforceLimit() {
    final files = _files();
    if (files.length <= maxFiles) return 0;
    final byTime = [...files];
    byTime.sort((a, b) {
      final ta = a.statSync().modified;
      final tb = b.statSync().modified;
      return ta.compareTo(tb);
    });
    var removed = 0;
    for (final f in byTime.take(files.length - maxFiles)) {
      try {
        f.deleteSync();
        removed++;
      } catch (_) {}
    }
    if (removed > 0) {
      fileLogger.info('CoverCache', '超出 $maxFiles 张，删了最久没用过的 $removed 张');
    }
    return removed;
  }

  /// 清空，返回释放的字节数
  static int clearAll() {
    var freed = 0;
    var count = 0;
    for (final f in _files()) {
      try {
        final n = f.lengthSync();
        f.deleteSync();
        freed += n;
        count++;
      } catch (_) {}
    }
    if (count > 0) {
      fileLogger.info('CoverCache',
          '清空封面缓存：$count 个文件，释放 ${(freed / 1024 / 1024).toStringAsFixed(1)}MB');
    }
    return freed;
  }
}
