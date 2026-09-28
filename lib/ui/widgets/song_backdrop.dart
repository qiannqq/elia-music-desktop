import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/backdrop.dart';
import '../../services/api_client.dart';
import '../../services/player_controller.dart';
import '../../services/silence_probe.dart';
import '../../services/video_bg.dart';

/// 会动 / 会跳的整块背景 —— 现在播放页与「整体背景（歌曲封面）」共用这一份。
///
/// 观感照 AMLL 的背景渲染器复刻：**匀速慢转**（约 31 秒一圈）
/// + **低频把画面轻轻向内放大**（最多 25%）+ 一点点压暗 + 暗角。
/// 没有按拍「搓」那一套 —— 那是早期版本的猜测，和它实际的行为对不上。
///
/// 这一份是从 `lib/ui/now_playing.dart` 里搬出来的（原来叫 `_Backdrop` /
/// `_RecordArt` / `_VideoBackdrop` 三个私有类），一个字都没改逻辑，
/// 只是改成公共的、参数化的：**两处必须长得一模一样**，各留一份迟早会漂。
///
/// 运动公式、照片滤镜、模糊底图都在 `lib/core/backdrop.dart`。
class SongBackdrop extends StatelessWidget {
  const SongBackdrop({
    super.key,
    required this.pic,
    required this.mid,
    required this.amount,
    required this.spin,
  });

  /// 封面原图地址（母版，自己会按档位降）
  final String pic;

  /// 当前歌曲的 id —— 换歌要重取低频包络
  final String mid;

  /// 律动幅度倍数（设置里的「现在播放页」→「律动幅度」）
  final double amount;

  /// 转速倍数（设置里的「现在播放页」→「旋转速度」）
  final double spin;

  @override
  Widget build(BuildContext context) {
    // B站音源开了「视频背景」并且解码出帧之后换成视频；
    // 在那之前（拉流中、不是 B站、设置关着）都还是封面。
    // 两者之间补一段淡入淡出 —— 硬切会像画面闪了一下。
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: videoBackground.frame,
      builder: (_, video, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        child: video == null
            ? CoverBackdrop(pic: pic, mid: mid, amount: amount, spin: spin)
            : VideoBackdrop(key: const ValueKey('bili-video'), image: video),
      ),
    );
  }
}

/// 封面背景：一张**预先糊好的**大图挂在窗口正中、绕自己的中心转。
///
/// 两处开销上的讲究：
///  * 底图是糊一次就存下来的普通图片（[BlurredArt]）：`ImageFiltered` 在滑动
///    子树里会每帧重糊并与内容错位，这里之后只是贴图 + 改变换矩阵；
///  * 尺寸给到 `1.06 × 对角线`：绕屏幕中心转，图的**内切圆半径**（边长/2）
///    只要盖得住窗口的外接圆（对角线/2）就行。贴图本身只有 256²，
///    放大由 GPU 采样，显存可以忽略。
class CoverBackdrop extends StatefulWidget {
  const CoverBackdrop({
    super.key,
    required this.pic,
    required this.mid,
    required this.amount,
    required this.spin,
  });

  final String pic;
  final String mid;
  final double amount;
  final double spin;

  @override
  State<CoverBackdrop> createState() => _CoverBackdropState();
}

class _CoverBackdropState extends State<CoverBackdrop> {
  /// **30Hz** 的时钟，只驱动这一层。
  ///
  /// 原来是 `AnimationController.repeat()`（跟着 vsync 走、60fps）。换成定时器的
  /// 原因是实测出来的：播放期间应用本来就在每帧出帧（36~43fps），而每帧只有 3ms 级
  /// ——「卡」不来自绘制量，来自**一直在渲染**这件事本身在跟系统合成器抢 DWM
  /// （千奈的原话：不播放时拖标题栏很流畅，放歌就不行）。背景只是缓慢旋转 +
  /// 跟着鼓点轻轻缩放，30fps 看不出来，却让常驻出帧率减半。
  Timer? _clock;

  /// 每走一格 +1 —— `AnimatedBuilder` 听它，只重建背景这一小块。
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  /// `TickerMode.of(context)`：被盖住时（现在播放页开着）连定时器一起停。
  /// ⚠️ `TickerMode` 本身只管 Ticker，管不到 `Timer` —— 必须显式读它。
  bool _tickerEnabled = true;

  bool get _running => _clock != null;

  void _startClock() {
    if (_running || !_tickerEnabled) return;
    // 起跑前对齐一次：别把停表那段时间当成 dt（那会让低频平滑器一步跳过去）
    _wallPrev = _wall.elapsed;
    _clock = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _frame.value++;
    });
  }

  void _stopClock() {
    _clock?.cancel();
    _clock = null;
  }

  /// 快速跟随的响度（压暗层用）
  double _level = 0;

  /// 平滑过的「低频音量」（0~1，见 [bgVolume]）—— 缩放与推角都看它
  double _bass = 0;

  /// 真实时间的钟：算帧间隔、以及「位置事件距今多久」
  final Stopwatch _wall = Stopwatch();

  /// 位置事件的锚点：那只事件说「音频到了 _anchorPos 秒」，发生在这只表的 _anchorAt。
  double _anchorPos = 0;
  Duration _anchorAt = Duration.zero;

  Duration _wallPrev = Duration.zero;

  /// 这一帧的平滑播放时刻（秒）。
  ///
  /// ⚠️ 不能拿 `player.position` 直接当播放时刻：播放器的位置事件是**每 200ms 一档**
  /// （audioplayers 的位置流），而包络是 20ms 一档 —— 按事件采样会一步跨过鼓点的
  /// 上升沿（一个鼓点只有几十毫秒）。所以拿「最近一次事件的时刻 + 事件到现在的时间」
  /// 当播放时刻，误差只剩几十毫秒。
  double get _playT {
    final since = (_wall.elapsed - _anchorAt).inMicroseconds / 1e6;
    return _anchorPos + since.clamp(0.0, 0.4);
  }

  void _onPos() {
    _anchorPos = player.positionNotifier.value.inMicroseconds / 1e6;
    _anchorAt = _wall.elapsed;
  }

  /// 两条包络都是一次探测算出来的，一起取：
  /// [bass]（80~120Hz）管缩放与推角，[level]（全频段响度）管压暗层。
  LevelTrack? _bassTrack;
  LevelTrack? _levelTrack;

  /// 包络还没算好时的重试（探测要解一遍整首歌，是异步的）
  Timer? _retry;

  bool get _hasTracks => _bassTrack != null && _levelTrack != null;

  /// 换一首歌：重拿两条包络，跟随器清零
  void _useTracks(String mid) {
    _bassTrack = SilenceProbe.bass(mid);
    _levelTrack = SilenceProbe.levels(mid);
    _bass = 0;
    _level = 0;
  }

  @override
  void initState() {
    super.initState();
    _wall.start();
    player.positionNotifier.addListener(_onPos);
    _onPos();
    _useTracks(widget.mid);
    player.addListener(_sync);
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled != _tickerEnabled) {
      _tickerEnabled = enabled;
      _sync();
    }
  }

  @override
  void didUpdateWidget(covariant CoverBackdrop old) {
    super.didUpdateWidget(old);
    if (old.mid != widget.mid) {
      _useTracks(widget.mid);
      _onPos();
      _sync();
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    player.positionNotifier.removeListener(_onPos);
    player.removeListener(_sync);
    _stopClock();
    _frame.dispose();
    super.dispose();
  }

  void _scheduleRetry() {
    _retry?.cancel();
    // 没在放歌就不必等包络：探测要解一遍整首歌，暂停时反复重试纯属空转
    // （表现是背景一直不跳，还挂着一个每 2 秒醒一次的定时器）。
    // 按下播放时 `player` 的监听会再调一次 `_sync()`，那会儿再来看。
    if (!player.isPlaying) return;
    _retry = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      final bass = SilenceProbe.bass(widget.mid);
      final level = SilenceProbe.levels(widget.mid);
      if (bass == null || level == null) {
        _scheduleRetry();
        return;
      }
      setState(() {
        _bassTrack = bass;
        _levelTrack = level;
      });
      _sync();
    });
  }

  /// 只要在播就转（慢转本身不依赖包络，低频那项只是叠在上面的）。
  void _sync() {
    if (!_hasTracks) {
      // 低频还没算好（探测在后台跑）→ 过会儿再来看
      _scheduleRetry();
    } else {
      _retry?.cancel();
    }
    if (player.isPlaying) {
      // 起跑前重新对一次表（暂停期间位置不动，直接续上）
      _onPos();
      _startClock();
    } else {
      _stopClock();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, cons) {
        final w = cons.maxWidth;
        final h = cons.maxHeight;
        final diag = math.sqrt(w * w + h * h);
        final size = diag * kBackdropScale;
        return RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 图挂在窗口正中间、绕自己的中心转 —— 和 AMLL 一样，
              // 旋转与缩放的不动点就是屏幕中心
              Positioned(
                left: (w - size) / 2,
                top: (h - size) / 2,
                width: size,
                height: size,
                child: AnimatedBuilder(
                  animation: _frame,
                  builder: (_, child) {
                    final t = _playT;
                    // 帧间隔用真实时间的钟：暂停时时钟停了，画面就停住
                    final wall = _wall.elapsed;
                    final dt = ((wall - _wallPrev).inMicroseconds / 1e6)
                        .clamp(0.0, 0.1);
                    _wallPrev = wall;
                    final bassTrack = _bassTrack;
                    final levelTrack = _levelTrack;
                    if (dt > 0) {
                      if (bassTrack != null) {
                        // 低频「上得快、落得慢」：鼓点打下去立刻放大，之后慢慢回来
                        _bass = followLevel(_bass, bgVolume(bassTrack.levelAt(t)),
                            dt, attack: 0.05, release: 0.35);
                      }
                      if (levelTrack != null) {
                        _level = followLevel(_level, levelTrack.levelAt(t), dt,
                            attack: 0.05, release: 0.40);
                      }
                    }
                    return Transform.rotate(
                      angle: bgAngle(t, _bass, widget.amount, spin: widget.spin),
                      child: Transform.scale(
                        scale: bgZoom(_bass, widget.amount),
                        child: child,
                      ),
                    );
                  },
                  // 底图自己再关一层：旋转只改变换，纹理不用重画
                  child: RepaintBoundary(
                    child: widget.pic.isEmpty
                        ? const SizedBox.shrink()
                        : BlurredArt(
                            // 背景要糊掉，但糊之前缩到 256 —— 用原图这一档，
                            // 和封面预热共用同一份下载与解码缓存
                            provider: ResizeImage(
                              NetworkImage(ApiClient.getProxyImageUrl(
                                ApiClient.coverUrlFor(widget.pic,
                                    px: kBackdropCoverPx),
                              )),
                              width: kBackdropPx,
                              height: kBackdropPx,
                            ),
                          ),
                  ),
                ),
              ),
              // 压暗：只压一点点。
              //
              // 实测标定过（同一张封面，和 iPad 上的 Apple Music 比）：
              // 它的背景亮度是同图封面的 **0.76**（= 只压 24%），而且中心到边缘
              // 靠**暗角**收下去；我们原先压了 0.50~0.68，所以整页发灰发暗。
              // 响的时候再透一点点 —— 所以这一层必须跟着时钟每帧重算。
              AnimatedBuilder(
                animation: _frame,
                builder: (_, _) => DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.24 - 0.06 * _level),
                  ),
                ),
              ),
              const VignetteOverlay(),
            ],
          ),
        );
      },
    );
  }
}

/// B站视频背景：把解码出来的那一帧铺满整屏（cover），上面罩的是**和封面背景
/// 同一套**「压暗 + 暗角」—— 不压的话画面本身的亮部会把内容的对比度吃光。
///
/// 不跟着封面那套旋转 / 律动：画面自己就在动，再转一圈只会晕。
class VideoBackdrop extends StatelessWidget {
  const VideoBackdrop({super.key, required this.image});

  final ui.Image image;

  @override
  Widget build(BuildContext context) {
    // 自己关一层 `RepaintBoundary`：这个画面每 1/30 秒换一次，
    // 不关起来就会把**整页**（封面、歌词、控件）的绘制记录一起标脏。
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          RawImage(
            image: image,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
          ),
          // 压暗与暗角的数值和封面背景保持一致（0.24 + 0.26）
          const DimOverlay(),
          const VignetteOverlay(),
        ],
      ),
    );
  }
}

/// 压暗层：静态 24%（视频背景 / 整窗背景用）
class DimOverlay extends StatelessWidget {
  const DimOverlay({super.key, this.alpha = 0.24});

  final double alpha;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: alpha),
        ),
      );
}

/// 暗角：中心不压、四周收下去（比线性渐变自然）
class VignetteOverlay extends StatelessWidget {
  const VignetteOverlay({super.key});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            radius: 0.95,
            stops: const [0.45, 1.0],
            colors: [
              Colors.transparent,
              Colors.black.withValues(alpha: 0.26),
            ],
          ),
        ),
      );
}

/// 预先糊好的背景底图。
///
/// **不在动画里用 `ImageFiltered`**：它产生的是 `ImageFilterLayer`，而这个页面
/// 整体在滑动、这一层自己还在转（每帧换变换矩阵）—— 滤镜层的缓存跟矩阵绑在一起，
/// 实测结果是**每帧重新糊一遍**（掉帧），而且和内容错位（背景比内容慢半拍）。
///
/// 改成「糊一次、存成一张普通 `ui.Image`」：之后每帧只是贴图 + 改变换，
/// 零滤镜开销，也不会错位。
///
/// 糊的时候顺手套一道**照片滤镜**（[bgPhotoFilter]，照 AMLL 的配方）：
/// 对比度 0.4 → 饱和度 **×3** → 对比度 1.7。Apple Music 那种背景是「亮艳」的，
/// 而模糊只会把颜色摊平、越糊越灰 —— 不补饱和度就整页发灰。
class BlurredArt extends StatefulWidget {
  const BlurredArt({
    super.key,
    required this.provider,
    this.sigma = kBackdropSigma,
    this.photoFilter = true,
  });

  /// **已经带目标分辨率**的图源（调用方自己套 `ResizeImage`）
  final ImageProvider provider;

  final double sigma;
  final bool photoFilter;

  @override
  State<BlurredArt> createState() => _BlurredArtState();
}

class _BlurredArtState extends State<BlurredArt> {
  ui.Image? _image;
  Object? _loading;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant BlurredArt old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider ||
        old.sigma != widget.sigma ||
        old.photoFilter != widget.photoFilter) {
      _load();
    }
  }

  Future<void> _load() async {
    final token = widget.provider;
    _loading = token;
    try {
      final blurred = await blurBackdrop(
        token,
        sigma: widget.sigma,
        photoFilter: widget.photoFilter,
      );
      // 期间已经换歌 / 换页面了：这份结果丢掉
      if (!mounted || _loading != token) {
        blurred?.dispose();
        return;
      }
      setState(() => _image = blurred);
    } catch (_) {
      if (mounted && _loading == token) setState(() => _image = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) return const SizedBox.shrink();
    return RawImage(
      image: img,
      fit: BoxFit.cover,
      // 放大十几倍，双线性就够了（本来就糊）
      filterQuality: FilterQuality.low,
    );
  }
}
