import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../core/file_logger.dart';
import '../core/local_store.dart';
import '../core/lyric.dart';
import '../models/song.dart';
import 'api_client.dart';
import 'lyric_cache.dart';

enum PlayMode { repeatAll, repeatOne, shuffle }

extension PlayModeX on PlayMode {
  String get id => switch (this) {
        PlayMode.repeatAll => 'repeat-all',
        PlayMode.repeatOne => 'repeat-one',
        PlayMode.shuffle => 'shuffle',
      };

  String get label => switch (this) {
        PlayMode.repeatAll => '列表循环',
        PlayMode.repeatOne => '单曲循环',
        PlayMode.shuffle => '随机播放',
      };

  static PlayMode fromId(String? id) => switch (id) {
        'repeat-one' => PlayMode.repeatOne,
        'shuffle' => PlayMode.shuffle,
        _ => PlayMode.repeatAll,
      };
}

/// 播放器 —— `public/dist/js/player.js` 的 Dart 移植。
class PlayerController extends ChangeNotifier {
  PlayerController._();

  static final PlayerController instance = PlayerController._();

  final AudioPlayer _player = AudioPlayer();

  Song? currentSong;
  String? currentUrl;
  bool isPlaying = false;
  bool isLoading = false;

  /// 正在准备新歌（已停掉旧歌、等新歌地址）。
  /// 期间要**丢弃位置/时长事件** —— 它们是上一首迟到的，会把进度条搅乱。
  bool _preparing = false;
  PlayMode playMode = PlayMode.repeatAll;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  double volume = 0.8;

  List<LyricLine> lyricLines = const [];
  int activeLyricIndex = -1;

  /// 歌词区是否处于「暂停」展示态（显示歌名而非歌词）
  bool lyricPaused = true;

  String? errorMessage;
  Timer? _errorTimer;
  Timer? _lastLyricTimer;
  int _retryCount = 0;
  int _lyricGeneration = 0;
  bool _disposed = false;

  /// 播放结束 / 上一首 / 下一首 回调，action ∈ {next, prev, random}
  void Function(String action)? onEnded;

  /// 播放模式切换回调
  void Function(PlayMode mode)? onModeChange;

  bool get hasSong => currentSong != null;

  Future<void> init() async {
    playMode = PlayModeX.fromId(LocalStore.get('qqmusic_play_mode'));
    final savedVolume = double.tryParse(LocalStore.get('qqmusic_volume') ?? '');
    volume = savedVolume ?? 0.8;
    await _player.setVolume(volume);

    _player.onPositionChanged.listen((p) {
      if (_disposed || _preparing) return;
      position = p;
      _updateActiveLyric();
      notifyListeners();
    });

    _player.onDurationChanged.listen((d) {
      if (_disposed) return;
      // ⚠️ 这里**不能**用 _preparing 屏蔽：新歌的时长事件常常在 play() 完成前
      // 就到达，屏蔽掉会导致右侧时长一直停在 0:00。
      // 旧歌已被 stop()，不会再发时长事件，无需屏蔽。
      duration = d;
      notifyListeners();
    });

    _player.onPlayerStateChanged.listen((s) {
      if (_disposed) return;
      final playing = s == PlayerState.playing;
      if (playing != isPlaying) {
        isPlaying = playing;
        lyricPaused = !playing;
        notifyListeners();
      }
    });

    _player.onPlayerComplete.listen((_) {
      if (_disposed) return;
      _handleEnded();
    });

    _player.onLog.listen((msg) {
      if (msg.startsWith('E/flutter') || msg.contains('error')) {
        debugPrint('[Player] $msg');
      }
    });
  }

  // ------------------------------------------------------------ 播放控制

  /// 立刻把歌曲挂上并进入**加载态**，让播放栏马上展开。
  ///
  /// 对齐 Electron：点播放时播放栏立刻出现并转圈，而不是等网络取回播放地址
  /// 之后才「突然」弹出来（用户反馈「播放要等一会」）。
  void prepare(Song song) {
    currentSong = song;
    currentUrl = '';
    position = Duration.zero;
    duration = Duration.zero;
    lyricLines = const [];
    activeLyricIndex = -1;
    lyricPaused = false;
    isLoading = true;
    _retryCount = 0;
    _lastLyricTimer?.cancel();

    // ⚠️ 必须立刻停掉正在播放的旧歌：
    // 否则新歌加载期间旧歌会继续出声，而且它的位置事件会持续覆盖 position
    // —— 表现为「进度条清零、右侧时长归零，但左侧时间还在正常增加」。
    _preparing = true;
    unawaited(_player.stop().catchError((_) {}));
    fileLogger.info('Player', 'prepare mid=${song.mid} name=${song.name}（停旧歌）');

    notifyListeners();
  }

  /// 取播放地址失败时收掉加载态（播放栏保留，由调用方提示错误）
  void cancelLoading() {
    isLoading = false;
    _preparing = false;
    notifyListeners();
  }

  Future<void> play(Song song, String url) async {
    currentSong = song;
    currentUrl = url;
    _retryCount = 0;
    _lastLyricTimer?.cancel();

    position = Duration.zero;
    duration = Duration.zero;
    lyricLines = const [];
    activeLyricIndex = -1;
    lyricPaused = false;
    isLoading = true;
    notifyListeners();

    _loadLyrics(song);

    final proxyUrl = ApiClient.getProxyAudioUrl(url);
    try {
      // ⚠️ 这里必须**再停一次并 await**：prepare() 里的 stop() 是 fire-and-forget，
      // 若它还没结束就调用 play()，两者会竞态 —— 实测旧歌会继续出声、
      // 它的位置事件还会把新歌的进度覆盖掉。
      await _player.stop();
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setVolume(volume);
      await _player.play(UrlSource(proxyUrl));
      _preparing = false; // 新歌已开始，后续事件都属于它
      isLoading = false;
      fileLogger.info('Player', 'playing mid=${song.mid} name=${song.name}');
      notifyListeners();
    } catch (e) {
      debugPrint('[Player] play failed: $e');
      await _retryWithLowerQuality();
    }
  }

  Future<void> _retryWithLowerQuality() async {
    final song = currentSong;
    if (song == null || _retryCount >= 1) {
      showError('音频加载失败');
      isLoading = false;
      isPlaying = false;
      notifyListeners();
      return;
    }
    _retryCount++;
    try {
      final url = await ApiClient.getSongUrl(song.mid, false, song);
      if (url.isEmpty) throw Exception('empty url');
      currentUrl = url;
      await _player.play(UrlSource(ApiClient.getProxyAudioUrl(url)));
      isLoading = false;
      notifyListeners();
    } catch (e) {
      showError('音频加载失败');
      isLoading = false;
      isPlaying = false;
      notifyListeners();
    }
  }

  Future<void> togglePlay() async {
    if (currentSong == null) return;
    try {
      if (isPlaying) {
        await _player.pause();
      } else {
        await _player.resume();
      }
    } catch (e) {
      showError('播放失败');
    }
  }

  Future<void> close() async {
    try {
      await _player.stop();
    } catch (_) {}
    currentSong = null;
    currentUrl = null;
    isPlaying = false;
    isLoading = false;
    position = Duration.zero;
    duration = Duration.zero;
    lyricLines = const [];
    activeLyricIndex = -1;
    lyricPaused = true;
    notifyListeners();
  }

  /// 按百分比跳转（0~1），与原 `seek(percent)` 一致
  Future<void> seekPercent(double percent) async {
    if (!percent.isFinite || percent < 0 || percent > 1) return;
    if (duration.inMilliseconds <= 0) return;
    await _player.seek(Duration(milliseconds: (percent * duration.inMilliseconds).round()));
  }

  Future<void> setVolume(double v) async {
    volume = v.clamp(0.0, 1.0);
    await _player.setVolume(volume);
    LocalStore.set('qqmusic_volume', volume.toString());
    notifyListeners();
  }

  void cycleMode() {
    final modes = PlayMode.values;
    final idx = modes.indexOf(playMode);
    playMode = modes[(idx + 1) % modes.length];
    LocalStore.set('qqmusic_play_mode', playMode.id);
    onModeChange?.call(playMode);
    notifyListeners();
  }

  void _handleEnded() {
    if (playMode == PlayMode.repeatOne) {
      _player.seek(Duration.zero);
      _player.resume();
      return;
    }
    _lastLyricTimer?.cancel();
    isPlaying = false;
    isLoading = false;
    position = Duration.zero;
    notifyListeners();
    onEnded?.call(playMode == PlayMode.shuffle ? 'random' : 'next');
  }

  void showError(String msg) {
    errorMessage = msg;
    _errorTimer?.cancel();
    _errorTimer = Timer(const Duration(seconds: 4), () {
      errorMessage = null;
      notifyListeners();
    });
    notifyListeners();
  }

  // ------------------------------------------------------------ 歌词

  Future<void> _loadLyrics(Song song) async {
    final gen = ++_lyricGeneration;
    if (song.mid.isEmpty) {
      lyricLines = const [];
      notifyListeners();
      return;
    }
    try {
      // 走共享缓存：播放时即预取，歌词弹窗稍后打开可直接命中（不再重复拉网络）
      final bundle = await LyricCache.load(song.mid, isNetease: song.isNetease);
      if (gen != _lyricGeneration) return;
      lyricLines = bundle?.lines ?? const [];
      activeLyricIndex = -1;
      notifyListeners();
    } catch (e) {
      if (gen != _lyricGeneration) return;
      lyricLines = const [];
      notifyListeners();
    }
  }

  void _updateActiveLyric() {
    if (lyricLines.isEmpty) return;
    final ct = position.inMilliseconds / 1000.0;
    var idx = -1;
    for (var i = 0; i < lyricLines.length; i++) {
      if (lyricLines[i].time <= ct) {
        idx = i;
      } else {
        break;
      }
    }
    if (idx == activeLyricIndex || idx < 0) return;
    activeLyricIndex = idx;

    if (idx == lyricLines.length - 1) {
      _lastLyricTimer?.cancel();
      _lastLyricTimer = Timer(const Duration(seconds: 5), () {
        lyricPaused = true;
        notifyListeners();
      });
    } else {
      _lastLyricTimer?.cancel();
      _lastLyricTimer = null;
      if (isPlaying && lyricPaused) lyricPaused = false;
    }
  }

  /// 播放器进度条位置（0~1）
  double get progress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _disposed = true;
    _player.dispose();
    super.dispose();
  }
}

final player = PlayerController.instance;
