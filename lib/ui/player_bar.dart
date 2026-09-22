import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import 'widgets/karaoke_text.dart';
import '../core/lyric.dart';
import '../models/song.dart';
import '../services/api_client.dart';
import '../services/player_controller.dart';
import '../state/app_state.dart';
import 'icons.dart';
import 'widgets/common.dart';
import 'widgets/context_menu.dart';

const double kPlayerBarHeight = 72;
const double kLyricLineHeight = 24;

/// 播放模式的图标（`AppIcons` 的路径数据）—— 按钮与菜单共用一份
String _modeIcon(PlayMode mode) => switch (mode) {
      PlayMode.sequential => AppIcons.playOrder,
      PlayMode.reverse => AppIcons.playOrderReverse,
      PlayMode.repeatAll => AppIcons.repeatAll,
      PlayMode.repeatOne => AppIcons.repeatOne,
      PlayMode.shuffle => AppIcons.shuffle,
    };



/// 底部播放器栏 —— 对应 `.player-bar`
class PlayerBar extends StatefulWidget {
  const PlayerBar({super.key, required this.state, this.onOpenQueue});

  final AppState state;

  /// 点「播放列表」时调 —— 面板由 shell 托管（它要盖在页面之上、播放栏之下）。
  final VoidCallback? onOpenQueue;

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> with SingleTickerProviderStateMixin {
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  bool _draggingProgress = false;

  /// 播放模式按钮的锚点 —— 菜单要贴着它往上弹
  final GlobalKey _modeKey = GlobalKey();

  /// 拖动进度条前的播放状态 —— 松手后据此决定要不要恢复播放
  bool _wasPlayingBeforeSeek = false;
  double _dragProgress = 0;

  @override
  void initState() {
    super.initState();
    player.addListener(_onPlayer);
    _syncGlow();
  }

  @override
  void dispose() {
    player.removeListener(_onPlayer);
    _glow.dispose();
    super.dispose();
  }

  /// 只在「结构性」状态变化时重建播放栏。
  ///
  /// 位置每秒变化几十次，而它只影响进度条、时间与歌词高亮这三处 ——
  /// 那三处各自用 `ValueListenableBuilder` 盯着 `positionNotifier`。
  /// 这里若无条件 setState，整条播放栏（含封面、控制键、歌词）都会跟着位置
  /// 一起重建，白烧掉大量帧预算。
  int _lastStateKey = 0;

  void _onPlayer() {
    if (!mounted) return;
    _syncGlow();
    final key = Object.hash(
      player.currentSong?.mid,
      player.isPlaying,
      player.isLoading,
      player.errorMessage,
      player.playMode,
      player.activeLyricIndex,
      player.lyricLines.length,
      player.lyricPaused,
      player.duration,
      player.volume,
    );
    if (key == _lastStateKey) return;
    _lastStateKey = key;
    setState(() {});
  }

  void _syncGlow() {
    if (player.isPlaying && !_glow.isAnimating) {
      _glow.repeat(reverse: true);
    } else if (!player.isPlaying && _glow.isAnimating) {
      _glow.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final song = player.currentSong;
    if (song == null) return const SizedBox.shrink();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          height: kPlayerBarHeight,
          decoration: BoxDecoration(
            color: c.playerBg,
            border: Border(top: BorderSide(color: c.borderSubtle)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              SizedBox(
                width: 240,
                child: Row(
                  children: [
                    _buildCover(context, song),
                    const SizedBox(width: 12),
                    Expanded(child: _buildMeta(context, song)),
                  ],
                ),
              ),
              Expanded(child: _buildCenter(context)),
              SizedBox(width: 200, child: _buildExtra(context)),
            ],
          ),
        ),
        if (player.errorMessage != null)
          Positioned(
            top: -40,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFC42B1C),
                  borderRadius: BorderRadius.circular(c.radius),
                  boxShadow: c.shadowLg,
                ),
                child: Text(
                  player.errorMessage!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ------------------------------------------------------------ 左侧：封面 + 歌词

  Widget _buildCover(BuildContext context, Song song) {
    final c = context.c;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() {}),
      onExit: (_) => setState(() {}),
      child: GestureDetector(
        onTap: () => _openLyric(),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Stack(
            children: [
              // 发光**单独一层**，并且只在它内部重建。
              //
              // 两点讲究：
              //  * 模糊核（blurRadius/spreadRadius）固定，只让透明度呼吸 ——
              //    动 blurRadius 等于每帧重算一次高斯模糊，是光栅化里最贵的操作；
              //  * 外面套 RepaintBoundary，把 2.4 秒的循环动画关在这一层里，
              //    不让它把封面图也带着每帧重绘。
              RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _glow,
                  builder: (_, _) => Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: player.isPlaying
                          ? [
                              BoxShadow(
                                color: c.accent.withValues(
                                    alpha: (0.35 + 0.25 * _glow.value) * 0.6),
                                blurRadius: 16,
                                spreadRadius: 3,
                              )
                            ]
                          : const [],
                    ),
                  ),
                ),
              ),
              // 封面也单独隔离开：它上面没有动画，不该被别的东西带着重绘
              RepaintBoundary(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 800),
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: song.pic.isEmpty
                        ? Center(
                            child: AppIcon(AppIcons.music,
                                size: 24, color: c.textTertiary),
                          )
                        : Image.network(
                            ApiClient.getProxyImageUrl(song.pic),
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Center(
                              child: AppIcon(AppIcons.music,
                                  size: 24, color: c.textTertiary),
                            ),
                          ),
                  ),
                ),
              ),
              if (player.isLoading)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMeta(BuildContext context, Song song) {
    final c = context.c;
    final lines = player.lyricLines;
    final idx = player.activeLyricIndex;
    final showLyric = lines.isNotEmpty && !player.lyricPaused;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            // 必须 opaque + 撑满整行宽：否则命中区等于**已绘制内容**的宽度
            // （歌词 Text 只有自身那么宽），点歌词右侧空白就无效
            // —— 表现为动态歌词只有贴近左侧才点得中。
            behavior: HitTestBehavior.opaque,
            onTap: () => _openLyric(),
            child: SizedBox(
              width: double.infinity,
              height: kLyricLineHeight,
              child: ClipRect(
                child: Stack(
                  // 只有 Positioned 子节点 → Stack 尺寸取 constraints.biggest（=24），
                  // 不会被超长的歌词 Column 撑开
                  children: [
                    // 歌词滚动区
                    Positioned.fill(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 300),
                        opacity: showLyric ? 1 : 0,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(
                            begin: 0,
                            end: -(idx.clamp(0, math.max(0, lines.length - 1))) *
                                kLyricLineHeight,
                          ),
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeOutCubic,
                          builder: (ctx, offset, child) => Transform.translate(
                            offset: Offset(0, offset),
                            child: child,
                          ),
                          // 必须用 OverflowBox 解除高度约束：Positioned.fill 给的是
                          // **紧约束**，而歌词总高（几十行 × 24px）远超 24px，
                          // 直接放 Column 会触发 RenderFlex overflow（实测溢出 1584px）。
                          child: OverflowBox(
                            alignment: Alignment.topLeft,
                            minHeight: 0,
                            maxHeight: double.infinity,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (var i = 0; i < lines.length; i++)
                                  SizedBox(
                                    height: kLyricLineHeight,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: (i == idx && lines[i].hasWords)
                                          // 当前行且有逐字时间 → 卡拉OK式逐字高亮。
                                          // 用滑动版：这一行只有 24px 高、一百多像素宽，
                                          // 长句用省略号裁掉等于把逐字歌词废掉。
                                          // key 按行时间给：换句时新建 State，位移从 0 起
                                          // （满足「切下一句直接切、不往回滑」）。
                                          // 只有「正在唱的这行」需要跟着播放位置走，
                                          // 用 ValueListenableBuilder 把重建压到这一行
                                          ? ValueListenableBuilder<Duration>(
                                              valueListenable:
                                                  player.positionNotifier,
                                              builder: (_, pos, _) =>
                                                  SlidingKaraokeText(
                                                key: ValueKey(
                                                    'karaoke-${lines[i].time}'),
                                                line: lines[i],
                                                position:
                                                    pos.inMilliseconds / 1000.0,
                                                activeColor: c.accent,
                                                inactiveColor: c.textTertiary,
                                              ),
                                            )
                                          : Text(
                                              lines[i].text,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: i == idx ? 13 : 12,
                                                fontWeight: i == idx
                                                    ? FontWeight.w600
                                                    : FontWeight.w400,
                                                color: i == idx
                                                    ? c.accent
                                                    : c.textTertiary,
                                              ),
                                            ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 歌名浮层（歌词暂停态显示）
                    Positioned.fill(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 300),
                        opacity: showLyric ? 0 : 1,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            song.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: c.text,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        // 歌曲名也可点击打开歌词（等价原版 `e.name.addEventListener('click',openLyricModal)`）
        // 命中区要**撑满整行宽**：只包住 Text 的话，可点击范围就只有文字那点宽度，
        // 点到文字旁边的空白就无效。
        SizedBox(
          width: double.infinity,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openLyric,
              child: Text(
                song.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: c.textTertiary),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openLyric() {
    final song = player.currentSong;
    // 必须用 requestLyricDialog：它先弹窗再取歌词。
    // 早期误用 loadLyricForModal（只加载不弹窗），导致「点歌词没有任何反应」。
    if (song != null) widget.state.requestLyricDialog(song.mid);
  }

  /// 播放模式：展开二级菜单让用户直接选，而不是一个一个轮着切。
  ///
  /// 菜单**向上**长，锚点取播放栏的顶边而不是按钮本身 —— 贴着按钮算的话，
  /// 菜单底边会压住进度条那一行。
  void _showModeMenu() {
    final bar = context.findRenderObject() as RenderBox?;
    final button = _modeKey.currentContext?.findRenderObject() as RenderBox?;
    if (bar == null || button == null) return;
    showAppContextMenu(
      context: context,
      position: Offset(
        button.localToGlobal(Offset.zero).dx,
        bar.localToGlobal(Offset.zero).dy,
      ),
      above: true,
      items: [
        for (final mode in PlayMode.values)
          AppMenuItem(
            label: mode.label,
            icon: _modeIcon(mode),
            checked: mode == player.playMode,
            onTap: () => player.setMode(mode),
          ),
      ],
    );
  }

  // ------------------------------------------------------------ 中间：控制 + 进度

  Widget _buildCenter(BuildContext context) {
    final c = context.c;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 控件行：固定宽度 + 显式等间距。
        // 音量控件是固定 116 宽（36 图标槽 + 80 滑块区），比别的槽宽 80，
        // 所以左侧加一个等宽（80）的**隐形配重**，这样：
        //   * 播放键仍在整行正中（80 与右侧多出的 80 相互抵消）；
        //   * 五个图标的中心距完全一致（各 36 槽 + 28 间距）。
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 80), // 配重，抵消音量多出的宽度
            _ctrlSlot(
              AppIconButton(
                key: _modeKey,
                icon: _modeIcon(player.playMode),
                size: 28,
                iconSize: 16,
                baseColor: c.textTertiary,
                hoverColor: c.accent,
                hoverBg: Colors.transparent,
                onTap: _showModeMenu,
                tooltip: player.playMode.label,
              ),
            ),
            const SizedBox(width: 28),
            _ctrlSlot(
              AppIconButton(
                icon: AppIcons.prev,
                size: 28,
                iconSize: 16,
                filled: true,
                onTap: () => widget.state.handleEndedAction('prev'),
                tooltip: '上一首',
              ),
            ),
            const SizedBox(width: 28),
            _ctrlSlot(
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: player.togglePlay,
                  child: HoverBuilder(
                    builder: (ctx, hovered) => Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: hovered ? c.accentHover : c.accent,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: AppIcon(
                          player.isPlaying ? AppIcons.pause : AppIcons.play,
                          size: 20,
                          color: c.accentText,
                          filled: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 28),
            _ctrlSlot(
              AppIconButton(
                icon: AppIcons.next,
                size: 28,
                iconSize: 16,
                filled: true,
                onTap: () => widget.state.handleEndedAction('next'),
                tooltip: '下一首',
              ),
            ),
            const SizedBox(width: 28),
            // ---- 音量（最右，悬浮向右展开滑块）----
            _VolumeControl(
              volume: player.volume,
              onChanged: player.setVolume,
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 进度与时间**只**依赖播放位置：用 ValueListenableBuilder 把重建
        // 关在这一小块里。位置每秒变化几十次，若让整个播放栏跟着重建，
        // 封面、控制键、歌词都要白重画一遍。
        ValueListenableBuilder<Duration>(
          valueListenable: player.positionNotifier,
          builder: (context, _, _) {
            final progress = _draggingProgress ? _dragProgress : player.progress;
            final displayPos = _draggingProgress
                ? Duration(
                    milliseconds:
                        (progress * player.duration.inMilliseconds).round(),
                  )
                : player.position;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
          SizedBox(
            width: 400,
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Text(
                    formatTime(displayPos.inMilliseconds / 1000.0),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: c.textTertiary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppProgressBar(
                    value: progress,
                    height: 4,
                    hoverHeight: 6,
                    draggable: true,
                    // 拖动过程中**只更新本地预览**，不真的 seek ——
                    // 边拖边 seek 会让音频不停跳转，听感很鬼畜。
                    onSeek: (v) => setState(() {
                      _draggingProgress = true;
                      _dragProgress = v;
                    }),
                    // 按下/开始拖动：先暂停，并记住拖动前的播放状态
                    onSeekStart: () {
                      _wasPlayingBeforeSeek = player.isPlaying;
                      player.pause();
                    },
                    // 松手/抬起：真正 seek，然后还原拖动前的播放状态
                    onSeekEnd: () {
                      final v = _dragProgress;
                      setState(() => _draggingProgress = false);
                      player.seekPercent(v).then((_) {
                        if (_wasPlayingBeforeSeek) player.resume();
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 36,
                  child: Text(
                    formatTime(player.duration.inMilliseconds / 1000.0),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: c.textTertiary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 控件行的统一占位格。
  ///
  /// 五个控件的实际宽度不同（28 / 28 / 36 / 28 / 16），而 spaceEvenly
  /// 平分的是「间隙」—— 宽度不同则中心距不同，看起来间距就不一致。
  /// 统一套 36×36 并居中后，间距才真正相等。
  Widget _ctrlSlot(Widget child) => SizedBox(
        width: 36,
        height: 36,
        child: Center(child: child),
      );

  // ------------------------------------------------------------ 右侧：歌词 + 关闭

  Widget _buildExtra(BuildContext context) {
    final c = context.c;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        AppIconButton(
          icon: AppIcons.queue,
          size: 28,
          iconSize: 16,
          baseColor: c.textTertiary,
          hoverColor: c.accent,
          hoverBg: Colors.transparent,
          onTap: () => widget.onOpenQueue?.call(),
          tooltip: '播放列表',
        ),
        AppIconButton(
          icon: AppIcons.lyricDoc,
          size: 28,
          iconSize: 16,
          baseColor: c.textTertiary,
          hoverColor: c.accent,
          hoverBg: Colors.transparent,
          onTap: _openLyric,
          tooltip: '歌词',
        ),
        AppIconButton(
          icon: AppIcons.close,
          size: 28,
          iconSize: 16,
          // AppIcons.close 是 12 见方坐标系，必须显式声明，
          // 否则会被当成 24 画布 → 只画在左上角四分之一、又小又偏
          viewBox: 12,
          baseColor: c.textTertiary,
          onTap: () => player.close(),
          tooltip: '关闭播放器',
        ),
      ],
    );
  }
}

/// 音量控件 —— 默认只显示图标，**鼠标悬浮时向右展开**滑块。
///
/// 关键设计（踩过坑）：
///   * 控件整体是**固定宽度**（图标槽 36 + 滑块区 80 = 116），
///     所以展开时不会挤动左右任何元素，控件行里各元素的间距也保持均匀；
///   * 图标与滑块**都在这个固定宽度之内**。
///     早先把滑块做成画在父级边界之外的浮层（Positioned + Clip.none），
///     结果 Flutter 的命中测试只在父级尺寸内进行 —— 滑块**既 hover 不到、
///     也点不动**，鼠标一过去就被判定离开而收起。
///   * 滑块本身用 OverflowBox 固定 80px，避免被 0 宽容器挤变形。
class _VolumeControl extends StatefulWidget {
  const _VolumeControl({required this.volume, required this.onChanged});

  final double volume;
  final ValueChanged<double> onChanged;

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  bool _hovered = false;
  bool _dragging = false;
  Timer? _collapseTimer;

  static const _expandDuration = Duration(milliseconds: 180);
  static const _sliderWidth = 80.0;
  static const _iconSlot = 36.0; // 与其它控件槽一致，保证中心距均匀

  /// 收起延迟：留一点缓冲，避免鼠标在边界上轻微抖动就收起。
  static const _collapseDelay = Duration(milliseconds: 200);

  bool get _expanded => _hovered || _dragging;

  void _enter() {
    _collapseTimer?.cancel();
    if (!_hovered) setState(() => _hovered = true);
  }

  void _exit() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(_collapseDelay, () {
      if (mounted) setState(() => _hovered = false);
    });
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _enter(),
      onExit: (_) => _exit(),
      child: Listener(
        // 滚轮调音量
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            final delta = event.scrollDelta.dy < 0 ? 0.05 : -0.05;
            widget.onChanged((widget.volume + delta).clamp(0.0, 1.0));
          }
        },
        child: SizedBox(
          width: _iconSlot + _sliderWidth,
          height: _iconSlot,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Row(
                children: [
                  // 图标槽：与其它控件同宽，保证中心距一致
                  SizedBox(
                    width: _iconSlot,
                    child: Center(
                      child: AppIcon(
                        AppIcons.volume,
                        size: 16,
                        color: _expanded ? c.accent : c.textTertiary,
                      ),
                    ),
                  ),
                  // 滑块区：**始终占位 80**，宽度在内部 0↔80 动画
                  Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedContainer(
                      duration: _expandDuration,
                      curve: Curves.easeOut,
                      width: _expanded ? _sliderWidth : 0,
                      height: 20,
                      child: ClipRect(
                        child: AnimatedOpacity(
                          opacity: _expanded ? 1 : 0,
                          duration: _expandDuration,
                          curve: Curves.easeOut,
                          child: OverflowBox(
                            alignment: Alignment.centerLeft,
                            minWidth: _sliderWidth,
                            maxWidth: _sliderWidth,
                            child: _VolumeSlider(
                              value: widget.volume,
                              width: _sliderWidth,
                              onChanged: (v) {
                                setState(() => _dragging = true);
                                widget.onChanged(v);
                              },
                              onEnd: () => setState(() => _dragging = false),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              // 百分比提示（纯展示，画在控件上方）
              if (_expanded)
                Positioned(
                  bottom: 30,
                  left: _iconSlot - 10,
                  width: _sliderWidth + 20,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: c.card,
                        border: Border.all(color: c.border),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _pctLabel(widget.volume),
                        style: TextStyle(fontSize: 12, color: c.text),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _pctLabel(double v) => '${(v * 100).round()}%';
}

class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({
    required this.value,
    required this.onChanged,
    required this.onEnd,
    this.width = 80,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      width: width,
      height: 16,
      child: LayoutBuilder(
        builder: (ctx, cons) {
          void update(Offset local) {
            onChanged((local.dx / cons.maxWidth).clamp(0.0, 1.0));
          }

          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => update(d.localPosition),
              onHorizontalDragStart: (d) => update(d.localPosition),
              onHorizontalDragUpdate: (d) => update(d.localPosition),
              onHorizontalDragEnd: (_) => onEnd(),
              onTapUp: (_) => onEnd(),
              child: Center(
                // 同 AppProgressBar：轨道必须显式撑满宽度，
                // 否则 Center 的松约束会让它缩成填充条宽度并居中。
                child: Container(
                  width: double.infinity,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.progressBg,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: value.clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: c.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
