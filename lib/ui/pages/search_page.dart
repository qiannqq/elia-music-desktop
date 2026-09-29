import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/motion.dart';
import '../../services/app_background.dart';
import '../../models/song.dart';
import '../../state/app_state.dart';
import '../icons.dart';
import '../widgets/common.dart';
import '../widgets/context_menu.dart';
import '../widgets/fluent.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/song_actions.dart';

/// 搜索页 —— 对应 `#page-search`
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.state,
    required this.scrollController,
    required this.inputController,
    required this.onOpenLyric,
  });

  final AppState state;
  final ScrollController scrollController;

  /// 输入框控制器由 shell 持有（见 AppShell 里的说明），
  /// 这样切到别的页面再回来，已输入的内容还在。
  final TextEditingController inputController;

  /// 打开歌词弹窗（右键菜单里的「歌词」用）
  final ValueChanged<String> onOpenLyric;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

/// 可选的搜索音源。`id` 要和 `AppState.setSearchSource` 认的字符串一致。
class _SourceDef {
  const _SourceDef(this.id, this.label);

  final String id;
  final String label;
}

const List<_SourceDef> _kSources = [
  _SourceDef('qq', 'QQ音乐'),
  _SourceDef('netease', '网易云音乐'),
  _SourceDef('bilibili', 'B站'),
];

class _SearchPageState extends State<SearchPage> {
  // 焦点不跨页面保留：切回来时不该自动弹出光标
  final FocusNode _focus = FocusNode();

  TextEditingController get _input => widget.inputController;

  /// 菜单锚在**整条搜索框**上：它要从框的下方展开，不能压在框上
  final GlobalKey _barKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 搜索框的底色与提示文字都跟着焦点走：焦点一变就重画一次
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _search() {
    if (widget.state.isSearching) return;
    widget.state.handleSearch(_input.text);
  }

  /// 「全部添加」的歌单选择。
  ///
  /// 复用右键菜单那一套：每个歌单一项，已经在里面的不动（见
  /// [AppState.addAllToPlaylist]）。
  void _showAddAllMenu(BuildContext ctx) {
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final at = box.localToGlobal(Offset(0, box.size.height));
    showAppContextMenu(
      context: ctx,
      position: at,
      items: [
        for (final p in widget.state.playlists)
          AppMenuItem(
            label: p.name,
            icon: AppIcons.playlist,
            // 「完全单向」的歌单不给往里加：加进去也会被下一次同步清掉
            enabled: !widget.state.playlistLocked(p.id),
            onTap: () => widget.state.addAllToPlaylist(p.id),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final state = widget.state;
    final hasResults = state.searchResults.isNotEmpty;

    // 新一页到了 → 滚回顶部（放在 postFrame 里，等这一帧布局完再滚）
    if (_pendingPage != null && !state.pageLoading) {
      final arrived = state.currentPage == _pendingPage;
      _pendingPage = null;
      if (arrived) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToTop());
      }
    }

    // 滚轮加过渡动画（不影响速度，只是不再一格一跳）
    return SmoothWheelScroll(
      controller: widget.scrollController,
      // 用 CustomScrollView 而不是 SingleChildScrollView + Wrap：
      // 结果区得是懒加载的。300 条结果用 Wrap 会一次建出 300 张卡，
      // 切页（页面整体重建）和滚动都要重来一遍。
      child: CustomScrollView(
      controller: widget.scrollController,
      slivers: [
        // ---------------- search-center ----------------
        SliverToBoxAdapter(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: hasResults ? 0 : 260),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.page, AppSpace.pageTop, AppSpace.page, 0),
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
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.5,
                        color: c.text,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '搜索歌曲、歌手，或粘贴歌单链接 / B站 BV 号',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: c.textTertiary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '点击左侧音源图标可切换音源',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, color: c.textTertiary),
                    ),
                    const SizedBox(height: 24),
                  ],
                  // 音源选择不再是横排那几个按钮了：它挪进了搜索框左侧那个
                  // 按钮里（点开是个菜单），所以这里直接就是搜索框。
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: _buildSearchBar(c, state, onResultsPage: hasResults),
                  ),
                ],
              ),
            ),
          ),
        ),

        // ---------------- 结果区 ----------------
        if (hasResults) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
                AppSpace.page, AppSpace.line, AppSpace.page, 0),
            sliver: SliverToBoxAdapter(child: _buildResultsHeader(c, state)),
          ),
          // 比上面那个 16 小：结果头部的按钮比文字高，
          // 文字垂直居中后下方天然多出约 6px，这里减掉才能让
          // 「搜索框→标题」与「标题→卡片」两段视觉间距一致。
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
                AppSpace.page, 10, AppSpace.page, 0),
            sliver: _buildGrid(context, state),
          ),
          if (state.searchKeyword.isNotEmpty && !state.isPlaylistPage)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
              sliver: SliverToBoxAdapter(child: _buildPagination(c, state)),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ]
        // 搜索完成但 0 条 —— 以前这里什么都不显示，看起来像「点了没反应」
        else if (state.hasSearched &&
            !state.isSearching &&
            state.searchKeyword.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.page, vertical: AppSpace.page),
              child: EmptyState(
                icon: AppIcons.search,
                title: '没有找到「${state.searchKeyword}」相关的歌曲',
                hint: '换个关键词，或切换到另一个音源试试',
              ),
            ),
          ),

        // 底部留白（原来在 SingleChildScrollView 的 padding 里）
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    ));
  }

  Widget _buildSearchBar(AppColors c, AppState state,
      {required bool onResultsPage}) {
    final focused = _focus.hasFocus;
    // 两侧按钮什么时候露出来：
    //  * 聚焦时当然露；
    //  * **正在搜索**时也要露 —— 按回车/点搜索之后焦点会退出，只按「聚焦」判断的话，
    //    那个刚替换成转圈圈的加载图标会被一起藏起来，用户会以为「我没按到」，
    //    然后再点一次搜索框重按一遍（千奈报的）；
    //  * 已经在**搜索结果页**上时常驻（那儿随时要换音源、或者再搜一次）。
    final showButtons = focused || state.isSearching || onResultsPage;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 未聚焦 = 高透明（"浅色"就是透），聚焦 = 低透明（更实）—— 底色在两档之间补间。
    //
    // ⚠️ 要分两种情况：**铺了整体背景**（照片/封面）时用「白/黑 + 透明度」那套
    // （压在图上观感正好，千奈说这种时候"很完美"）；**没铺背景**时底色是主题的
    // 纯色面，白 alpha 会淡得几乎看不见，深色下还会出现「聚焦反而更浅」——
    // 所以那一档改用实打实的灰/黑：浅色主题下未聚焦是比底稍深的灰、聚焦是纯白；
    // 深色主题下未聚焦是稍亮的灰、聚焦更深更实。
    final onPhoto = appBackground.active;
    final Color fill;
    if (onPhoto) {
      fill = dark
          ? (focused ? const Color(0xE01A1A1A) : const Color(0x4D000000))
          : (focused ? const Color(0xF2FFFFFF) : const Color(0x59FFFFFF));
    } else {
      // ⚠️ 这两档必须是**不透明**的颜色：`Color.lerp` 是按未预乘插值的，
      // 「8% 黑」到「纯白」中间会路过一个比两端都怪的颜色 —— 表现就是
      // 千奈看到的「浅色下先突然变暗再亮回来 / 深色下先突然变亮再暗回去」。
      // 两端都做实色，中间的灰就是一条干净的渐变。
      fill = dark
          ? (focused ? const Color(0xFF0D0D0D) : const Color(0xFF2A2A2A))
          : (focused ? const Color(0xFFFFFFFF) : const Color(0xFFE7E7E7));
    }
    return AnimatedContainer(
      key: _barKey,
      duration: Motion.controlNormal,
      curve: Motion.decelerate,
      height: 44,
      decoration: BoxDecoration(
        color: fill,
        // 胶囊形：半径就是高度的一半
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      // 整条都聚焦输入框：TextField 用 isDense 之后只有 ~20px 高，
      // 点到上下留白时不聚焦的话，用户会觉得「可点击区域很小」。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _focus.requestFocus(),
        child: Row(
          children: [
            // 左：音源选择（点开是菜单）。**未聚焦时整体隐藏** ——
            // 只留下一个浅色输入框（千奈要的那个观感）。
            // 用透明度而不是整块拿掉：留着占位，居中的提示文字就不会左右跳。
            AnimatedOpacity(
              duration: Motion.controlFast,
              curve: Motion.decelerate,
              opacity: showButtons ? 1 : 0,
              child: IgnorePointer(
                ignoring: !showButtons,
                child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: state.isSearching ? null : _showSourceMenu,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Center(
                    child: SourceIcon(source: state.searchSource, size: 18),
                  ),
                ),
              ),
                ),
              ),
            ),
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _focus,
                onSubmitted: (_) => _search(),
                onChanged: state.onSearchInputChanged,
                cursorColor: c.accent,
                // 输入的文字**居中**（含占位文字——它就是 hintText）
                textAlign: TextAlign.center,
                // 字体不加粗：显式 w400（别继承主题里偏粗的那档）
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: c.text),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  // 聚焦之后光标已经在里面了，提示文字就该收起来
                  hintText: focused ? null : '搜索歌曲或粘贴歌单链接、BV号',
                  hintStyle: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: c.textTertiary),
                ),
              ),
            ),
            // 右：搜索（同样只在聚焦时露出来）
            AnimatedOpacity(
              duration: Motion.controlFast,
              curve: Motion.decelerate,
              opacity: showButtons ? 1 : 0,
              child: IgnorePointer(
                ignoring: !showButtons,
                child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: state.isSearching ? null : _search,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Center(
                    child: state.isSearching
                        ? SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(c.accent),
                            ),
                          )
                        : AppIcon(AppIcons.search, size: 17, color: c.accent),
                  ),
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

  /// 音源菜单。复用右键菜单那一套（弹出动画、圆角、悬停都是同一套），
  /// 只是锚在音源按钮上、朝下弹。
  void _showSourceMenu() {
    final box = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    // 锚在搜索框的**下沿**再留 6px：菜单从框下面展开，不压在框上
    showAppContextMenu(
      context: context,
      position: box.localToGlobal(Offset(0, box.size.height + 6)),
      above: false,
      items: [
        for (final s in _kSources)
          AppMenuItem(
            label: s.label,
            icon: AppIcons.music,
            // 直接给品牌图（assets/source_icons 那三张），别用 SVG 硬画
            iconWidget: SourceIcon(source: s.id, size: 16),
            checked: widget.state.searchSource == s.id,
            onTap: () {
              widget.state.setSearchSource(s.id);
              // 切音源不该把焦点弄丢：菜单一收就把光标还给输入框，
              // 否则输入框当场退回「未聚焦」那副样子（未聚焦连两侧按钮都藏起来）。
              _focus.requestFocus();
            },
          ),
      ],
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
        // 「全部添加」要先问加到哪个歌单 —— 多歌单之后没有「默认那一个」可言
        Builder(
          builder: (ctx) => AppButton(
            label: '全部添加',
            small: true,
            variant: AppButtonVariant.accent,
            onPressed: () => _showAddAllMenu(ctx),
          ),
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

  /// 结果网格（sliver）。
  ///
  /// 必须是懒加载的：结果动辄两三百条，一次性全建出来会让切页和滚动都很沉。
  Widget _buildGrid(BuildContext context, AppState state) {
    return SliverLayoutBuilder(
      builder: (ctx, cons) {
        // 等价 CSS `repeat(auto-fill, minmax(320px, 1fr))`，gap 8
        final cols = ((cons.crossAxisExtent + 8) / 328).floor().clamp(1, 8);
        // 卡片高度 = 封面 44（固定）+ 上下内边距 20 + 边框 2。
        // 文字那两行正常比封面矮，只有系统文本放大时才可能超过它。
        final ts = MediaQuery.textScalerOf(ctx);
        final textH = ts.scale(13) * 1.4 + 2 + ts.scale(12) * 1.4;
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            mainAxisExtent: (textH > 44 ? textH : 44.0) + 22,
          ),
          delegate: SliverChildBuilderDelegate(
            (ctx, i) {
              final song = state.searchResults[i];
              // 每个卡片独立成层：滚动时只需平移图层，不必重新光栅化整屏卡片。
              return RepaintBoundary(
                // 稳定 key：与歌单一致，避免列表变动时子项 State 错位
                key: ValueKey('search-${song.mid}'),
                child: _SongCard(
                  song: song,
                  state: state,
                  onOpenLyric: widget.onOpenLyric,
                ),
              );
            },
            childCount: state.searchResults.length,
          ),
        );
      },
    );
  }

  /// 换页后要不要滚回顶部，以及等的是哪一页。
  ///
  /// 必须等**新一页真的到了**再滚：请求还没回来就滚上去，
  /// 用户看到的是「跳回顶部、内容却还是旧的」，像卡住了。
  int? _pendingPage;

  void _scrollToTop() {
    if (!widget.scrollController.hasClients) return;
    widget.scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// 翻页：先给加载反馈，**新内容到了再**回到顶部
  void _changePage(AppState state, int target) {
    if (state.pageLoading) return;
    _pendingPage = target;
    state.changePage(target);
  }

  Widget _buildPagination(AppColors c, AppState state) {
    final totalPages = ((state.searchTotal / 50).ceil()).clamp(1, 1 << 30);
    final hasNext = state.currentPage < totalPages;
    final busy = state.pageLoading;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppButton(
            label: '上一页',
            onPressed: busy || state.currentPage <= 1
                ? null
                : () => _changePage(state, state.currentPage - 1),
          ),
          const SizedBox(width: 16),
          if (busy)
            // 加载提示放在页码旁边：用户正在看这里，反馈最直接
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
            )
          else
            SizedBox(
              width: 14,
              height: 14,
              child: SizedBox.shrink(),
            ),
          const SizedBox(width: 8),
          Text(
            busy ? '加载中…' : '第 ${state.currentPage}/$totalPages 页',
            style: TextStyle(fontSize: 13, color: c.textSecondary),
          ),
          const SizedBox(width: 16),
          AppButton(
            label: '下一页',
            onPressed: !hasNext || busy
                ? null
                : () => _changePage(state, state.currentPage + 1),
          ),
        ],
      ),
    );
  }
}

/// 搜索结果卡片 —— 对应 `.song-card`
class _SongCard extends StatefulWidget {
  const _SongCard({
    required this.song,
    required this.state,
    required this.onOpenLyric,
  });

  final Song song;
  final AppState state;
  final ValueChanged<String> onOpenLyric;

  @override
  State<_SongCard> createState() => _SongCardState();
}

class _SongCardState extends State<_SongCard> {
  bool _hovered = false;

  /// 右键菜单。
  ///
  /// 条目与歌单页共用 [buildSongMenuItems]，但不带「从歌单中移除 / 置顶 /
  /// 置底 / 编辑歌曲名」—— 搜索结果多半还没进歌单，那几项做了也没意义。
  void _showMenu(Offset position) {
    final song = widget.song;
    showAppContextMenu(
      context: context,
      position: position,
      items: buildSongMenuItems(
        context: context,
        state: widget.state,
        song: song,
        onOpenLyric: widget.onOpenLyric,
        // 改名改的是歌单里那一份，搜索结果的改动存不下来，
        // 所以这一项在搜索页不给（同「从歌单中移除 / 置顶 / 置底」）
        onEditName: null,
        inPlaylist: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final song = widget.song;
    final state = widget.state;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ClickRegion(
        onSecondaryClick: _showMenu,
        onDoubleClick: () => state.playSong(song.mid),
        child: AnimatedContainer(
          duration: kStateFade,
          curve: Motion.easyEase,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            // Win11 的卡片：`CardBackgroundFillColorDefault` + `CardStrokeColorDefault`
            color: _hovered ? c.cardHover : c.card,
            border: Border.all(color: _hovered ? c.border : c.cardStroke),
            borderRadius: BorderRadius.circular(c.radiusLg),
          ),
          child: Row(
            children: [
              SongCover(pic: song.pic, size: 44),
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
      ),
    );
  }
}
