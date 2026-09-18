import '../core/local_store.dart';
import '../core/lyric.dart';
import 'api_client.dart';

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
    required bool isNetease,
    bool force = false,
  }) {
    if (!force) {
      final hit = _cache[mid];
      if (hit != null) return Future<LyricBundle?>.value(hit);
      final pending = _inflight[mid];
      if (pending != null) return pending;
    }
    final fut = _fetch(mid, isNetease);
    _inflight[mid] = fut;
    fut.whenComplete(() => _inflight.remove(mid));
    return fut;
  }

  static Future<LyricBundle?> _fetch(String mid, bool isNetease) async {
    try {
      var raw = '';
      var trans = '';

      // 用户自定义歌词优先（与 `custom_lyric_<mid>` 键名保持一致）
      final localLrc = LocalStore.get('custom_lyric_$mid');
      if (localLrc != null && localLrc.trim().isNotEmpty) {
        raw = localLrc;
      } else {
        final res = isNetease
            ? await ApiClient.neLyric(mid)
            : await ApiClient.getLyric(mid);
        raw = res.lyric;
        trans = res.trans;
      }
      final localTrans = LocalStore.get('custom_lyric_trans_$mid');
      if (localTrans != null) trans = localTrans;

      final bundle = LyricBundle(
        raw: raw,
        trans: trans,
        lines: parseLrc(raw),
        transMap: parseTransLrc(trans),
      );
      _cache[mid] = bundle;
      return bundle;
    } catch (_) {
      return null;
    }
  }

  /// 自定义歌词保存/清除后让其失效，下次重新读取
  static void invalidate(String mid) => _cache.remove(mid);
}
