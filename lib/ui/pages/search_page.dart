import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../models/song.dart';
import '../../services/api_client.dart';
import '../../state/app_state.dart';
import '../icons.dart';
import '../widgets/common.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/song_actions.dart';

/// 搜索页 —— 对应 `#page-search`
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.state,
    required this.scrollController,
    required this.inputController,
  });

  final AppState state;
  final ScrollController scrollController;

  /// 输入框控制器由 shell 持有（见 AppShell 里的说明），
  /// 这样切到别的页面再回来，已输入的内容还在。
  final TextEditingController inputController;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  // 焦点不跨页面保留：切回来时不该自动弹出光标
  final FocusNode _focus = FocusNode();

  TextEditingController get _input => widget.inputController;

  @override
  void dispose() {
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

    // 滚轮加过渡动画（不影响速度，只是不再一格一跳）
    return SmoothWheelScroll(
      controller: widget.scrollController,
      child: SingleChildScrollView(
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
                  // 比上面那个 16 小：结果头部的按钮比文字高，
                  // 文字垂直居中后下方天然多出约 6px，这里减掉才能让
                  // 「搜索框→标题」与「标题→卡片」两段视觉间距一致。
                  const SizedBox(height: 10),
                  _buildGrid(context, state),
                  if (state.searchKeyword.isNotEmpty && !state.isPlaylistPage)
                    _buildPagination(c, state),
                  const SizedBox(height: 16),
                ],
              ),
            )
          // 搜索完成但 0 条 —— 以前这里什么都不显示，看起来像「点了没反应」
          else if (state.hasSearched &&
              !state.isSearching &&
              state.searchKeyword.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 64, vertical: 32),
              child: EmptyState(
                icon: AppIcons.search,
                title: '没有找到「${state.searchKeyword}」相关的歌曲',
                hint: '换个关键词，或切换到另一个音源试试',
              ),
            ),
        ],
      ),
    ));
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
      // 整条都聚焦输入框：
      // TextField 用了 isDense，实际高度只有 ~20px，而外框 44px ——
      // 点到上下留白时不会聚焦，用户会觉得「可点击区域很小」。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _focus.requestFocus(),
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
      ),
    );
  }

  Widget _buildResultsHeader(AppColors c, AppState state) {
    // 标题组用 Expanded 占满剩余空间，**不要**再用 Spacer：
    // `Flexible`(flex:1) 与 `Spacer`(flex:1) 会平分剩余空间，标题只取自身宽度、
    // 留下一段空白，右侧按钮就被推到中间而不是最右侧（等价原 CSS 的
    // `.results-header{justify-content:space-between}`）。
    return Row(
      children: [
        Expanded(
          child: Row(
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
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w500, color: c.textTertiary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
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
                // 稳定 key：与歌单一致，避免列表变动时子项 State 错位
                key: ValueKey('search-${song.mid}'),
                width: itemWidth,
                child: _SongCard(song: song, state: state),
              ),
          ],
        );
      },
    );
  }

  /// 翻页：换页后回到顶部
  ///
  /// 不回去的话，新一页会停在上一页的滚动位置，
  /// 而且从列表底部直接换内容观感很跳。
  void _changePage(AppState state, int target) {
    state.changePage(target);
    if (widget.scrollController.hasClients) {
      widget.scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
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
            onPressed: state.currentPage <= 1
                ? null
                : () => _changePage(state, state.currentPage - 1),
          ),
          const SizedBox(width: 16),
          Text(
            '第 ${state.currentPage}/$totalPages 页',
            style: TextStyle(fontSize: 13, color: c.textSecondary),
          ),
          const SizedBox(width: 16),
          AppButton(
            label: '下一页',
            onPressed: hasNext ? () => _changePage(state, state.currentPage + 1) : null,
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
              // 不要用 Colors.transparent（那是「透明的黑」）——
              // Color.lerp 从它过渡到灰色时会经过半透明的黑，悬浮瞬间先「黑」一下。
              // 用同色 + alpha 0 才能保证插值在同一色相内。
              color: active ? c.accentLight : c.accentLight.withValues(alpha: 0),
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
              // 弹出层打开时也要保持可见：
              // 全屏遮罩会让卡片收到 onExit（_hovered 变 false）→ 按钮淡出；
              // 关掉菜单后 hover 回来又淡入 —— 表现为「所有按钮消失再出现」。
              opacity: (_hovered || state.openAddMenuMid == song.mid) ? 1 : 0,
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
