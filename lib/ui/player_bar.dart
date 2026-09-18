import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/lyric.dart';
import '../models/song.dart';
import '../services/api_client.dart';
import '../services/player_controller.dart';
import '../state/app_state.dart';
import 'icons.dart';
import 'widgets/common.dart';

const double kPlayerBarHeight = 72;
const double kLyricLineHeight = 24;



/// 底部播放器栏 —— 对应 `.player-bar`
class PlayerBar extends StatefulWidget {
  const PlayerBar({super.key, required this.state});

  final AppState state;

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> with SingleTickerProviderStateMixin {
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  bool _draggingProgress = false;
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

  void _onPlayer() {
    if (mounted) {
      _syncGlow();
      setState(() {});
    }
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
    final glow = 0.35 + 0.25 * _glow.value;

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
              AnimatedContainer(
                duration: const Duration(milliseconds: 800),
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: player.isPlaying
                      ? [
                          BoxShadow(
                            color: c.accent.withValues(alpha: glow * 0.6),
                            blurRadius: 6 + 10 * _glow.value,
                            spreadRadius: 1 + 3 * _glow.value,
                          )
                        ]
                      : [
                          BoxShadow(
                            color: c.accent.withValues(alpha: 0),
                            blurRadius: 6,
                            spreadRadius: 1,
                          )
                        ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: song.pic.isEmpty
                      ? Center(
                          child: AppIcon(AppIcons.music, size: 24, color: c.textTertiary),
                        )
                      : Image.network(
                          ApiClient.getProxyImageUrl(song.pic),
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Center(
                            child: AppIcon(AppIcons.music, size: 24, color: c.textTertiary),
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
            onTap: () => _openLyric(),
            child: SizedBox(
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
                          // ⚠️ 必须用 OverflowBox 解除高度约束：Positioned.fill 给的是
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
                                      child: Text(
                                        lines[i].text,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: i == idx ? 13 : 12,
                                          fontWeight: i == idx
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                          color: i == idx ? c.accent : c.textTertiary,
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
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _openLyric,
            child: Text(
              song.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: c.textTertiary),
            ),
          ),
        ),
      ],
    );
  }

  void _openLyric() {
    final song = player.currentSong;
    // ⚠️ 必须用 requestLyricDialog：它先弹窗再取歌词。
    // 早期误用 loadLyricForModal（只加载不弹窗），导致「点歌词没有任何反应」。
    if (song != null) widget.state.requestLyricDialog(song.mid);
  }

  // ------------------------------------------------------------ 中间：控制 + 进度

  Widget _buildCenter(BuildContext context) {
    final c = context.c;
    final progress = _draggingProgress ? _dragProgress : player.progress;
    final displayPos = _draggingProgress
        ? Duration(
            milliseconds: (progress * player.duration.inMilliseconds).round(),
          )
        : player.position;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // ⚠️ 必须限宽：用 spaceEvenly 直接铺满整个中间区会让图标间距被拉得很宽
        // （实测约 120px，参考图只有 40~60px）。固定 340 宽后间距与参考图一致。
        SizedBox(
          width: 340,
          child: Row(
            // 对齐参考图：模式 | 上一首 | 播放 | 下一首 | 音量（播放键正好居中）
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
            // ---- 播放模式（最左）----
            AppIconButton(
              icon: switch (player.playMode) {
                PlayMode.repeatAll => AppIcons.repeatAll,
                PlayMode.repeatOne => AppIcons.repeatOne,
                PlayMode.shuffle => AppIcons.shuffle,
              },
              size: 28,
              iconSize: 16,
              baseColor: c.textTertiary,
              hoverColor: c.accent,
              hoverBg: Colors.transparent,
              onTap: player.cycleMode,
              tooltip: player.playMode.label,
            ),
            AppIconButton(
              icon: AppIcons.prev,
              size: 28,
              iconSize: 16,
              filled: true,
              onTap: () => widget.state.handleEndedAction('prev'),
              tooltip: '上一首',
            ),
            const SizedBox(width: 12),
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
            const SizedBox(width: 12),
            AppIconButton(
              icon: AppIcons.next,
              size: 28,
              iconSize: 16,
              filled: true,
              onTap: () => widget.state.handleEndedAction('next'),
              tooltip: '下一首',
            ),
            // ---- 音量（最右，悬浮向右展开滑块）----
            _VolumeControl(
              volume: player.volume,
              onChanged: player.setVolume,
            ),
            ],
          ),
        ),
        const SizedBox(height: 4),
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
                  onSeek: (v) {
                    setState(() {
                      _draggingProgress = true;
                      _dragProgress = v;
                    });
                    player.seekPercent(v).then((_) {
                      if (mounted) setState(() => _draggingProgress = false);
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
  }

  // ------------------------------------------------------------ 右侧：歌词 + 关闭

  Widget _buildExtra(BuildContext context) {
    final c = context.c;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
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
          baseColor: c.textTertiary,
          onTap: () => player.close(),
          tooltip: '关闭播放器',
        ),
      ],
    );
  }
}

/// 音量条 —— 对应 `.player-volume-wrapper input[type=range]`（80×4）
/// 音量控件 —— 默认只显示图标，**鼠标悬浮时向右展开**滑块（带展开/收起动画）。
///
/// 参考图里音量位只有图标；展开用「宽度 0→80 + 透明度」两个动画叠加，
/// 里面的滑块用 OverflowBox 固定 80px，避免被 0 宽容器挤变形。
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

  static const _expandDuration = Duration(milliseconds: 180);
  static const _sliderWidth = 80.0;

  bool get _expanded => _hovered || _dragging;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        // 滚轮调音量
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            final delta = event.scrollDelta.dy < 0 ? 0.05 : -0.05;
            widget.onChanged((widget.volume + delta).clamp(0.0, 1.0));
          }
        },
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.centerLeft,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 展开/收起动画：宽度 0 ↔ 80，**在图标左侧**展开
                // （对齐参考图：音量图标锚在控件组最右，滑块往组内长，
                //  而不是往右伸到右侧空白区）。
                // ⚠️ 必须同时给**有限高度**：里面是 OverflowBox（按父级约束定尺寸），
                // 若高度无界会抛 "RenderConstrainedOverflowBox was given an
                // infinite size during layout"（实测踩过）。
                AnimatedContainer(
                  duration: _expandDuration,
                  curve: Curves.easeOut,
                  width: _expanded ? _sliderWidth : 0,
                  height: 20,
                  child: ClipRect(
                    child: AnimatedOpacity(
                      opacity: _expanded ? 1 : 0,
                      duration: _expandDuration,
                      curve: Curves.easeOut,
                      // OverflowBox：让滑块始终保持 80px，被外层宽度裁剪出「展开」效果。
                      // 右对齐 → 宽度变小时从左侧收起。
                      child: OverflowBox(
                        alignment: Alignment.centerRight,
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
                AppIcon(
                  AppIcons.volume,
                  size: 16,
                  color: _expanded ? c.accent : c.textTertiary,
                ),
              ],
            ),
            // 百分比提示
            if (_expanded)
              Positioned(
                bottom: 22,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.card,
                      border: Border.all(color: c.border),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${(widget.volume * 100).round()}%',
                      style: TextStyle(fontSize: 12, color: c.text),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
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
                // ⚠️ 同 AppProgressBar：轨道必须显式撑满宽度，
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
