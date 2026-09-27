import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/file_logger.dart';
import '../models/song.dart';
import 'api_client.dart';
import 'bilibili_service.dart';
import 'player_controller.dart';

/// B站音源的「视频背景」。
///
/// B站的投稿本来就是视频，听歌时把**同一支视频**铺在现在播放页的背景上，
/// 画面与音频**严格对齐**（音频是唯一的时间轴，视频只是跟着它走）。
///
/// 三段式，缺一不可：
///
///  1. **拉流**：`dash.video[]` 里挑一条最小的（见 `pickBilibiliVideo`），
///     走本地代理（会补 Referer）下载到临时目录。这一步要几秒到几十秒 ——
///     **只有整段流拉完之后才切背景**，在那之前背景仍然是那张旋转的封面。
///  2. **解码**：交给**随包自带**的 ffmpeg（`优先 d3d11va 硬解，起不来退回软解`），
///     输出定尺寸的 rawvideo(BGRA) 直接从管道出来 —— 一帧就是 `宽 × 高 × 4` 字节。
///  3. **对轴**：ffmpeg 的输出被 `-fps_mode cfr -r 30` 钉成严格等间隔，于是
///     「第 k 帧 ↔ 拉流起点 + k/30 秒」是一条直线。每拍拿音频当前时刻算目标帧号，
///     贴出队列里**最后一个不晚于它的帧**（晚了丢帧、早了就等）—— 不去凑两个
///     播放器各自的时钟，所以不会积累漂移。
///
/// 暂停时画面停在当前帧（管道写满，ffmpeg 自己也会停下来）；拖动进度条则重启
/// ffmpeg 到新位置（`-ss` 快跳，一两百毫秒，这期间保持上一帧不动）。
class VideoBackground {
  VideoBackground._();
  static final VideoBackground instance = VideoBackground._();

  /// 当前可以显示的帧。**null = 没有视频**（背景继续用封面）。
  final ValueNotifier<ui.Image?> frame = ValueNotifier<ui.Image?>(null);

  /// 解码帧率。**必须与 ffmpeg 的 `-r` 一致** —— 「帧号 ↔ 时间」就靠它换算。
  static const double fps = 30;

  /// 解码出来的画面尺寸（**固定**，不随源比例变）。
  ///
  /// ⚠️ 故意很小：这一层要的是「和封面一样的模糊」，画面在 ffmpeg 里就已经糊成
  /// 一大片色域（见 [kVideoBlurSigma]），解到 1080P 只是白烧 CPU 和显存；
  /// 而且**固定尺寸就不用先探测**（探测是一次网络往返，实测能拖 22 秒）。
  /// 源的比例由 ffmpeg 的 orce_original_aspect_ratio=increase,crop 处理。
  static const int frameWidth = 320;
  static const int frameHeight = 180;

  /// 队列最多攒多少帧（兜底上限，真正管用的是下面那条「领先多少秒」）
  static const int maxQueued = 24;

  /// 解码最多比播放位置**领先**多少秒。
  ///
  /// ⚠️ 不设这个的话 ffmpeg 会一口气把整支视频解完（它比实时快得多），
  /// 队列只能留住最后几帧、播放位置要的那些早被挤掉了 —— 表现是画面隔一阵
  /// 跳一下。靠**暂停读取**给管道压力，ffmpeg 自己就会停在前面等着。
  static const double lookaheadSecs = 1.0;

  /// 位置跳这么多秒就当「跳转」（拖进度条 / 换歌），重新解到新位置。
  /// 正常推进时位置事件间隔只有零点几秒，不会误判。
  static const double seekJumpSecs = 1.5;

  /// 想要的是哪首歌的视频（null = 不要）
  String? _wanted;

  /// 每次「换目标」+1：异步流程回来时对不上就丢弃（拉流、起进程都是慢活）
  int _epoch = 0;


  /// 测试用：只记「想要哪首」，不去真的拉流/起 ffmpeg（单测里没有网络也没有解码器）。
  @visibleForTesting
  bool debugDisabled = false;

  /// 现在想要的是哪首歌的视频（null = 不要）。测试用来看接线对不对。
  @visibleForTesting
  String? get wantedMid => _wanted;

  // ---- 解码运行时
  Process? _ffmpeg;
  StreamSubscription<List<int>>? _stdoutSub;
  String? _ffmpegPath;
  /// 候选流地址（本地代理，非 mcdn 的在前）与当前用的是第几个
  List<String> _candidates = const [];
  int _candidate = 0;

  /// 交给 ffmpeg 的输入（当前候选；不落盘）
  String? get _input =>
      _candidates.isEmpty ? null : _candidates[_candidate % _candidates.length];
  int _frameBytes = 0;
  static const ({int width, int height}) _decodedSize =
      (width: frameWidth, height: frameHeight);

  /// 字节流里还没凑成整帧的尾巴
  Uint8List _carry = Uint8List(0);

  /// 待显示的帧（按帧号升序）。**不含**已经贴出去的那一帧。
  final Queue<_DecodedFrame> _queue = Queue<_DecodedFrame>();
  int _nextIndex = 0;

  /// 这一轮解码的起点（音频时间轴上的秒数，对应第 0 帧）
  double _baseSecs = 0;

  /// 位置事件的锚点：上一次事件说「到了 _expectPos 秒」，发生在 _expectAt。
  /// 认「跳转」靠它（见 _onPosition），不能拿上一拍的位置去比。
  double _expectPos = 0;
  Duration _expectAt = Duration.zero;

  Timer? _clock;

  /// 上一帧刚换下来的图：**下一拍再 dispose** ——
  /// 这一拍的绘制记录可能还引用着它，立刻释放会画出错。
  ui.Image? _retired;

  /// 硬解起不来时置上，之后都走软解
  bool _softFallback = false;

  /// 这一支视频有多长（秒）。用来判断「还有没有内容可解」——
  /// 片子放完了就别再反复拉进程。
  double _videoSecs = 0;

  /// ffmpeg 退出了（放完了 / 出错了）
  bool _exited = false;

  /// 断流自续的次数与冷却：出错的片子别把进程反复拉起来
  int _restarts = 0;
  Duration _lastRestartAt = Duration.zero;
  static final Stopwatch _wall = Stopwatch()..start();

  /// 已经问过的流信息（同一首歌反复开页面时别再打 B站接口）
  final Map<String, List<String>> _streamCache = {};

  // ------------------------------------------------------------ 对外

  /// 告诉它「现在想要谁当背景」。
  ///
  /// [want] 由调用方决定（现在播放页开着 + 设置里开了 + 是 B站音源）。
  /// 目标没变时是空操作 —— 页面每次重建都会调它。
  void sync({required bool want, Song? song}) {
    final mid =
        (want && song != null && song.source == 'bilibili' && song.mid.isNotEmpty)
            ? song.mid
            : null;
    if (mid == _wanted) return;
    _wanted = mid;
    final epoch = ++_epoch;

    // 解码与下载**一起掐掉**：丢着一个还在写的下载，下一首的 `.part` 会被它占住，
    // 而半截文件本身也不可信（链路断过就丢过包）—— 宁可下次从头下。
    _stopDecoding();
    _clearFrame();
    _softFallback = false;
    if (mid == null) {
      fileLogger.info('VideoBg', '视频背景关掉（回到封面）');
      return;
    }
    if (debugDisabled) return;
    unawaited(_run(song!, epoch));
  }

  /// 退出应用前收干净：ffmpeg 是子进程，不杀会留在后台。
  void dispose() {
    _wanted = null;
    _epoch++;
    _stopDecoding();
    _clearFrame();
  }

  // ------------------------------------------------------------ 拉流

  Future<void> _run(Song song, int epoch) async {
    try {
      final ffmpeg = await _findFfmpeg();
      if (ffmpeg == null) {
        fileLogger.warn('VideoBg', '没找到随包的 ffmpeg，视频背景用不了（背景保持封面）');
        return;
      }
      _ffmpegPath = ffmpeg;
      final urls = await _streamUrls(song, epoch);
      if (urls == null || urls.isEmpty || epoch != _epoch) return;
      _candidates = urls;
      _candidate = 0;

      // ⚠️ **不探测分辨率**：探测是一次完整的网络往返（`ffmpeg -i <流地址>`），
      // 节点一慢就干等 —— 实测那一次花了 22 秒，而起解码本身只要 1.3 秒。
      // 尺寸固定成 320x180，**比例交给 ffmpeg 自己裁**（见 `ffmpegArgs` 的
      // `force_original_aspect_ratio=increase,crop`），所以清单里那对
      // width/height 对不对得上都无所谓。
      _frameBytes = frameWidth * frameHeight * 4;
      _videoSecs = player.duration.inMilliseconds / 1000.0;
      fileLogger.info('VideoBg',
          '${song.mid} 解码 ${frameWidth}x$frameHeight（流式，不落盘、不探测）');
      await _start(epoch);
    } catch (e) {
      fileLogger.warn('VideoBg', '${song.mid} 视频背景失败: $e');
    }
  }

  /// 取这条视频的**候选流地址**（不落盘，直接交给 ffmpeg 边拉边解）。
  ///
  /// 千奈定的：**别先下整段**（那要十几秒才出画面），让 ffmpeg 直接读流 ——
  /// 它自己会用 HTTP Range 边取边解，第一帧通常一秒内就出来了。
  ///
  /// 地址走的是 App 自己的本地代理（`ApiClient.getProxyMediaUrl`）：B站 CDN 要
  /// Referer，那层代理会补上，省得再给 ffmpeg 塞 `-headers`。
  ///
  /// ⚠️ 返回的是**一串**候选（同一份流 B站挂了好几个节点，非 mcdn 的排前面）：
  /// `mcdn.bilivideo.cn` 那个是 P2P 边缘节点，实测会把连接掐掉（代理回 5XX，
  /// ffmpeg 报 `Server returned 5XX Server Error reply`），所以得起不来/半路断
  /// 的时候换下一个。
  ///
  /// 同一首歌只问一次流信息，反复开页面不必反复打 B站接口；那条地址两小时左右
  /// 失效，所以**失败要作废缓存**，下次重开页面会重新问一次。
  Future<List<String>?> _streamUrls(Song song, int epoch) async {
    var urls = _streamCache[song.mid];
    if (urls == null) {
      try {
        urls = (await bilibiliService.getVideoStream(song)).urls;
        _streamCache[song.mid] = urls;
      } catch (e) {
        fileLogger.warn('VideoBg', '${song.mid} 取视频流地址失败: $e');
        return null;
      }
    }
    if (epoch != _epoch) return null;
    return [for (final u in urls) ApiClient.getProxyMediaUrl(u)];
  }

  /// 换下一个候选节点（按顺序循环）。返回是否真的换了。
  bool _nextCandidate() {
    if (_candidates.length < 2) return false;
    _candidate = (_candidate + 1) % _candidates.length;
    fileLogger.info('VideoBg',
        '换流节点 #${_candidate + 1}/${_candidates.length}');
    return true;
  }

  // ------------------------------------------------------------ 解码

  /// 起解码并开始对轴（硬解失败的退回在 [_spawn] 里做）。
  Future<void> _start(int epoch) async {
    _baseSecs = _now();
    _expectPos = _baseSecs;
    _expectAt = _wall.elapsed;
    _carry = Uint8List(0);
    _queue.clear();
    _nextIndex = 0;
    _exited = false;
    _restarts = 0;

    // 先硬解，起不来退软解；这条流起不来就换下一个候选节点再试。
    // B站那条 `mcdn` 的 P2P 边缘节点实测会把连接掐掉（代理回 5XX）。
    var ok = false;
    for (var round = 0; round < math.max(1, _candidates.length); round++) {
      ok = await _spawn(hardware: !_softFallback);
      if (!ok && !_softFallback) {
        fileLogger.info('VideoBg', '硬解起不来（显卡/驱动不支持这个编码），改用软解');
        _softFallback = true;
        _resetFrames();
        ok = await _spawn(hardware: false);
      }
      if (ok) break;
      if (epoch != _epoch) return;
      if (!_nextCandidate()) break;
      _resetFrames();
    }
    if (!ok) {
      fileLogger.warn('VideoBg', 'ffmpeg 起不来（候选节点都试过了），视频背景用不了');
      return;
    }
    if (epoch != _epoch) return;
    _listenPosition();
    _syncClock();
    // 暂停着打开播放页时帧循环不转，第一帧得手动贴一次 —— 否则要等用户按下播放
    // 才有画面。
    _tick();
    fileLogger.info('VideoBg', '视频背景就绪，from ${_baseSecs.toStringAsFixed(2)}s');
  }

  /// 丢掉还没成帧的字节与队列（换节点/换位置重启时用）
  void _resetFrames() {
    _carry = Uint8List(0);
    _queue.clear();
    _nextIndex = 0;
  }

  /// 起一次 ffmpeg，等到第一帧（拿不到就算这次失败）。
  Future<bool> _spawn({required bool hardware}) async {
    final ffmpeg = _ffmpegPath;
    final url = _input;
    if (ffmpeg == null || url == null) return false;

    _stopProcess();
    Process proc;
    try {
      proc = await Process.start(
        ffmpeg,
        ffmpegArgs(
          input: url,
          width: _decodedSize.width,
          height: _decodedSize.height,
          startSecs: _baseSecs,
          hardware: hardware,
        ),
      );
    } catch (e) {
      fileLogger.warn('VideoBg', '启动 ffmpeg 失败: $e');
      return false;
    }
    _ffmpeg = proc;
    fileLogger.info('VideoBg',
        'ffmpeg 起（${hardware ? 'd3d11va 硬解' : '软解'}）from ${_baseSecs.toStringAsFixed(2)}s');

    final first = Completer<bool>();
    proc.stderr
        .transform(const SystemEncoding().decoder)
        .listen((s) {
      final text = s.trim();
      // 「Broken pipe」是我们自己杀进程时的正常回声（管道那头没了），不当错误报
      if (text.isNotEmpty && !text.contains('Broken pipe')) {
        fileLogger.warn('VideoBg', 'ffmpeg: $text');
      }
    });
    unawaited(proc.exitCode.then((code) {
      fileLogger.info('VideoBg', 'ffmpeg 退出 code=$code');
      // 记下来：如果这时片子还没放完、用户还在听，帧循环会自己再起一次
      if (identical(_ffmpeg, proc)) _exited = true;
      if (!first.isCompleted) first.complete(false);
    }));
    _stdoutSub = proc.stdout.listen(
      (chunk) {
        _onBytes(chunk);
        if (!first.isCompleted && _nextIndex > 0) first.complete(true);
      },
      onDone: () {
        if (!first.isCompleted) first.complete(false);
      },
    );

    final ok = await first.future
        .timeout(const Duration(seconds: 6), onTimeout: () => false);
    if (!ok) _stopProcess();
    return ok;
  }

  /// 收字节、切成一帧一帧。
  ///
  /// ⚠️ **别写 `[..._carry, ...chunk]`**：那是把两段半兆的缓冲展开成一个
  /// `List<int>` 再拷一遍，一秒几十次就是几百 MB 的垃圾 —— 实测就是它把界面
  /// 拖到「未响应」。这里只在**确实要拼出一帧**时分配一次，其余都是视图。
  void _onBytes(List<int> chunk) {
    if (_frameBytes <= 0) return;
    final data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    var off = 0;

    if (_carry.isNotEmpty) {
      final need = _frameBytes - _carry.length;
      if (data.length < need) {
        _carry = _join(_carry, data);
        return;
      }
      _pushFrame(_join(_carry, Uint8List.sublistView(data, 0, need)));
      _carry = Uint8List(0);
      off = need;
    }

    while (data.length - off >= _frameBytes) {
      _pushFrame(Uint8List.sublistView(data, off, off + _frameBytes));
      off += _frameBytes;
    }
    _carry = off >= data.length
        ? Uint8List(0)
        : Uint8List.fromList(Uint8List.sublistView(data, off));
  }

  static Uint8List _join(Uint8List a, Uint8List b) {
    final out = Uint8List(a.length + b.length);
    out.setRange(0, a.length, a);
    out.setRange(a.length, out.length, b);
    return out;
  }

  void _pushFrame(Uint8List bgra) {
    final index = _nextIndex++;
    final w = _decodedSize.width;
    final h = _decodedSize.height;
    ui.decodeImageFromPixels(bgra, w, h, ui.PixelFormat.bgra8888, (img) {
      // 进程已经被换掉/杀掉了：这一帧没人要了
      if (_ffmpeg == null) {
        img.dispose();
        return;
      }
      final last = _queue.isEmpty ? null : _queue.last.index;
      if (last != null && last > index) {
        // 解码回调偶尔会乱序回来（引擎那边是异步的）：晚到的那帧直接丢，
        // 别把队列的顺序搞乱 —— 取帧是按顺序二分找的。
        img.dispose();
        return;
      }
      if (_queue.length >= maxQueued) {
        // 消费不过来（掉帧）：丢最旧的一帧，别让内存涨
        _queue.removeFirst().image.dispose();
      }
      _queue.add(_DecodedFrame(index, img));
      _pump();
    });
  }

  /// 该不该继续从管道里读。
  ///
  /// 队列**领先播放位置太多**（或攒得太多）就 `pause()` —— 管道写满之后 ffmpeg
  /// 自己会阻塞在那里等；播放位置追上来（或队列被消费掉）再 `resume()`。
  void _pump() {
    final sub = _stdoutSub;
    if (sub == null) return;
    final ahead = _queue.isEmpty || _ffmpeg == null
        ? false
        : (_baseSecs + _queue.last.index / fps) - _now() > lookaheadSecs;
    if (_queue.length >= maxQueued || ahead) {
      if (!sub.isPaused) sub.pause();
    } else if (sub.isPaused) {
      sub.resume();
    }
  }

  // ------------------------------------------------------------ 对轴

  void _listenPosition() {
    player.positionNotifier.removeListener(_onPosition);
    player.positionNotifier.addListener(_onPosition);
    player.removeListener(_syncClock);
    player.addListener(_syncClock);
  }

  void _unlisten() {
    player.positionNotifier.removeListener(_onPosition);
    player.removeListener(_syncClock);
  }

  double _now() => player.positionNotifier.value.inMicroseconds / 1e6;

  /// 位置事件（约 200ms 一次）：只用来认「跳转」——
  /// 暂停时帧循环是停的，往回拖进度条就只能靠它发现。
  ///
  /// ⚠️ 判据是「位置走了多远 vs 真实过了多久」，**不是**「和上次记下的位置差多少」：
  /// 起一次 ffmpeg 要一两秒，那段时间帧循环是停的，正常播放也会攒出两秒的差 ——
  /// 按后者判就会把正常播放当成「拖了进度条」，于是反复重启解码器（实测日志里
  /// 一串「起 → 退出 → 起」，画面根本立不住）。
  void _onPosition() {
    if (_ffmpeg == null) return;
    final pos = _now();
    final elapsed = (_wall.elapsed - _expectAt).inMicroseconds / 1e6;
    final moved = pos - _expectPos;
    _expectPos = pos;
    _expectAt = _wall.elapsed;
    if (isSeekJump(moved, elapsed)) _restartAt(pos);
  }

  /// 播放/暂停切换：帧循环只在播放时转（暂停时画面停住，也省电）。
  void _syncClock() {
    if (_ffmpeg == null) return;
    if (player.isPlaying) {
      _clock ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
    } else {
      _clock?.cancel();
      _clock = null;
      _expectPos = _now();
      _expectAt = _wall.elapsed;
    }
  }

  void _tick() {
    // 上一拍换下来的图，现在这一拍没人引用了
    _retired?.dispose();
    _retired = null;

    final pos = _now();
    if (_queue.isEmpty) {
      // ffmpeg 已经退出、片子却没放完（解码出错，或者一次只解了一小段）——
      // 那就再起一次。不给冷却的话出错的片子会把进程反复拉起来。
      if (_exited &&
          player.isPlaying &&
          _restarts < 8 &&
          (_videoSecs <= 0 || pos < _videoSecs) &&
          _wall.elapsed - _lastRestartAt > const Duration(seconds: 2)) {
        _restarts++;
        fileLogger.info('VideoBg', '视频解码中断，从 ${pos.toStringAsFixed(1)}s 再起一次');
        // 半路被掐多半是这个节点的问题：换个候选再试
        _nextCandidate();
        _restartAt(pos);
      }
      return;
    }

    final want = ((pos - _baseSecs) * fps).floor();
    final keep = frameIndexAt([for (final f in _queue) f.index], want);
    if (keep >= 0) {
      for (var i = 0; i < keep; i++) {
        _queue.removeFirst().image.dispose();
      }
      _show(_queue.removeFirst().image);
    }
    // 消费掉一些了：看看能不能让 ffmpeg 继续往前解
    _pump();
  }

  void _show(ui.Image img) {
    final old = frame.value;
    frame.value = img;
    // 上一帧晚一拍再回收：这一帧的绘制记录可能还引用着它
    _retired?.dispose();
    _retired = old;
  }

  /// 跳到 [secs] 对应的位置重新解。
  void _restartAt(double secs) {
    if (_ffmpegPath == null || _input == null) return;
    if ((secs - _baseSecs).abs() < 0.05 && _ffmpeg != null && !_exited) return;
    final epoch = _epoch;
    _baseSecs = secs;
    _carry = Uint8List(0);
    _queue.clear();
    _nextIndex = 0;
    _exited = false;
    _lastRestartAt = _wall.elapsed;
    final playing = player.isPlaying;
    _clock?.cancel();
    _clock = null;
    unawaited(() async {
      if (!await _spawn(hardware: !_softFallback)) return;
      if (epoch != _epoch) return;
      if (playing) _syncClock();
    }());
  }

  // ------------------------------------------------------------ 收尾

  /// 只收进程与队列，**保留当前这一帧**（跳转重启时画面不能闪回封面）。
  void _stopProcess() {
    _stdoutSub?.cancel();
    _stdoutSub = null;
    final proc = _ffmpeg;
    _ffmpeg = null;
    if (proc != null) {
      try {
        proc.kill();
      } catch (_) {}
    }
    for (final f in _queue) {
      f.image.dispose();
    }
    _queue.clear();
  }

  void _stopDecoding() {
    _clock?.cancel();
    _clock = null;
    _unlisten();
    _stopProcess();
    _retired?.dispose();
    _retired = null;
  }

  void _clearFrame() {
    _retired?.dispose();
    _retired = null;
    frame.value?.dispose();
    frame.value = null;
  }

  // ------------------------------------------------------------ ffmpeg 定位

  /// ffmpeg 是**随包自带**的，所以先看 exe 旁边；PATH 只作为开发期的兜底
  /// （直接 `flutter run` 时 exe 在 build 目录里，旁边那份由 CMake 拷过去）。
  Future<String?> _findFfmpeg() async {
    final known = _ffmpegPath;
    if (known != null && File(known).existsSync()) return known;

    String exeDir;
    try {
      exeDir = File(Platform.resolvedExecutable).parent.path;
    } catch (_) {
      exeDir = AppPaths.appDir;
    }
    final candidates = <String>[
      p.join(exeDir, 'ffmpeg.exe'), // 随包自带（打包 / 构建都会放到这里）
      p.join(exeDir, 'bin', 'ffmpeg.exe'),
      p.join(AppPaths.appDir, 'ffmpeg.exe'),
      p.join(AppPaths.appDir, 'bin', 'ffmpeg.exe'),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) {
        fileLogger.info('VideoBg', 'ffmpeg: $c');
        return c;
      }
    }
    try {
      final r = await Process.run('where', ['ffmpeg']);
      if (r.exitCode == 0) {
        final line = '${r.stdout}'
            .split(RegExp(r'[\r\n]+'))
            .map((e) => e.trim())
            .firstWhere((e) => e.isNotEmpty, orElse: () => '');
        if (line.isNotEmpty && File(line).existsSync()) {
          fileLogger.info('VideoBg', 'ffmpeg（PATH，开发期兜底）: $line');
          return line;
        }
      }
    } catch (_) {}
    return null;
  }
}

class _DecodedFrame {
  _DecodedFrame(this.index, this.image);
  final int index;
  final ui.Image image;
}

/// 拼 ffmpeg 参数（**纯函数，好单测**）。
///
/// 几个要点：
///  * **模糊与照片滤镜都在 ffmpeg 里做** —— 和封面背景那条链路一致
///    （256px 小图 + sigma 18 的高斯模糊 + 「对比度 0.4 → 饱和 ×3 → 对比度 1.7」，
///    合成起来就是 `eq=contrast=0.68:saturation=3.0`：那个 0.68x+40.96 的仿射
///    和 `bgPhotoFilter()` 算出来的完全一样）。放在这里做的好处是 Flutter 侧
///    每帧只是贴一张图，不用每帧 `saveLayer` 去糊。
///  * `-hwaccel d3d11va` 只管「用什么解」；后面这条软件滤镜链会让 ffmpeg 自己把帧
///    从显存拷回内存（所以**不能**写 `-hwaccel_output_format`，写了参数的写法
///    就完全变样）。
///  * `-ss` 放在 `-i` **前面**：快跳到最近的关键帧再解到指定时刻，
///    拖进度条时这一下只要一两百毫秒。
///  * `-fps_mode cfr -r 30` 把输出钉成严格等间隔 —— 「第 k 帧 = 起点 + k/30 秒」
///    这条换算就是靠它成立的（源是 60fps 会抽帧、24fps 会补帧）。
List<String> ffmpegArgs({
  required String input,
  required int width,
  required int height,
  required double startSecs,
  required bool hardware,
  double fps = VideoBackground.fps,
  double blurSigma = kVideoBlurSigma,
}) =>
    <String>[
      '-hide_banner',
      '-loglevel', 'error',
      '-nostdin',
      if (hardware) ...['-hwaccel', 'd3d11va'],
      if (startSecs > 0.05) ...['-ss', startSecs.toStringAsFixed(3)],
      '-i', input,
      '-an', '-sn', '-dn',
      '-vf', 'scale=$width:$height:force_original_aspect_ratio=increase,'
          'crop=$width:$height,gblur=sigma=$blurSigma,'
          'eq=contrast=0.68:saturation=3.0',
      '-pix_fmt', 'bgra',
      '-r', '${fps.round()}',
      '-fps_mode', 'cfr',
      '-f', 'rawvideo',
      '-',
    ];

/// 视频那层的模糊半径。照封面背景那条链路取（它是对 256px 的小图做 sigma 18），
/// 我们解码出来也是同一量级的尺寸，所以用同一个值观感才一致。
const double kVideoBlurSigma = 18;

/// 这一次位置事件算不算「跳转」。
///
/// [moved] = 位置走了多少秒，[elapsed] = 真实过了多少秒。两者差得太多才是跳转
/// （拖了进度条 / 换了歌）。
///
/// ⚠️ **别拿「和上一拍记下的位置差多少」当判据**：起一次 ffmpeg 要一两秒，那段时间
/// 帧循环是停的，正常播放也会攒出两秒的差 —— 按那个判会把正常播放当成跳转，
/// 于是反复重启解码器，日志里一串「起 → 退出 → 起」，画面根本立不住（实测踩过）。
bool isSeekJump(
  double moved,
  double elapsed, {
  double tolerance = VideoBackground.seekJumpSecs,
}) =>
    (moved - elapsed).abs() > tolerance;

/// 在一串**按帧号升序**的帧号里，找最后一个 ≤ [want] 的下标（二分）。
///
/// 返回 −1 = 队列里最早的帧都比目标晚（解码还没追上来）→ 画面先保持不动。
/// 这就是「按音频时间轴取帧」那一步的判定，抽出来单独测。
int frameIndexAt(List<int> indices, int want) {
  var lo = 0;
  var hi = indices.length - 1;
  var ans = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (indices[mid] <= want) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}

final videoBackground = VideoBackground.instance;
