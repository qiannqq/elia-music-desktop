import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import '../core/app_theme.dart';
import '../core/window_fx.dart';
import '../core/lyric.dart';
import '../core/lyric_scroll.dart';
import '../models/song.dart';
import '../services/api_client.dart';
import '../services/lyric_cache.dart';
import '../services/player_controller.dart';
import '../services/silence_probe.dart';
import '../services/video_bg.dart';
import '../state/app_state.dart';
import '../state/toast.dart';
import 'icons.dart';
import 'player_bar.dart';
import 'widgets/common.dart';
import 'widgets/context_menu.dart';
import 'widgets/song_actions.dart';

/// 歌词行的透明度：当前句最亮，离得越远越暗。
///
/// 已经唱过的（在当前句上面的）比还没唱的暗得更快 —— 参考图里往上那几句
/// 明显比往下那几句淡。**返回 0.16 以上**：整句完全看不见的话，
/// 滚动过程会像「空了几行」。
double lyricLineOpacity(int index, int activeIndex) {
  if (index == activeIndex) return 1;
  if (activeIndex < 0) return 0.6; // 还没唱到任何一句：一律用「未唱」的档
  final dist = (index - activeIndex).abs();
  final base = index < activeIndex ? 0.5 : 0.6;
  final v = base - 0.13 * (dist - 1);
  return v.clamp(0.16, base);
}

/// 当前句里「还没唱到」的那部分用的不透明度。
///
/// 它比相邻行的整行透明度（0.5~0.6）更暗 —— 当前句的对比度要给足，
/// 逐字刷亮才有「点亮」的感觉。也正是因为它更暗，换行时必须补间过去：
/// 直接切就是千奈看到的「一整个句子突然变暗」。
const double kActiveUnsungAlpha = 0.42;

/// 一行歌词的**目标**颜色（两个不透明度，颜色一律是白）：
/// [sung] 已唱的部分、[unsung] 还没唱到的部分。
///
///  * 当前句 → (1.0, 0.42)：未唱部分压暗，等逐字刷亮一格一格走到纯白；
///  * 其余行 → 两个值都等于该行的整行透明度，整行一个色。
///
/// ⚠️ 换行时这两个目标值会**跳变**，但颜色本身不能跟着跳 ——
/// 由 [_LyricLineFade] 用 260ms 从「上一刻真实的颜色」滑到新目标。
/// 谁要是把它们直接塞进样式里，就又回到「突兀地关灯」了。
({double sung, double unsung}) lyricLineAlphas({
  required bool active,
  required double opacity,
}) =>
    active
        ? (sung: 1.0, unsung: kActiveUnsungAlpha)
        : (sung: opacity, unsung: opacity);

/// 现在播放页 —— 仿 Apple Music 的整屏播放页，点播放栏左侧封面从下往上推出来。
///
/// 配色**不跟主题走**：底色是封面自己（放大 + 高斯模糊 + 压暗），文字一律白系。
/// 浅色主题下它照样是这一副样子 —— 这是设计的一部分（Apple Music 的播放页也这样）。
/// 播放页封面（含背景、预热）统一用的封面档位。
///
/// 显示尺寸最大 320 逻辑像素，2 倍屏也就 640 物理像素 —— 1200 档足够，
/// 而原图动辄 1.5~4.7MB（实测 3000×3000 那张 4.7MB），白下 10 倍流量。
/// ⚠️ 三处（[SongCover]、背景、预热）必须是**同一个数**，否则各下各的。
const int kNowPlayingCoverPx = 1200;

class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({
    super.key,
    required this.state,
    required this.open,
    required this.onClose,
  });

  final AppState state;

  /// 开关由外壳持有：页面**常驻组件树**、只切它 ——
  /// 条件性地把它挂上/摘下会让整棵子树重建（下面靠 State 记的滚动位置会一起没）。
  final bool open;

  final VoidCallback onClose;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    reverseDuration: const Duration(milliseconds: 300),
  );

  /// 从下往上推：整页从屏幕下沿滑进来
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 1),
    end: Offset.zero,
  ).animate(CurvedAnimation(
    parent: _anim,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  ));

  @override
  void initState() {
    super.initState();
    if (widget.open) _anim.value = 1;
    player.addListener(_onPlayer);
    // 一开机就把当前这首的封面预热好（页面常驻组件树，State 从启动就在）
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefetchCover());
  }

  /// 现在该不该给「视频背景」拉流：**页面开着 + 设置里开着 + B站音源**。
  ///
  /// 每次重建都调一次是故意的 —— 换歌、开关页面、改设置都要重新判断，
  /// 而 `VideoBackground.sync` 对「目标没变」是空操作。
  void _syncVideoBackground() {
    videoBackground.sync(
      want: widget.open && widget.state.bgVideo,
      song: player.currentSong,
    );
  }

  /// 已经预热过封面的歌
  String _prefetchedMid = '';

  /// 把这一页要用的**大图那一档**提前解好。
  ///
  /// 播放栏那个封面是 48px 一档、这一页要 512px 一档 —— 解码尺寸不同就是两个缓存
  /// 条目，不预热的话推上来时得现下一张图（几百毫秒），表现成「封面过一会儿才出现、
  /// 背景比封面先亮」。`Image.network(cacheWidth:)` 内部是 `ResizeImage`，
  /// 所以预热也得用同一层包装，否则 key 对不上。
  void _prefetchCover() {
    final song = player.currentSong;
    if (song == null || song.pic.isEmpty || song.mid == _prefetchedMid) return;
    _prefetchedMid = song.mid;
    // 和封面、背景用同一档（否则各自都是一个不同的 URL = 下好几张）
    final url = ApiClient.getProxyImageUrl(
      ApiClient.coverUrlFor(song.pic, px: kNowPlayingCoverPx),
    );
    if (url.isEmpty) return;
    precacheImage(ResizeImage(NetworkImage(url), width: 512), context)
        .catchError((_) {});
  }

  @override
  void didUpdateWidget(covariant NowPlayingPage old) {
    super.didUpdateWidget(old);
    // ⚠️ 这里**不要**去比较 `old.state.bgPulse != widget.state.bgPulse`：
    // AppState 是全局单例，两个字段读的是同一个对象的当前值，永远相等 ——
    // 绿过一段时间，实际表现是「在设置页拖律动幅度，播放页毫无变化」。
    // 这两个活的设置项现在由 `_buildPage` 里的 `AnimatedBuilder` 单独听
    // AppState 处理（见那里的说明），这里只管开合动画。
    if (widget.open != old.open) {
      if (widget.open) {
        // 等一帧再起跑：这一帧要把整页建出来 + 布局完，把它塞进动画的头几帧
        // 就是「先卡一下再滑」。先建好滑动就只是移动一张已经栅格化好的图。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.open) _anim.forward();
        });
      } else {
        _anim.reverse();
      }
    }
    // 页面开合、设置里开关「B站视频背景」都要重新判断一次
    _syncVideoBackground();
  }

  @override
  void dispose() {
    player.removeListener(_onPlayer);
    _dragPreview.dispose();
    _anim.dispose();
    super.dispose();
  }

  /// 播放器的低频变化（换歌 / 换行 / 播放暂停）才需要重建这一页；
  /// 播放位置走 `positionNotifier`，只重建进度那一小块。
  void _onPlayer() {
    if (!mounted) return;
    _prefetchCover();
    if (!widget.open) return;
    _syncVideoBackground(); // 换歌了：该拉新一首的视频流
    setState(() => _page = null); // 内容作废，下一帧重建
  }

  /// 这一页的内容。
  ///
  /// **必须缓存**：出场动画的每一帧都会调 `AnimatedBuilder` 的 builder，
  /// 要是把 `_buildPage()` 写在 builder 里，420ms 里会重建二十多次整页
  /// （60 行歌词 + 全屏模糊）—— 表现就是推上来的时候一抽一抽的。
  /// 挂到 `AnimatedBuilder.child` 上就只建一次，每帧只换那个位移。
  Widget? _page;

  @override
  Widget build(BuildContext context) {
    // 关着且动画已经归零：内容整块不建。
    // 里面有一层全屏高斯模糊，留在树上等于白占一份光栅化结果。
    if (!widget.open && _anim.isDismissed) {
      _page = null;
      return const SizedBox.shrink();
    }
    final page = _page ??= _buildPage(context);
    return AnimatedBuilder(
      animation: _anim,
      builder: (ctx, child) => IgnorePointer(
        // 收起的过程中不该还能点到（那会儿底下的界面已经该能用了）
        ignoring: !widget.open,
        // 整页再套一层 RepaintBoundary：这一页里每帧会变的东西（逐字歌词、
        // 进度条、背景光斑）各自有自己的边界，所以这一页的绘制记录是**静的**
        // —— 滑动就只是移动一张已经栅格化好的图，不会每帧重画一遍内容。
        child: SlideTransition(
          position: _slide,
          child: RepaintBoundary(child: child),
        ),
      ),
      child: page,
    );
  }

  Widget _buildPage(BuildContext context) {
    final song = player.currentSong;
    final pic = song?.pic ?? '';

    return ColoredBox(
      // 封面还没解出来时的兜底底色
      color: const Color(0xFF121215),
      // 这一页里所有滚动区都不要滚动条（Apple Music 的歌词页没有）。
      // 桌面端的 MaterialScrollBehavior 会给每个 Scrollable 自动套一个
      // Scrollbar，不关掉的话歌词右边会挂着一条。
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Stack(
          children: [
            Positioned.fill(
              // B站音源开了「视频背景」并且**整段流已经拉完、解码出帧**之后，
              // 这里换成视频；在那之前（拉流中、不是 B站、设置关着）都还是封面。
              // 两者之间补一段淡入淡出 —— 硬切会像画面闪了一下。
              child: ValueListenableBuilder<ui.Image?>(
                valueListenable: videoBackground.frame,
                builder: (_, video, _) => AnimatedSwitcher(
                  duration: const Duration(milliseconds: 320),
                  child: video == null
                      // ⚠️ 「律动幅度 / 旋转速度」是设置页里的**活值**，但整页内容
                      // 是缓存的（`_page`）—— 直接把它塞进缓存的那份 widget 里，
                      // 用户在设置页拖滑块不会有任何变化（那两份 widget 是同一个
                      // 实例，框架会直接跳过更新）。所以只让这一小块听着 AppState
                      // 重建：不去作废整页（整页有几十行歌词 + 一层全屏模糊）。
                      ? AnimatedBuilder(
                          animation: widget.state,
                          builder: (_, _) => _Backdrop(
                            pic: pic,
                            mid: song?.mid ?? '',
                            amount: widget.state.bgPulse,
                            spin: widget.state.bgSpin,
                          ),
                        )
                      : _VideoBackdrop(
                          key: const ValueKey('bili-video'),
                          image: video,
                        ),
                ),
              ),
            ),
            if (song != null)
              Positioned.fill(child: _buildContent(song)),
            // 标题栏在最上层（见 app_shell），所以收起键要落在它下面
            Positioned(
              left: 16,
              top: kTitlebarHeight + 10,
              child: _buildClose(),
            ),
          ],
        ),
      ),
    );
  }

  /// 左上角的收起键。
  ///
  /// ⚠️ **全屏时整块不画**（不是禁用）：全屏是沉浸态，这时候该退的是全屏 ——
  /// 留一个灰着的收起键在那里，既没人知道它为什么不能点，也白占着画面
  /// （千奈报的「只是做了屏蔽、没有隐藏」）。Esc 仍然先退全屏。
  Widget _buildClose() {
    return ValueListenableBuilder<bool>(
      valueListenable: appFullscreen,
      builder: (_, full, _) => full
          ? const SizedBox.shrink()
          : AppIconButton(
              icon: AppIcons.chevronDown,
              size: 40,
              iconSize: 22,
              baseColor: Colors.white.withValues(alpha: 0.72),
              hoverColor: Colors.white,
              hoverBg: Colors.white.withValues(alpha: 0.12),
              tooltip: '收起',
              onTap: widget.onClose,
            ),
    );
  }

  Widget _buildContent(Song song) {
    final bundle = LyricCache.peek(song.mid);
    return LayoutBuilder(
      builder: (ctx, cons) {
        // 窗口高度决定封面多大；宽度太窄时也别把歌词挤没
        final cover = (cons.maxHeight * 0.40).clamp(120.0, 320.0);
        final left = cover + 24;
        final lyrics = player.lyricLines;
        // 歌词字号跟着可用宽度走：窄窗口下 30px 的大字一行放不下几个字
        final lyricSize = (cons.maxWidth * 0.030).clamp(19.0, 30.0);

        return Padding(
          padding: const EdgeInsets.fromLTRB(48, 52, 44, 32),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: left,
                child: _buildLeft(song, cover),
              ),
              const SizedBox(width: 44),
              Expanded(
                child: lyrics.isEmpty
                    ? _buildNoLyric(song)
                    : _LyricsView(
                        // 换歌就整块重建：滚动位置、每行的 key 都要跟着重来
                        key: ValueKey(song.mid),
                        lines: lyrics,
                        transMap: bundle?.transMap ?? const {},
                        activeIndex: player.activeLyricIndex,
                        fontSize: lyricSize,
                        // 拖完进度条会 +1 → 歌词区知道这一跳是「跳转」
                        seekToken: _seekToken,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNoLyric(Song song) {
    return Center(
      child: Text(
        player.isLoading ? '歌词加载中…' : '《${song.name}》暂无歌词',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.white.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 左栏

  Widget _buildLeft(Song song, double cover) {
    return LayoutBuilder(
      builder: (ctx, cons) => SingleChildScrollView(
        // 窗口特别矮时（最小 560）让左栏能滚，不要撑出 overflow
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: cons.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCover(song, cover),
              const SizedBox(height: 26),
              Text(
                song.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Builder(builder: (btnCtx) => _buildMore(song, btnCtx)),
                ],
              ),
              const SizedBox(height: 22),
              _buildProgress(),
              const SizedBox(height: 22),
              _buildTransport(),
              const SizedBox(height: 20),
              _buildVolume(),
            ],
          ),
        ),
      ),
    );
  }

  /// 暂停时封面**收小一点**、恢复播放时弹回原样（见 [_PausedCoverScale]）。
  ///
  /// 阴影跟着一起缩放（`Transform.scale` 会带上子树），像封面真的往后退了一点。
  Widget _buildCover(Song song, double size) {
    return _PausedCoverScale(
      playing: player.isPlaying,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 40,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: SongCover(
          pic: song.pic.isEmpty ? null : song.pic,
          size: size,
          radius: 10,
          px: kNowPlayingCoverPx,
        ),
      ),
    );
  }

  /// 「…」—— 和歌单页/播放列表面板用的是同一套菜单
  Widget _buildMore(Song song, BuildContext btnCtx) {
    return AppIconButton(
      icon: AppIcons.more,
      size: 30,
      iconSize: 18,
      filled: true,
      baseColor: Colors.white.withValues(alpha: 0.6),
      hoverColor: Colors.white,
      hoverBg: Colors.white.withValues(alpha: 0.12),
      tooltip: '更多',
      onTap: () {
        final box = btnCtx.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        showAppContextMenu(
          context: btnCtx,
          position: box.localToGlobal(Offset(0, box.size.height + 4)),
          items: buildSongMenuItems(
            context: btnCtx,
            state: widget.state,
            song: song,
            onOpenLyric: widget.state.requestLyricDialog,
            // 正在播的这一首：菜单给「从播放队列中移除」，和队列面板一致
            inQueue: true,
          ),
        );
      },
    );
  }

  Widget _buildProgress() {
    // 进度条每秒跟着位置变几十次：用 RepaintBoundary 把它关在这一小块里，
    // 否则它每帧都会把整页（含全屏模糊）的绘制记录标脏。
    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: player.positionNotifier,
        builder: (ctx, _, _) {
          // ⚠️ 拖动预览必须走**自己的 ValueNotifier**，不能用 `setState`：
          // 整页内容是缓存的（`_page ??= _buildPage()`），`setState` 之后
          // `build()` 又把同一个 widget 实例原样返回 —— 页面根本没重建，
          // 表现就是「拖动时进度不跟鼠标走，松手才跳过去」。
          return ValueListenableBuilder<double?>(
            valueListenable: _dragPreview,
            builder: (ctx, dragging, _) {
              final progress = dragging ?? player.progress;
              final display = dragging != null
                  ? Duration(
                      milliseconds:
                          (progress * player.duration.inMilliseconds).round())
                  : player.position;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppProgressBar(
                    value: progress,
                    height: 4,
                    hoverHeight: 7,
                    draggable: true,
                    trackColor: Colors.white.withValues(alpha: 0.22),
                    fillColor: Colors.white,
                    // 拖动时只更新本地预览，不真的 seek（边拖边 seek 听感很鬼畜）
                    onSeek: (v) => _dragPreview.value = v,
                    onSeekStart: () {
                      _wasPlaying = player.isPlaying;
                      player.pause();
                    },
                    onSeekEnd: () {
                      final v = _dragPreview.value;
                      _dragPreview.value = null;
                      if (v == null) return;
                      // 告诉歌词区「这一跳是跳转」：用更慢、会轻微回弹的弹簧，
                      // 而且不错峰（AMLL 的 Seek 也是这么分的）
                      setState(() => _seekToken++);
                      player.seekPercent(v).then((_) {
                        if (_wasPlaying) player.resume();
                      });
                    },
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        formatTime(display.inMilliseconds / 1000.0),
                        style: _timeStyle,
                      ),
                      const Spacer(),
                      Text(
                        formatTime(player.duration.inMilliseconds / 1000.0),
                        style: _timeStyle,
                      ),
                    ],
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  static const _timeStyle = TextStyle(
    fontSize: 11,
    color: Color(0x99FFFFFF),
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// 传输控件：**播放模式 · 上一首/播放/下一首 · 全屏**。
  ///
  /// 顺序与分组照参考图（也是 Apple Music 的样子）：
  ///   * 最左是播放模式（**点击循环切换**，不是弹菜单 —— AMLL 的 `cycleRepeat`
  ///     就是点一下换一个，我们跟着它）；
  ///   * 中间三个紧挨着，整体在中间居中；
  ///   * 最右是全屏/退出全屏。
  Widget _buildTransport() {
    // 五个按钮**等间距**（`spaceBetween`：两端贴边、相邻间隔一致）。
    // 之前是「中间三个抱团、两边甩开」，看着像两组控件而不是一行。
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildModeButton(),
        _transportButton(
          icon: AppIcons.prev,
          tooltip: '上一首',
          onTap: () => widget.state.handleEndedAction('prev'),
        ),
        _buildPlayButton(),
        _transportButton(
          icon: AppIcons.next,
          tooltip: '下一首',
          onTap: () => widget.state.handleEndedAction('next'),
        ),
        _buildFullscreenButton(),
      ],
    );
  }

  /// 播放模式：点一下切到下一个模式（顺序就是 `PlayMode.values`）。
  Widget _buildModeButton() {
    return AppIconButton(
      icon: playModeIcon(player.playMode),
      size: 40,
      iconSize: 20,
      filled: true,
      baseColor: Colors.white.withValues(alpha: 0.85),
      hoverColor: Colors.white,
      hoverBg: Colors.white.withValues(alpha: 0.12),
      tooltip: player.playMode.label,
      onTap: _cyclePlayMode,
    );
  }

  /// 循环切换播放模式，并在右上角提示当前是哪个。
  ///
  /// 提示是必要的：图标只差一点（尤其是 repeatAll / repeatOne 与 sequential），
  /// 点一下没有反馈的话用户不知道切到哪了。
  void _cyclePlayMode() {
    final modes = PlayMode.values;
    final next = modes[(modes.indexOf(player.playMode) + 1) % modes.length];
    player.setMode(next);
    toast.show(next.label, type: ToastType.info, duration: 1500);
  }

  Widget _transportButton({
    required String icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return AppIconButton(
      icon: icon,
      size: 40,
      iconSize: 22,
      filled: true,
      baseColor: Colors.white.withValues(alpha: 0.85),
      hoverColor: Colors.white,
      hoverBg: Colors.white.withValues(alpha: 0.12),
      tooltip: tooltip,
      onTap: onTap,
    );
  }

  /// 播放键：**只有图标，没有圆底**（与播放栏那边一致）。
  ///
  /// 槽位仍是 52×52 —— 这一行五个控件是等间距的（`spaceBetween`），
  /// 改尺寸会把间距带歪；主次靠图标更大（28）与更亮的白来区分。
  /// 【key 给测试用】：以前它是靠「圆形白底」被测试找到的，圆底去掉之后
  /// 那个判据不再成立，`now_playing_test.dart` 改成按这个 key 找。
  Widget _buildPlayButton() {
    return AppIconButton(
      key: const Key('now-playing-play'),
      icon: player.isPlaying ? AppIcons.pause : AppIcons.play,
      size: 52,
      iconSize: 28,
      filled: true,
      baseColor: Colors.white.withValues(alpha: 0.92),
      hoverColor: Colors.white,
      hoverBg: Colors.white.withValues(alpha: 0.12),
      onTap: player.togglePlay,
    );
  }

  /// 全屏 / 退出全屏。图标跟着状态换（角朝外 = 进全屏，角朝内 = 退出来）。
  ///
  /// 状态取自共享的 [appFullscreen]（不是页面本地字段）：窗口被系统事件改变时
  /// 也要跟着回滚，否则图标会和实际情况不符。
  Widget _buildFullscreenButton() {
    return ValueListenableBuilder<bool>(
      valueListenable: appFullscreen,
      builder: (_, full, _) => AppIconButton(
        icon: full ? AppIcons.compress : AppIcons.expand,
        size: 40,
        iconSize: 20,
        filled: true,
        baseColor: Colors.white.withValues(alpha: 0.85),
        hoverColor: Colors.white,
        hoverBg: Colors.white.withValues(alpha: 0.12),
        tooltip: full ? '退出全屏' : '全屏',
        onTap: _toggleFullscreen,
      ),
    );
  }

  /// 进 / 退全屏 —— 真正的活在原生侧做（`windows/runner/window_fx.cpp`）。
  ///
  /// ⚠️ 为什么不在 Dart 里 `windowManager.setBounds(显示器矩形)`（走通过一版，问题一堆）：
  /// `setBounds` 是 `SetWindowPos`，而窗口在「正常」状态下被改尺寸时，Windows 会
  /// **顺手更新它的「还原尺寸」**。于是「铺满显示器」之后系统的最大化/还原语义全乱：
  /// 点最大化看起来没变化、再点还原回到「显示器大小」且能拖、拖过之后还原尺寸被
  /// 永久改掉（只能重启）。原生那边改成「进全屏切 `WS_POPUP`（系统层面就无法
  /// 最大化/还原）、退出用 `SetWindowPlacement` 连位置尺寸和最大化状态一起还回去」。
  ///
  /// 也别用 `windowManager.setFullScreen`：它的全屏分支在 `is_frameless_` 为真时
  /// 整段被跳过（我们正是 frameless），退出分支还会把 `WS_THICKFRAME | WS_MAXIMIZEBOX`
  /// 加回去 —— 原生标题栏就冒出来了。
  Future<void> _toggleFullscreen() => toggleFullscreen();

  Widget _buildVolume() {
    return Row(
      children: [
        AppIcon(
          AppIcons.volume,
          size: 15,
          color: Colors.white.withValues(alpha: 0.55),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AppProgressBar(
            value: player.volume,
            height: 3,
            hoverHeight: 6,
            draggable: true,
            trackColor: Colors.white.withValues(alpha: 0.22),
            fillColor: Colors.white.withValues(alpha: 0.9),
            onSeek: player.setVolume,
          ),
        ),
        const SizedBox(width: 10),
        AppIcon(
          AppIcons.volume,
          size: 19,
          color: Colors.white.withValues(alpha: 0.85),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 进度条拖动

  /// 每次拖完进度条 +1 —— 歌词区据此把这一跳当成「跳转」处理
  int _seekToken = 0;

  /// 拖动中的预览比例（`null` = 没在拖）。
  ///
  /// 见 [_buildProgress] 里的说明：不能靠 `setState`，整页内容是缓存的。
  final ValueNotifier<double?> _dragPreview = ValueNotifier<double?>(null);

  /// 拖动前的播放状态（松手后要不要接着放）
  bool _wasPlaying = false;
}

/// AMLL 背景律动的三条公式（照它的 MeshGradientRenderer 复刻）。
///
/// 它那边的模型是：
///
///   * **匀速慢转**：角度 = `(已播秒数 + 低频音量) × 2`；换算过来就是
///     **0.2 rad/s（约 31 秒一圈）**，低频那项最多再把角度推 0.2 rad（≈11.5°）；
///   * **低频 → 缩放**：外面给的 0~1 低频音量它内部先 `/10`，再用 `1 − 2×音量`
///     去缩 UV，所以最多把画面**向内放大 25%** —— 这就是「跟着鼓点跳动」；
///   * 低频还让画面稍微暗一点点（最多 5%，基本看不出来）。
///
/// 三个量都乘上设置里的幅度倍数（`amount`，调成 0 就是完全静止）。
double bgVolume(double level) => ((level - 0.5) / 0.4).clamp(0.0, 1.0);

/// 转角（弧度）：0.2 rad/s 的匀速慢转 + 低频推角。
///
/// [spin] 是设置里的「旋转速度」倍数，**只乘在匀速那一项上** ——
/// 低频推角与缩放幅度归 [amount]（「律动幅度」）管，两个选项互不干扰；
/// 幅度调 0 依旧是「完全静止」。
double bgAngle(double seconds, double bass, double amount, {double spin = 1}) =>
    0.2 * amount * spin * seconds + 0.2 * amount * bass;

/// 低频驱动的缩放倍数（最多向内放大 25%；`amount` 再放大这个幅度）。
double bgZoom(double bass, double amount) =>
    1.0 / (1.0 - (0.2 * bass * amount).clamp(0.0, 0.6));
/// 背景 = 一张**放得很大、绕着屏幕中心**的糊封面，外面罩两层黑。
///
/// 运动照 AMLL 的背景渲染器复刻（见上面 `bgAngle` / `bgZoom`）：
/// **匀速慢转**（约 31 秒一圈）+ **低频把画面轻轻向内放大**（最多 25%）。
/// 没有按拍「搓」那一套 —— 那是上一版的猜测，和它实际的行为对不上。
///
/// 两处开销上的讲究：
///  * 底图是**预先糊好的普通图片**（[_RecordArt]）：`ImageFiltered` 在滑动子树里会
///    每帧重糊并和内容错位，这里一次糊好、之后只是贴图 + 改变换矩阵；
///  * 尺寸给到 `2.8 × 对角线`：绕屏幕中心转，图的**内切圆半径**（边长/2）只要盖得住
///    窗口的外接圆（对角线/2）就行，2.8 倍余量很大。贴图本身只有 512²，
///    放大由 GPU 采样，显存可以忽略。
class _Backdrop extends StatefulWidget {
  const _Backdrop({
    required this.pic,
    required this.mid,
    required this.amount,
    required this.spin,
  });

  final String pic;
  final String mid;

  /// 律动幅度倍数（设置里的「现在播放页」→「律动幅度」）：
  /// 1.0 = 默认幅度 + 最多 25% 的低频放大；0 = 完全静止
  final double amount;

  /// 转速倍数（设置里的「现在播放页」→「旋转速度」）：
  /// 1.0 = 约 31 秒一圈，0 = 不转（低频推角仍在）
  final double spin;

  @override
  State<_Backdrop> createState() => _BackdropState();
}

class _BackdropState extends State<_Backdrop>
    with SingleTickerProviderStateMixin {
  /// 60fps 的时钟，只驱动这一层
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

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
  void didUpdateWidget(covariant _Backdrop old) {
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
    _clock.dispose();
    super.dispose();
  }

  void _scheduleRetry() {
    _retry?.cancel();
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
    if (player.isPlaying && !_clock.isAnimating) {
      // 起跑前重新对一次表（暂停期间位置不动，直接续上）
      _onPos();
      _wallPrev = _wall.elapsed;
      _clock.repeat();
    } else if (!player.isPlaying && _clock.isAnimating) {
      _clock.stop();
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
                  animation: _clock,
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
                        : _RecordArt(
                            // 背景要糊掉，但糊之前缩到 512 —— 用原图这一档，
                            // 和封面预热共用同一份下载与解码缓存
                            url: ApiClient.getProxyImageUrl(
                              ApiClient.coverUrlFor(widget.pic,
                                  px: kNowPlayingCoverPx),
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
              // 响的时候再透一点点。
              AnimatedBuilder(
                animation: _clock,
                builder: (_, _) => DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.24 - 0.06 * _level),
                  ),
                ),
              ),
              // 暗角：中心不压、四周收下去（也是抄它那套，比线性渐变自然）
              DecoratedBox(
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
              ),
            ],
          ),
        );
      },
    );
  }
}

/// B站视频背景：把解码出来的那一帧铺满整屏（cover），上面罩的是**和封面背景
/// 同一套**「压暗 + 暗角」—— 不压的话画面本身的亮部会把歌词的对比度吃光。
///
/// 不跟着封面那套旋转 / 律动：画面自己就在动，再转一圈只会晕。
class _VideoBackdrop extends StatelessWidget {
  const _VideoBackdrop({super.key, required this.image});

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
          // 压暗与暗角的数值和 `_Backdrop` 保持一致（那里是 0.24 + 0.26）
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.24),
            ),
          ),
          DecoratedBox(
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
          ),
        ],
      ),
    );
  }
}

/// 暂停时把封面收小（0.75），恢复播放时弹回原样。
///
/// 两条曲线不一样，这是照 AMLL 的 Cover 组件来的：
///   * **收进去**：`Cubic(0.4, 0.2, 0.1, 1)`、600ms —— 平顺地收，别弹；
///   * **弹回来**：`Cubic(0.3, 0.2, 0.2, 1.4)`、500ms —— 末端 y 到 1.4，
///     所以最后会**轻轻过冲一下再落回**，那点回弹就是「丝滑」的来源
///     （纯缓出会显得软塌塌的）。
///
/// ⚠️ 别用 `TweenAnimationBuilder`/`AnimatedScale`：前者首次构建不会落到目标值
/// （测试里实测到「暂停态还是 1.0」），后者只能给一条曲线、分不出收与放。
class _PausedCoverScale extends StatefulWidget {
  const _PausedCoverScale({required this.playing, required this.child});

  final bool playing;
  final Widget child;

  /// 暂停时缩到多小（和 AMLL 的默认值一致）
  static const double paused = 0.75;

  @override
  State<_PausedCoverScale> createState() => _PausedCoverScaleState();
}

class _PausedCoverScaleState extends State<_PausedCoverScale>
    with SingleTickerProviderStateMixin {
  /// 0 = 暂停（缩着），1 = 播放（原样）
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
    value: widget.playing ? 1 : 0,
  );

  late Animation<double> _scale = _build();

  Animation<double> _build() => Tween<double>(
        begin: _PausedCoverScale.paused,
        end: 1.0,
      ).animate(CurvedAnimation(
        parent: _c,
        curve: widget.playing
            ? const Cubic(0.3, 0.2, 0.2, 1.4)
            : const Cubic(0.4, 0.2, 0.1, 1),
      ));

  @override
  void didUpdateWidget(covariant _PausedCoverScale old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing) {
      // 曲线绑在 CurvedAnimation 上，要跟着方向一起换
      setState(() => _scale = _build());
      _c.duration = Duration(milliseconds: widget.playing ? 500 : 600);
      _c.animateTo(widget.playing ? 1.0 : 0.0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _scale,
      builder: (_, child) => Transform.scale(
        key: const ValueKey('coverScale'),
        scale: _scale.value,
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// 预先糊好的封面（唱片本体）。
///
/// **不在动画里用 `ImageFiltered`**：它产生的是 `ImageFilterLayer`，而这个页面整体在
/// 滑动、这一层自己还在转（每帧换变换矩阵）—— 滤镜层的缓存跟矩阵绑在一起，实测结果是
/// **每帧重新糊一遍**（掉帧），而且和内容错位（背景比内容慢半拍）。
///
/// 改成「糊一次、存成一张普通 `ui.Image`」：之后每帧只是贴图 + 改变换，
/// 零滤镜开销，也不会错位。
///
/// 糊的时候顺手套一道**照片滤镜**（[bgPhotoFilter]，照 AMLL 的配方）：
/// 对比度 0.4 → 饱和度 **×3** → 对比度 1.7。Apple Music 那种背景是「亮艳」的，
/// 而模糊只会把颜色摊平、越糊越灰 —— 不补饱和度就整页发灰。
class _RecordArt extends StatefulWidget {
  const _RecordArt({required this.url});

  final String url;

  @override
  State<_RecordArt> createState() => _RecordArtState();
}

class _RecordArtState extends State<_RecordArt> {
  ui.Image? _image;
  String _loading = '';

  /// 解出来的边长。
  ///
  /// 256 就够：它会被放大到约 1.06×对角线（1080p 窗口下约 1400px），
  /// 放大 5.5 倍；「解得更细」在这条链路上没有任何意义 —— 反正要糊掉。
  static const int _px = 256;

  /// 模糊半径（作用在这张 256 的小图上）。
  ///
  /// 屏幕上看到的模糊 ≈ `_sigma × (显示尺寸 / _px)` —— 18 × 5.5 ≈ **100px**，
  /// 糊到这个程度就只剩大块色域，没有能看出照片结构的细节了。
  static const double _sigma = 18;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _RecordArt old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load();
  }

  Future<void> _load() async {
    final url = widget.url;
    if (url.isEmpty) {
      if (mounted) setState(() => _image = null);
      return;
    }
    _loading = url;
    try {
      final provider = ResizeImage(NetworkImage(url), width: _px, height: _px);
      final stream = provider.resolve(ImageConfiguration.empty);
      final done = Completer<ui.Image>();
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          if (!done.isCompleted) done.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (e, _) {
          if (!done.isCompleted) done.completeError(e);
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      final src = await done.future;

      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImage(
        src,
        Offset.zero,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: _sigma,
            sigmaY: _sigma,
            // 不给 clamp 的话四周会糊出一圈透明边
            tileMode: ui.TileMode.clamp,
          )
          ..colorFilter = ColorFilter.matrix(bgPhotoFilter()),
      );
      final blurred =
          await recorder.endRecording().toImage(src.width, src.height);
      // 期间已经换歌 / 换页面了：这份结果丢掉
      if (!mounted || _loading != url) return;
      setState(() => _image = blurred);
    } catch (_) {
      if (mounted && _loading == url) setState(() => _image = null);
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

// ============================================================ 歌词区

/// 一行的弹簧（照 AMLL 的 `group.posY`）。
///
/// 每行**各自**一个弹簧、各自的启动延迟：最上面那行先走，下面的依次跟上 ——
/// 整片像被带着走，而不是一张平板在平移。
///
/// 起点固定为「这次变化之前的位置」，等 [delay] 秒后开始走。
/// 所有行的**目标**是同一个值（整片一起移动同一段距离），差别只在相位。
class _RowSpring {
  _RowSpring(this.value);

  /// 当前值（屏幕位移，单位像素）
  double value;

  double _from = 0;
  double _to = 0;
  double _elapsed = 0;
  double _delay = 0;
  SpringSimulation? _sim;
  bool _done = true;

  bool get done => _done;
  bool get settled => _done;

  /// 指定新的目标（[from] 是这行此刻的位置，[delay] 是比首行晚多久启动，
  /// [velocity] 是它此刻的速度）。
  ///
  /// [velocity] 为什么要给：滚轮是一格一格来的，每一格都从速度 0 重新起跑的话，
  /// 连着一滚就变成「加速→减速→加速→减速」。带上当前速度，轨迹在位置和速度上
  /// 都连续，看起来就是一条曲线。（换行那条路仍然传 0，手感不变。）
  void aim({
    required double from,
    required double to,
    required SpringDescription spec,
    required double delay,
    double velocity = 0,
  }) {
    value = from;
    _from = from;
    _to = to;
    _delay = delay;
    _elapsed = 0;
    _sim = SpringSimulation(spec, from, to, velocity);
    _done = false;
  }

  /// 此刻的速度（px/s）—— 还没起跑时是 0
  double get velocity {
    if (_done || _sim == null) return 0;
    final t = _elapsed - _delay;
    return t <= 0 ? 0 : _sim!.dx(t);
  }

  /// 立刻到位（不动画）：首次定位、换歌都走这里
  void settle(double v) {
    value = v;
    _from = v;
    _to = v;
    _sim = null;
    _done = true;
  }

  void advance(double dt) {
    if (_done) return;
    _elapsed += dt;
    final t = _elapsed - _delay;
    if (t <= 0) {
      value = _from;
      return;
    }
    value = _sim!.x(t);
    if (_sim!.isDone(t)) {
      value = _to;
      _done = true;
    }
  }
}

/// 把一行的位移贴上去。
///
/// 用 `Transform.translate` 而不是改布局：位移量是**过程量**（最终归零），
/// 不需要参与布局（参与的话每帧都要重排整片歌词）。
/// `child` 走 `ValueListenableBuilder` 的 child，行内容不会跟着重建。
class _RowOffset extends StatelessWidget {
  const _RowOffset({
    required this.index,
    required this.listenable,
    required this.child,
  });

  final int index;
  final ValueListenable<double> listenable;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: listenable,
      builder: (_, dy, child) => Transform.translate(
        key: ValueKey('rowOffset$index'),
        offset: Offset(0, dy),
        child: child,
      ),
      child: child,
    );
  }
}

/// 歌词区。
///
/// 结构照 AMLL 的 `LyricPlayer`：**没有滚动容器**，每行一个弹簧 + 一个启动延迟，
/// 每帧由自己推导的播放时刻决定「对齐哪一行」。
///
/// 为什么不用 `ScrollController` + `animateTo`（这是重写过一版的原因）：
///
///  * **时机**：行高亮原来是靠播放器的位置事件（约 200ms 一档）驱动的，
///    于是「行亮起」之后还要再等最多 200ms 才开始滚 —— 观感就是「亮了才切、有滞后」。
///    这里改成用 **Stopwatch + 位置事件锚点** 推出的连续播放时刻，每帧自己算当前行，
///    行一开始就滚（AMLL 就是这么做的：它每帧 `setCurrentTime`）。
///  * **错峰**：`animateTo` 是把整片内容一起平移，做不到「上下行依次跟上」。
///    每行一个弹簧 + 各自的延迟才有 AMLL 那种涟漪感。
///  * **不打断**：补间动画每次从速度 0 起跑，连续两句挨得近时会一顿一顿；
///    弹簧带着当前值接着走，中途换目标也不打嗝。
class _LyricsView extends StatefulWidget {
  const _LyricsView({
    super.key,
    required this.lines,
    required this.transMap,
    required this.activeIndex,
    required this.fontSize,
    required this.seekToken,
  });

  final List<LyricLine> lines;
  final Map<double, String> transMap;

  /// 播放器给的当前行（用来做**初始值**；之后由本组件自己每帧推导）
  final int activeIndex;

  final double fontSize;

  /// 每次用户拖完进度条 +1。变了就说明这一跳是「跳转」——
  /// 用更慢、会轻微回弹的弹簧（AMLL 的 Seek 也是这套），而且不错峰。
  final int seekToken;

  @override
  State<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<_LyricsView>
    with SingleTickerProviderStateMixin {
  final GlobalKey _viewport = GlobalKey();

  /// 一行一个 key：算目标位置时要量「这一行现在在屏幕上的哪」（RenderBox）。
  /// 逐行按需生成、按行数复用，别每帧新建（GlobalKey 一换就重建那一行的 State）。
  final List<GlobalKey> _rowKeys = [];

  /// 每行的位移 + 通知（给 [_RowOffset]）
  final List<_RowSpring> _springs = [];
  final List<ValueNotifier<double>> _offsets = [];

  late final Ticker _ticker = createTicker(_onTick);

  /// 当前句停在视口高度的这个比例处（和 AMLL 的 `alignPosition: 0.35` 一致）
  static const double _anchor = 0.35;

  /// 比当前句往上/往下各管多少行（屏幕外的行不需要错峰）
  static const int _staggerAbove = 3;
  static const int _staggerBelow = 14;

  /// 用户滚过之后，隔这么久恢复自动跟随（AMLL 是 500ms）
  static const Duration _resumeFollowDelay = Duration(milliseconds: 900);

  /// 提前多久开始盯着「下一行」。
  ///
  /// ⚠️ 帧循环不能常驻（页面永远不 idle：测试里 `pumpAndSettle` 会一直等下去，
  /// 真机上也白吃帧）。换成「快到下一行时才转」——启动时刻不要求精确（有这
  /// 1.5 秒的窗口），但一旦转起来，换行时刻就是**帧级**精确的，这就够了。
  static const double _watchAheadSecs = 1.5;

  // ------------------------------------------------------------ 播放时刻

  /// 真实时间的钟：算帧间隔、以及「位置事件距今多久」
  final Stopwatch _wall = Stopwatch();

  /// 位置事件的锚点：那只事件说「音频到了 _anchorPos 秒」，发生在这只表的 _anchorAt。
  double _anchorPos = 0;
  Duration _anchorAt = Duration.zero;

  Duration _lastTick = Duration.zero;

  /// 这一帧的平滑播放时刻（秒）。
  ///
  /// ⚠️ 播放器的位置事件是**粗粒度**的（约 200ms 一档）。拿它当播放时刻的话，
  /// 「行该亮了」最多要等 200ms 才被知道 —— 滚动就慢了这 200ms，
  /// 观感正是「歌词亮了才切过去」。所以拿「最近一次事件的时刻 + 事件到现在的
  /// 真实时间」当播放时刻，误差只剩几十毫秒。
  double get _playSecs {
    final since = (_wall.elapsed - _anchorAt).inMicroseconds / 1e6;
    // 暂停时位置不动，所以把「事件之后」的部分夹在 0.5 秒内，别越滑越远
    return _anchorPos + since.clamp(0.0, 0.5);
  }

  void _onPosition() {
    _anchorPos = player.positionNotifier.value.inMicroseconds / 1e6;
    _anchorAt = _wall.elapsed;
    // 位置事件是每 ~200ms 一次的粗粒度时钟，但**「提前 1.5 秒起表」这个动作
    // 不要求精确** —— 只要在换行之前转起来就行；转起来之后换行时刻由帧循环
    // 精确捕捉。所以这里顺手启动就够了。
    //
    // ⚠️ 起表条件不能只看 `_shouldWatchRowChange()`：拖动进度条会先**暂停**播放
    // （见 `onSeekStart`），暂停时它恒为 false —— 于是**往回**拖之后表再也起不来，
    // 歌词卡在旧的一句上不动（往前拖反而没事：那一跳让「离下一句还多久」变成
    // 大负数，条件意外成立）。位置对应的行和 `_active` 不一致时也必须起表，
    // 让帧循环把 `_active` 追上来。
    if (_shouldWatchRowChange() || _resolveActive(_playSecs) != _active) {
      _startTicking();
    }
  }

  // ------------------------------------------------------------ 状态

  /// 自己推导的当前行（毫秒精度，不依赖位置事件）
  int _active = -1;

  /// 上一次看到的播放状态 —— 用来认出「按下播放」这个动作
  /// （滚过之后要重新聚焦回正在唱的那句，见 `_onPlayerChanged`）。
  bool _wasPlaying = false;

  /// 上一跳是不是「跳转」（用慢弹簧、不错峰）
  bool _pendingSeek = false;

  /// 每个弹簧的落位延迟（按行号错峰算出来的）
  double _delayFor(int i) {
    final active = _active;
    if (active < 0 || i < active - _staggerAbove || i > active + _staggerBelow) {
      return 0;
    }
    final first = math.max(0, active - _staggerAbove);
    final delays = staggerDelays(
      first: first,
      last: math.min(widget.lines.length - 1, active + _staggerBelow),
      active: active,
    );
    final k = i - first;
    return (k >= 0 && k < delays.length) ? delays[k] : 0;
  }

  /// 用户手动滚动的偏移：**正 = 内容上移**（看后面的句子）、负 = 往回看。
  /// 它不是「位移」而是「相对于自动对齐位置的偏移」—— 换行时自动对齐变了，
  /// 用户那点偏移照样保留。
  double _userScroll = 0;
  bool _followSuspended = false;
  Duration _resumeAt = Duration.zero;

  /// 视口高度（换行时算目标位置要用）
  double _viewportH = 0;

  /// 上下的留白（= 视口高 × 锚点）：第一句和最后一句也能停在锚点上
  double _pad = 0;

  /// 每一行的高度（换行 / 换尺寸时量一次）。
  ///
  /// ⚠️ **只量高度、不量位置**：行外面套着 `Transform.translate`，量位置会
  /// 混进当前的位移（读到的位置和 `_springs[i].value` 差一帧就累计误差 ——
  /// 实测「当前句跑到视口上方 700px」）。`size.height` 完全不受位移影响，
  /// 用它累加出每行的内容坐标最稳。
  final List<double> _rowHeights = [];

  /// 内容总高（= 上下留白 + 所有行高）
  double _contentH = 0;

  static Duration _now() => _wallClock.elapsed;
  static final Stopwatch _wallClock = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    _syncRows();
    _wall.start();
    player.positionNotifier.addListener(_onPosition);
    player.addListener(_onPlayerChanged);
    // ⚠️ `_active` 要在 `_onPosition()` **之前**定下来：后者会拿它和位置对应的行
    // 比对（不一致就起表），顺序反了的话开机第一下就把表白白转起来。
    _active = widget.activeIndex;
    _wasPlaying = player.isPlaying;
    _onPosition();
    // 页面是**按需建**的（收起时整块不建），推上来时得直接定位到当前句，
    // 而且这一次要**瞬移**（刚打开就自己滚一段很怪）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _snapToActive();
      _startTicking();
    });
  }

  @override
  void didUpdateWidget(covariant _LyricsView old) {
    super.didUpdateWidget(old);
    if (old.lines.length != widget.lines.length) {
      _syncRows();
      _active = widget.activeIndex;
      _userScroll = 0;
      _followSuspended = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _snapToActive();
      });
      return;
    }
    // 拖完进度条：这一跳按「跳转」处理（慢弹簧、会轻微回弹、不错峰）
    if (old.seekToken != widget.seekToken) _pendingSeek = true;
  }

  /// ⚠️ **播放中 Ticker 必须一直转**：当前行是每帧自己推导出来的，
  /// 停表之后就没人知道「该换行了」（这一版重写前就是这么漏的）。
  void _onPlayerChanged() {
    final playing = player.isPlaying;
    final resumed = playing && !_wasPlaying;
    _wasPlaying = playing;
    if (!playing) return;
    _onPosition();
    // 用户滚过之后**一按播放就重新聚焦回正在唱的那句**（千奈报的：以前会
    // 停在滚到的位置继续往下走）。清掉手工偏移、恢复自动跟随，然后**带弹簧
    // 滑回去** —— 不是瞬移，滑法跟滚轮那条一致（同一个弹簧）。
    if (resumed && (_userScroll != 0 || _followSuspended)) {
      _userScroll = 0;
      _followSuspended = false;
      _active = _resolveActive(_playSecs);
      if (mounted) setState(() {});
      _glideTo(_targetDyFor(_active < 0 ? 0 : _active));
    }
    if (_shouldWatchRowChange() || _resolveActive(_playSecs) != _active) {
      _startTicking();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    player.positionNotifier.removeListener(_onPosition);
    player.removeListener(_onPlayerChanged);
    for (final n in _offsets) {
      n.dispose();
    }
    super.dispose();
  }

  void _syncRows() {
    while (_rowKeys.length < widget.lines.length) {
      _rowKeys.add(GlobalKey());
    }
    while (_rowKeys.length > widget.lines.length) {
      _rowKeys.removeLast();
    }
    while (_springs.length < widget.lines.length) {
      _springs.add(_RowSpring(0));
      _offsets.add(ValueNotifier<double>(0));
    }
    while (_springs.length > widget.lines.length) {
      _springs.removeLast();
      _offsets.removeLast().dispose();
    }
  }

  // ------------------------------------------------------------ 目标位置

  /// 量一遍每一行的高度（换行 / 换尺寸时调一次就够）
  void _measureRows() {
    _rowHeights.clear();
    var sum = 0.0;
    for (final key in _rowKeys) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) {
        // 还没布局（或树里没有这一行）：这次量不准，等下一帧
        _rowHeights.clear();
        return;
      }
      _rowHeights.add(box.size.height);
      sum += box.size.height;
    }
    _contentH = _pad * 2 + sum;
  }

  /// 第 [i] 行顶部在**内容坐标**里的位置（和位移无关）
  double _contentTopOf(int i) {
    var y = _pad;
    for (var k = 0; k < i && k < _rowHeights.length; k++) {
      y += _rowHeights[k];
    }
    return y;
  }

  /// 让第 [i] 行的顶部停在锚点上时，整片内容需要的位移。
  ///
  /// 位移对所有行是**同一个值**（整片一起移动同一段距离）—— 差别只在各行的相位。
  double _targetDyFor(int i) {
    if (i < 0 || i >= widget.lines.length) {
      return _springs.isEmpty ? 0 : _springs[0].value;
    }
    if (_rowHeights.length != widget.lines.length) return _springs[i].value;
    // 内容不能被拖出视口：上边界 0（内容顶部贴视口顶部）、
    // 下边界 = 内容底部贴视口底部
    final minDy = math.min(0.0, _viewportH - _contentH);
    return (_viewportH * _anchor - _contentTopOf(i) - _userScroll)
        .clamp(minDy, 0.0);
  }

  /// 直接定位到当前句（首次打开 / 换歌）
  void _snapToActive() {
    _measureRows();
    final i = _active < 0
        ? 0
        : (_active > widget.lines.length - 1
            ? widget.lines.length - 1
            : _active);
    if (widget.lines.isEmpty) return;
    final dy = _targetDyFor(i);
    for (final s in _springs) {
      s.settle(dy);
    }
    _pushOffsets();
  }

  /// 换行：给每行排新的目标与延迟
  void _aimRows(int from) {
    _measureRows();
    final seek = _pendingSeek;
    _pendingSeek = false;

    // 这一句和上一句差多久 —— 弹簧快慢看它（AMLL 的 getPosYSpringPolicy）
    double? intervalMs;
    if (from > 0 && from < widget.lines.length) {
      intervalMs =
          (widget.lines[from].time - widget.lines[from - 1].time) * 1000;
    }
    final spec = lyricSpringFor(
      intervalMs: intervalMs,
      seeking: seek,
      endOfSong: from == widget.lines.length - 1,
    );

    final to = _targetDyFor(from);
    final stagger = !seek; // 跳转不错峰（AMLL 的 disableStagger 同理）
    for (var i = 0; i < _springs.length; i++) {
      final s = _springs[i];
      s.aim(
        from: s.value,
        to: to,
        spec: spec,
        delay: stagger ? _delayFor(i) : 0,
      );
    }
  }

  void _pushOffsets() {
    for (var i = 0; i < _springs.length; i++) {
      _offsets[i].value = _springs[i].value;
    }
  }

  // ------------------------------------------------------------ 帧循环

  void _startTicking() {
    if (_ticker.isActive) return;
    _lastTick = Duration.zero;
    _ticker.start();
  }

  void _stopTicking() {
    if (_ticker.isActive) _ticker.stop();
  }

  /// 现在需要盯着「下一行什么时候开始」吗
  bool _shouldWatchRowChange() {
    if (!player.isPlaying) return false;
    final lines = widget.lines;
    if (lines.isEmpty) return false;
    final next = _active + 1;
    if (next >= lines.length) return false;
    return lines[next].time - _playSecs <= _watchAheadSecs;
  }

  /// 按播放时刻找当前行（行按时间升序）
  int _resolveActive(double t) {
    final lines = widget.lines;
    if (lines.isEmpty) return -1;
    if (t < lines.first.time) return 0;
    var lo = 0, hi = lines.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time <= t) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  void _onTick(Duration elapsed) {
    if (!mounted) {
      _stopTicking();
      return;
    }
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0) return;
    // 掉帧（或刚从后台回来）时别把一大段时间一口气积分出来
    final step = dt.clamp(0.0, 1 / 30);

    // 暂停期间位置不动，先把表对回来，别让平滑时钟继续往前滑
    if (!player.isPlaying) _onPosition();

    // 1) 自己推导当前行（毫秒精度）—— 这是「行一开始就滚」的关键。
    //
    // ⚠️ **暂停时也要算**：拖进度条会先 pause，拖完位置已经跳到别处，而
    // `_active` 还停在旧的一句上 —— 表现就是「暂停时往回拖会卡住：歌词不动，
    // 按播放也不聚焦过来」（千奈报的）。往前拖能侥幸恢复，是因为那一跳让
    // `_shouldWatchRowChange()` 意外成立。
    final idx = _resolveActive(_playSecs);
    if (idx != _active) {
      _active = idx;
      if (mounted) setState(() {}); // 高亮跟着换
      _aimRows(idx);
    } else if (_pendingSeek) {
      // 跳转落在同一句里：行号没变，但也得重新对一次位 —— 不然
      // `_pendingSeek` 会一直挂着，等下一次换行时白用一次慢弹簧。
      _aimRows(idx);
    }

    // 2) 用户滚动过 → 到点恢复自动跟随
    if (_followSuspended && _now() > _resumeAt) {
      _followSuspended = false;
      _aimRows(_active.clamp(0, math.max(0, widget.lines.length - 1)));
    }

    // 3) 推进每一行的弹簧
    var moving = false;
    for (var i = 0; i < _springs.length; i++) {
      final s = _springs[i];
      s.advance(step);
      if (!s.done) moving = true;
      if (_offsets[i].value != s.value) _offsets[i].value = s.value;
    }
    // 没事可做就停表：下一次换行前 1.5 秒会由位置事件重新起表
    if (!moving && !_followSuspended && !_shouldWatchRowChange()) {
      _stopTicking();
    }
  }

  /// 滚轮：自己处理（没有滚动容器了）。
  ///
  /// 滚过之后**挂起自动对齐**一小段（AMLL 是 500ms）—— 否则下一句一到就被拉回去，
  /// 用户根本没法自己翻着看。
  ///
  /// ⚠️ 滚是**带弹簧动画**滑过去的（千奈要的「像歌单列表那样的滚动动画」），
  /// 不是 `settle` 一下瞬移。滚轮是一格一格来的，所以走 [lyricWheelSpring] 并
  /// **带上当前速度**：连着滚的时候轨迹连续，不会一格一顿。
  void _onScrollSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (widget.lines.isEmpty) return;
    _measureRows();
    final measured = _rowHeights.length == widget.lines.length;
    // 现在整片内容的目标位移（跟着当前句对齐、再叠上用户自己的偏移）
    final dy = _targetDyFor(_active < 0 ? 0 : _active);
    // 还没量出行高时别夹下界（否则会被夹到 0，滚轮等于失灵）
    final minDy = measured
        ? math.min(0.0, _viewportH - _contentH)
        : double.negativeInfinity;
    // ⚠️ 夹的是**内容位移**（[minDy, 0]：内容底部不许拖出视口下沿、顶部不许拖出
    // 上沿），不是 `_userScroll >= 0`。以前那个写法等于**只能往下滚** ——
    // 往上滚（回看前面几句）一点反应都没有，正是千奈说的
    // 「歌词几乎不响应鼠标滚轮」的一半。
    final next = (dy - event.scrollDelta.dy).clamp(minDy, 0.0);
    if (next == dy) return;
    setState(() {
      // dy = 对齐目标 − _userScroll，所以位移变多少，偏移就反着变多少
      _userScroll += dy - next;
      _followSuspended = true;
      _resumeAt = _now() + _resumeFollowDelay;
    });
    _glideTo(next);
    _startTicking();
  }

  /// 把整片内容**带弹簧**滑到位移 [to]（滚轮 / 重新聚焦走这条）。
  ///
  /// 与 [`_aimRows`] 的区别：不走「换行」那套按行间隔取刚度的策略、也不错峰，
  /// 而且带着每行**此刻的速度**接手 —— 连续滚轮才是同一条曲线。
  void _glideTo(double to) {
    final spec = lyricWheelSpring();
    for (var i = 0; i < _springs.length; i++) {
      final s = _springs[i];
      s.aim(from: s.value, to: to, spec: spec, delay: 0, velocity: s.velocity);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, cons) {
        _viewportH = cons.maxHeight;
        final pad = cons.maxHeight * _anchor;
        if (_pad != pad) _pad = pad;
        return Listener(
          // ⚠️ **必须 opaque**：默认的 `deferToChild` 要子节点命中才算数，
          // 而每一行只有「文字那么宽」（Column 是 start 对齐、不撑满）——
          // 指针放在歌词面板右边的空白处（长句之外）时滚轮事件根本进不来，
          // 表现就是「歌词几乎不响应鼠标滚轮」（千奈报的）。
          // 这一层本来就是最上面那层，不用把事件让给谁。
          behavior: HitTestBehavior.opaque,
          onPointerSignal: _onScrollSignal,
          child: ClipRect(
            child: Stack(
              key: _viewport,
              children: [
                // ⚠️ `OverflowBox` 是必需的：Stack 会给非定位子项一个
                // 「不超过视口」的高度约束，几十行歌词必然溢出（实测报
                // RenderFlex overflowed by 3998 pixels）。放开高度让 Column
                // 按自然高度排布，超出的部分由外面的 ClipRect 裁掉 ——
                // 这正是「每行自己算屏幕位置」要的前提。
                // `Positioned.fill`（而不是只给 top/left/right）：
                // OverflowBox 自己也得有个确定的高度，否则它会被当成
                // 「无限大」而报 RenderConstrainedOverflowBox 的断言。
                Positioned.fill(
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minHeight: 0,
                    maxHeight: double.infinity,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 上下各留一段：第一句和最后一句也能停在锚点上
                        SizedBox(height: pad),
                        for (var i = 0; i < widget.lines.length; i++)
                          KeyedSubtree(
                            key: _rowKeys[i],
                            child: _RowOffset(
                              index: i,
                              listenable: _offsets[i],
                              child: _buildRow(i),
                            ),
                          ),
                        SizedBox(height: pad),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRow(int i) {
    final line = widget.lines[i];
    final trans = transAt(widget.transMap, line.time).trim();
    // 高亮用**自己推导的**当前行（毫秒精度），不用位置事件那一路 ——
    // 用那边的话「行亮起」会晚最多 200ms，滚动也跟着晚。
    final active = i == _active;
    final opacity = lyricLineOpacity(i, _active);
    // ⚠️ **字号和字重都不跟着「当前句」变**（曾经当前句放大到 1.0×、加粗到 w700）：
    //  * 字号变大会让长句子「唱到就折成两行、唱完又收回去」，整片歌词跟着跳；
    //  * 字重也会改变字宽，同样会重新折行；
    //  * 而且逐字那行是 `Text.rich`（着色器直接写进 span），换样式是**瞬变**的，
    //    不像普通行那样有 `AnimatedDefaultTextStyle` 平滑过渡 —— 所以他看到
    //    「逐字那句字体突然变化」，反而觉得没有字体变化的普通行更顺。
    // 强调只靠**颜色**：当前句满亮度，其余按距离变暗（`lyricLineOpacity`）。
    //
    // 样式里**不带颜色**（颜色一律由 [_LyricLineFade] 补间），
    // 所以这个 TextStyle 在整首歌里对同一行始终相等 —— `_KaraokeLine` 的排版缓存
    // 就是靠它命中的，别往里面塞会变的东西。
    final base = TextStyle(
      fontFamily: kFontFamily,
      fontFamilyFallback: kFontFallback,
      fontSize: widget.fontSize,
      height: 1.26,
      fontWeight: FontWeight.w600,
    );
    final alphas = lyricLineAlphas(active: active, opacity: opacity);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: widget.fontSize * 0.30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 逐字行与非逐字行**共用同一条渲染路径**（`_KaraokeLine` 内部再分），
          // 换行时不会有「整棵子树换一种东西」的瞬变。
          _LyricLineFade(
            line: line,
            style: base,
            active: active,
            sungAlpha: alphas.sung,
            unsungAlpha: alphas.unsung,
          ),
          if (trans.isNotEmpty) ...[
            const SizedBox(height: 5),
            AnimatedDefaultTextStyle(
              duration: _kLineFadeDuration,
              curve: _kLineFadeCurve,
              style: TextStyle(
                fontFamily: kFontFamily,
                fontFamilyFallback: kFontFallback,
                fontSize: widget.fontSize * 0.52,
                height: 1.3,
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: opacity * 0.72),
              ),
              child: Text(trans),
            ),
          ],
        ],
      ),
    );
  }
}

/// 换行时颜色走完要多久。和普通行（`AnimatedDefaultTextStyle`）用同一组
/// 时长与曲线 —— 逐字行和没逐字的行摆在一起，过渡必须是一模一样的。
const Duration _kLineFadeDuration = Duration(milliseconds: 260);
const Curve _kLineFadeCurve = Curves.easeOut;

/// 一行歌词的颜色补间。
///
/// 为什么需要它：目标色（`lyricLineAlphas`）在换行时是**跳变**的
/// ——上一句从「纯白」掉到 50%、下一句整句从 60% 暗到 42%（还要再逐字亮起来）。
/// 直接照目标色渲染，就是千奈报的那两句：
///
///  * 「下一句切上来时整个歌词突然变暗」；
///  * 「切走时这一句整个突然变暗」。
///
/// 这里把目标色当**目的地**：每次目标变了就从「这一刻真实的颜色」补间过去，
/// 中间那 260ms 就是「逐渐关灯 / 逐渐开灯」。上一句暗下去和新一句亮起来
/// 是同时发生的，接缝处也就看不出来了。
///
/// ⚠️ 起点取的是**当前值**、不是上一组目标值：换行比 260ms 还快的时候
/// （短句、快歌）也不会跳一下。
class _LyricLineFade extends StatefulWidget {
  const _LyricLineFade({
    required this.line,
    required this.style,
    required this.active,
    required this.sungAlpha,
    required this.unsungAlpha,
  });

  final LyricLine line;

  /// 排版样式（字号/字重/字体），**不含颜色**
  final TextStyle style;

  /// 是不是当前句（决定要不要逐字刷亮）
  final bool active;

  final double sungAlpha;
  final double unsungAlpha;

  @override
  State<_LyricLineFade> createState() => _LyricLineFadeState();
}

class _LyricLineFadeState extends State<_LyricLineFade>
    with SingleTickerProviderStateMixin {
  /// 一开始就是 1（已经落在目标上）：页面推上来时当前句不该先淡入一次
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _kLineFadeDuration,
    value: 1,
  );

  late final Animation<double> _t =
      CurvedAnimation(parent: _c, curve: _kLineFadeCurve);

  late double _sungFrom = widget.sungAlpha;
  late double _sungTo = widget.sungAlpha;
  late double _unsungFrom = widget.unsungAlpha;
  late double _unsungTo = widget.unsungAlpha;

  @override
  void didUpdateWidget(covariant _LyricLineFade old) {
    super.didUpdateWidget(old);
    if (widget.sungAlpha == _sungTo && widget.unsungAlpha == _unsungTo) return;
    _sungFrom = _at(_sungFrom, _sungTo);
    _unsungFrom = _at(_unsungFrom, _unsungTo);
    _sungTo = widget.sungAlpha;
    _unsungTo = widget.unsungAlpha;
    _c.forward(from: 0);
  }

  /// 此刻这个量走到哪了（`_c` 停在 1 时就是终点）
  double _at(double from, double to) => from + (to - from) * _t.value;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 关一层 `RepaintBoundary`：补间期间这一行要重画十几帧，
    // 不关起来就会把**整页**的绘制记录标脏（连封面、控件一起重画）。
    // 常驻这一层（不按 active 开关）：一是每行都是独立的绘制记录，
    // 二是开关会让 `_KaraokeLine` 的 State 被重建一次。
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _t,
        builder: (_, _) {
          final sung = Colors.white.withValues(alpha: _at(_sungFrom, _sungTo));
          final unsung =
              Colors.white.withValues(alpha: _at(_unsungFrom, _unsungTo));
          return _KaraokeLine(
            line: widget.line,
            style: widget.style,
            sung: sung,
            unsung: unsung,
            active: widget.active,
          );
        },
      ),
    );
  }
}

/// 逐字进度：现在唱到第几个字、这个字唱了多少（0~1）。
///
/// 返回 null = 还没唱到第一个字（调用方按 0 处理）。
///
/// 字与字之间的空档会**停在上一个字的末尾**（`t = 1`）—— 这正是卡拉OK该有的样子：
/// 没到下一个字之前，刷亮的位置不动。
({int index, double t})? karaokeWordAt(List<LyricWord> words, double seconds) {
  if (words.isEmpty) return null;
  var index = -1;
  var t = 0.0;
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (seconds < w.time) break; // 还没到这个字
    if (seconds >= w.end) {
      // 这个字唱完了：先记下，再看下一个字有没有到
      index = i;
      t = 1;
      continue;
    }
    final d = w.duration;
    index = i;
    t = d <= 0 ? 1 : (seconds - w.time) / d;
    break;
  }
  if (index < 0) return null;
  return (index: index, t: t.clamp(0.0, 1.0));
}

/// 逐字歌词：把这一行**从左往右**刷亮，交界处是一条渐隐带（不是硬分界）。
///
/// 手法是给这一行的 `TextStyle.foreground` 挂一条**很窄的 `LinearGradient`**：
/// 着色矩形只有「渐隐带」那么宽、位置随进度横向移动，渐变两端之外会各自延伸
/// 到边界色 —— 于是左边天然是「已唱」色、右边是「未唱」色，中间是过渡。
/// 带宽调到 0 就是硬边，调大就是柔和的渐隐。
///
/// ⚠️ 别用 `ShaderMask` 做这件事：它每帧都要 `saveLayer`（一块离屏纹理），
/// 60fps 下光是分配/释放这些纹理就会把出场动画拖成幻灯片。
/// 挂 `foreground` 着色器是**直接用渐变画字形**，没有离屏层。
/// 背景底图相对**窗口对角线**的放大倍数。
///
/// 绕屏幕中心转，图的内切圆半径（边长/2）只要盖得住窗口的外接圆（对角线/2）就行
/// → **1.0 倍就是下限**，这里留 6% 余量。
///
/// ⚠️ **别把它放大**：这个值直接决定「背景能采到封面的多少」——
/// 放到 2.8 倍时只看得见封面中心那一小块（宽 30%、高 30%），封面上半部的颜色
/// 根本进不了画面。实测同一张 Lover 封面：2.8 倍出来是没有人味的灰蓝
/// （R−G 只有 +17），1.06 倍能采到宽 81%、高 53%，R−G 到 +43（明显的粉，
/// iPad 上是 +34）。`test/now_playing_test.dart` 里有一条守着它。
const double kBackdropScale = 1.06;

/// 背景底图的「照片滤镜」—— 照 AMLL 的配方：
/// **对比度 0.4 → 饱和度 3.0 → 对比度 1.7**（三步都是仿射变换，合成成一个矩阵）。
///
/// 为什么要这么狠地提饱和：底图要糊成一大片色域，而模糊本身会把颜色摊平；
/// 不补回来的话整页就是灰的 —— 实测我们的背景 RGB 119/123/131（几乎没有色相），
/// 而 Apple Music 同一张封面是 197/163/156（明显的粉）。
///
/// 合成公式：对比度 `y = c·x + 128(1−c)`、饱和度按 Rec.709 亮度权重混灰，
/// 所以最终 = `c1·c2·sat(x) + 128·(c2(1−c1) + (1−c2))`。
/// 中间那两步**不clamp**（和 AMLL 一样在浮点里算完才落盘），否则合并不了。
List<double> bgPhotoFilter({
  double contrast1 = 0.4,
  double saturate = 3.0,
  double contrast2 = 1.7,
}) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final m = 1 - saturate;
  final k = contrast1 * contrast2;
  final off = 128 * (contrast2 * (1 - contrast1) + (1 - contrast2));
  return <double>[
    (lr * m + saturate) * k, lg * m * k, lb * m * k, 0, off, //
    lr * m * k, (lg * m + saturate) * k, lb * m * k, 0, off, //
    lr * m * k, lg * m * k, (lb * m + saturate) * k, 0, off, //
    0, 0, 0, 1, 0,
  ];
}

/// 逐字歌词里**每一行**该怎么着色。
///
/// 为什么需要它：着色用的是一条只沿**水平方向**取值的渐变（`LinearGradient`），
/// 它的值只跟 x 有关、**跟 y 无关** —— 所以句子折成两行时，同一列上的两行会
/// 拿到同一个颜色，表现为「上下两行同时亮」（千奈报的）。
/// 想只点亮正在唱的那一行，只能**一行给一个着色器**。
enum KaraokeRowStyle {
  /// 已经唱过去了：整行用「已唱」色（把渐变推到天边，全用第一个色）
  sung,

  /// 还没轮到：整行用「未唱」色
  unsung,

  /// 正在唱的这一行：有一条会走的渐隐带
  boundary,
}

/// 给出每一行的着色类型。[activeRow] 为 null（还没唱到第一个字）时全按未唱。
List<KaraokeRowStyle> karaokeRowStyles(int rowCount, int? activeRow) {
  return [
    for (var r = 0; r < rowCount; r++)
      if (activeRow == null || r > activeRow)
        KaraokeRowStyle.unsung
      else if (r < activeRow)
        KaraokeRowStyle.sung
      else
        KaraokeRowStyle.boundary,
  ];
}

class _KaraokeLine extends StatefulWidget {
  const _KaraokeLine({
    required this.line,
    required this.style,
    required this.sung,
    required this.unsung,
    required this.active,
  });

  final LyricLine line;

  /// 只用来排版（字号/字重/字体）；颜色由 [sung] / [unsung] 决定
  final TextStyle style;
  final Color sung;
  final Color unsung;

  /// 是不是当前句。只有当前句才去排字框、跟播放位置逐帧刷亮 ——
  /// 别的行整句一个颜色就够，不必为它们各算一遍逐字边界。
  final bool active;

  @override
  State<_KaraokeLine> createState() => _KaraokeLineState();
}

class _KaraokeLineState extends State<_KaraokeLine> {
  TextPainter? _painter;
  List<Rect>? _boxes;
  double? _width;
  TextStyle? _style;

  /// 每个字属于第几行（按 box 的 top 分组）
  List<int> _wordRow = const [];

  /// 每一行在整行文本里的字符区间 + 该行的字属于哪些词
  List<({int start, int end, double top, double bottom})> _rows = const [];

  /// 渐隐带半宽 = 字号 × 这个系数（0.45 → 整条带子约一个字宽）
  static const double _fadeRatio = 0.45;

  /// 「整行已唱 / 整行未唱」时把渐变推到天边去 —— 渐变两端之外会各自延伸到
  /// 边界色，所以推到 +∞ 就是全用第一个色（已唱）、推到 −∞ 就是全用第二个色。
  static const double _far = 1e5;

  /// 排版一次就够：只在文本/样式/可用宽度变了的时候重排
  void _ensureLayout(double maxWidth) {
    if (_painter != null && _width == maxWidth && _style == widget.style) return;
    final words = widget.line.words!;
    final tp = TextPainter(
      text: TextSpan(text: widget.line.text, style: widget.style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);

    // 每个字在文本里的横向范围。字的文本拼起来就是整行（见 parseQrc），
    // 所以按长度累加就能得到字符区间。
    final boxes = <Rect>[];
    final offsets = <int>[];
    var offset = 0;
    for (final w in words) {
      offsets.add(offset);
      final start = offset;
      offset += w.text.length;
      final list = tp.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: offset),
      );
      boxes.add(list.isEmpty
          ? Rect.zero
          // 折行时一个字会拆成多个 box：从第一个的左到最后一个的右
          : Rect.fromLTRB(list.first.left, list.first.top, list.last.right,
              list.last.bottom));
    }

    // 按 box 的 top 把字分成行（同一行的 top 相同，浮点误差留 1px 容差）
    final wordRow = List<int>.filled(boxes.length, 0);
    final rows = <({int start, int end, double top, double bottom})>[];
    for (var i = 0; i < boxes.length; i++) {
      final box = boxes[i];
      final end = offsets[i] + words[i].text.length;
      if (rows.isNotEmpty && (box.top - rows.last.top).abs() < 1.0) {
        final last = rows.removeLast();
        rows.add((
          start: last.start,
          end: end,
          top: last.top,
          bottom: box.bottom > last.bottom ? box.bottom : last.bottom,
        ));
      } else {
        rows.add((start: offsets[i], end: end, top: box.top, bottom: box.bottom));
      }
      wordRow[i] = rows.length - 1;
    }
    // 空 box（正则没量到的）落到最后一行，别越界
    _wordRow = wordRow;
    _rows = rows;
    _painter = tp;
    _boxes = boxes;
    _width = maxWidth;
    _style = widget.style;
  }

  /// 当前唱到哪一行的哪个 x（x 是整行文本坐标系里的位置）
  ({int row, double x})? _progress(double seconds) {
    final hit = karaokeWordAt(widget.line.words!, seconds);
    if (hit == null) return null;
    final boxes = _boxes!;
    final i = hit.index.clamp(0, boxes.length - 1);
    final box = boxes[i];
    return (row: _wordRow[i], x: box.left + (box.right - box.left) * hit.t);
  }

  /// 一行用的着色器。
  ///
  /// [x] 是这一行的刷亮边界：传 [_far] 就是整行已唱（全用第一个色），
  /// 传 −[_far] 就是整行未唱。
  Paint _paint(double x) {
    final fade = (widget.style.fontSize ?? 20) * _fadeRatio;
    return Paint()
      ..shader = LinearGradient(colors: [widget.sung, widget.unsung])
          .createShader(
        // 着色矩形 = 渐隐带本身，宽度就是过渡的长度。
        // ⚠️ 渐变只沿**水平方向**取值，与 y 无关 —— 所以「一行一个 shader」
        // 才是能不能只点亮一行的关键，靠矩形高度是拦不住的。
        Rect.fromLTWH(x - fade, 0, fade * 2, (_painter?.height ?? 40) + 4),
      );
  }

  @override
  Widget build(BuildContext context) {
    final words = widget.line.words;
    // 两种情况都走整行一个平色：
    //  * **没有逐字时间**（普通 LRC）—— 本来就只有整行高亮；
    //  * **不是当前句** —— 整行按距离变暗，不必为它算逐字边界。
    //
    // 平色有两个好处：省掉每个字一份着色器；而且**这种渲染是能读出来的**
    // （`TextStyle.color`）—— 换行时它是慢慢暗下去还是直接掉下去，测得到
    // （见 now_playing_test 里的「换行过渡」）。
    //
    // 那一句刚唱完时逐字边界本来就在末尾，所以从「带边界的富文本」换成平色
    // 不会有可见的跳变。
    if (!widget.active || words == null || words.isEmpty) {
      return Text(widget.line.text, style: _flat(widget.sung));
    }

    return LayoutBuilder(
      builder: (ctx, cons) {
        _ensureLayout(cons.maxWidth);
        // 只有这一行要跟着播放位置逐帧重画，所以监听器挂在这里 ——
        // 挂高了会让整页歌词跟着每秒重画几十次。
        return ValueListenableBuilder<Duration>(
          valueListenable: player.positionNotifier,
          builder: (ctx, pos, _) {
            final full = widget.line.text;
            final rows = _rows;
            // 还没量出行来（空歌词之类）就整句按未唱色渲染
            if (rows.isEmpty) {
              return Text(full, style: _flat(widget.unsung));
            }
            final prog = _progress(pos.inMilliseconds / 1000.0);
            // 还没唱到第一个字（QRC 里行起点常常早于第一个字）：整句一个未唱色。
            // 换行的那一瞬间正是这个状态 —— 颜色得跟着 [_LyricLineFade] 的补间走，
            // 所以这里必须把 `unsung` 用上，不能写死一个常数。
            if (prog == null) {
              return Text(full, style: _flat(widget.unsung));
            }
            final styles = karaokeRowStyles(rows.length, prog.row);
            return Text.rich(
              TextSpan(
                children: [
                  for (var r = 0; r < rows.length; r++)
                    TextSpan(
                      text: full.substring(rows[r].start, rows[r].end),
                      style: widget.style.copyWith(
                        foreground: _paint(switch (styles[r]) {
                          KaraokeRowStyle.sung => _far,
                          KaraokeRowStyle.unsung => -_far,
                          KaraokeRowStyle.boundary => prog.x,
                        }),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 平色渲染用的样式（`foreground` 与 `color` 不能同时给，这里只用 `color`）
  TextStyle _flat(Color c) => widget.style.copyWith(color: c);
}
