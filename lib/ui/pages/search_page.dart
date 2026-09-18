import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../models/song.dart';
import '../../services/api_client.dart';
import '../../state/app_state.dart';
import '../icons.dart';
import '../widgets/common.dart';
import '../widgets/song_actions.dart';

/// 搜索页 —— 对应 `#page-search`
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.state, required this.scrollController});

  final AppState state;
  final ScrollController scrollController;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _search() {
    if (widget.state.isSearching) return;
    widget.state.handleSearch(_input.text);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final state = widget.state;
    final hasResults = state.searchResults.isNotEmpty;

    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---------------- search-center ----------------
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: hasResults ? 0 : 260),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!hasResults) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Elia Music',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: c.text,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '搜索歌曲、歌手，或粘贴QQ音乐/网易云音乐歌单链接',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: c.textTertiary),
                    ),
                    const SizedBox(height: 24),
                  ],
                  _buildSourceTabs(c, state),
                  const SizedBox(height: 20),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: _buildSearchBar(c, state),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- 结果区 ----------------
          if (hasResults)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 64),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  _buildResultsHeader(c, state),
                  const SizedBox(height: 16),
                  _buildGrid(context, state),
                  if (state.searchKeyword.isNotEmpty && !state.isPlaylistPage)
                    _buildPagination(c, state),
                  const SizedBox(height: 16),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSourceTabs(AppColors c, AppState state) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _SourceTab(
          source: 'qq',
          label: 'QQ音乐',
          active: state.searchSource == 'qq',
          disabled: state.isSearching,
          onTap: () => state.setSearchSource('qq'),
        ),
        const SizedBox(width: 8),
        _SourceTab(
          source: 'netease',
          label: '网易云音乐',
          active: state.searchSource == 'netease',
          disabled: state.isSearching,
          onTap: () => state.setSearchSource('netease'),
        ),
      ],
    );
  }

  Widget _buildSearchBar(AppColors c, AppState state) {
    final linkStyle = state.searchLinkStyle;
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: c.inputBg,
        border: Border.all(color: c.inputBorder, width: 1.5),
        borderRadius: BorderRadius.circular(c.radiusLg),
      ),
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        children: [
          AppIcon(AppIcons.search, size: 18, color: c.textTertiary),
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              onSubmitted: (_) => _search(),
              onChanged: state.onSearchInputChanged,
              cursorColor: c.accent,
              style: TextStyle(fontSize: 14, color: c.text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                hintText: '搜索歌曲、歌手、专辑 或 粘贴QQ/网易云歌单链接',
                hintStyle: TextStyle(fontSize: 14, color: c.textTertiary),
              ),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: state.isSearching ? null : _search,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: linkStyle ? Colors.transparent : c.accent,
                  border: linkStyle ? Border.all(color: c.accent, width: 1.5) : null,
                  borderRadius: BorderRadius.circular(c.radius),
                ),
                child: Center(
                  child: state.isSearching
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              linkStyle ? c.accent : Colors.white,
                            ),
                          ),
                        )
                      : AppIcon(
                          AppIcons.search,
                          size: 16,
                          color: linkStyle ? c.accent : c.accentText,
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsHeader(AppColors c, AppState state) {
    return Row(
      children: [
        Flexible(
          child: Text(
            state.searchKeyword.isEmpty ? '搜索结果' : state.searchKeyword,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${state.searchResults.length} 首',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textTertiary),
        ),
        const Spacer(),
        AppButton(
          label: '全部添加',
          small: true,
          variant: AppButtonVariant.accent,
          onPressed: state.addAllResults,
        ),
        const SizedBox(width: 8),
        AppButton(
          label: '批量下载',
          small: true,
          variant: AppButtonVariant.primary,
          icon: AppIcons.download,
          iconSize: 14,
          onPressed: () => state.batchDownload(state.searchResults),
        ),
      ],
    );
  }

  Widget _buildGrid(BuildContext context, AppState state) {
    return LayoutBuilder(
      builder: (ctx, cons) {
        // 等价 CSS `repeat(auto-fill, minmax(320px, 1fr))`，gap 8
        final cols = ((cons.maxWidth + 8) / 328).floor().clamp(1, 8);
        final itemWidth = (cons.maxWidth - (cols - 1) * 8) / cols;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final song in state.searchResults)
              SizedBox(
                width: itemWidth,
                child: _SongCard(song: song, state: state),
              ),
          ],
        );
      },
    );
  }

  Widget _buildPagination(AppColors c, AppState state) {
    final totalPages = ((state.searchTotal / 50).ceil()).clamp(1, 1 << 30);
    final hasNext = state.currentPage < totalPages;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppButton(
            label: '上一页',
            onPressed: state.currentPage <= 1 ? null : () => state.changePage(state.currentPage - 1),
          ),
          const SizedBox(width: 16),
          Text(
            '第 ${state.currentPage}/$totalPages 页',
            style: TextStyle(fontSize: 13, color: c.textSecondary),
          ),
          const SizedBox(width: 16),
          AppButton(
            label: '下一页',
            onPressed: hasNext ? () => state.changePage(state.currentPage + 1) : null,
          ),
        ],
      ),
    );
  }
}

class _SourceTab extends StatelessWidget {
  const _SourceTab({
    required this.source,
    required this.label,
    required this.active,
    required this.disabled,
    required this.onTap,
  });

  final String source;
  final String label;
  final bool active;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: HoverBuilder(
        cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
        builder: (_, hovered) => GestureDetector(
          onTap: disabled ? null : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: active ? c.accentLight : Colors.transparent,
              border: Border.all(
                color: active ? c.accent : (hovered ? c.textTertiary : c.border),
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SourceIcon(source: source, size: 16),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: active ? c.accent : c.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 搜索结果卡片 —— 对应 `.song-card`
class _SongCard extends StatefulWidget {
  const _SongCard({required this.song, required this.state});

  final Song song;
  final AppState state;

  @override
  State<_SongCard> createState() => _SongCardState();
}

class _SongCardState extends State<_SongCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final song = widget.song;
    final state = widget.state;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _hovered ? c.cardHover : c.card,
          border: Border.all(color: _hovered ? c.border : c.borderSubtle),
          borderRadius: BorderRadius.circular(c.radius),
        ),
        child: Row(
          children: [
            SongCover(url: ApiClient.getProxyImageUrl(song.pic), size: 44),
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
            AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: _hovered ? 1 : 0,
              child: Row(
                children: [
                  AppIconButton(
                    icon: AppIcons.play,
                    size: 32,
                    iconSize: 16,
                    accentHover: true,
                    baseColor: c.accent,
                    hoverBg: c.accentLight,
                    tooltip: '试听',
                    onTap: () => state.playSong(song.mid),
                  ),
                  DownloadButton(mid: song.mid, state: state),
                  AddButton(mid: song.mid, state: state),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
