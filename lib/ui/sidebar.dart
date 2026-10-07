import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_theme.dart';
import '../core/motion.dart';
import '../models/playlist.dart';
import '../state/app_state.dart';
import '../state/toast.dart';
import 'dialogs/playlist_sync_dialog.dart';
import 'icons.dart';
import 'widgets/common.dart';
import 'widgets/context_menu.dart';
import 'widgets/fluent.dart';

class NavDef {
  final String page;
  final String icon;
  final String label;
  const NavDef(this.page, this.icon, this.label);
}

/// 导航项的左右外边距（官方 `NavigationViewItemButtonMargin` 的横向值）。
/// 选中底与指示条都要用它对齐 —— 别在两处各写一个 4。
const double _kItemMargin = 4;

const List<NavDef> kNavItems = [
  NavDef('search', AppIcons.search, '搜索'),
  // ⚠️ 歌单**不在**这个列表里：它现在是侧边栏里一个常驻的、可折叠的分组
  //（见 `_PlaylistGroup`），夹在「搜索」与「设置」之间。
  NavDef('settings', AppIcons.settings, '设置'),
  NavDef('about', AppIcons.info, '关于'),
];

/// 侧边栏 —— 对应 `.sidebar` / `.nav-item` / `.nav-badge`
///
/// 结构：搜索 / **歌单分组** / 设置 / 关于。歌单分组是常驻的，可以折叠
///（2026-09-29 改：以前是「点【歌单】导航项才伸出一排子项」，那种下拉式的
/// 观感不好，千奈明确要换成常驻分组 + 上下各一条淡分隔线）。
/// 窄侧边栏（compact）放不下名字，分组只留图标与那两条线。
class AppSidebar extends StatelessWidget {
  const AppSidebar({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final compact = constraints.maxWidth < 800;
        // 紧凑宽度 48 是官方的 `NavigationViewCompactPaneLength`；
        // 展开宽度 WinUI 只给上限（320），应用自定 —— 这里 200 够放歌单名。
        final width = compact ? 48.0 : 200.0;

        return Container(
          width: width,
          // 必须显式撑满高度：外层 Row 的 crossAxisAlignment 默认是 center，
          // 不给高度的话侧边栏会按内容高度**垂直居中**，背景只占中间一条，
          // 上下露出窗口底色 —— 看着就像一张被裁过的图贴在中间。
          height: double.infinity,
          decoration: BoxDecoration(
            // 官方的展开态 pane 是**完全透明**的（`SolidBackgroundFillColor-
            // Transparent`）：云母直接透上来，只靠一条分隔线跟内容区分。
            color: c.sidebarBg,
            border: Border(right: BorderSide(color: c.borderSubtle)),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 4 : 4,
            vertical: 8,
          ),
          child: SingleChildScrollView(
            child: Column(
              children: [
                // 搜索在最上，歌单分组夹在它与「设置 / 关于」之间
                _navItem(kNavItems.first, compact),
                _PlaylistGroup(state: state, compact: compact),
                for (final item in kNavItems.skip(1)) _navItem(item, compact),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _navItem(NavDef item, bool compact) {
    return _NavItem(
      item: item,
      active: state.page == item.page,
      compact: compact,
      badge: 0,
      onTap: () => state.navigate(item.page),
    );
  }
}

/// 「歌单」分组里那一排子项
class _PlaylistChildren extends StatelessWidget {
  const _PlaylistChildren({required this.state});

  final AppState state;

  /// 子列表的长度上限（约 7 条歌单），再多就在里面滚
  static const double _maxListHeight = 224;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 26, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 歌单多了不能把整个侧边栏撑长：这里给一个长度上限，超出的部分
          // 在**这一块里**滚。用的是普通 SingleChildScrollView ——
          // Flutter 的滚轮只会交给光标下最近的那个滚动区，所以滚它的时候
          // 外层侧边栏不会跟着动。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _maxListHeight),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in state.playlists)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: _PlaylistChild(
                        key: ValueKey('sidebar-playlist-${p.id}'),
                        playlist: p,
                        active: p.id == state.currentPlaylistId,
                        state: state,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 子项：歌单名 + 歌曲数。悬停出铅笔（就地改名），右键出菜单（重命名 / 删除）。
class _PlaylistChild extends StatefulWidget {
  const _PlaylistChild({
    super.key,
    required this.playlist,
    required this.active,
    required this.state,
  });

  final Playlist playlist;
  final bool active;
  final AppState state;

  @override
  State<_PlaylistChild> createState() => _PlaylistChildState();
}

class _PlaylistChildState extends State<_PlaylistChild> {
  bool _hovered = false;
  bool _editing = false;
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // 点到别处、或按 Tab 走掉，都当作「改完了」—— 就地编辑没有确定键
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing && mounted) _commit();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startEdit() {
    _ctrl.text = widget.playlist.name;
    _ctrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _ctrl.text.length,
    );
    setState(() => _editing = true);
    _focus.requestFocus();
  }

  void _commit() {
    final name = _ctrl.text;
    setState(() => _editing = false);
    widget.state.renamePlaylist(widget.playlist.id, name);
  }

  void _cancel() => setState(() => _editing = false);

  void _showMenu(Offset at) {
    showAppContextMenu(
      context: context,
      position: at,
      items: [
        AppMenuItem(label: '重命名', icon: AppIcons.edit, onTap: _startEdit),
        // 同步只认「音源 → 本地」这一个方向。机制（完全单向 / 增加单向 /
        // 兼容单向）**只在弹窗里选** —— 同一组选项在右键菜单里再摆一份，
        // 用户就得在两处维持同一个心智模型，还容易以为两处是两套配置。
        AppMenuItem(
          label: '同步设置',
          icon: AppIcons.refresh,
          dividerBefore: true,
          onTap: () =>
              showPlaylistSyncDialog(context, widget.state, widget.playlist.id),
        ),
        AppMenuItem(
          label: '删除歌单',
          icon: AppIcons.trash,
          danger: true,
          dividerBefore: true,
          enabled: widget.state.playlists.length > 1,
          onTap: () {
            if (widget.state.deletePlaylist(widget.playlist.id)) {
              toast.show('已删除「${widget.playlist.name}」', type: ToastType.info);
            }
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final active = widget.active;
    // 选中 / 悬浮都用**文字**表达（跟设置页那四个分栏同一套）：
    // 选中 = 主色（1 级，最亮），悬浮 = 主文字色（2 级），其余 = 次要文字色。
    // 不给整行上底色 —— 一行行都亮一块的话，这个分组会花得看不出层次。
    final fg = active ? c.accent : (_hovered ? c.text : c.textSecondary);

    // 前置封面用「置底」那一首的封面（空歌单、或那首没有封面 → 回退成图标）
    final lastSong = widget.playlist.songs.isNotEmpty
        ? widget.playlist.songs.last
        : null;
    final coverPic = (lastSong?.coverPic ?? '').isEmpty
        ? null
        : lastSong!.coverPic;

    // 显示态与编辑态**共用同一个 TextStyle + 同一个 strut**。
    //
    // `Text` 会自动把 DefaultTextStyle 合进来（于是拿到主题里的字体栈），
    // `TextField` 的 style 不会 —— 整段都是汉字、只能靠回退字体渲染时，
    // 两边算基线用的字体不同，进出编辑态字就上下跳 1px（歌名那一处踩过
    // 同一个坑，修法一样：style 手动合并、两边挂同一个 strut）。
    final labelStyle = DefaultTextStyle.of(
      context,
    ).style.merge(TextStyle(fontSize: 13.5, color: fg));
    final labelStrut = StrutStyle.fromTextStyle(
      labelStyle,
      forceStrutHeight: true,
    );

    final label = _editing
        ? TextField(
            controller: _ctrl,
            focusNode: _focus,
            style: labelStyle,
            strutStyle: labelStrut,
            cursorColor: c.accent,
            cursorWidth: 1.5,
            onSubmitted: (_) => _commit(),
            // 无边框、无内边距 —— 外观完全交给下面那条线，输入框本身不可见
            decoration: const InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          )
        : Text(
            widget.playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: labelStyle,
            strutStyle: labelStrut,
          );

    final row = Container(
      height: 32,
      padding: const EdgeInsets.only(left: 6, right: 4),
      // 不给底色：选中与悬浮都由上面的文字色表达（见 fg 的说明）。
      child: Row(
        children: [
          // 前置封面：取该歌单**最下面那一首**的封面（「置底」，跟原版一致）。
          // 空歌单没有封面，给一块同宽的占位图标 —— 免得那几行文字左右跳。
          SizedBox(
            width: 24,
            child: Center(
              child: coverPic == null
                  ? AppIcon(AppIcons.music, size: 14, color: c.textTertiary)
                  : SongCover(pic: coverPic, size: 20, radius: 4),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: CallbackShortcuts(
              // Esc 放弃修改，回到原来的名字
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): _cancel,
              },
              child: label,
            ),
          ),
          if (_editing)
            const SizedBox.shrink()
          else if (_hovered)
            // 铅笔：无边框仅图标，跟歌单行里那个是同一套
            AppIconButton(
              icon: AppIcons.edit,
              size: 20,
              iconSize: 12,
              baseColor: c.textTertiary,
              hoverColor: c.accent,
              hoverBg: c.accent.withValues(alpha: 0),
              tooltip: '重命名',
              onTap: _startEdit,
            )
          else
            Text(
              '${widget.playlist.songs.length}',
              style: TextStyle(
                fontSize: 11,
                color: c.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );

    // 改名时下面那条线跟着名字走 —— 与歌名编辑同一套观感
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: _editing ? 1 : 0),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          builder: (ctx, t, _) => FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: t,
            child: Container(height: 1.5, color: c.accent),
          ),
        ),
      ],
    );

    return ClickRegion(
      onSecondaryClick: _editing ? null : _showMenu,
      child: MouseRegion(
        cursor: _editing ? SystemMouseCursors.text : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          // 同 _NavItem：让命中区跟悬浮区一致（能悬浮就能点）
          behavior: HitTestBehavior.opaque,
          onTap: _editing
              ? null
              : () {
                  // 换歌单 + **进歌单页**：以前进歌单页靠那个【歌单】导航项，
                  // 现在导航项没了（分组常驻），点歌单行就得自己把页面带过去
                  // —— 少了这一句，点了没反应、界面停在原地。
                  widget.state.switchPlaylist(widget.playlist.id);
                  widget.state.navigate('playlist');
                },
          child: body,
        ),
      ),
    );
  }
}

/// 子列表最下方固定的一项
/// 侧边栏里的「歌单」分组：一条淡线 + 标题行（带折叠箭头与新建）+ 歌单列表 + 一条淡线。
///
/// 千奈特意强调那两条线**必须有**：分组跟上下两个导航按钮挨在一起时，光靠间距
/// 会显得挤、像一坨；加一条很淡的分隔线，才读得出「这是一组」。
class _PlaylistGroup extends StatelessWidget {
  const _PlaylistGroup({required this.state, required this.compact});

  final AppState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _GroupDivider(),
        _PlaylistHeader(state: state, compact: compact),
        if (!compact)
          // 展开/收起要有动画：直接 if 掉的话是「啪」地跳出来。
          // 收起时给一个零高度的占位，AnimatedSize 才有东西可以量。
          AnimatedSize(
            duration: Motion.controlNormal,
            curve: Motion.decelerate,
            alignment: Alignment.topCenter,
            child: state.playlistsExpanded
                ? _PlaylistChildren(state: state)
                : const SizedBox(width: double.infinity),
          ),
        const _GroupDivider(),
      ],
    );
  }
}

/// 分组上下那条很淡的分隔线。
class _GroupDivider extends StatelessWidget {
  const _GroupDivider();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Container(height: 1, color: context.c.borderSubtle),
      );
}

/// 分组标题行：`[图标] 歌单 [折叠箭头] … [＋]`。
///
/// 整行是**折叠开关**（跟参考样式里那种分组标题一致）；右边的 `＋` 是新建歌单，
/// 它有自己的一层手势，点它不会连带把分组收起来。
class _PlaylistHeader extends StatefulWidget {
  const _PlaylistHeader({required this.state, required this.compact});

  final AppState state;
  final bool compact;

  @override
  State<_PlaylistHeader> createState() => _PlaylistHeaderState();
}

class _PlaylistHeaderState extends State<_PlaylistHeader> {
  bool _hovered = false;
  bool _pressed = false;
  bool _plusHovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final compact = widget.compact;
    final state = widget.state;
    final active = state.page == 'playlist';
    final fg = active ? c.text : (_hovered ? c.text : c.textSecondary);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          setState(() => _pressed = false);
          state.togglePlaylistsExpanded();
        },
        child: Container(
          height: 36,
          margin: const EdgeInsets.symmetric(
            horizontal: _kItemMargin,
            vertical: 2,
          ),
          padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
          decoration: BoxDecoration(
            color: stateFill(
              c,
              hovered: _hovered,
              pressed: _pressed,
              selected: active,
            ),
            borderRadius: BorderRadius.circular(c.radius),
          ),
          child: Row(
            mainAxisAlignment: compact
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              AppIcon(AppIcons.playlist, size: 16, color: fg),
              if (!compact) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '歌单',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: fg,
                    ),
                  ),
                ),
                // 折叠箭头：展开时转半圈 —— 状态变了要看得出来，不能只是「有/没有」
                AnimatedRotation(
                  turns: state.playlistsExpanded ? 0.5 : 0,
                  duration: Motion.controlFast,
                  curve: Motion.decelerate,
                  child: AppIcon(
                    AppIcons.chevronDown,
                    size: 12,
                    color: c.textTertiary,
                  ),
                ),
                const SizedBox(width: 2),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => setState(() => _plusHovered = true),
                  onExit: (_) => setState(() => _plusHovered = false),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      final p = state.createPlaylist();
                      state.switchPlaylist(p.id);
                      toast.show('已新建「${p.name}」', type: ToastType.success);
                    },
                    child: SizedBox(
                      key: const Key('sidebar-new-playlist'),
                      width: 24,
                      height: 24,
                      child: Center(
                        child: AppIcon(
                          AppIcons.plus,
                          size: 13,
                          color: _plusHovered ? c.accent : c.textTertiary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.item,
    required this.active,
    required this.compact,
    required this.badge,
    required this.onTap,
  });

  final NavDef item;
  final bool active;
  final bool compact;
  final int badge;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final active = widget.active;
    // WinUI 的 NavigationView：选中项**不是**主色文字，而是
    // `TextFillColorPrimary`（主文字色）+ `SubtleFillColorSecondary` 底，
    // 「我在这一页」这件事由左边那道主色指示条表达。
    final fg = active ? c.text : (_hovered ? c.text : c.textSecondary);
    final bg = stateFill(
      c,
      hovered: _hovered,
      pressed: _pressed,
      selected: active,
    );

    Widget row = Container(
      // `NavigationViewItemOnLeftMinHeight` = 36
      height: 36,
      margin: const EdgeInsets.symmetric(horizontal: _kItemMargin, vertical: 2),
      padding: EdgeInsets.symmetric(horizontal: widget.compact ? 0 : 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(c.radius),
      ),
      child: Row(
        mainAxisAlignment: widget.compact
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        children: [
          AppIcon(widget.item.icon, size: 16, color: fg),
          if (!widget.compact) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.item.label,
                style: TextStyle(
                  // 正文档 14 —— 选中项**不加粗**（官方只换颜色，字重恒定）
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: fg,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.badge > 0)
              Container(
                constraints: const BoxConstraints(minWidth: 20),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: c.badgeBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${widget.badge}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: c.badgeText,
                  ),
                ),
              ),
          ],
        ],
      ),
    );

    // 激活态指示条：官方左侧模式是 **3×16、圆角 2**。
    // 位置贴着**选中那一项自己的左边缘**（也就是那一圈 4px 外边距之内），
    // 看起来是「长在选项卡里侧」；挂在导航栏边缘的话离选项卡还有一截，
    // 观感是「外面飘着一根线」（千奈真机看出来的）。
    if (active) {
      row = Stack(
        alignment: Alignment.centerLeft,
        children: [
          row,
          const Positioned(left: _kItemMargin, child: _NavIndicator()),
        ],
      );
    }

    return FluentFocus(
      radius: c.radius,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          // ⚠️ `opaque`：里面那层 Container 带 4px 外边距，默认的
          // `deferToChild` 会把这圈边距排除在命中区之外 ——
          // 于是「划过去会高亮、点下去却没反应」。能悬浮就得能点。
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: row,
        ),
      ),
    );
  }
}

/// 导航选中指示条 —— 3×16、圆角 2、主色。
///
/// ⚠️ **不要给它套补间**（`TweenAnimationBuilder` / `AnimatedContainer`）：
/// 侧边栏每次重建（切页、改歌单都会）都会新建一个 tween，动画从 0 重跑一遍
/// —— 表现就是「每切一次页，指示条闪一下」。官方那条指示条是从一个条目
/// **滑**到另一个条目的，那需要把它做成跨条目共用的一个实例；
/// 现在是每条各自画一根，所以老老实实静态画。
class _NavIndicator extends StatelessWidget {
  const _NavIndicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: 16,
      decoration: BoxDecoration(
        color: context.c.accent,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
