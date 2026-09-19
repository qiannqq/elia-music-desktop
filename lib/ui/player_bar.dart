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
            // ⚠️ 必须 opaque + 撑满整行宽：否则命中区等于**已绘制内容**的宽度
            // （歌词 Text 只有自身那么宽），点歌词右侧空白就无效
            // —— 用户反馈「动态歌词只有贴近左侧才能点」正是这个。
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
                                      child: (i == idx && lines[i].hasWords)
                                          // 当前行且有逐字时间 → 卡拉OK式逐字高亮
                                          ? KaraokeText(
                                              line: lines[i],
                                              position:
                                                  player.position.inMilliseconds / 1000.0,
                                              activeColor: c.accent,
                                              inactiveColor: c.textTertiary,
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
        // ⚠️ 命中区要**撑满整行宽**：只包住 Text 的话，可点击范围就只有文字那点宽度，
        // 点到文字旁边的空白就无效（用户反馈「点歌名不弹歌词」正是这个）。
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
                  // 边拖边 seek 会让音频不停跳转，听感很鬼畜（用户反馈）。
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
/// ⚠️ 关键设计（踩过坑）：
///   * 控件整体是**固定宽度**（图标槽 36 + 滑块区 80 = 116），
///     所以展开时不会挤动左右任何元素，控件行里各元素的间距也保持均匀；
///   * 图标与滑块**都在这个固定宽度之内**。
///     早先把滑块做成画在父级边界之外的浮层（Positioned + Clip.none），
///     结果 Flutter 的命中测试只在父级尺寸内进行 —— 滑块**既 hover 不到、
///     也点不动**，鼠标一过去就被判定离开而收起（用户反馈的现象）。
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
