import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/file_logger.dart';
import '../models/song.dart';
import 'api_client.dart';
import 'player_controller.dart';
import '../state/app_state.dart';

/// Windows 系统媒体控件（SMTC）—— 让应用出现在系统媒体面板
/// （音量弹层 / 锁屏），并接管硬件媒体键。
///
/// 数据**全部来自 [player]**：它是播放状态的唯一来源，这里只做转述，
/// 不另建一份播放状态，否则两边迟早会对不上。
class SmtcService {
  SmtcService._();

  static final SmtcService instance = SmtcService._();

  static const _channel = MethodChannel('elia/smtc');

  /// 位置推送的最小间隔。
  ///
  /// audioplayers 的位置事件大约 200ms 一次，而每次推送都是一次跨进程
  /// COM 调用 —— 全推过去既浪费，也会让面板上的进度条一顿一顿的。
  /// 换歌、播放状态变化、seek 之后会强制推一次，所以这里只影响「播放中」。
  static const _timelineIntervalMs = 1000;

  bool _ready = false;
  String? _mid;
  String? _title;
  bool? _playing;
  int _lastTimelineAt = 0;
  final Map<String, Uint8List> _coverCache = {};

  /// 建会话并开始跟随播放器。系统不支持时静默降级（不影响播放本身）。
  Future<void> init() async {
    _channel.setMethodCallHandler(_onNativeCall);
    try {
      _ready = await _channel.invokeMethod<bool>('init') ?? false;
    } catch (e) {
      _ready = false;
      fileLogger.error('SMTC', '初始化异常: $e');
    }
    if (!_ready) {
      fileLogger.warn('SMTC', '会话建立失败，系统媒体面板与媒体键不可用');
      return;
    }
    fileLogger.info('SMTC', '会话已建立');
    player.addListener(_onPlayer);
    _sync();
  }

  /// 释放会话（退出前调用；进程直接结束时由系统回收，不调用也不会残留）
  Future<void> dispose() async {
    player.removeListener(_onPlayer);
    try {
      await _channel.invokeMethod('dispose');
    } catch (_) {}
    _ready = false;
  }

  // ------------------------------------------------------------ 播放器 → 系统

  void _onPlayer() {
    if (_ready) _sync();
  }

  void _sync({bool forceTimeline = false}) {
    final song = player.currentSong;

    // 没有歌：收掉会话，别在媒体面板上留一个空的条目
    if (song == null) {
      if (_mid != null) {
        _mid = null;
        _playing = null;
        _push('status', {'status': 'stopped'});
        _push('enabled', {'enabled': false});
      }
      return;
    }

    // 去重按「mid + 歌名」：mid 没变但名字被改过时，面板上的标题也得跟着换
    if (song.mid != _mid || song.name != _title) {
      _mid = song.mid;
      _title = song.name;
      _push('enabled', {'enabled': true});
      _push('metadata', {
        'title': song.name,
        'artist': song.artist,
        'album': song.album,
      });
      unawaited(_pushCover(song));
      forceTimeline = true;
    }

    if (player.isPlaying != _playing) {
      _playing = player.isPlaying;
      _push('status', {'status': player.isPlaying ? 'playing' : 'paused'});
      forceTimeline = true;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!forceTimeline && now - _lastTimelineAt < _timelineIntervalMs) return;
    _lastTimelineAt = now;
    _push('timeline', {
      'positionMs': player.position.inMilliseconds,
      'durationMs': player.duration.inMilliseconds,
    });
  }

  void _push(String method, [Object? args]) {
    _channel.invokeMethod(method, args).catchError((Object e) {
      fileLogger.warn('SMTC', '$method 失败: $e');
      return null;
    });
  }

  /// 把封面转成系统一定解得了的格式。
  ///
  /// 缩略图最终由 Windows 图像组件（WIC）解码，而 QQ 的封面经常是 **WebP**
  /// —— 跟 URL 后缀是不是 `.jpg` 无关，取决于上游的 content negotiation。
  /// 系统没装 WebP 解码扩展时，塞进去既不报错也不显示，面板上就一直空着。
  /// 所以非 JPEG/PNG 的先在这里解一遍、重新编码成 PNG。
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

  /// 封面走内存流交给原生。
  ///
  /// 封面本来就要经本地代理取一次给界面用，这里复用同一个地址再取一遍字节，
  /// 比让系统进程去访问 127.0.0.1 上的本地服务可靠得多。
  Future<void> _pushCover(Song song) async {
    final url = ApiClient.getProxyImageUrl(song.pic);
    if (url.isEmpty) {
      fileLogger.warn('SMTC', '这首歌没有封面地址');
      return;
    }
    try {
      var bytes = _coverCache[url];
      if (bytes == null) {
        final res =
            await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
          fileLogger.warn('SMTC', '封面取回失败: HTTP ${res.statusCode}');
          return;
        }
        final raw = res.bodyBytes;
        // 封面失败是「静默」的（面板上只是空白），所以把原始字节数、图片魔数
        // 都记下来 —— 出问题时一眼能看出是没取到、格式不对，还是原生没塞进去。
        final magic = raw.length >= 4
            ? raw
                .sublist(0, 4)
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join()
            : '';
        bytes = await _toDecodable(raw);
        fileLogger.info('SMTC',
            '封面 原始=${raw.length}B magic=$magic → 送出=${bytes.length}B');
        _coverCache[url] = bytes;
        // 只留最近几首，长播一个歌单时不让它无限涨
        if (_coverCache.length > 8) _coverCache.remove(_coverCache.keys.first);
      }
      // 取封面的过程中可能已经换歌了，别把旧封面盖上去
      if (song.mid != _mid) return;
      final status = await _channel.invokeMethod<String>('thumbnail', bytes);
      fileLogger.info('SMTC', '封面回执: ${status ?? 'null'}');
    } catch (e) {
      fileLogger.warn('SMTC', '封面处理失败: $e');
    }
  }

  // ------------------------------------------------------------ 系统 → 播放器

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'onEvent') return;
    final args = (call.arguments as Map?) ?? const {};
    final event = args['event'];

    // 媒体键接管的决策日志（判断在原生侧做，这里只负责落到文件里）
    if (event == 'keylog') {
      fileLogger.info('SMTC', '媒体键 → ${args['what']}  ${args['detail']}');
      return;
    }

    fileLogger.info('SMTC', '收到系统事件: $event');

    switch (event) {
      // 明确的播放/暂停，**不是** toggle：
      // 系统（以及我们自己的媒体键分派）发来的是确定动作，
      // 用 toggle 会出现「按播放反而暂停」这种反效果。
      case 'play':
        await player.resume();
        break;
      case 'pause':
        await player.pause();
        break;
      case 'next':
        app.handleEndedAction('next');
        break;
      case 'previous':
        app.handleEndedAction('prev');
        break;
      case 'stop':
        await player.close();
        break;
      case 'seek':
        final ms = (args['positionMs'] as num?)?.toDouble() ?? 0;
        final total = player.duration.inMilliseconds.toDouble();
        if (total > 0) await player.seekPercent(ms / total);
        break;
      default:
        return;
    }

    // 上面几个动作都是异步的，等它们落地后再推一次状态，
    // 否则面板上的按钮/进度会短暂地和真实状态不一致。
    _sync(forceTimeline: true);
  }
}

final smtc = SmtcService.instance;
