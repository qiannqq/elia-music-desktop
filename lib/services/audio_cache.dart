import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/file_logger.dart';
import 'api_client.dart';

/// 音频磁盘缓存。
///
/// 为什么要有：每次播放都去上游取一次音频，既要重新拿 vkey（QQ 那边有频控，
/// 反复取会被拦成 HTTP 418），播放前还得等一整轮网络。缓存之后
/// **同一首歌第二次播放直接读本地文件，完全不碰 API**。
///
/// 首次播放仍是流式播放（不等下载完，避免开播变慢），同时后台把音频落盘；
/// 下一次播放命中缓存就直接播本地文件。
///
/// 淘汰策略（缓存不能无限涨，也不能把用户常听的删掉）：
///   * **不在歌单里**（含从歌单移除的）→ 24 小时后删；
///   * 在歌单里但 **30 天没听过** → 删；
///   * 另有一个数量上限兜底，防止歌单极大时把盘塞满。
class AudioDiskCache {
  AudioDiskCache._();

  static Directory? _dir;

  /// 缓存目录：`<data>/audio_cache`
  static Directory get dir {
    final cached = _dir;
    if (cached != null) return cached;
    final d = Directory(p.join(AppPaths.dataDir, 'audio_cache'));
    if (!d.existsSync()) d.createSync(recursive: true);
    _dir = d;
    return d;
  }

  /// 数量上限兜底（策略之外的保险丝）
  static const int maxFiles = 300;

  /// 不在歌单里 → 多久后删
  static const Duration orphanTtl = Duration(hours: 24);

  /// 在歌单里但多久没听 → 删
  static const Duration idleTtl = Duration(days: 30);

  // ------------------------------------------------------------ 元数据

  /// 每首歌的时间戳：`{mid: {cachedAt, lastPlayedAt}}`（毫秒）
  ///
  /// 单独放一个索引文件，比给每个音频配一个 sidecar 文件省事，
  /// 也不会因为音频文件被外部删掉而留下孤儿元数据。
  static File get _indexFile => File(p.join(dir.path, 'index.json'));

  static Map<String, Map<String, int>> _readIndex() {
    try {
      if (!_indexFile.existsSync()) return {};
      final raw = jsonDecode(_indexFile.readAsStringSync());
      if (raw is! Map) return {};
      return raw.map((k, v) => MapEntry(
            k.toString(),
            (v as Map).map((k2, v2) =>
                MapEntry(k2.toString(), (v2 as num).toInt())),
          ));
    } catch (_) {
      return {};
    }
  }

  static void _writeIndex(Map<String, Map<String, int>> index) {
    try {
      _indexFile.writeAsStringSync(jsonEncode(index), flush: true);
    } catch (_) {}
  }

  // ------------------------------------------------------------ 读写

  /// 命中缓存则返回本地文件，否则返回 null
  static File? find(String mid) {
    if (mid.isEmpty) return null;
    try {
      for (final f in dir.listSync()) {
        if (f is File && p.basenameWithoutExtension(f.path) == mid) {
          // 半成品（下载中断）不算命中
          if (f.lengthSync() > 0) return f;
        }
      }
    } catch (_) {}
    return null;
  }

  /// 记录「这首歌刚被播放过」——「30 天没听过」这条规则靠它
  static void touch(String mid) {
    if (mid.isEmpty) return;
    final index = _readIndex();
    final e = index.putIfAbsent(mid, () => {});
    e['lastPlayedAt'] = DateTime.now().millisecondsSinceEpoch;
    e.putIfAbsent('cachedAt', () => e['lastPlayedAt']!);
    _writeIndex(index);
  }

  /// 后台把音频下载到缓存。
  ///
  /// 先写 `.part` 再改名：中途失败/被杀时不会留下一个「看起来命中、
  /// 其实是半截」的缓存文件 —— 那种文件播到一半会断。
  static Future<void> warm(String mid, String url) async {
    if (mid.isEmpty || url.isEmpty) return;
    if (find(mid) != null) return;
    final target = File(p.join(dir.path, '$mid${_ext(url)}'));
    final part = File('${target.path}.part');
    try {
      final res = await http
          .get(Uri.parse(ApiClient.getProxyAudioUrl(url)))
          .timeout(const Duration(seconds: 60));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        fileLogger.warn('AudioCache',
            '$mid 缓存失败: HTTP ${res.statusCode}（不影响本次播放）');
        return;
      }
      await part.writeAsBytes(res.bodyBytes, flush: true);
      await part.rename(target.path);
      final index = _readIndex();
      index[mid] = {
        'cachedAt': DateTime.now().millisecondsSinceEpoch,
        'lastPlayedAt': DateTime.now().millisecondsSinceEpoch,
      };
      _writeIndex(index);
      fileLogger.info('AudioCache',
          '$mid 已缓存 ${(res.bodyBytes.length / 1024 / 1024).toStringAsFixed(1)}MB');
    } catch (e) {
      fileLogger.warn('AudioCache', '$mid 缓存失败: $e（不影响本次播放）');
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------ 淘汰

  /// 按策略清理缓存。
  ///
  /// [playlistMids] 是当前歌单里的歌曲 mid 集合 —— 判断「还在不在歌单里」。
  /// [now] 只为测试注入，正常运行不用传。
  static void prune({
    required Set<String> playlistMids,
    DateTime? now,
  }) {
    final ts = (now ?? DateTime.now()).millisecondsSinceEpoch;
    try {
      final index = _readIndex();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.extension(f.path) != '.part' &&
              p.basename(f.path) != 'index.json')
          .toList();

      var removed = 0;
      for (final f in files) {
        final mid = p.basenameWithoutExtension(f.path);
        final meta = index[mid] ?? const <String, int>{};
        // 没有元数据的（老版本留下的）按文件修改时间兜底
        final cachedAt =
            meta['cachedAt'] ?? f.statSync().modified.millisecondsSinceEpoch;
        final lastPlayedAt = meta['lastPlayedAt'] ?? cachedAt;

        final inPlaylist = playlistMids.contains(mid);
        final keep = inPlaylist
            // 在歌单里：30 天没听过才删
            ? ts - lastPlayedAt <= idleTtl.inMilliseconds
            // 不在歌单里（含被移除的）：24 小时后删
            : ts - (lastPlayedAt > cachedAt ? lastPlayedAt : cachedAt) <=
                orphanTtl.inMilliseconds;

        if (!keep) {
          try {
            f.deleteSync();
            index.remove(mid);
            removed++;
          } catch (_) {}
        }
      }

      // 数量上限兜底：按最后播放时间淘汰最旧的
      final survivors = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.extension(f.path) != '.part')
          .toList();
      if (survivors.length > maxFiles) {
        survivors.sort((a, b) {
          final am = index[p.basenameWithoutExtension(a.path)]?['lastPlayedAt'] ??
              a.statSync().modified.millisecondsSinceEpoch;
          final bm = index[p.basenameWithoutExtension(b.path)]?['lastPlayedAt'] ??
              b.statSync().modified.millisecondsSinceEpoch;
          return am.compareTo(bm);
        });
        for (final f in survivors.take(survivors.length - maxFiles)) {
          try {
            f.deleteSync();
            index.remove(p.basenameWithoutExtension(f.path));
            removed++;
          } catch (_) {}
        }
      }

      _writeIndex(index);
      if (removed > 0) fileLogger.info('AudioCache', '按策略清理了 $removed 个缓存');
    } catch (e) {
      fileLogger.warn('AudioCache', '清理失败: $e');
    }
  }

  /// 音频扩展名：Windows 后端靠后缀判断容器格式，本地文件同样要带对后缀
  static String _ext(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final e = p.extension(path).toLowerCase();
    if (e == '.mp3' || e == '.m4a' || e == '.flac' || e == '.aac') return e;
    return '.mp3';
  }
}
