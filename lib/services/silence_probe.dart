import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/file_logger.dart';
import 'api_client.dart';
import 'audio_cache.dart';

/// 一首歌的首尾静音（毫秒）。
///
/// 时间轴是**原始音频**的，不是裁剪后的 —— 进度条、歌词、播放位置记忆
/// 全都按原始时间来，这里只说明「该从哪儿开始、到哪儿算完」。
class SilenceTrim {
  const SilenceTrim({
    required this.durationMs,
    required this.startMs,
    required this.endMs,
  });

  final int durationMs;
  final int startMs;
  final int endMs;

  /// 开头要跳过多少
  bool get hasStart => startMs > 0;

  /// 结尾是不是要提前收
  bool get hasEnd => endMs > 0 && endMs < durationMs;

  /// 没有任何要跳的
  bool get isEmpty => !hasStart && !hasEnd;

  Map<String, Object?> toJson() => {
        'durationMs': durationMs,
        'startMs': startMs,
        'endMs': endMs,
      };

  static SilenceTrim? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final d = (raw['durationMs'] as num?)?.toInt();
    final s = (raw['startMs'] as num?)?.toInt();
    final e = (raw['endMs'] as num?)?.toInt();
    if (d == null || s == null || e == null || d <= 0) return null;
    return SilenceTrim(durationMs: d, startMs: s, endMs: e);
  }
}

/// 一份探测结果怎么用 —— 什么时候跳开头、什么时候算唱完。
///
/// 从播放器里拆出来单独放，是因为这里全是「只跳一次、用户拖过就别再动」
/// 这类容易写错又不容易看出来的判定，而播放器本身依赖插件、不好测。
class SilenceSkip {
  SilenceTrim? _trim;
  bool _leadingDone = false;
  bool _endHandled = false;

  SilenceTrim? get trim => _trim;

  /// 换歌 / 拿到新结果
  void apply(SilenceTrim? trim) {
    _trim = trim;
    _leadingDone = false;
    _endHandled = false;
  }

  void reset() => apply(null);

  /// 用户自己拖了进度条：他要是拖回开头那段空白，就让他听
  void userSeeked() => _leadingDone = true;

  /// 单曲循环重头放：开头那段要重新跳
  void rewind() {
    _leadingDone = false;
    _endHandled = false;
  }

  /// 现在该跳到哪儿？返回要跳到的位置，不用跳返回 null。
  ///
  /// **有副作用**：判定过一次就不再判 —— 「只跳一次」正是这里要保证的，
  /// 否则用户拖回开头会被立刻顶回去。
  Duration? leadingTarget(Duration position) {
    final t = _trim;
    if (t == null || !t.hasStart || _leadingDone) return null;
    _leadingDone = true;
    final start = Duration(milliseconds: t.startMs);
    return position < start ? start : null;
  }

  /// 到尾巴那段空白的起点了 —— 该当这首唱完了。
  ///
  /// 同样只认第一次：不然位置事件每来一次就触发一遍「放完了」。
  bool reachedEnd(Duration position) {
    final t = _trim;
    if (t == null || !t.hasEnd || _endHandled) return false;
    if (position < Duration(milliseconds: t.endMs)) return false;
    _endHandled = true;
    return true;
  }
}

/// 首尾静音探测。
///
/// 解码后的采样在 Dart 这边拿不到（audioplayers 只给播放控制），所以真正
/// 干活的是原生桥（`windows/runner/audio_probe.*`，Media Foundation）。
/// 这一层负责三件事：挑给原生什么源、等结果、把结果存下来。
///
/// 存盘是必须的：探测要解一次音频（本地文件几十毫秒，网络流几百毫秒），
/// 每播一次都探一遍纯属浪费 —— 一首歌探一次就够。
class SilenceProbe {
  SilenceProbe._();

  static const _channel = MethodChannel('elia/audio_probe');

  /// 等结果的上限。本地文件 100ms 上下，网络流慢一些，但也不该等太久 ——
  /// 等不到就当这首歌没有可跳的空白，下次播放再试（结果会存下来）。
  static const Duration timeout = Duration(seconds: 8);

  /// 等「本地音频文件出现」的上限。
  ///
  /// 首次播放是边播边缓存（见 `AudioDiskCache.warm`），文件要一两秒才落地；
  /// 尾部的空白在几分钟之后，所以等这一会儿完全来得及。
  static Duration fileWait = const Duration(seconds: 20);

  static const Duration pollInterval = Duration(milliseconds: 150);
  static const Duration filePollInterval = Duration(milliseconds: 300);

  static File get _cacheFile => File(p.join(AppPaths.dataDir, 'silence_cache.json'));

  /// 探测结果：`{mid: {durationMs, startMs, endMs, epoch}}`
  ///
  /// 带 `epoch`（凭据代次）：同一个 mid 在匿名和会员状态下拿到的音频不一样，
  /// 那份旧结果对不上新的音频。
  static Map<String, Map<String, Object?>> _readCache() {
    try {
      if (!_cacheFile.existsSync()) return {};
      final raw = jsonDecode(_cacheFile.readAsStringSync());
      if (raw is! Map) return {};
      return {
        for (final e in raw.entries)
          if (e.value is Map) e.key.toString(): (e.value as Map).cast<String, Object?>(),
      };
    } catch (_) {
      return {};
    }
  }

  static void _writeCache(Map<String, Map<String, Object?>> cache) {
    try {
      _cacheFile.writeAsStringSync(jsonEncode(cache), flush: true);
    } catch (e) {
      fileLogger.warn('Silence', '探测结果写盘失败: $e');
    }
  }

  /// 已缓存的探测结果（没有 / 过期返回 null）
  static SilenceTrim? cached(String mid) {
    if (mid.isEmpty) return null;
    final entry = _readCache()[mid];
    if (entry == null) return null;
    if ((entry['epoch'] as num?)?.toInt() != AudioDiskCache.epoch) return null;
    return SilenceTrim.fromJson(entry);
  }

  /// 清掉全部探测结果，返回释放的字节数。
  ///
  /// 跟音频缓存一起清：探测结果是从那份音频算出来的，音频没了它就没意义。
  static int clearCache() {
    try {
      final f = _cacheFile;
      if (!f.existsSync()) return 0;
      final n = f.lengthSync();
      f.deleteSync();
      return n;
    } catch (_) {
      return 0;
    }
  }

  /// 探测这首歌的首尾静音。探不出来（打不开、超时、平台不支持）返回 null。
  ///
  /// [url] 是这次播放用的音频地址，用来在**本地没有文件**时兜底下一份。
  ///
  /// ⚠️ **探测只在本地文件上做，绝不喂 http 地址。** Media Foundation 走 http 时
  /// 每定位一次就把「从那个位置到文件尾」整段重下一遍 —— 实测一个 4.5MB 的 m4a
  /// 会发 31 个请求、拉出 60MB，网络上一轮下来十几秒（还会跟播放抢带宽）。
  /// 本地文件同样的文件只要 110ms。
  static Future<SilenceTrim?> probe(String mid, {String url = ''}) async {
    if (mid.isEmpty) return null;

    final hit = cached(mid);
    if (hit != null) return hit;

    File? file = _localFile(mid);
    file ??= await _waitForLocalFile(mid);
    var temporary = false;
    if (file == null) {
      file = await _downloadToTemp(mid, url);
      temporary = file != null;
    }
    if (file == null) return null;

    try {
      return await _probeFile(mid, file.path);
    } finally {
      if (temporary) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// 本地已有这份音频就直接用（最常见的情况：已经缓存过）
  static File? _localFile(String mid) => AudioDiskCache.find(mid);

  /// 等后台那份边播边缓存的文件落地
  static Future<File?> _waitForLocalFile(String mid) async {
    final deadline = DateTime.now().add(fileWait);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(filePollInterval);
      final f = AudioDiskCache.find(mid);
      if (f != null) return f;
    }
    return null;
  }

  /// 兜底：用户把音频缓存关了（或者这次缓存失败）时，自己下一份到 `temp/`。
  ///
  /// 下完就删，只在本地一次都没留过的时候才走这条路。
  static Future<File?> _downloadToTemp(String mid, String url) async {
    if (url.isEmpty) return null;
    final proxied = ApiClient.getProxyAudioUrl(url);
    if (proxied.isEmpty) return null;
    final target = File(p.join(AppPaths.tempDir, 'silence_$mid.audio'));
    try {
      final res = await http
          .get(Uri.parse(proxied))
          .timeout(const Duration(seconds: 60));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        fileLogger.warn('Silence', '$mid 临时下载失败: HTTP ${res.statusCode}');
        return null;
      }
      await target.writeAsBytes(res.bodyBytes, flush: true);
      return target;
    } catch (e) {
      fileLogger.warn('Silence', '$mid 临时下载失败: $e');
      return null;
    }
  }

  /// 让原生侧解一遍这个文件，等它给出首尾静音
  static Future<SilenceTrim?> _probeFile(String mid, String path) async {
    final stopwatch = Stopwatch()..start();
    try {
      await _channel.invokeMethod<Object?>('start', {'source': path});
    } catch (e) {
      // 平台不支持 / 测试环境没有这个桥：当作没有可跳的空白
      fileLogger.info('Silence', '探测通道不可用（$e）');
      return null;
    }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      Map<Object?, Object?>? res;
      try {
        res = await _channel.invokeMethod<Map<Object?, Object?>>('poll');
      } catch (_) {
        return null;
      }
      if (res == null) continue;
      // 原生那边只留一个任务，源对不上说明它已经被别的歌顶掉了
      if (res['source'] != path) return null;
      if (res['ok'] != true) {
        fileLogger.info('Silence', '$mid 探测失败（解不开或读不到）');
        return null;
      }

      final trim = SilenceTrim(
        durationMs: (res['durationMs'] as num?)?.toInt() ?? 0,
        startMs: (res['startMs'] as num?)?.toInt() ?? 0,
        endMs: (res['endMs'] as num?)?.toInt() ?? 0,
      );
      if (trim.durationMs <= 0) return null;

      final cache = _readCache();
      cache[mid] = {
        ...trim.toJson(),
        'epoch': AudioDiskCache.epoch,
      };
      _writeCache(cache);
      fileLogger.info(
        'Silence',
        '$mid 首尾静音 开头${trim.startMs}ms 结尾${trim.durationMs - trim.endMs}ms'
        '（${stopwatch.elapsedMilliseconds}ms）',
      );
      return trim;
    }

    fileLogger.warn('Silence', '$mid 探测超时（${timeout.inSeconds}s），本次不跳过');
    return null;
  }
}
