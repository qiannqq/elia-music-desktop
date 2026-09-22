import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/file_logger.dart';
import '../core/local_store.dart';
import '../core/lyric.dart';
import '../models/song.dart';
import 'api_client.dart';
import 'lyric_cache.dart';
import 'player_controller.dart';

/// 本地存储的键。缺省或不是 `1` 都算关闭。
const String kDesktopLyricKey = 'desktop_lyric_enabled';

/// 胶囊要显示的那一句。
///
/// [lineIndex] 指向 [LyricLine] 列表；`-1` 表示还没有唱到的句子，
/// 这时 [text] 是「歌名 · 歌手」，不走逐字。
class LyricIslandFrame {
  const LyricIslandFrame({
    required this.visible,
    required this.text,
    required this.trans,
    required this.lineIndex,
  });

  const LyricIslandFrame.hidden()
      : visible = false,
        text = '',
        trans = '',
        lineIndex = -1;

  final bool visible;
  final String text;
  final String trans;
  final int lineIndex;

  /// 没在放、正在换歌、没有歌：不显示。
  /// 有当前句就用当前句；空行往前找最近一句有字的，翻译跟着那一句。
  /// 一句都还没到，就退到「歌名 · 歌手」。
  static LyricIslandFrame compose({
    required bool playing,
    required bool loading,
    required bool hasSong,
    required String title,
    required String artist,
    required List<LyricLine> lines,
    required int index,
    Map<double, String> transMap = const {},
  }) {
    if (!playing || loading || !hasSong) return const LyricIslandFrame.hidden();

    final i = _pick(lines, index);
    if (i >= 0) {
      final line = lines[i];
      return LyricIslandFrame(
        visible: true,
        text: line.text.trim(),
        trans: transAt(transMap, line.time).trim(),
        lineIndex: i,
      );
    }

    final name = title.trim();
    final who = artist.trim();
    final String text;
    if (name.isEmpty && who.isEmpty) return const LyricIslandFrame.hidden();
    if (name.isEmpty) {
      text = who;
    } else if (who.isEmpty || who == name) {
      text = name;
    } else {
      text = '$name · $who';
    }
    return LyricIslandFrame(visible: true, text: text, trans: '', lineIndex: -1);
  }

  static int _pick(List<LyricLine> lines, int index) {
    if (lines.isEmpty) return -1;
    if (index >= lines.length) index = lines.length - 1;
    for (var i = index; i >= 0; i--) {
      if (lines[i].text.trim().isNotEmpty) return i;
    }
    return -1;
  }
}

/// 桌面顶部的歌词胶囊。
///
/// 换句、暂停、换歌才走 `update`。播放位置单独走 `clock`，
/// 而且只在和上次锚点差了一截时才发 —— 逐字高亮在原生侧用本地时钟补间，
/// 不然位置事件每秒几十次，通道会被刷满。
class LyricIslandService {
  LyricIslandService._();

  static final LyricIslandService instance = LyricIslandService._();

  static const _channel = MethodChannel('elia/lyric_island');

  bool enabled = false;
  String _last = '';
  int _anchorMs = 0;
  int _anchorAt = 0;
  String _coverFor = '';
  int _coverGen = 0;
  final Map<String, Uint8List> _coverCache = {};

  Future<void> init() async {
    enabled = LocalStore.get(kDesktopLyricKey) == '1';
    player.addListener(_onPlayer);
    player.positionNotifier.addListener(_onPosition);
    if (!enabled) return;
    await _apply(true);
  }

  /// 开关立刻改内存里的值（设置页跟着刷新），窗口的创建放到通道那边。
  void setEnabled(bool value) {
    if (enabled == value) return;
    enabled = value;
    LocalStore.set(kDesktopLyricKey, value ? '1' : '0');
    unawaited(_apply(value));
  }

  void _onPlayer() {
    if (!enabled) return;
    _push();
  }

  void _onPosition() {
    if (!enabled || !player.isPlaying || player.isLoading) return;
    final ms = player.position.inMilliseconds;
    final now = DateTime.now().millisecondsSinceEpoch;
    final predicted = _anchorMs + (now - _anchorAt);
    // 正常播放的偏差不用管，原生时钟自己在走。
    // 差了一截才是拖动进度，或者后端把位置一下纠正了。
    if ((ms - predicted).abs() < 160) return;
    _note(ms);
    _channel.invokeMethod('clock', {
      'positionMs': ms,
    }).catchError((Object e) {
      fileLogger.warn('LyricIsland', 'clock 失败: $e');
      return null;
    });
  }

  void _note(int ms) {
    _anchorMs = ms;
    _anchorAt = DateTime.now().millisecondsSinceEpoch;
  }

  Future<void> _apply(bool value) async {
    try {
      final ok = await _channel.invokeMethod<bool>('setEnabled', {
        'enabled': value,
      });
      if (value && ok != true) {
        fileLogger.warn('LyricIsland', '窗口没有建起来');
        return;
      }
      fileLogger.info('LyricIsland', value ? '已打开' : '已关闭');
      if (value) _push(force: true);
      if (!value) {
        _last = '';
        _coverFor = '';
      }
    } catch (e) {
      fileLogger.warn('LyricIsland', 'setEnabled 失败: $e');
    }
  }

  void _push({bool force = false}) {
    final song = player.currentSong;
    final bundle = song == null ? null : LyricCache.peek(song.mid);
    final frame = LyricIslandFrame.compose(
      playing: player.isPlaying,
      loading: player.isLoading,
      hasSong: song != null,
      title: song?.name ?? '',
      artist: song?.artist ?? '',
      lines: player.lyricLines,
      index: player.activeLyricIndex,
      transMap: bundle?.transMap ?? const {},
    );

    final LyricLine? line = frame.lineIndex >= 0 &&
            frame.lineIndex < player.lyricLines.length
        ? player.lyricLines[frame.lineIndex]
        : null;
    final words = <Map<String, Object>>[];
    if (line != null && line.hasWords) {
      for (final w in line.words!) {
        words.add({
          't': (w.time * 1000).round(),
          'd': (w.duration * 1000).round(),
          's': w.text,
        });
      }
    }
    final startMs = line == null ? 0 : (line.time * 1000).round();
    var endMs = startMs;
    if (line != null) {
      final next = frame.lineIndex + 1;
      if (next < player.lyricLines.length) {
        endMs = (player.lyricLines[next].time * 1000).round();
      } else {
        endMs = startMs + 4000;
      }
    }

    final sig = '${frame.visible}|${song?.mid}|${frame.text}|${frame.trans}|'
        '${words.length}|$startMs|$endMs';
    final pos = player.position.inMilliseconds;
    if (!force && sig == _last) return;
    _last = sig;
    _note(pos);

    _channel.invokeMethod('update', {
      'song': song?.mid ?? '',
      'playing': frame.visible,
      'positionMs': pos,
      'text': frame.text,
      'trans': frame.trans,
      'sweep': frame.lineIndex >= 0,
      'startMs': startMs,
      'endMs': endMs,
      'words': words,
    }).catchError((Object e) {
      fileLogger.warn('LyricIsland', 'update 失败: $e');
      return null;
    });

    if (song != null && song.mid != _coverFor) {
      _coverFor = song.mid;
      unawaited(_pushCover(song));
    }
  }

  Future<void> _pushCover(Song song) async {
    final gen = ++_coverGen;
    final url = ApiClient.getProxyImageUrl(song.pic);
    Uint8List bytes = Uint8List(0);
    if (url.isNotEmpty) {
      try {
        var cached = _coverCache[url];
        if (cached == null) {
          final res = await http
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 8));
          if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
            cached = await _toDecodable(res.bodyBytes);
            _coverCache[url] = cached;
            if (_coverCache.length > 8) {
              _coverCache.remove(_coverCache.keys.first);
            }
          }
        }
        if (cached != null) bytes = cached;
      } catch (e) {
        fileLogger.warn('LyricIsland', '封面取回失败: $e');
      }
    }
    if (gen != _coverGen || song.mid != player.currentSong?.mid) return;
    try {
      await _channel.invokeMethod('cover', {
        'song': song.mid,
        'bytes': bytes,
      });
    } catch (e) {
      fileLogger.warn('LyricIsland', 'cover 失败: $e');
    }
  }

  /// 封面经常是 WebP，GDI+ 解不了。JPEG/PNG 原样送，其余先转成 PNG。
  Future<Uint8List> _toDecodable(Uint8List bytes) async {
    bool startsWith(List<int> magic) {
      if (bytes.length < magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (bytes[i] != magic[i]) return false;
      }
      return true;
    }

    if (startsWith(const [0xFF, 0xD8, 0xFF]) ||
        startsWith(const [0x89, 0x50, 0x4E, 0x47])) {
      return bytes;
    }
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return data == null ? bytes : data.buffer.asUint8List();
  }
}

final lyricIsland = LyricIslandService.instance;
