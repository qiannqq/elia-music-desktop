import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_theme.dart';
import '../models/playlist.dart';
import '../state/app_state.dart';
import '../state/toast.dart';
import 'icons.dart';
import 'widgets/common.dart';
import 'widgets/context_menu.dart';

class NavDef {
  final String page;
  final String icon;
  final String label;
  const NavDef(this.page, this.icon, this.label);
}

const List<NavDef> kNavItems = [
  NavDef('search', AppIcons.search, '搜索'),
  NavDef('playlist', AppIcons.playlist, '歌单'),
  NavDef('settings', AppIcons.settings, '设置'),
  NavDef('about', AppIcons.info, '关于'),
];

/// 侧边栏 —— 对应 `.sidebar` / `.nav-item` / `.nav-badge`
///
/// 「歌单」下面会延伸出一排子项（每个歌单一条，最下方固定是「新建歌单」）。
/// 窄侧边栏（compact）放不下名字，子项就不展开 —— 那里面塞文字只会挤成一团。
class AppSidebar extends StatelessWidget {
  const AppSidebar({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final compact = constraints.maxWidth < 800;
        final width = compact ? 56.0 : 200.0;

        return Container(
          width: width,
          // 必须显式撑满高度：外层 Row 的 crossAxisAlignment 默认是 center，
          // 不给高度的话侧边栏会按内容高度**垂直居中**，背景只占中间一条，
          // 上下露出窗口底色 —— 看着就像一张被裁过的图贴在中间。
          height: double.infinity,
          decoration: BoxDecoration(
            color: c.sidebarBg,
            border: Border(right: BorderSide(color: c.borderSubtle)),
          ),
          padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 8, vertical: 8),
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final item in kNavItems) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: _NavItem(
                      item: item,
                      active: state.page == item.page,
                      compact: compact,
                      badge: item.page == 'playlist' ? state.songs.length : 0,
                      onTap: () {
                        if (item.page != 'playlist') {
                          state.navigate(item.page);
                          return;
                        }
                        // 已经在歌单页了：这一下就是「收起 / 展开子列表」。
                        // 从别的页面过来时 navigate 自己会展开，不用再补一下。
                        if (state.page == 'playlist') {
                          state.togglePlaylistsExpanded();
                        } else {
                          state.navigate(item.page);
                        }
                      },
                    ),
                  ),
                  if (item.page == 'playlist' && !compact)
                    // 展开/收起要有动画：直接 if 掉的话是「啪」地跳出来。
                    // 收起时给一个零高度的占位，AnimatedSize 才有东西可以量。
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: state.playlistsExpanded
                          ? _PlaylistChildren(state: state)
                          : const SizedBox(width: double.infinity),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 「歌单」下面的那一排子项
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
          // 【新建歌单】放在滚动区**外面**：歌单再多它也得露在最下面
          _NewPlaylistButton(state: state),
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
        AppMenuItem(
          label: '重命名',
          icon: AppIcons.edit,
          onTap: _startEdit,
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
    final fg = active ? c.accent : (_hovered ? c.text : c.textSecondary);

    // 显示态与编辑态**共用同一个 TextStyle + 同一个 strut**。
    //
    // `Text` 会自动把 DefaultTextStyle 合进来（于是拿到主题里的字体栈），
    // `TextField` 的 style 不会 —— 整段都是汉字、只能靠回退字体渲染时，
    // 两边算基线用的字体不同，进出编辑态字就上下跳 1px（歌名那一处踩过
    // 同一个坑，修法一样：style 手动合并、两边挂同一个 strut）。
    final labelStyle = DefaultTextStyle.of(context).style.merge(TextStyle(
      fontSize: 12.5,
      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
      color: fg,
    ));
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
      height: 30,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: active
            ? c.accentLight
            : (_hovered ? c.hover : c.hover.withValues(alpha: 0)),
        borderRadius: BorderRadius.circular(c.radius),
      ),
      child: Row(
        children: [
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
          onTap: _editing ? null : () => widget.state.switchPlaylist(widget.playlist.id),
          child: body,
        ),
      ),
    );
  }
}

/// 子列表最下方固定的一项
class _NewPlaylistButton extends StatefulWidget {
  const _NewPlaylistButton({required this.state});

  final AppState state;

  @override
  State<_NewPlaylistButton> createState() => _NewPlaylistButtonState();
}

class _NewPlaylistButtonState extends State<_NewPlaylistButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () {
          final p = widget.state.createPlaylist();
          widget.state.switchPlaylist(p.id);
          toast.show('已新建「${p.name}」', type: ToastType.success);
        },
        child: Container(
          height: 30,
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: BoxDecoration(
            color: _hovered ? c.hover : c.hover.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(c.radius),
          ),
          child: Row(
            children: [
              AppIcon(
                AppIcons.plus,
                size: 13,
                color: _hovered ? c.accent : c.textTertiary,
              ),
              const SizedBox(width: 7),
              Text(
                '新建歌单',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: _hovered ? c.accent : c.textTertiary,
                ),
              ),
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

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final active = widget.active;
    final fg = active ? c.accent : (_hovered ? c.text : c.textSecondary);
    final bg = active
        ? c.accentLight
        : (_hovered ? c.hover : c.hover.withValues(alpha: 0));

    Widget row = Container(
      height: 38,
      padding: EdgeInsets.symmetric(horizontal: widget.compact ? 0 : 14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(c.radius),
      ),
      child: Row(
        mainAxisAlignment: widget.compact ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          AppIcon(widget.item.icon, size: 18, color: fg),
          if (!widget.compact) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.item.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
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
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: c.badgeText,
                  ),
                ),
              ),
          ],
        ],
      ),
    );

    // 激活态左侧 3×16 指示条
    if (active && !widget.compact) {
      row = Stack(
        alignment: Alignment.centerLeft,
        children: [
          row,
          Positioned(
            left: 0,
            child: Container(
              width: 3,
              height: 16,
              decoration: BoxDecoration(
                color: c.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(onTap: widget.onTap, child: row),
    );
  }
}
