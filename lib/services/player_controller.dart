import 'dart:async';
import 'package:path/path.dart' as p;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../core/file_logger.dart';
import '../core/local_store.dart';
import '../core/lyric.dart';
import '../models/song.dart';
import 'api_client.dart';
import 'audio_cache.dart';
import 'lyric_cache.dart';
import 'silence_probe.dart';

enum PlayMode { sequential, reverse, repeatAll, repeatOne, shuffle }

extension PlayModeX on PlayMode {
  String get id => switch (this) {
        PlayMode.sequential => 'sequential',
        PlayMode.reverse => 'reverse',
        PlayMode.repeatAll => 'repeat-all',
        PlayMode.repeatOne => 'repeat-one',
        PlayMode.shuffle => 'shuffle',
      };

  String get label => switch (this) {
        PlayMode.sequential => '顺序播放',
        PlayMode.reverse => '倒序播放',
        PlayMode.repeatAll => '列表循环',
        PlayMode.repeatOne => '单曲循环',
        PlayMode.shuffle => '随机播放',
      };

  /// 走到队尾就停 —— 顺序与倒序是这一对，区别于各种循环
  bool get stopsAtEnd =>
      this == PlayMode.sequential || this == PlayMode.reverse;

  static PlayMode fromId(String? id) => switch (id) {
        'sequential' => PlayMode.sequential,
        'reverse' => PlayMode.reverse,
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

  /// 当前这首歌有没有**真的**加载进底层播放器。
  ///
  /// 两种情况为 false：
  ///  * 重启后恢复的「播放态记忆」—— 只把歌挂到播放栏上，没碰音频源；
  ///  * 上一次取播放地址失败。
  /// 这两种状态下，底层播放器里留着的还是**上一首**的源，
  /// 直接 `resume()` 会把它放出来。
  bool _sourceLoaded = false;

  /// 加载成功后要跳到的位置（记忆态恢复、或失败重试后接着放）
  Duration? _pendingSeek;

  // ------------------------------------------------------------ 首尾静音
  //
  // 时间轴**保持原始**：跳开头用 seek，到结尾当「放完了」。进度条、歌词、
  // 播放位置记忆都还按原始时间走，不另造一套裁剪后的时长。
  final SilenceSkip _silence = SilenceSkip();

  /// 当前歌没有可播的源、需要重新取地址时回调。
  /// 由状态层注入（`AppState.playSong`）—— 服务层不反向依赖状态层。
  void Function(Song song)? onReloadRequested;

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

  /// 播到的时长明显短于这首歌本身 —— 上游给的是试听片段。
  /// 由上层决定怎么办（删缓存、提示用户）。
  void Function(Song song)? onShortAudio;

  /// 播放模式切换回调
  void Function(PlayMode mode)? onModeChange;

  bool get hasSong => currentSong != null;

  /// 播放位置单独广播，**不走** ChangeNotifier。
  ///
  /// 位置每秒变化几十次（Windows 后端几乎每帧都报一次），而 `notifyListeners`
  /// 的订阅方是整棵界面树 —— 实测播放时 AppShell.build 每秒被调用 70 多次，
  /// 帧率被这一件事吃掉。真正需要跟着位置走的只有进度条、时间显示和
  /// 歌词高亮，让它们各自监听这个 notifier 就够了。
  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);

  /// 歌名被改后同步到播放栏与系统媒体面板。
  ///
  /// 播放栏和 SMTC 读的都是 `currentSong`，只改歌单里那份不够 ——
  /// 会看到「列表里已经改名，播放栏还是旧名」。
  void renameCurrentSong(String mid, String newName) {
    final song = currentSong;
    if (song == null || song.mid != mid) return;
    currentSong = song.copyWith(name: newName);
    notifyListeners();
  }

  Future<void> init() async {
    playMode = PlayModeX.fromId(LocalStore.get('qqmusic_play_mode'));
    final savedVolume = double.tryParse(LocalStore.get('qqmusic_volume') ?? '');
    volume = savedVolume ?? 0.8;
    await _player.setVolume(volume);

    _player.onPositionChanged.listen((p) {
      if (_disposed || _preparing) return;
      position = p;
      positionNotifier.value = p;
      // 尾巴那段空白：到点就当这首唱完了，别让用户对着静音等几秒
      if (_silence.reachedEnd(p)) {
        _handleEnded();
        return;
      }
      // 只有「唱到下一句」这种低频变化才需要整棵树知道
      if (_updateActiveLyric()) notifyListeners();
    });

    _player.onDurationChanged.listen((d) {
      if (_disposed) return;
      // 这里**不能**用 _preparing 屏蔽：新歌的时长事件常常在 play() 完成前
      // 就到达，屏蔽掉会导致右侧时长一直停在 0:00。
      // 旧歌已被 stop()，不会再发时长事件，无需屏蔽。
      duration = d;
      notifyListeners();
      _checkShortAudio(d);
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
  /// 之后才「突然」弹出来。
  void prepare(Song song) {
    currentSong = song;
    currentUrl = '';
    _sourceLoaded = false;
    position = Duration.zero;
    positionNotifier.value = Duration.zero;
    duration = Duration.zero;
    lyricLines = const [];
    activeLyricIndex = -1;
    lyricPaused = false;
    isLoading = true;
    _retryCount = 0;
    _lastLyricTimer?.cancel();
    // 换歌了：上一首的静音区间与「已经跳过」的状态都作废
    _silence.reset();

    // 必须立刻停掉正在播放的旧歌：
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
    // 源没加载成：这时点播放不能 resume（那会放出上一首），要重新取地址
    _sourceLoaded = false;
    notifyListeners();
  }

  Future<void> play(Song song, String url) async {
    currentSong = song;
    currentUrl = url;
    _retryCount = 0;
    _lastLyricTimer?.cancel();

    position = Duration.zero;
    positionNotifier.value = Duration.zero;
    duration = Duration.zero;
    lyricLines = const [];
    activeLyricIndex = -1;
    lyricPaused = false;
    isLoading = true;
    notifyListeners();

    _loadLyrics(song);

    try {
      // 这里必须**再停一次并 await**：prepare() 里的 stop() 是 fire-and-forget，
      // 若它还没结束就调用 play()，两者会竞态 —— 实测旧歌会继续出声、
      // 它的位置事件还会把新歌的进度覆盖掉。
      await _player.stop();
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setVolume(volume);

      // 先看本地缓存：命中就直接播本地文件，完全不碰网络 ——
      // 也就不会再因为上游频控（HTTP 418）而放不出来。
      final cached = AudioDiskCache.find(song.mid);
      if (cached != null) {
        fileLogger.info('Player', '命中音频缓存 ${p.basename(cached.path)}');
        // 记下「这首歌刚被听过」——「30 天没听过就删」那条规则靠它
        AudioDiskCache.touch(song.mid);
        await _player.play(DeviceFileSource(cached.path));
      } else {
        await _player.play(UrlSource(ApiClient.getProxyAudioUrl(url)));
        // 边播边缓存：本次不等它，下一次播放就快了
        unawaited(AudioDiskCache.warm(song.mid, url));
      }
      _preparing = false; // 新歌已开始，后续事件都属于它
      _sourceLoaded = true;
      isLoading = false;
      // 记忆态恢复 / 失败重试：源就绪之后再跳回原来的位置
      await _seekToPending();
      await _skipLeadingSilence();
      savePlaybackState();
      fileLogger.info('Player', 'playing mid=${song.mid} name=${song.name}');
      notifyListeners();
    } catch (e) {
      debugPrint('[Player] play failed: $e');
      await _retryWithLowerQuality();
    }
  }

  /// 跳到 [_pendingSeek] 记下的位置（有的话）。
  ///
  /// seek 失败不该被当成「这首歌放不了」—— 位置不准总比整首放不出来好，
  /// 所以单独吞掉异常，不让它冒到 [play] 的 catch 里触发降码率重试。
  Future<void> _seekToPending() async {
    final target = _pendingSeek;
    _pendingSeek = null;
    if (target == null || target <= Duration.zero) return;
    position = target;
    positionNotifier.value = target;
    try {
      await _player.seek(target);
    } catch (e) {
      fileLogger.warn('Player', '跳到 ${target.inMilliseconds}ms 失败: $e');
    }
  }

  /// 应用一首歌的首尾静音探测结果（null = 没探出来 / 没有可跳的）。
  ///
  /// 结果一般比音频晚到（要解一次音频），所以这里可能是在歌已经放着的时候
  /// 被调用 —— 那时开头那段可能还没放完，正好跳过去。
  void applySilenceTrim(SilenceTrim? trim) {
    _silence.apply(trim);
    unawaited(_skipLeadingSilence());
  }

  /// 开头那段空白：一知道就跳过去。
  ///
  /// 只在「还停在空白里」的时候跳。用户自己拖回开头（[seekPercent]）时
  /// 会先立起「已经处理过」的标记，想听那段就听，不会再被顶走。
  Future<void> _skipLeadingSilence() async {
    // 源还没加载（记忆态、上次取地址失败）：等真正播的时候 [play] 会再调一次
    if (!_sourceLoaded) return;
    final target = _silence.leadingTarget(position);
    if (target == null) return;
    position = target;
    positionNotifier.value = target;
    try {
      await _player.seek(target);
    } catch (e) {
      fileLogger.warn('Player', '跳过开头无声失败: $e');
    }
  }

  /// 单曲循环时从头发一遍：开头那段空白也要重新跳
  Future<void> _restartFromStart() async {
    try {
      await _player.seek(Duration.zero);
      await _player.resume();
    } catch (_) {}
    // 等跳回去了再复位，否则「放完了」那条判定会被上一轮的位置事件再触发一次
    _silence.rewind();
    await _skipLeadingSilence();
  }

  Future<void> _retryWithLowerQuality() async {
    final song = currentSong;
    if (song == null || _retryCount >= 1) {
      showError('音频加载失败');
      isLoading = false;
      isPlaying = false;
      _preparing = false;
      _sourceLoaded = false;
      notifyListeners();
      return;
    }
    _retryCount++;
    try {
      final url = await ApiClient.getSongUrl(song.mid, false, song);
      if (url.isEmpty) throw Exception('empty url');
      currentUrl = url;
      await _player.play(UrlSource(ApiClient.getProxyAudioUrl(url)));
      _preparing = false;
      _sourceLoaded = true;
      isLoading = false;
      await _seekToPending();
      savePlaybackState();
      notifyListeners();
    } catch (e) {
      showError('音频加载失败');
      isLoading = false;
      isPlaying = false;
      // 加载失败也要把「准备中」收掉，否则位置事件会被一直丢弃
      _preparing = false;
      _sourceLoaded = false;
      notifyListeners();
    }
  }

  Future<void> togglePlay() async {
    final song = currentSong;
    if (song == null) return;
    // 没有可播的源：重启后的记忆态、或上一次取地址失败。
    // 这两种情况下底层播放器里是**上一首**的源，resume() 会把它放出来 ——
    // 表现为「音频拉取失败后点播放，放的是上一首」。
    // 改为重新取一次地址，加载完成后自动跳到记住的位置。
    if (!_sourceLoaded) {
      _pendingSeek = position > Duration.zero ? position : null;
      onReloadRequested?.call(song);
      return;
    }
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

  /// 暂停（拖动进度条时用；已在暂停状态则忽略）
  Future<void> pause() async {
    if (!isPlaying) return;
    try {
      await _player.pause();
      savePlaybackState();
    } catch (_) {}
  }

  /// 恢复播放（拖完进度条后还原拖动前的状态）
  Future<void> resume() async {
    // 没有源就没什么可恢复的（见 togglePlay 的说明）
    if (!_sourceLoaded || isPlaying || currentSong == null) return;
    try {
      await _player.resume();
    } catch (_) {}
  }

  Future<void> close() async {
    try {
      await _player.stop();
    } catch (_) {}
    currentSong = null;
    currentUrl = null;
    isPlaying = false;
    isLoading = false;
    _sourceLoaded = false;
    _pendingSeek = null;
    position = Duration.zero;
    positionNotifier.value = Duration.zero;
    duration = Duration.zero;
    lyricLines = const [];
    activeLyricIndex = -1;
    lyricPaused = true;
    // 用户主动关掉播放栏 = 不想再记着这首歌，记忆一起清掉
    _clearPlaybackState();
    notifyListeners();
  }

  /// 按百分比跳转（0~1），与原 `seek(percent)` 一致
  Future<void> seekPercent(double percent) async {
    if (!percent.isFinite || percent < 0 || percent > 1) return;
    if (duration.inMilliseconds <= 0) return;
    // 用户自己拖的：他要是拖回开头那段空白，就让他听，别再自动顶走
    _silence.userSeeked();
    final target =
        Duration(milliseconds: (percent * duration.inMilliseconds).round());
    // 源还没加载（记忆态 / 上次取地址失败）：往底层的旧源上 seek 是白费，
    // 只把位置记下来，等真正加载时再跳（见 _seekToPending）。
    if (!_sourceLoaded) {
      _pendingSeek = target;
      position = target;
      positionNotifier.value = target;
      notifyListeners();
      return;
    }
    await _player.seek(target);
  }

  Future<void> setVolume(double v) async {
    volume = v.clamp(0.0, 1.0);
    await _player.setVolume(volume);
    LocalStore.set('qqmusic_volume', volume.toString());
    notifyListeners();
  }

  /// 直接指定播放模式（播放栏的二级菜单用）。
  ///
  /// 以前是「点一次换下一个」的循环切换：想从「列表循环」切到「随机」得连点
  /// 两次、中间还经过「单曲循环」—— 用户没法直接选自己要的那个。
  void setMode(PlayMode mode) {
    if (playMode == mode) return;
    playMode = mode;
    LocalStore.set('qqmusic_play_mode', playMode.id);
    onModeChange?.call(playMode);
    notifyListeners();
  }

  // ------------------------------------------------------------ 播放态记忆

  static const _kLastMid = 'last_play_mid';
  static const _kLastPosition = 'last_play_position';
  static const _kLastDuration = 'last_play_duration';

  /// 把「正在听的是哪首、听到哪」落盘。
  ///
  /// 只写内存，真正的落盘由 `LocalStore` 的防抖 / 退出前的 `flush()` 负责
  /// （见 `main.dart` 的 `_forceExit`）。
  void savePlaybackState() {
    final song = currentSong;
    if (song == null) {
      _clearPlaybackState();
      return;
    }
    LocalStore.set(_kLastMid, song.mid);
    LocalStore.set(_kLastPosition, '${position.inMilliseconds}');
    LocalStore.set(_kLastDuration, '${duration.inMilliseconds}');
  }

  void _clearPlaybackState() {
    LocalStore.remove(_kLastMid);
    LocalStore.remove(_kLastPosition);
    LocalStore.remove(_kLastDuration);
  }

  /// 恢复上次关闭时的播放态：把歌与进度放回播放栏，**不自动播放**。
  ///
  /// 只写状态、不碰音频源（`_sourceLoaded` 保持 false），所以启动时既没有
  /// 网络请求也没有声音；用户点播放时才真正取地址，并跳到记住的位置
  /// （见 [togglePlay] 与 [_seekToPending]）。
  ///
  /// [lookup] 由调用方传 `AppState.findSong` —— 服务层不反向依赖状态层。
  void restoreLastPlayback(Song? Function(String mid) lookup) {
    final mid = LocalStore.get(_kLastMid) ?? '';
    if (mid.isEmpty) return;
    final song = lookup(mid);
    // 歌已经被移出歌单了：这份记忆没有意义，顺手清掉
    if (song == null) {
      _clearPlaybackState();
      return;
    }

    final posMs = int.tryParse(LocalStore.get(_kLastPosition) ?? '') ?? 0;
    final durMs = int.tryParse(LocalStore.get(_kLastDuration) ?? '') ?? 0;

    currentSong = song;
    duration = Duration(milliseconds: durMs);
    // 位置比时长还大说明这份记录对不上了（换了歌、时长没记准），从头开始
    final valid = durMs > 0 && posMs > 0 && posMs < durMs;
    position = Duration(milliseconds: valid ? posMs : 0);
    positionNotifier.value = position;
    isLoading = false;
    isPlaying = false;
    _sourceLoaded = false;
    _preparing = false;
    // 与「暂停」一致：歌词区显示歌名，而不是停在某一句歌词上
    lyricPaused = true;
    lyricLines = const [];
    activeLyricIndex = -1;

    fileLogger.info(
      'Player',
      '恢复上次播放态 mid=$mid 位置=${position.inMilliseconds}ms '
      '时长=${duration.inMilliseconds}ms',
    );
    notifyListeners();
  }

  /// 已经上报过试听片段的歌，别重复提示
  String? _shortAudioMid;

  /// 试听片段的判据：**这首歌本身不短，但只拿到一小段**。
  ///
  /// 只看「播到的很短」会误伤真正的小段子，所以要求歌曲元数据里的时长
  /// 至少 1.5 分钟。30 秒 / 60 秒是网易云试听的常见长度。
  void _checkShortAudio(Duration d) {
    final song = currentSong;
    if (song == null || song.duration < 90000) return;
    final ms = d.inMilliseconds;
    if (ms <= 0 || ms > 65000) return;
    if (_shortAudioMid == song.mid) return;
    _shortAudioMid = song.mid;
    onShortAudio?.call(song);
  }

  void _handleEnded() {
    if (playMode == PlayMode.repeatOne) {
      position = Duration.zero;
      positionNotifier.value = Duration.zero;
      unawaited(_restartFromStart());
      return;
    }
    _lastLyricTimer?.cancel();
    isPlaying = false;
    isLoading = false;
    position = Duration.zero;
    positionNotifier.value = Duration.zero;
    notifyListeners();
    // 交给上层按播放队列决定下一首 —— 队尾怎么处理（停 / 绕回 / 重洗）
    // 是队列的事，播放器不该知道
    onEnded?.call('next');
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
      final bundle = await LyricCache.load(song.mid, source: song.source);
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

  /// 歌词被编辑保存后重新装载。
  ///
  /// 播放栏的歌词是播放器自己持有的 `lyricLines`，与歌词弹窗**不是同一份**：
  /// 弹窗读 `AppState.currentLyricParsed`，播放器读 `_loadLyrics` 的结果。
  /// 只刷新弹窗的话，正在播放的这首歌会一直显示保存前的旧歌词 ——
  /// 表现为「弹窗里已经是新歌词，播放栏还是旧的」。
  ///
  /// 调用前 `LyricCache` 已被作废，所以这里会重新读一遍本地自定义歌词并重新解析。
  Future<void> reloadLyrics() async {
    final song = currentSong;
    if (song == null) return;
    await _loadLyrics(song);
  }

  /// 返回**是否换了行** —— 调用方据此决定要不要通知界面（换行是低频事件，
  /// 而它每次都被位置事件调用）。
  bool _updateActiveLyric() {
    if (lyricLines.isEmpty) return false;
    final ct = position.inMilliseconds / 1000.0;

    // 快路径：位置事件每秒几十次，绝大多数时候还停在**同一句**里。
    // 每次都从头扫一遍是 O(n)（长歌一两百句），纯属白费。
    final cur = activeLyricIndex;
    if (cur >= 0 &&
        cur < lyricLines.length &&
        lyricLines[cur].time <= ct &&
        (cur + 1 >= lyricLines.length || lyricLines[cur + 1].time > ct)) {
      return false;
    }

    var idx = -1;
    for (var i = 0; i < lyricLines.length; i++) {
      if (lyricLines[i].time <= ct) {
        idx = i;
      } else {
        break;
      }
    }
    if (idx == activeLyricIndex || idx < 0) return false;
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
    return true;
  }

  /// 播放器进度条位置（0~1）
  double get progress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _disposed = true;
    positionNotifier.dispose();
    _player.dispose();
    super.dispose();
  }
}

final player = PlayerController.instance;
