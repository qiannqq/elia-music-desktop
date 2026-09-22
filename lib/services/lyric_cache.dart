import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/file_logger.dart';
import '../core/local_store.dart';
import '../core/lyric.dart';
import 'api_client.dart';
import 'bilibili_service.dart';

/// 一份完整歌词（原文 + 翻译 + 解析结果）
class LyricBundle {
  const LyricBundle({
    required this.raw,
    required this.trans,
    required this.lines,
    required this.transMap,
  });

  final String raw;
  final String trans;
  final List<LyricLine> lines;
  final Map<double, String> transMap;

  bool get isEmpty => lines.isEmpty;
}

/// 歌词缓存 —— **播放器栏与歌词弹窗共用同一份数据**。
///
/// 背景：之前播放器（`PlayerController._loadLyrics`）与歌词弹窗
/// （`AppState.loadLyricForModal`）各自独立请求歌词，于是「点歌词按钮时快时慢」
/// —— 每次打开弹窗都要重新拉一遍网络。
///
/// 现在统一走这里：
///  * 歌曲开始播放时就预取并缓存（用户看播放器栏的滚动歌词时缓存已就绪）；
///  * 打开弹窗优先读缓存，命中则**瞬间显示**；
///  * 同一 mid 的并发请求会被合并，播放器与弹窗不会重复拉取。
class LyricCache {
  LyricCache._();

  static final Map<String, LyricBundle> _cache = {};
  static final Map<String, Future<LyricBundle?>> _inflight = {};

  /// 同步读缓存（命中则完全不需要网络）
  static LyricBundle? peek(String mid) => _cache[mid];

  /// 是否有该 mid 的请求正在进行
  static bool isLoading(String mid) => _inflight.containsKey(mid);

  /// 取歌词：命中缓存直接返回；否则发请求（同一 mid 并发只请求一次）
  static Future<LyricBundle?> load(
    String mid, {
    required String source,
    bool force = false,
  }) {
    if (!force) {
      final hit = _cache[mid];
      if (hit != null) return Future<LyricBundle?>.value(hit);
      final pending = _inflight[mid];
      if (pending != null) return pending;
    }
    final fut = _fetch(mid, source);
    _inflight[mid] = fut;
    fut.whenComplete(() => _inflight.remove(mid));
    return fut;
  }

  /// 丢掉这首歌的缓存（内存 + 磁盘）。用户把歌词清空时要用 ——
  /// 不丢的话下次取词会命中磁盘缓存，旧歌词又回来了。
  static void dropDisk(String mid) {
    _cache.remove(mid);
    try {
      final f = _diskFile(mid);
      if (f.existsSync()) f.deleteSync();
    } catch (e) {
      fileLogger.warn('Lyric', '$mid 删缓存失败: $e');
    }
  }

  /// 磁盘上的歌词缓存：`<data>/lyrics/<mid>.json`
  static File _diskFile(String mid) =>
      File(p.join(AppPaths.dataDir, 'lyrics', '$mid.json'));

  static void _saveToDisk(String mid, String raw, String trans) {
    try {
      final f = _diskFile(mid);
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'raw': raw, 'trans': trans}), flush: true);
    } catch (e) {
      fileLogger.warn('Lyric', '$mid 写缓存失败: $e');
    }
  }

  static ({String raw, String trans})? _readFromDisk(String mid) {
    try {
      final f = _diskFile(mid);
      if (!f.existsSync()) return null;
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final raw = (m['raw'] as String?) ?? '';
      if (raw.isEmpty) return null;
      return (raw: raw, trans: (m['trans'] as String?) ?? '');
    } catch (_) {
      return null;
    }
  }

  static Future<LyricBundle?> _fetch(String mid, String source) async {
    try {
      var raw = '';
      var trans = '';
      var fromDisk = false;

      // 1) 用户自定义歌词优先（与 `custom_lyric_<mid>` 键名保持一致）
      //
      // 注意判据是 `!= null` 而不是「非空」：**空串也是用户的意思**
      //（他把歌词删干净了）。这时必须停在这里，不能再往磁盘缓存/网络走，
      // 否则旧歌词又回来了。
      final localLrc = LocalStore.get('custom_lyric_$mid');
      if (localLrc != null) {
        raw = localLrc.trim().isEmpty ? '' : localLrc;
      } else {
        // 2) 其次磁盘缓存 —— 命中就完全不需要网络
        //    （内存缓存重启就没了，这是「每次都去请求」的主因之一）
        final disk = _readFromDisk(mid);
        if (disk != null) {
          raw = disk.raw;
          trans = disk.trans;
          fromDisk = true;
        } else {
          // 3) 最后才请求网络
          // B 站的歌词来自视频字幕：没有字幕就返回空串，
          // 上层按「没有歌词」处理即可。
          final res = switch (source) {
            'netease' => await ApiClient.neLyric(mid),
            'bilibili' => await bilibiliService.getLyricByMid(mid),
            _ => await ApiClient.getLyric(mid),
          };
          raw = res.lyric;
          trans = res.trans;
          if (raw.isNotEmpty) _saveToDisk(mid, raw, trans);
        }
      }
      final localTrans = LocalStore.get('custom_lyric_trans_$mid');
      if (localTrans != null) trans = localTrans;
      if (fromDisk) fileLogger.info('Lyric', '$mid 命中磁盘缓存，未请求网络');

      // QRC（逐字歌词）的行头是 `[起点ms,时长ms]`，**不是** `[mm:ss.xx]`，
      // 必须走 parseQrc；否则会解析出 0 行、逐字歌词显示不出来。
      final isQrc = looksLikeQrc(raw);
      final bundle = LyricBundle(
        raw: raw,
        trans: trans,
        lines: isQrc ? parseQrc(raw) : parseLrc(raw),
        transMap: parseTransLrc(trans),
      );
      // 记下长度与解析结果：歌词「显示不出来 / 没有翻译」时能直接从日志判断
      // 是接口没给、还是解析没吃进去。
      final withWords = bundle.lines.where((l) => l.hasWords).length;
      fileLogger.info(
        'Lyric',
        '$mid $source${isQrc ? ' qrc' : ''} raw=${raw.length} trans=${trans.length}'
        ' → lines=${bundle.lines.length} 其中逐字行=$withWords transMap=${bundle.transMap.length}',
      );
      if (raw.isNotEmpty && bundle.lines.isEmpty) {
        fileLogger.warn('Lyric', '$mid 歌词非空但解析出 0 行，原文首行: '
            '${raw.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '')}');
      }
      _cache[mid] = bundle;
      return bundle;
    } catch (e) {
      fileLogger.error('Lyric', '$mid 获取失败: $e');
      return null;
    }
  }

  /// 外部把「迟到但有效」的歌词补进缓存（内存 + 磁盘）。
  ///
  /// 用在 QRC 超时回退的场景：降级的普通歌词先返回给界面，而那个 QRC 请求
  /// 其实还在飞；它 10 秒后带着逐字歌词和翻译回来时，如果没人接住，
  /// 这份降级结果就会被缓存住 —— 用户再怎么打开歌词都看不到翻译。
  static void putRaw(String mid, String raw, String trans) {
    if (raw.isEmpty) return;
    final isQrc = looksLikeQrc(raw);
    final bundle = LyricBundle(
      raw: raw,
      trans: trans,
      lines: isQrc ? parseQrc(raw) : parseLrc(raw),
      transMap: parseTransLrc(trans),
    );
    if (bundle.isEmpty) return;
    _cache[mid] = bundle;
    _saveToDisk(mid, raw, trans);
    fileLogger.info('Lyric',
        '$mid 迟到的歌词已补进缓存（lines=${bundle.lines.length} trans=${trans.length}）');
  }

  /// 自定义歌词保存/清除后让其失效，下次重新读取。
  ///
  /// 磁盘缓存一并删掉：用户刚改过歌词，本地那份已经不是最新了。
  static void invalidate(String mid) {
    _cache.remove(mid);
    try {
      final f = _diskFile(mid);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // ------------------------------------------------------------ 占用与清理

  /// 歌词缓存目录
  static Directory get dir => Directory(p.join(AppPaths.dataDir, 'lyrics'));

  /// 磁盘上占用的字节数
  static int sizeOnDisk() {
    var total = 0;
    try {
      if (dir.existsSync()) {
        for (final f in dir.listSync().whereType<File>()) {
          try {
            total += f.lengthSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// 清空全部歌词缓存（内存 + 磁盘），返回释放的字节数。
  ///
  /// **内存那份也要清**：只删文件的话，内存里还留着整首歌词，
  /// 表现为「清了缓存但歌词照样立刻出来」。
  static int clearAll() {
    _cache.clear();
    var freed = 0;
    try {
      if (dir.existsSync()) {
        for (final f in dir.listSync().whereType<File>()) {
          try {
            final n = f.lengthSync();
            f.deleteSync();
            freed += n;
          } catch (_) {}
        }
      }
    } catch (e) {
      fileLogger.warn('Lyric', '清理缓存失败: $e');
    }
    if (freed > 0) {
      fileLogger.info(
          'Lyric', '清空歌词缓存，释放 ${(freed / 1024).toStringAsFixed(0)}KB');
    }
    return freed;
  }
}
