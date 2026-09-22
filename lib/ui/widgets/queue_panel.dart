import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../models/song.dart';
import '../../services/api_client.dart';
import '../../services/player_controller.dart';
import '../../state/app_state.dart';
import '../icons.dart';
import 'common.dart';
import 'context_menu.dart';
import 'smooth_scroll.dart';
import 'song_actions.dart';

/// 播放列表面板 —— 从右侧滑出，展示 [AppState.playQueue]。
///
/// 队列是**唯一**的播放依据：顺序类模式下它就是歌单的顺序，随机模式下是洗好的
/// 顺序（以前那份藏着的随机池现在摊开在这里）。所以这个面板看到什么，
/// 播放栏就按什么走。
class QueuePanel extends StatefulWidget {
  const QueuePanel({
    super.key,
    required this.state,
    required this.open,
    required this.onClose,
    required this.onOpenLyric,
    required this.scrollController,
  });

  final AppState state;
  final bool open;
  final VoidCallback onClose;
  final ValueChanged<String> onOpenLyric;

  /// 由 shell 持有 —— 面板开着时 Home / End / PgUp / PgDn 要作用在队列上，
  /// 那几个键的处理挂在 shell 的根 Focus 上，得够得着这条控制器。
  final SmoothScrollController scrollController;

  static const Duration slide = Duration(milliseconds: 220);

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  /// 挂在 `prototypeItem` 上，用来量真实行高（见 [scrollListToRow]）
  final GlobalKey _prototypeKey = GlobalKey();

  double get _rowHeight => _prototypeKey.currentContext?.size?.height ?? 0;

  /// 滚到队列里正在播放的那一首。
  ///
  /// 行高要从真实的那一行量 —— 布局还没跑过时量不到，那就等这一帧结束再试。
  void _scrollToNowPlaying() {
    final index = widget.state.queueIndex;
    if (index < 0) return;
    final h = _rowHeight;
    if (h <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) scrollListToRow(widget.scrollController, index, _rowHeight);
      });
      return;
    }
    scrollListToRow(widget.scrollController, index, h);
  }

  void _showMenu(Song song, Offset at) {
    showAppContextMenu(
      context: context,
      position: at,
      items: buildSongMenuItems(
        context: context,
        state: widget.state,
        song: song,
        onOpenLyric: widget.onOpenLyric,
        // 队列里不做就地改名（那套输入框长在歌单行上），所以不给这一项
        inQueue: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return IgnorePointer(
      // 收起来的时候整块不接事件，否则透明的遮罩会挡住下面的页面
      ignoring: !widget.open,
      child: Stack(
        children: [
          // 遮罩：点一下就收起来
          AnimatedOpacity(
            opacity: widget.open ? 1 : 0,
            duration: QueuePanel.slide,
            child: GestureDetector(
              onTap: widget.onClose,
              child: Container(color: c.modalOverlay),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: AnimatedSlide(
              offset: widget.open ? Offset.zero : const Offset(1, 0),
              duration: QueuePanel.slide,
              curve: Curves.easeOutCubic,
              child: _panel(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final c = context.c;
    final queue = widget.state.playQueue;
    final hasCurrent = widget.state.queueIndex >= 0;
    return Container(
      width: 360,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(left: BorderSide(color: c.border)),
        boxShadow: c.shadowLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 10, 12),
            child: Row(
              children: [
                AppIcon(AppIcons.queue, size: 16, color: c.accent),
                const SizedBox(width: 8),
                Text(
                  '播放列表',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: c.text,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    queue.isEmpty
                        ? '空'
                        : '${queue.length} 首 · ${player.playMode.label}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.textTertiary),
                  ),
                ),
                // 定位到正在播放 —— 与歌单页那个是同一套做法
                if (hasCurrent)
                  AppIconButton(
                    icon: AppIcons.target,
                    size: 28,
                    iconSize: 15,
                    baseColor: c.textTertiary,
                    hoverColor: c.accent,
                    hoverBg: Colors.transparent,
                    tooltip: '定位到正在播放',
                    onTap: _scrollToNowPlaying,
                  ),
                AppIconButton(
                  icon: AppIcons.close,
                  size: 28,
                  iconSize: 14,
                  // close 是 12 见方坐标系，不声明就会被当成 24 画布
                  viewBox: 12,
                  baseColor: c.textTertiary,
                  onTap: widget.onClose,
                  tooltip: '关闭',
                ),
              ],
            ),
          ),
          Container(height: 1, color: c.borderSubtle),
          Expanded(
            child: queue.isEmpty
                ? const EmptyState(
                    icon: AppIcons.queue,
                    title: '播放列表是空的',
                    hint: '播放一首歌，或右键「插入到下一首」',
                  )
                : SmoothWheelScroll(
                    controller: widget.scrollController,
                    child: ListView.builder(
                      controller: widget.scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: queue.length,
                      // 行高必须给：不给的话恢复滚动位置那一次 jumpTo 要从第 0 行
                      // 逐行往下量（见 test/playlist_scroll_test.dart）。
                      // 顺带它也是「定位到正在播放」算目标位置的依据。
                      prototypeItem: _QueueRow(
                        key: _prototypeKey,
                        song: const Song(mid: '', name: '歌名', artist: '歌手'),
                        index: 0,
                        playing: false,
                        onTap: () {},
                      ),
                      itemBuilder: (ctx, i) {
                        final song = queue[i];
                        return _QueueRow(
                          key: ValueKey('queue-${song.mid}'),
                          song: song,
                          index: i,
                          playing: i == widget.state.queueIndex,
                          onTap: () => widget.state.playResolved(song),
                          onSecondary: (at) => _showMenu(song, at),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 队列里的一行：正在播的三角 / 序号、封面、歌名 + 歌手。
class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.song,
    required this.index,
    required this.playing,
    required this.onTap,
    this.onSecondary,
  });

  final Song song;
  final int index;
  final bool playing;
  final VoidCallback onTap;

  /// 右键：参数是全局坐标（用来定位菜单）
  final ValueChanged<Offset>? onSecondary;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final row = HoverBuilder(
      builder: (_, hovered) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          color: hovered ? c.hover : Colors.transparent,
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: playing
                    ? AppIcon(AppIcons.play,
                        size: 11, color: c.accent, filled: true)
                    : Text(
                        '${index + 1}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: c.textTertiary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              // 与歌单行**同 URL 同尺寸**：两边算出来的 cacheWidth 一样，
              // ImageCache 的键就一样 —— 来回切不会重复解码，也不会多打一次网络。
              SongCover(url: ApiClient.getProxyImageUrl(song.pic), size: 40),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SourceIcon(source: song.source, size: 14),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            song.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight:
                                  playing ? FontWeight.w600 : FontWeight.w400,
                              color: playing ? c.accent : c.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: c.textTertiary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (onSecondary == null) return row;
    return ClickRegion(onSecondaryClick: onSecondary, child: row);
  }
}
