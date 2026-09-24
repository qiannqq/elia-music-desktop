import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../../models/song.dart';
import '../../services/api_client.dart';
import '../../services/player_controller.dart';
import '../../state/app_state.dart';
import '../icons.dart';
import '../widgets/common.dart';
import '../widgets/context_menu.dart';
import '../widgets/smooth_scroll.dart';
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

/// 量一段文字画出来有多宽（单行）。
///
/// 就地编辑的下划线、歌单内搜索的线都靠它：线的长度得跟着内容走，
/// 而且要**有最小长度**，超出去才继续长。
double _measureTextWidth(String text, TextStyle style, double maxWidth) {
  final painter = TextPainter(
    // 空串量出来是 0，给个空格免得线完全不见（此时光标还闪在开头）
    text: TextSpan(text: text.isEmpty ? ' ' : text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return painter.width.clamp(0.0, maxWidth);
}

class _PlaylistPageState extends State<PlaylistPage>
    with SingleTickerProviderStateMixin {
  /// 当前鼠标悬停的歌曲 mid —— **单一数据源**。
  ///
  /// 原先每个条目各自维护 _hovered，靠 onExit 清除。鼠标快速划过时
  /// 上一个条目的 onExit 可能不生效，导致「两行同时高亮」。
  /// 改为由页面统一记录：进入 B 时 A 自然就不再是高亮态，不依赖 exit 事件。
  ///
  /// 用 ValueNotifier 而不是 `setState`：原先悬浮一变就重建**整个页面**
  /// （含整张 ListView 与所有可见行）。快速滚动时鼠标不断划过新行，
  /// 等于每划过一行就重建一次列表。改成每行自己订阅，只有真正变了的那行重建。
  final ValueNotifier<String?> _hoveredMid = ValueNotifier<String?>(null);

  // ------------------------------------------------------------ 拖动中的卡片

  /// 拖动中那张卡片的当前状态 —— **卡片是我们自己画的**（见 [_dragCardLayer]），
  /// 不用框架那层 overlay 代理。
  ///
  /// 代理挂在 `MaterialApp` 的根 Overlay 上，而根 Overlay 在 `ZoomWrapper`
  /// **外面** —— 界面缩放不是 100% 时两边坐标系就不一致了：实测 110% 下卡片
  /// 只有真行的 91% 宽（真行 1129.6、卡片 1026.9，正好差一个 1.1），松手还会
  /// 往左上角飞一段，然后真行在落点「放大归位」。自己画就都在列表这一层，
  /// 尺寸、位置、落点动画全对得上。
  final ValueNotifier<_DragCard?> _dragCard = ValueNotifier<_DragCard?>(null);

  /// 正在拖的行下标（跟着框架的 onReorderStart / onReorderEnd 起止）
  int? _dragFrom;

  /// 抓手在卡片内的位置、卡片原本的左边与宽度 —— 拖动中**只跟垂直走**
  double _dragGrabDy = 0;
  double _dragLeft = 0;
  double _dragWidth = 0;

  /// 指针当前的纵向位置（列表区域坐标系）
  double _dragPointerDy = 0;

  /// 松手后往落点滑：从 [_dropFromTop] 到 [_dropToTop]
  double? _dropFromTop;
  double? _dropToTop;

  /// 卡片的不透明度动画：拿起来 1 → 0.7，松手再放回 1（同一个控制器回退）。
  ///
  /// 时长跟框架那条落点动画（`_proxyAnimation`，250ms）**对齐**：两边都从松手
  /// 那一刻起跑，才会在同一帧结束。
  late final AnimationController _dragFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: 0,
  )
    ..addListener(_onDragFadeTick)
    ..addStatusListener(_onDragFadeStatus);

  /// 拖动中不给任何行加悬停高亮 —— 鼠标掠过别的卡片时它们不该亮
  final ValueNotifier<bool> _dragging = ValueNotifier(false);

  /// 撤卡片放在**自己那条动画回退到 0 的那一帧**（见 [_onDragFadeStatus]）。

  /// 松手那条动画回退到 0 —— **就在这一帧撤卡片**。
  ///
  /// 撤早了会闪（卡片消失、真行还没回来），撤晚了会「亮一下」（卡片和真行叠一帧：
  /// 正在播放那圈光晕的 `BoxShadow` 是 alpha 0.3，两张叠起来合成成 0.51）。
  /// 所以两条动画必须**同一帧起跑、同一帧结束**：时长都是 250ms（框架那条
  /// `_proxyAnimation` 也是 250ms）、都在松手那一刻 `reverse()`、
  /// 都由同一个 vsync 驱动 —— 于是「我这边归位完成」就是「框架提交新顺序、
  /// 把行放回来」的同一帧，交接不早不晚。
  ///
  /// ⚠️ 拿起时 `forward(from: 0)` 也会经过 `dismissed`，用 `_dropToTop` 区分。
  void _onDragFadeStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || _dropToTop == null) return;
    _clearDragCard();
  }

  /// 拿列表区域这一层量坐标（它跟列表是同一套坐标系）
  final GlobalKey _listAreaKey = GlobalKey();

  /// 量列表视口用（算落点在第几行）
  final GlobalKey _listKey = GlobalKey();

  double get _dragOpacity => 1 - 0.3 * _dragFade.value;

  /// 每一帧：位置（拖动中跟指针 / 松手后滑向落点）+ 不透明度
  void _onDragFadeTick() {
    final card = _dragCard.value;
    if (card == null) return;
    final from = _dropFromTop;
    final to = _dropToTop;
    final top = (from == null || to == null)
        ? _dragPointerDy - _dragGrabDy
        : from + (to - from) * (1 - _dragFade.value);
    _dragCard.value = card.copyWith(top: top, opacity: _dragOpacity);
  }

  // ------------------------------------------------------------ 歌单内搜索

  bool _searching = false;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// 下划线的长度。收起动画要靠它：宽度跟着输入一起归零的话，线会在动画
  /// **开始之前**就没了 —— 表现成「展开有动画、收起没动画」。
  double _lastSearchWidth = 0;

  /// 线的最小长度。空着的时候也得看得见，不然不知道点没点上。
  static const double _searchMinWidth = 140;

  /// 按 [_query] 过滤后的歌单。关键词为空就是全部。
  List<Song> get _visibleSongs {
    final q = _query.toLowerCase();
    if (q.isEmpty) return widget.state.songs;
    return widget.state.songs
        .where((s) =>
            s.name.toLowerCase().contains(q) ||
            s.artist.toLowerCase().contains(q))
        .toList();
  }

  void _toggleSearch() {
    final next = !_searching;
    setState(() => _searching = next);
    if (next) {
      _searchFocus.requestFocus();
      return;
    }
    // 收起时连输入内容一起清掉：只收线、留着上次的过滤条件，
    // 会让人以为「列表怎么少了几首」。
    _searchCtrl.clear();
    _searchFocus.unfocus();
    setState(() => _query = '');
  }

  /// 没有搜索按钮 —— 回车即搜。
  void _submitSearch(String value) {
    setState(() => _query = value.trim());
  }

  /// 放大镜右边那条线：宽度跟着输入内容走（有最小长度），展开/收起带动画。
  Widget _buildSearchLine(AppColors c) {
    final style = TextStyle(fontSize: 13, color: c.text);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: _searching ? 1 : 0),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      builder: (ctx, t, _) {
        // 量不到就沿用上一次的宽度：收起时文字已经清空了，直接量会得到 0，
        // 线会「啪」地消失，而不是收回去。
        final measured = _measureTextWidth(_searchCtrl.text, style, 320);
        final want = measured < _searchMinWidth ? _searchMinWidth : measured;
        if (_searching) _lastSearchWidth = want;
        final width = (_lastSearchWidth == 0 ? want : _lastSearchWidth) * t;
        return Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IgnorePointer(
                  ignoring: !_searching,
                  child: Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: TextField(
                      controller: _searchCtrl,
                      focusNode: _searchFocus,
                      style: style,
                      cursorColor: c.accent,
                      cursorWidth: 1.5,
                      onSubmitted: _submitSearch,
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: '在歌单里搜索',
                        hintStyle:
                            TextStyle(fontSize: 13, color: c.textTertiary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                // 线本身：跟主题色一致
                Container(height: 1.5, color: c.accent),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 挂在 `prototypeItem` 上，用来量真实行高（见 [scrollListToRow]）。
  /// 「定位到正在播放」要按行高算目标位置，手写公式字体一缩放就偏。
  final GlobalKey _prototypeKey = GlobalKey();

  /// 可拖动那个分支的原型。
  ///
  /// **两个分支不能共用一个 GlobalKey** —— 切分支的那一帧同一个 key 会挂到
  /// 两棵树上，sliver 直接断言失败（`_childElements.containsKey(child.slot)`）。
  final GlobalKey _prototypeKeyReorder = GlobalKey();

  /// 当前活着的那一个原型量出来的行高（两个分支同时只有一个在树上）
  double get _rowHeight =>
      _prototypeKey.currentContext?.size?.height ??
      _prototypeKeyReorder.currentContext?.size?.height ??
      0;

  /// 滚到正在播放的那一首。带滚动动画（与滚轮同一条曲线），不是直接跳。
  void _scrollToNowPlaying() {
    final mid = player.currentSong?.mid;
    if (mid == null) return;
    final index = widget.state.songs.indexWhere((s) => s.mid == mid);
    if (index < 0) {
      widget.state.showInfo('正在播放的歌不在歌单里');
      return;
    }
    final h = _rowHeight;
    if (h <= 0) {
      // 还没布局过，量不到行高 —— 等这一帧结束再来
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) scrollListToRow(widget.scrollController, index, _rowHeight);
      });
      return;
    }
    scrollListToRow(widget.scrollController, index, h);
  }

  @override
  @override
  void initState() {
    super.initState();
    // 线长跟着输入走 —— 打字时要重建（只在展开态，别的时候不监听）
    _searchCtrl.addListener(() {
      if (_searching && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _dragFade.dispose();
    _dragCard.dispose();
    _dragging.dispose();
    _hoveredMid.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 只被用来量行高的那一行（不参与绘制）。
  Widget _prototypeRow(AppState state, Key key) => _PlaylistItem(
        key: key,
        song: const Song(mid: '', name: '歌名', artist: '歌手'),
        state: state,
        onOpenLyric: widget.onOpenLyric,
        hoveredMid: _hoveredMid,
      );

  /// 拖完一次。
  ///
  /// 拖动中的自动滚动是直接 `jumpTo` 的，没经过控制器 —— 不清掉基准，
  /// 下一次滚轮会从过期的目标位置开始，出现一下跳变。
  void _reorder(int from, int to) {
    // 框架这时才提交新顺序、把行放回落点 —— 卡片跟它同帧交接，中间不留空洞
    _clearDragCard();
    final c = widget.scrollController;
    if (c is SmoothScrollController) c.invalidateTarget();
    widget.state.moveSong(from, to);
  }

  /// 按下卡片：先只记抓手位置，等框架真的开始拖了再显示卡片 ——
  /// 点一下不该闪出一张卡片。
  void _onCardGrab(int index, RenderBox rowBox, Offset globalPos) {
    final area = _listAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (area == null || !area.hasSize) return;
    final rowTopLeft = area.globalToLocal(rowBox.localToGlobal(Offset.zero));
    final pointer = area.globalToLocal(globalPos);
    _dragGrabDy = pointer.dy - rowTopLeft.dy;
    _dragLeft = rowTopLeft.dx;
    _dragWidth = rowBox.size.width;
    _dragPointerDy = pointer.dy;
  }

  /// 框架的拖动开始了 —— 卡片出场，并沿不透明度动画淡下去
  void _onReorderStart(int index) {
    _dragFrom = index;
    _dropFromTop = null;
    _dropToTop = null;
    // 拖动期间只有被拖的那张卡片是"重点"：把已有的悬停清掉，并抑制后续悬停
    _hoveredMid.value = null;
    _dragging.value = true;
    _dragFade.forward(from: 0);
    _dragCard.value = _DragCard(
      song: widget.state.songs[index],
      left: _dragLeft,
      top: _dragPointerDy - _dragGrabDy,
      width: _dragWidth,
      opacity: _dragOpacity,
    );
  }

  /// 指针在列表区域里移动 —— 卡片跟着走（只跟纵向，横向不动）
  void _onAreaPointerMove(PointerMoveEvent event) {
    final from = _dragFrom;
    if (from == null || _dropToTop != null) return;
    // 拖动中途列表被改短了（框架会 cancelReorder，它不发 onReorderEnd）——
    // 卡片不能留在屏幕上
    if (from >= widget.state.songs.length) {
      _clearDragCard();
      return;
    }
    final area = _listAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (area == null) return;
    _dragPointerDy = area.globalToLocal(event.position).dy;
    _dragCard.value =
        _dragCard.value?.copyWith(top: _dragPointerDy - _dragGrabDy);
  }

  /// 松手：卡片滑到落点（第 [insertIndex] 格），不透明度同时放回 1。
  ///
  /// 落点按「行高 × 下标 − 滚动偏移」算 —— 行是等高的（原型量出来的
  /// `_rowHeight`），跟「定位到正在播放」用的是同一个算法。
  void _onReorderEnd(int insertIndex) {
    final from = _dragFrom;
    final card = _dragCard.value;
    final area = _listAreaKey.currentContext?.findRenderObject() as RenderBox?;
    final list = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (from == null ||
        card == null ||
        area == null ||
        list == null ||
        _rowHeight <= 0) {
      _clearDragCard();
      return;
    }
    // 框架给的 insertIndex 是「被拖走的那一格还在」时的下标，减一才是落点
    final to = insertIndex > from ? insertIndex - 1 : insertIndex;
    final viewportTop = area.globalToLocal(list.localToGlobal(Offset.zero)).dy;
    final offset =
        widget.scrollController.hasClients ? widget.scrollController.offset : 0.0;
    _dropFromTop = card.top;
    _dropToTop = viewportTop + to * _rowHeight - offset;
    _dragFade.reverse();
  }

  void _clearDragCard() {
    _dragging.value = false;
    _dragCard.value = null;
    _dragFrom = null;
    _dropFromTop = null;
    _dropToTop = null;
  }

  /// 拖动中那张卡片（自己画，见 [_dragCard]）
  Widget _dragCardLayer() {
    return Positioned.fill(
      // 卡片只是画出来看看，不能挡事件（底下的行还要收悬停/点击）
      child: IgnorePointer(
        child: ValueListenableBuilder<_DragCard?>(
          valueListenable: _dragCard,
          builder: (_, card, _) {
            if (card == null) return const SizedBox.shrink();
            return Stack(
              children: [
                Positioned(
                  left: card.left,
                  top: card.top,
                  width: card.width,
                  child: Opacity(
                    opacity: card.opacity,
                    child: _dragCardBody(card.song),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 卡片本体：跟悬停时的真卡片**长得一模一样**（`forceHover` 让行自己画
  /// 那圈底色与铅笔），只是整体半透明。
  Widget _dragCardBody(Song song) => _PlaylistItem(
        key: ValueKey(song.mid),
        song: song,
        state: widget.state,
        onOpenLyric: widget.onOpenLyric,
        hoveredMid: _hoveredMid,
        forceHover: true,
      );

  Widget _row(AppState state, List<Song> visible, int i, {int? dragIndex}) {
    // 在这里就把 mid 取出来捕获进闭包。
    // 若闭包里写 visible[i].mid，`i` 是回调触发时才求值的 ——
    // 列表一变（增删/拖拽/换序）就会取到别的歌，
    // 导致「上一行的高亮清不掉、两行同时高亮」。
    final mid = visible[i].mid;
    return _PlaylistItem(
      // 稳定 key（按 mid）：
      // 「添加到歌单顶部」会让歌曲换位置，若按索引复用 State，
      // 展开中的「+」二级菜单状态会跳到别的卡片上、
      // 收起动画被打断 —— 表现为「二级菜单突兀消失」。
      key: ValueKey(mid),
      song: visible[i],
      state: state,
      onOpenLyric: widget.onOpenLyric,
      hoveredMid: _hoveredMid,
      dragIndex: dragIndex,
      onGrab: dragIndex == null ? null : _onCardGrab,
      dragging: dragIndex == null ? null : _dragging,
    );
  }

  /// 歌曲列表本体。
  ///
  /// **两个分支都必须让列表知道行高。** 没有它时 `RenderSliverList` 无从由
  /// 偏移反推行号，只能从第 0 行逐行往下量 —— 切页回来恢复滚动位置那一次
  /// `jumpTo`，几百首就要在一帧里建出几百行（实测 376 首建 345 行，
  /// 还只是空行）。用真实的一行当原型（它只被量高度，不参与绘制），
  /// 字体、文字缩放怎么变都自动跟上，不必手写行高公式。
  Widget _songList(AppState state, List<Song> visible) {
    const padding = EdgeInsets.symmetric(horizontal: 32);

    // 歌单内搜索过滤中退回普通列表：那会儿下标指的是**过滤后**的列表，
    // 拖到哪里都会挪错位置。清掉关键词就能拖。
    if (_query.isNotEmpty) {
      return ListView.builder(
        controller: widget.scrollController,
        padding: padding,
        itemCount: visible.length,
        prototypeItem: _prototypeRow(state, _prototypeKey),
        itemBuilder: (ctx, i) => _row(state, visible, i),
      );
    }

    return ReorderableListView.builder(
      key: _listKey,
      scrollController: widget.scrollController,
      padding: padding,
      itemCount: visible.length,
      // ⚠️ 关掉默认拖手柄：桌面端那个手柄只在行尾一个 12px 的小图标上生效，
      // 按在卡片本身（哪怕是空白处）长按毫无反应。整张卡片的长按接在
      // _PlaylistItem 里。
      buildDefaultDragHandles: false,
      // 框架那层代理**不要**（压成 0 尺寸）：它在缩放层外的根 Overlay 上，
      // 坐标空间跟列表对不上。卡片由 _dragCardLayer 自己画。
      proxyDecorator: (_, _, _) => const SizedBox.shrink(),
      onReorderStart: _onReorderStart,
      onReorderEnd: _onReorderEnd,
      onReorderItem: _reorder,
      prototypeItem: _prototypeRow(state, _prototypeKeyReorder),
      itemBuilder: (ctx, i) => _row(state, visible, i, dragIndex: i),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final state = widget.state;
    final songs = state.songs;
    final visible = _visibleSongs;

    return Column(
      children: [
        // ---- 页头 ----
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 20),
          child: Row(
            children: [
              Text(
                // 显示**当前歌单名**：侧边栏切了歌单，这里得能看出来在哪个
                state.currentPlaylist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c.text),
              ),
              const SizedBox(width: 10),
              // 放大镜：点一下从它右侧划出一条线，就地搜歌单；再点一下连输入
              // 内容一起收起。展开/收起都有动画。
              AppIconButton(
                icon: AppIcons.search,
                size: 28,
                iconSize: 15,
                baseColor: _searching ? c.accent : c.textTertiary,
                hoverColor: c.accent,
                hoverBg: Colors.transparent,
                tooltip: _searching ? '收起搜索' : '在歌单里搜索',
                onTap: _toggleSearch,
              ),
              // 用 Expanded 把这块空间**先占住**：线在这个空间里长，
              // 右边的按钮不会被推着走。
              Expanded(child: _buildSearchLine(c)),
              // 定位到正在播放。只在有播放栏（有当前歌曲）时出现 ——
              // 没在放歌的时候它没有意义。
              if (player.currentSong != null) ...[
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
                const SizedBox(width: 12),
              ],
              if (songs.isNotEmpty) ...[
                AppButton(
                  label: '全选',
                  small: true,
                  onPressed: state.selectAll,
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
                    hint: '搜索或在搜索页面粘贴歌单链接来添加歌曲',
                  ),
                )
              : visible.isEmpty
                  ? const SingleChildScrollView(
                      child: EmptyState(
                        icon: AppIcons.search,
                        title: '没有匹配的歌曲',
                        hint: '换个关键词试试',
                      ),
                    )
                  : Listener(
                  // 拖动中要靠这一层跟指针：被拖的那一行已经被框架换成了占位
                  // 盒子，行内的监听器拿不到后续的 move 了。
                  behavior: HitTestBehavior.deferToChild,
                  onPointerMove: _onAreaPointerMove,
                  child: Stack(
                    key: _listAreaKey,
                    children: [
                      SmoothWheelScroll(
                        controller: widget.scrollController,
                        child: Scrollbar(
                          controller: widget.scrollController,
                          child: _songList(state, visible),
                        ),
                      ),
                      // 拖动中的卡片（自己画，见 _dragCardLayer）
                      _dragCardLayer(),
                    ],
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
                  AppButton(
                    label: '倒序',
                    small: true,
                    icon: AppIcons.playOrderReverse,
                    iconSize: 14,
                    onPressed: state.reversePlaylist,
                  ),
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

/// 拖动中那张卡片的状态。
///
/// 坐标全部是**列表区域**这一层的（跟列表同一个坐标系），所以缩放、滚动
/// 都已经算进去了 —— 这也是不用框架代理的原因（见 [_PlaylistPageState._dragCard]）。
class _DragCard {
  const _DragCard({
    required this.song,
    required this.left,
    required this.top,
    required this.width,
    required this.opacity,
  });

  final Song song;
  final double left;
  final double top;
  final double width;
  final double opacity;

  _DragCard copyWith({double? top, double? opacity}) => _DragCard(
        song: song,
        left: left,
        top: top ?? this.top,
        width: width,
        opacity: opacity ?? this.opacity,
      );
}

/// 歌单条目 —— 对应 `.playlist-item`
class _PlaylistItem extends StatefulWidget {
  const _PlaylistItem({
    super.key,
    required this.song,
    required this.state,
    required this.onOpenLyric,
    required this.hoveredMid,
    this.dragIndex,
    this.forceHover = false,
    this.onGrab,
    this.dragging,
  });

  final Song song;
  final AppState state;
  final ValueChanged<String> onOpenLyric;

  /// 全页共用的「当前悬停行」（见 _PlaylistPageState._hoveredMid）。
  /// 每行自己订阅，只重建自己。
  final ValueNotifier<String?> hoveredMid;

  /// 这一行在**可拖动列表**里的下标；null = 拖不动。
  ///
  /// null 有两种情形：量行高的原型行，以及歌单内搜索过滤中的整张表
  /// （那会儿下标指的是过滤后的列表）。改名展开中也拖不动，见 build。
  final int? dragIndex;

  /// 拖动中那张卡片：强制按「悬停态」画（底色 + 铅笔），
  /// 这样拿起来的样子跟鼠标停在上面时**一模一样**。
  final bool forceHover;

  /// 按下时上报「哪一行、那张卡片的盒子、指针在哪」—— 拖动中自己画卡片要用
  final void Function(int index, RenderBox rowBox, Offset globalPos)? onGrab;

  /// 是否正在拖动。为真时**不响应悬停**：拖动中鼠标会掠过别的卡片，
  /// 那不是「选中」，那些行不该亮起来。
  final ValueListenable<bool>? dragging;


  @override
  State<_PlaylistItem> createState() => _PlaylistItemState();
}

class _PlaylistItemState extends State<_PlaylistItem> {
  bool _editingName = false;

  /// 本行是不是当前悬停行。
  ///
  /// 只在**本行的悬停态真的变了**时才 setState —— 别的行变化不关本行的事。
  bool _hovered = false;

  /// 这一次按下是不是落在铅笔上。
  ///
  /// 点铅笔时，输入框会**先**失焦（框架的 TapRegion 在按下那一刻就把
  /// 「点了外面」报过来），于是「失焦即提交」会先把编辑收起来，
  /// 紧接着 onTap 又把它展开 —— 表现成「点铅笔没反应」。
  /// 用这个标记把那次失焦让给铅笔的 onTap 去处理。
  bool _pencilPressed = false;

  /// 上一次量到的下划线长度。
  ///
  /// 收起动画要靠它：如果宽度跟着编辑态一起归零，线会在动画开始**之前**
  /// 就没了 —— 表现成「展开有动画、收起没动画」。
  double _lastLineWidth = 0;
  final TextEditingController _nameCtrl = TextEditingController();
  final FocusNode _nameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _hovered =
        widget.forceHover || widget.hoveredMid.value == widget.song.mid;
    widget.hoveredMid.addListener(_onHoverChanged);
    // 点到别处、或按 Tab 走掉，都当作「改完了」—— 就地编辑没有再放一个确定键。
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus && _editingName && mounted) _commitName();
    });
    // 下划线的长度跟着名字走，所以打字时要重建（只在编辑态，别的时候不监听）
    _nameCtrl.addListener(() {
      if (_editingName && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.hoveredMid.removeListener(_onHoverChanged);
    _nameCtrl.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  /// 全页的悬停行变了 —— 只有「本行是否悬停」真的翻转时才重建自己
  void _onHoverChanged() {
    if (!mounted || widget.forceHover) return;
    final now = widget.hoveredMid.value == widget.song.mid;
    if (now == _hovered) return;
    setState(() => _hovered = now);
  }

  /// 鼠标进出本行 —— 写回全页共用的那一个值
  void _setHover(bool inside) {
    if (widget.forceHover) return;
    if (widget.dragging?.value ?? false) return;
    if (inside) {
      widget.hoveredMid.value = widget.song.mid;
    } else if (widget.hoveredMid.value == widget.song.mid) {
      widget.hoveredMid.value = null;
    }
  }

  void _startEditName() {
    final wasEditing = _editingName;
    _pencilPressed = false;
    // 已经展开着 → 这一下是「收起」：改动照常保存，与点别处一致
    if (wasEditing) {
      _commitName();
      return;
    }
    _nameCtrl.text = widget.song.name;
    // 选中全部：改名多半是整体重写，不是改一两个字
    _nameCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _nameCtrl.text.length,
    );
    setState(() => _editingName = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocus.requestFocus();
    });
  }

  void _commitName() {
    if (!_editingName) return;
    final name = _nameCtrl.text.trim();
    setState(() => _editingName = false);
    // 清空或没动过就当没改，不写存储
    if (name.isEmpty || name == widget.song.name) return;
    widget.state.renameSong(widget.song.mid, name);
  }

  void _cancelEditName() => setState(() => _editingName = false);

  /// 右键菜单。
  ///
  /// 条目按用途分组：播放 / 取用 / 编辑，然后才是会改动歌单的那几项。
  /// 具体条目在 [buildSongMenuItems] 里，与搜索页共用。
  void _showMenu(Offset position) {
    final state = widget.state;
    final song = widget.song;

    // 二级菜单（行尾那个「+」）开着的时候，右键只负责把它关掉。
    // 不这么做的话，右键会在它上面再叠一个菜单，两个弹层同时挂着。
    if (state.openAddMenuMid != null) {
      state.setOpenAddMenu(null);
      return;
    }

    showAppContextMenu(
      context: context,
      position: position,
      items: buildSongMenuItems(
        context: context,
        state: state,
        song: song,
        onOpenLyric: widget.onOpenLyric,
        onEditName: _startEditName,
        inPlaylist: true,
      ),
    );
  }

  /// 量出这段文字渲染出来有多宽 —— 下划线要正好画到名字末尾。
  /// 名字比可用宽度还长时按可用宽度截断（跟 Text 的省略号表现对齐）。
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final song = widget.song;
    final state = widget.state;
    final checked = state.selectedMids.contains(song.mid);
    final isPlaying = player.currentSong?.mid == song.mid;

    Widget row = _HoverRow(
      onHover: _setHover,
      // 改名输入框展开时这两样都要让位：双击是「选中一个词」，
      // 右键是 Flutter 自带的文本菜单 —— 抢过来会变成播放 / 弹我们的菜单。
      onSecondary: _editingName ? null : _showMenu,
      // 双击整行开始播放（与卡片列表一致的直觉操作）
      onDoubleClick: _editingName ? null : () => state.playSong(song.mid),
      // 这里**不能用 AnimatedContainer**：
      // 鼠标从 A 划到 B 时，A 的颜色要 120ms 才淡出、B 同时淡入 ——
      // 这 120ms 里两行都是高亮态，看起来就是「两首歌同时选中」。
      // 搜索页的卡片用的是普通 Container（瞬间切换），所以那边没有这个问题。
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isPlaying ? c.accentLight : (_hovered ? c.hover : Colors.transparent),
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
        // 边框画在内容**之上**（foregroundDecoration），不能放进 decoration：
        // 放进去它会占掉上下各 1.5px 的内高，正在播的那一行内容就溢出 3px
        // （原型行不是播放态、没有边框，所以量行高时看不出来）。
        foregroundDecoration: isPlaying
            ? BoxDecoration(
                border: Border.all(color: c.accent, width: 1.5),
                borderRadius: BorderRadius.circular(c.radius),
              )
            : null,
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
                        child: LayoutBuilder(
                          builder: (ctx, cons) {
                            // 显示态与编辑态**用同一个 TextStyle**：点编辑时
                            // 只有下划线出现，字的粗细、大小、颜色都不动。
                            //
                            // 必须手动把 DefaultTextStyle 合进来：`Text` 会自动
                            // 合并它，而 `TextField` 的 style **不会** —— 少了
                            // 主题里的 fontFamily / fontFamilyFallback 之后，
                            // 整段都是假名或汉字时（全靠回退字体渲染）两边会
                            // 走不同的字体 metrics，行高差一点点，看起来就是
                            // 「点编辑后歌名上下跳一下」。
                            // 混进任意一个拉丁字符/空格就不会 —— 那时主字体
                            // 自己能渲染，两边行高都由它决定。
                            final nameStyle = DefaultTextStyle.of(context)
                                .style
                                .merge(TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: c.text,
                            ));
                            // 基线必须显式钉死，否则**整段都是假名或汉字**时，
                            // 显示态会比编辑态高 1px，进出编辑态就上下跳一下：
                            // 那种文本一个字都得靠回退字体（Microsoft YaHei）
                            // 渲染，`Text` 于是拿回退字体的 ascent 算基线，而
                            // `TextField` 是按主字体（Segoe UI）的模板算的。
                            // 混进任意拉丁字符或空格就不会 —— 主字体自己能渲染，
                            // 两边都按它算。
                            // 两边挂同一个 strut（都用主字体的 metrics）之后，
                            // 不管什么字符集基线都一致。
                            final nameStrut = StrutStyle.fromTextStyle(
                              nameStyle,
                              forceStrutHeight: true,
                            );
                            // 下划线只画到名字那么长（不是整行）。只有编辑中的
                            // 那一行需要量宽度，别的时候不测。
                            // 收起时沿用记住的那次宽度，让动画从「满」缩到 0。
                            final measured = _editingName
                                ? _measureTextWidth(_nameCtrl.text, nameStyle,
                                        cons.maxWidth)
                                : null;
                            if (measured != null) _lastLineWidth = measured;
                            final lineWidth = measured ?? _lastLineWidth;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _editingName
                                    ? CallbackShortcuts(
                                        // Esc 放弃修改，回到原来的名字
                                        bindings: {
                                          const SingleActivator(
                                            LogicalKeyboardKey.escape,
                                          ): _cancelEditName,
                                        },
                                        child: TextField(
                                          controller: _nameCtrl,
                                          focusNode: _nameFocus,
                                          style: nameStyle,
                                          strutStyle: nameStrut,
                                          cursorColor: c.accent,
                                          cursorWidth: 1.5,
                                          onSubmitted: (_) => _commitName(),
                                          // 点别处 → 提交收起。写在这里而不是
                                          // 靠焦点变化：这样能认出「点的是铅笔」
                                          // 并放行（否则那一跳会把编辑先收掉，
                                          // 铅笔的 onTap 又立刻展开）。
                                          onTapOutside: (_) {
                                            if (_pencilPressed) return;
                                            _commitName();
                                          },
                                          // 无边框、无内边距 —— 外观完全交给
                                          // 下面那条线，输入框本身不可见
                                          decoration: const InputDecoration(
                                            isCollapsed: true,
                                            border: InputBorder.none,
                                          ),
                                        ),
                                      )
                                    : Text(
                                        song.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: nameStyle,
                                        strutStyle: nameStrut,
                                      ),
                                // 下划线：宽度 = 名字宽度 × 动画进度。
                                // 展开时 0 → 满，视觉上是从左往右画出去；
                                // 收起时满 → 0，右端先收，看起来是从右往左消失。
                                // 打字引起的宽度变化不走动画（进度没变），
                                // 所以线是即时跟着字走的，不会拖尾。
                                TweenAnimationBuilder<double>(
                                  tween: Tween<double>(
                                    begin: 0,
                                    end: _editingName ? 1 : 0,
                                  ),
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeOutCubic,
                                  builder: (_, t, _) => Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: SizedBox(
                                      height: 1.5,
                                      width: lineWidth * t,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: c.accent,
                                          borderRadius:
                                              BorderRadius.circular(1),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 2),
                      // 铅笔只在鼠标停在这一行时出现（占着位，进出不会让名字
                      // 左右跳）。hover 时**只把铅笔本身变蓝**：不传 hoverBg
                      // 会拿到默认的圆角底，这里用全透明的同色顶掉。
                      IgnorePointer(
                        ignoring: !_hovered,
                        child: AnimatedOpacity(
                          opacity: _hovered ? 1 : 0,
                          duration: const Duration(milliseconds: 120),
                          child: Listener(
                            // 铅笔在命中链上比框架的 TapRegion 更靠里，先收到
                            // 按下事件 —— 靠这一点把「点的是铅笔」告诉输入框
                            onPointerDown: (_) => _pencilPressed = true,
                            onPointerCancel: (_) => _pencilPressed = false,
                            child: AppIconButton(
                              icon: AppIcons.edit,
                              size: 20,
                              iconSize: 12,
                              baseColor: c.textTertiary,
                              hoverColor: c.accent,
                              hoverBg: c.accent.withValues(alpha: 0),
                              tooltip: '重命名',
                              onTap: _startEditName,
                            ),
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

    // 长按整张卡片开始拖动（见 _CardDragStart）。
    //
    // 改名展开时只是**禁用**，不能把这一层摘掉：树一变形，下面那层
    // `TweenAnimationBuilder`（下划线）会连 State 一起重建，新 State 里
    // 「上次量到的宽度」是 0，收起就变成「啪」地归零。
    final dragIndex = widget.dragIndex;
    if (dragIndex == null) return row;
    return _CardDragStart(
      index: dragIndex,
      enabled: !_editingName,
      onGrab: widget.onGrab,
      child: row,
    );
  }
}

const double kCardDragSlop = 4;

/// 长按整张卡片开始拖动。
///
/// 不用框架的 `ReorderableDelayedDragStartListener`：
///
/// 1. 它是「长按 0.5 秒」才接管，鼠标上手感很钝（Windows 拖文件是按下就能拖）。
/// 2. 它用 `computeHitSlop` 判「指针有没有挪动」，**鼠标是 1 像素**（触屏 18px）——
///    按住期间挪两个像素手势就作废。
/// 3. 它的 `Listener` 是 `deferToChild`：卡片里真正空白的那些像素收不到按下。
class _CardDragStart extends StatelessWidget {
  const _CardDragStart({
    required this.index,
    required this.enabled,
    required this.onGrab,
    required this.child,
  });

  /// 这一行在**可拖动列表**里的下标
  final int index;

  /// 改名展开中关掉 —— 输入框自己的长按要留给「选词」。
  /// 见调用处的注释：只能传 false，不能把这一层从树上摘掉。
  final bool enabled;

  /// 按下时上报「哪一行、那张卡片的盒子、指针在哪」—— 拖动中要自己画卡片
  /// （见 [_PlaylistPageState._dragCardLayer]），靠它算抓手位置。
  final void Function(int index, RenderBox rowBox, Offset globalPos)? onGrab;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      // opaque：整张卡片的空白处也要收得到按下
      behavior: HitTestBehavior.opaque,
      onPointerDown: !enabled
          ? null
          : (event) {
              final box = context.findRenderObject();
              if (box is RenderBox) onGrab?.call(index, box, event.position);
              SliverReorderableList.maybeOf(context)?.startItemDragReorder(
                index: index,
                event: event,
                recognizer: _PressDrag(debugOwner: context)
                  ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context),
              );
            },
      child: child,
    );
  }
}

/// 拖动识别器：移动超过 [kCardDragSlop] 就开始拖。
///
/// 与框架的 `ImmediateMultiDragGestureRecognizer` 只差阈值 —— 那边鼠标是
/// `kPrecisePointerHitSlop`（1px），手指稍微一动就变成拖动，点按钮都会误触。
class _PressDrag extends ImmediateMultiDragGestureRecognizer {
  _PressDrag({super.debugOwner});

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _PressDragState(event.position, event.kind, gestureSettings);
}

class _PressDragState extends MultiDragPointerState {
  _PressDragState(super.initialPosition, super.kind, super.gestureSettings);

  @override
  void checkForResolutionAfterMove() {
    if (pendingDelta!.distance > kCardDragSlop) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) =>
      starter(initialPosition);
}

/// 歌单条目外面那一层：悬浮高亮 + 右键菜单 + 双击播放。
///
/// 单独拎出来是为了不改变里面那棵树的缩进 —— 直接在外面套一层
/// GestureDetector 会把整块 Container 往里推两级，diff 全是缩进。
class _HoverRow extends StatelessWidget {
  const _HoverRow({
    required this.onHover,
    required this.onSecondary,
    required this.onDoubleClick,
    required this.child,
  });

  final ValueChanged<bool> onHover;

  /// 右键按下的位置（全局坐标），用来定位菜单。为 null 时整行不响应右键。
  final ValueChanged<Offset>? onSecondary;

  /// 为 null 时整行不响应双击
  final VoidCallback? onDoubleClick;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: ClickRegion(
        onSecondaryClick: onSecondary,
        onDoubleClick: onDoubleClick,
        child: child,
      ),
    );
  }
}
