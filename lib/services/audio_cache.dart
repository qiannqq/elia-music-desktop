import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/file_logger.dart';
import '../core/local_store.dart';
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

  /// 默认上限 4GB。
  static const int defaultLimitMb = 4 * 1024;

  /// 上限存成 MB（localStorage 只能存字符串），对外一律按整 GB 用
  static const String _limitKey = 'audio_cache_limit_mb';

  /// 可设范围（GB，整数档）。**0 = 不启用缓存**。
  static const int minLimitGb = 0;
  static const int maxLimitGb = 32;

  /// 上限（MB）。0 表示停用缓存。
  static int get limitMb {
    final raw = LocalStore.get(_limitKey);
    // 没设置过 → 默认值；设过就按设的来，**包括 0**
    if (raw == null) return defaultLimitMb;
    final mb = int.tryParse(raw);
    if (mb == null) return defaultLimitMb;
    if (mb <= 0) return 0;
    return mb.clamp(1024, maxLimitGb * 1024);
  }

  static int get limitBytes => limitMb * 1024 * 1024;

  /// 缓存是否启用。设为 0GB 就停用：不再存新歌，已经存下的也会被清掉。
  static bool get enabled => limitMb > 0;

  static void setLimitGb(int gb) {
    final v = gb.clamp(minLimitGb, maxLimitGb);
    LocalStore.set(_limitKey, (v * 1024).toString());
  }

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

  /// 按**实际内容**判断容器后缀。
  ///
  /// 不能只看 URL。B站的音频是 fMP4（路径 `.m4s`），上游还会把 Content-Type
  /// 在 `video/mp4` 和 `octet-stream` 之间来回变；而 Windows 后端是**按后缀**
  /// 挑解封装器的 —— 一个 fMP4 存成 `.mp3`，下次命中缓存时解不出来，
  /// 播放会回退到网络重拉一遍，表现就是「这首歌每次都像没缓存过」。
  static String extensionForBytes(Uint8List b) {
    if (b.length >= 12) {
      // fMP4：第一个 box 是 `....ftyp`
      if (b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70) {
        return '.m4a';
      }
      // fLaC
      if (b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43) {
        return '.flac';
      }
      // OggS
      if (b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53) {
        return '.ogg';
      }
    }
    // ID3 标签、MPEG 帧同步，以及认不出来的，都按 mp3 处理
    return '.mp3';
  }

  /// 读文件头，用来判断真实容器格式
  static Uint8List _head(File f) {
    RandomAccessFile? raf;
    try {
      raf = f.openSync();
      final n = f.lengthSync();
      return raf.readSync(n < 12 ? n : 12);
    } catch (_) {
      return Uint8List(0);
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  /// 命中缓存则返回本地文件，否则返回 null
  static File? find(String mid) {
    if (mid.isEmpty) return null;
    try {
      for (final f in dir.listSync()) {
        if (f is File && p.basenameWithoutExtension(f.path) == mid) {
          // 半成品（下载中断）不算命中
          if (f.lengthSync() <= 0) continue;
          // 后缀和实际内容对不上（早期版本把 fMP4 存成了 .mp3）就当没命中，
          // 顺手删掉：这种文件本来就播不出来，留着只会让播放每次都回退到网络。
          if (p.extension(f.path).toLowerCase() != extensionForBytes(_head(f))) {
            try {
              f.deleteSync();
            } catch (_) {}
            continue;
          }
          return f;
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
    // 设为 0GB 就不存了。播放照旧，只是每次都走网络。
    if (!enabled) return;
    if (find(mid) != null) return;
    // 先落到固定的 `.part`，拿到内容之后再按真实容器定后缀改名 ——
    // 后缀只能等下载完才知道（URL 上的后缀不可信，见 extensionForBytes）。
    final part = File(p.join(dir.path, '$mid.part'));
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
      final target =
          File(p.join(dir.path, '$mid${extensionForBytes(res.bodyBytes)}'));
      if (target.existsSync()) {
        try {
          target.deleteSync();
        } catch (_) {}
      }
      await part.rename(target.path);
      final index = _readIndex();
      index[mid] = {
        'cachedAt': DateTime.now().millisecondsSinceEpoch,
        'lastPlayedAt': DateTime.now().millisecondsSinceEpoch,
      };
      _writeIndex(index);
      fileLogger.info('AudioCache',
          '$mid 已缓存 ${(res.bodyBytes.length / 1024 / 1024).toStringAsFixed(1)}MB');
      // 刚存进来的这首也要算进上限里，不然一直播就会一直涨到下次启动
      enforceLimit();
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
    // 上面那几条规则管的是「该不该留」，管不到体积，最后再压一次上限
    enforceLimit();
  }

  /// 超过体积上限就按「最久没听过」删，删一个不够就再删一个，直到降下来。
  ///
  /// 与 [prune] 的分工：[prune] 管「该不该留」（时间规则），这里只管「装不装得下」。
  /// 返回删掉的个数。
  static int enforceLimit() {
    // 上限为 0（停用缓存）时，这里会把已有的全部清掉 —— 那正是「不启用」该有的样子。
    final limit = limitBytes;
    var total = sizeOnDisk();
    if (total <= limit) return 0;

    final index = _readIndex();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) =>
            p.extension(f.path) != '.part' && p.basename(f.path) != 'index.json')
        .toList();
    if (files.isEmpty) return 0;

    // 先把时间戳取出来再排序：排序比较器会被调很多次，
    // 在里面 statSync 等于把每个文件 stat 几十遍。
    final stamp = <String, int>{};
    for (final f in files) {
      final mid = p.basenameWithoutExtension(f.path);
      stamp[mid] = index[mid]?['lastPlayedAt'] ??
          f.statSync().modified.millisecondsSinceEpoch;
    }
    files.sort((a, b) => stamp[p.basenameWithoutExtension(a.path)]!
        .compareTo(stamp[p.basenameWithoutExtension(b.path)]!));

    var removed = 0;
    for (final f in files) {
      if (total <= limit) break;
      try {
        final n = f.lengthSync();
        f.deleteSync();
        total -= n;
        index.remove(p.basenameWithoutExtension(f.path));
        removed++;
      } catch (_) {
        // 正在播的那个文件被播放器占着删不掉 —— 跳过它，继续删下一个
      }
    }

    if (removed > 0) {
      _writeIndex(index);
      fileLogger.info('AudioCache',
          '超出 ${(limit / 1024 / 1024 / 1024).toStringAsFixed(1)}GB 上限，删了 $removed 个最久没听过的');
    }
    return removed;
  }

  // ------------------------------------------------------------ 占用与清理

  /// 缓存占用的字节数（含索引文件与下载中断留下的 `.part`）
  static int sizeOnDisk() {
    var total = 0;
    try {
      for (final f in dir.listSync().whereType<File>()) {
        try {
          total += f.lengthSync();
        } catch (_) {}
      }
    } catch (_) {}
    return total;
  }

  /// 清空全部音频缓存，返回释放的字节数。
  ///
  /// 正在播放的那个文件被播放器占着，Windows 上删不掉 —— 单个失败就跳过，
  /// 不能因为一个文件让整轮清理停下。
  static int clearAll() {
    var freed = 0;
    try {
      for (final f in dir.listSync().whereType<File>()) {
        try {
          final n = f.lengthSync();
          f.deleteSync();
          freed += n;
        } catch (_) {}
      }
    } catch (e) {
      fileLogger.warn('AudioCache', '清理失败: $e');
    }
    if (freed > 0) {
      fileLogger.info(
          'AudioCache', '清空缓存，释放 ${(freed / 1024 / 1024).toStringAsFixed(1)}MB');
    }
    return freed;
  }
}
