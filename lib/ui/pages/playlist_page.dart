import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  ///
  /// 用 ValueNotifier 而不是 `setState`：原先悬浮一变就重建**整个页面**
  /// （含整张 ListView 与所有可见行）。快速滚动时鼠标不断划过新行，
  /// 等于每划过一行就重建一次列表。改成每行自己订阅，只有真正变了的那行重建。
  final ValueNotifier<String?> _hoveredMid = ValueNotifier<String?>(null);

  /// 挂在 `prototypeItem` 上，用来量真实行高。
  /// 「定位到正在播放」要按行高算目标位置，手写公式字体一缩放就偏。
  final GlobalKey _prototypeKey = GlobalKey();

  double get _rowHeight => _prototypeKey.currentContext?.size?.height ?? 0;

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
  void dispose() {
    _hoveredMid.dispose();
    super.dispose();
  }

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
                    // 必须让列表知道行高。
                    //
                    // 没有它时，`RenderSliverList` 无从由偏移反推行号，
                    // 只能从第 0 行逐行往下量 —— 切页回来恢复滚动位置那一次
                    // `jumpTo`，几百首就要在一帧里建出几百行（实测 376 首
                    // 建 345 行，还只是空行）。
                    //
                    // 用真实的一行当原型（它只被量高度，不参与绘制），
                    // 字体、文字缩放怎么变都自动跟上，不必手写行高公式。
                    prototypeItem: _PlaylistItem(
                      key: _prototypeKey,
                      song: const Song(mid: '', name: '歌名', artist: '歌手'),
                      state: state,
                      onOpenLyric: widget.onOpenLyric,
                      hoveredMid: _hoveredMid,
                    ),
                    itemBuilder: (ctx, i) {
                      // 在这里就把 mid 取出来捕获进闭包。
                      // 若闭包里写 songs[i].mid，`i` 是回调触发时才求值的 ——
                      // 列表一变（增删/拖拽/换序）就会取到别的歌，
                      // 导致「上一行的高亮清不掉、两行同时高亮」。
                      final mid = songs[i].mid;
                      return _PlaylistItem(
                        // 稳定 key（按 mid）：
                        // 「添加到歌单顶部」会让歌曲换位置，若按索引复用 State，
                        // 展开中的「+」二级菜单状态会跳到别的卡片上、
                        // 收起动画被打断 —— 表现为「二级菜单突兀消失」。
                        key: ValueKey(mid),
                        song: songs[i],
                        state: state,
                        onOpenLyric: widget.onOpenLyric,
                        hoveredMid: _hoveredMid,
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
    required this.hoveredMid,
  });

  final Song song;
  final AppState state;
  final ValueChanged<String> onOpenLyric;

  /// 全页共用的「当前悬停行」（见 _PlaylistPageState._hoveredMid）。
  /// 每行自己订阅，只重建自己。
  final ValueNotifier<String?> hoveredMid;

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
    _hovered = widget.hoveredMid.value == widget.song.mid;
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
    if (!mounted) return;
    final now = widget.hoveredMid.value == widget.song.mid;
    if (now == _hovered) return;
    setState(() => _hovered = now);
  }

  /// 鼠标进出本行 —— 写回全页共用的那一个值
  void _setHover(bool inside) {
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
  double _measureNameWidth(String text, TextStyle style, double maxWidth) {
    final painter = TextPainter(
      // 空串量出来是 0，给个空格免得线完全不见（此时光标还闪在开头）
      text: TextSpan(text: text.isEmpty ? ' ' : text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter.width.clamp(0.0, maxWidth);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final song = widget.song;
    final state = widget.state;
    final checked = state.selectedMids.contains(song.mid);
    final isPlaying = player.currentSong?.mid == song.mid;

    return _HoverRow(
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
                                ? _measureNameWidth(_nameCtrl.text, nameStyle,
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
  }
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
