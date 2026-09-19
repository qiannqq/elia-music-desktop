import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../models/song.dart';
import '../../services/api_client.dart';
import '../../services/player_controller.dart';
import '../../state/app_state.dart';
import '../icons.dart';
import '../widgets/common.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/dialogs.dart';
import '../widgets/song_actions.dart';

/// 歌单页 —— 对应 `#page-playlist`
class PlaylistPage extends StatefulWidget {
  const PlaylistPage({
    super.key,
    required this.state,
    required this.scrollController,
    required this.onOpenLyric,
  });

  final AppState state;
  final ScrollController scrollController;
  final ValueChanged<String> onOpenLyric;

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  /// 当前鼠标悬停的歌曲 mid —— **单一数据源**。
  ///
  /// 原先每个条目各自维护 _hovered，靠 onExit 清除。鼠标快速划过时
  /// 上一个条目的 onExit 可能不生效，导致「两行同时高亮」。
  /// 改为由页面统一记录：进入 B 时 A 自然就不再是高亮态，不依赖 exit 事件。
  String? _hoveredMid;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final state = widget.state;
    final songs = state.songs;

    return Column(
      children: [
        // ---- 页头 ----
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 20),
          child: Row(
            children: [
              Text(
                '歌单',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c.text),
              ),
              const Spacer(),
              if (songs.isNotEmpty) ...[
                AppButton(
                  label: '全选',
                  small: true,
                  onPressed: state.selectAll,
                ),
                const SizedBox(width: 8),
                AppButton(
                  label: '清空',
                  small: true,
                  onPressed: () async {
                    final ok = await showConfirmDialog(context, '确定清空所有歌曲吗？');
                    if (ok) state.clearList();
                  },
                ),
                const SizedBox(width: 8),
                AppButton(
                  label: '导出',
                  small: true,
                  variant: AppButtonVariant.accent,
                  onPressed: state.exportPlaylist,
                ),
                const SizedBox(width: 8),
                AppButton(
                  label: '批量下载',
                  small: true,
                  variant: AppButtonVariant.primary,
                  icon: AppIcons.download,
                  iconSize: 14,
                  onPressed: () => state.batchDownload(state.songsForBatchDownload),
                ),
              ],
            ],
          ),
        ),

        // ---- 内容 ----
        Expanded(
          child: songs.isEmpty
              ? const SingleChildScrollView(
                  child: EmptyState(
                    icon: AppIcons.playlist,
                    title: '暂无歌曲',
                    hint: '搜索或粘贴歌单链接来添加歌曲',
                  ),
                )
              : SmoothWheelScroll(
                  controller: widget.scrollController,
                  child: Scrollbar(
                  controller: widget.scrollController,
                  child: ListView.builder(
                    controller: widget.scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    itemCount: songs.length,
                    itemBuilder: (ctx, i) {
                      // ⚠️ 在这里就把 mid 取出来捕获进闭包。
                      // 若闭包里写 songs[i].mid，`i` 是回调触发时才求值的 ——
                      // 列表一变（增删/拖拽/换序）就会取到别的歌，
                      // 导致「上一行的高亮清不掉、两行同时高亮」。
                      final mid = songs[i].mid;
                      return _PlaylistItem(
                        // ⚠️ 稳定 key（按 mid）：
                        // 「添加到歌单顶部」会让歌曲换位置，若按索引复用 State，
                        // 展开中的「+」二级菜单状态会跳到别的卡片上、
                        // 收起动画被打断 —— 表现为「二级菜单突兀消失」。
                        key: ValueKey(mid),
                        song: songs[i],
                        state: state,
                        onOpenLyric: widget.onOpenLyric,
                        hovered: _hoveredMid == mid,
                        onHover: (v) => setState(() {
                          if (v) {
                            _hoveredMid = mid;
                          } else if (_hoveredMid == mid) {
                            _hoveredMid = null;
                          }
                        }),
                      );
                    },
                  ),
                ),
                ),
        ),

        // ---- 批量操作栏 ----
        if (state.selectedMids.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 16, 32, 16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.border),
                borderRadius: BorderRadius.circular(c.radius),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '已选择 ${state.selectedMids.length} 首',
                      style: TextStyle(fontSize: 13, color: c.textSecondary),
                    ),
                  ),
                  AppButton(label: '反选', small: true, onPressed: state.invertSelect),
                  const SizedBox(width: 8),
                  AppButton(label: '删除', small: true, onPressed: state.deleteSelected),
                  const SizedBox(width: 8),
                  AppButton(
                    label: '批量下载',
                    small: true,
                    variant: AppButtonVariant.primary,
                    icon: AppIcons.download,
                    iconSize: 14,
                    onPressed: () => state.batchDownload(state.songsForBatchDownload),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 歌单条目 —— 对应 `.playlist-item`
class _PlaylistItem extends StatefulWidget {
  const _PlaylistItem({
    super.key,
    required this.song,
    required this.state,
    required this.onOpenLyric,
    required this.hovered,
    required this.onHover,
  });

  final Song song;
  final AppState state;
  final ValueChanged<String> onOpenLyric;

  /// 是否高亮 —— 由列表页统一裁决（见 _PlaylistPageState._hoveredMid）
  final bool hovered;
  final ValueChanged<bool> onHover;

  @override
  State<_PlaylistItem> createState() => _PlaylistItemState();
}

class _PlaylistItemState extends State<_PlaylistItem> {

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final song = widget.song;
    final state = widget.state;
    final checked = state.selectedMids.contains(song.mid);
    final isPlaying = player.currentSong?.mid == song.mid;

    return MouseRegion(
      onEnter: (_) => widget.onHover(true),
      onExit: (_) => widget.onHover(false),
      // ⚠️ 这里**不能用 AnimatedContainer**：
      // 鼠标从 A 划到 B 时，A 的颜色要 120ms 才淡出、B 同时淡入 ——
      // 这 120ms 里两行都是高亮态，看起来就是「两首歌同时选中」。
      // 搜索页的卡片用的是普通 Container（瞬间切换），所以那边没有这个问题。
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isPlaying ? c.accentLight : (widget.hovered ? c.hover : Colors.transparent),
          border: isPlaying ? Border.all(color: c.accent, width: 1.5) : null,
          borderRadius: BorderRadius.circular(c.radius),
          boxShadow: isPlaying
              ? [
                  BoxShadow(
                    color: c.accent.withValues(alpha: 0.3),
                    blurRadius: 12,
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            AppCheckbox(
              checked: checked,
              onChanged: (_) => state.toggleSelect(song.mid),
            ),
            const SizedBox(width: 12),
            SongCover(url: ApiClient.getProxyImageUrl(song.pic), size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      SourceIcon(source: song.source, size: 16),
                      const SizedBox(width: 2),
                      Expanded(
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
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.textTertiary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Row(
              children: [
                AppIconButton(
                  icon: AppIcons.play,
                  size: 32,
                  iconSize: 16,
                  baseColor: c.accent,
                  hoverBg: c.accentLight,
                  tooltip: '试听',
                  onTap: () => state.playSong(song.mid),
                ),
                DownloadButton(mid: song.mid, state: state),
                AppIconButton(
                  icon: AppIcons.lyricDoc,
                  size: 32,
                  iconSize: 16,
                  bordered: true,
                  accentHover: true,
                  tooltip: '歌词',
                  onTap: () => widget.onOpenLyric(song.mid),
                ),
                const SizedBox(width: 4),
                AppIconButton(
                  icon: AppIcons.trash,
                  size: 32,
                  iconSize: 16,
                  bordered: true,
                  accentHover: true,
                  tooltip: '删除',
                  onTap: () => state.removeFromList(song.mid),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
