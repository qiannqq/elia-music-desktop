import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../icons.dart';

/// 右键菜单里的一项
class AppMenuItem {
  const AppMenuItem({
    required this.label,
    required this.icon,
    this.onTap,
    this.children,
    this.danger = false,
    this.dividerBefore = false,
    this.checked = false,
    this.iconWidget,
    this.enabled = true,
  });

  final String label;

  /// 图标（`AppIcons` 里的 SVG 路径数据）。每一项都有，位置也固定，
  /// 免得文字左右参差。
  final String icon;

  /// 点这一项做什么。**有子项时可以为空**（那一项只负责展开子菜单）。
  final VoidCallback? onTap;

  /// 二级子菜单。非空时这一项变成「父项」：行尾带箭头，悬停/点击展开子菜单
  /// —— 像 Windows 的右键菜单那样。
  final List<AppMenuItem>? children;

  /// 直接给一个图标控件（比如音源那三张品牌图）。
  /// 传了它就用它，否则用 [icon] 里的内置图形。
  final Widget? iconWidget;

  bool get hasChildren => children != null && children!.isNotEmpty;

  /// 破坏性操作（移除之类）用警示色
  final bool danger;

  /// 在这一项之前画一条分隔线
  final bool dividerBefore;

  /// 当前生效的那一项 —— 行尾打勾（播放模式这类「多选一」的菜单用）
  final bool checked;

  /// 禁用项：置灰、不响应悬停与点击。比如「正在播的那首」不能再「插入到下一首」。
  final bool enabled;
}

/// 菜单项高度与宽度，按 WinUI 的 `MenuFlyout`：
/// 条目 **32**、菜单本体左右各留 4 的边距（官方 `MenuFlyoutPresenter` 的内边距）。
const double _kItemHeight = 32;
const double _kMenuWidth = 184;
const double _kDividerHeight = 9;

/// 在 [position] 处弹出右键菜单。
///
/// 卡片、圆角、hover 都沿用「+」二级菜单那一套，只是更快（130ms）——
/// 右键菜单要跟手，250ms 会显得黏。
///
/// [above] 为真时菜单向上长（[position] 是锚点的**顶边**）—— 贴着窗口
/// 底部的入口（播放栏的播放模式）只能往上弹。
///
/// 点外面、按 Esc、或选中任意一项之后收起。
Future<void> showAppContextMenu({
  required BuildContext context,
  required Offset position,
  required List<AppMenuItem> items,
  bool above = false,
}) {
  if (items.isEmpty) return Future<void>.value();
  final overlay = Overlay.of(context, rootOverlay: true);
  final completer = Completer<void>();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _MenuLayer(
      position: position,
      items: items,
      above: above,
      onClosed: () {
        entry.remove();
        if (!completer.isCompleted) completer.complete();
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _MenuLayer extends StatefulWidget {
  const _MenuLayer({
    required this.position,
    required this.items,
    required this.above,
    required this.onClosed,
  });

  final Offset position;
  final List<AppMenuItem> items;
  final bool above;
  final VoidCallback onClosed;

  @override
  State<_MenuLayer> createState() => _MenuLayerState();
}

class _MenuLayerState extends State<_MenuLayer> {
  bool _closing = false;

  /// 哪一个父项的子菜单开着（null = 都没开）
  int? _subIndex;

  /// 悬停一小会儿再展开 —— 鼠标从菜单上划过去时不该到处闪子菜单
  Timer? _openTimer;

  /// 从菜单/子菜单上移开后的一点宽限：够鼠标从父项挪到旁边的子菜单上
  Timer? _closeTimer;

  static const Duration _hoverOpenDelay = Duration(milliseconds: 180);
  static const Duration _leaveGrace = Duration(milliseconds: 160);

  /// 卡片内边距（上下各 6）
  static const double _padY = 6;

  @override
  void dispose() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    super.dispose();
  }

  void _close() {
    if (_closing) return;
    _openTimer?.cancel();
    _closeTimer?.cancel();
    setState(() => _closing = true);
  }

  /// Esc：子菜单开着就先收子菜单，再按一次才收整个菜单
  void _onEscape() {
    if (_subIndex != null) {
      _toggleSub(null);
      return;
    }
    _close();
  }

  /// 悬停父项 → 稍等一下就展开
  void _hoverItem(int i) {
    _closeTimer?.cancel();
    final item = widget.items[i];
    if (!item.hasChildren) {
      _openTimer?.cancel();
      if (_subIndex != null) setState(() => _subIndex = null);
      return;
    }
    if (_subIndex == i) {
      _openTimer?.cancel();
      return;
    }
    _openTimer?.cancel();
    _openTimer = Timer(_hoverOpenDelay, () {
      if (mounted) setState(() => _subIndex = i);
    });
  }

  /// 鼠标移开卡片：给一点宽限，进到子菜单上就会取消
  void _leaveCards() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _closeTimer = Timer(_leaveGrace, () {
      if (mounted) setState(() => _subIndex = null);
    });
  }

  void _enterCards() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
  }

  /// 点父项：开/关它的子菜单（不关整个菜单）
  void _toggleSub(int? i) {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    setState(() => _subIndex = _subIndex == i ? null : i);
  }

  /// 一组菜单项有多高（含卡片上下内边距）
  static double _menuHeight(List<AppMenuItem> items) => items.fold<double>(
        12,
        (sum, it) => sum + _kItemHeight + (it.dividerBefore ? _kDividerHeight : 0),
      );

  /// 第 [index] 项在自己卡片内的顶边（就是渲染时的实际排版结果）
  double _itemTop(List<AppMenuItem> items, int index) {
    var y = _padY;
    for (var i = 0; i < index; i++) {
      y += _kItemHeight;
      if (items[i].dividerBefore) y += _kDividerHeight;
    }
    return y;
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final items = widget.items;
    final height = _menuHeight(items);

    var left = widget.position.dx;
    var top = widget.position.dy;
    // 向上长：position.dy 是锚点顶边，菜单底边贴在它上面（留 6 的缝）
    if (widget.above) top -= height + 6;
    // 贴边就往回收，别让菜单跑出屏幕
    if (left + _kMenuWidth > screen.width - 8) left = screen.width - 8 - _kMenuWidth;
    if (top + height > screen.height - 8) top = screen.height - 8 - height;
    if (left < 8) left = 8;
    if (top < 8) top = 8;

    // 子菜单的位置：贴在父项右边；右边放不下就翻到左边。
    // 位置是**算**出来的（不是量出来的）：菜单的排版是各固定高度堆叠，
    // 所以父项在卡片内的偏移可以精确算 —— 省掉一层 GlobalKey + postFrame。
    Widget? submenu;
    final subIdx = _subIndex;
    if (subIdx != null && subIdx < items.length && items[subIdx].hasChildren) {
      final subItems = items[subIdx].children!;
      final subHeight = _menuHeight(subItems);
      var subLeft = left + _kMenuWidth;
      if (subLeft + _kMenuWidth > screen.width - 8) {
        subLeft = left - _kMenuWidth - 2;
      }
      // -_padY：让子菜单第一项和父项对齐（两张卡片都有 6 的上内边距）
      var subTop = top + _itemTop(items, subIdx) - _padY;
      if (subTop + subHeight > screen.height - 8) {
        subTop = screen.height - 8 - subHeight;
      }
      if (subTop < 8) subTop = 8;
      submenu = Positioned(
        left: subLeft < 8 ? 8 : subLeft,
        top: subTop,
        child: MouseRegion(
          onEnter: (_) => _enterCards(),
          onExit: (_) => _leaveCards(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            onSecondaryTapDown: (_) => _close(),
            child: _MenuCard(
              items: subItems,
              closing: _closing,
              onActivated: (child) {
                _close();
                child.onTap?.call();
              },
            ),
          ),
        ),
      );
    }

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _onEscape},
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            // 点外面关掉。
            //
            // 必须是 **opaque**，而且右键用 `onSecondaryTapDown`（按下就收）：
            // 之前是 translucent + `onSecondaryTap`（抬手才收），按下的那一刻
            // 事件会**穿透**到下面的行，行又弹出一个新菜单 ——
            // 表现为「菜单开着时再点右键，又展开一次」。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                onSecondaryTapDown: (_) => _close(),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              // 菜单自己也吃掉点击：落在留白 / 分隔线上的那一下不该把菜单关掉。
              // 但**右键例外** —— 菜单就在光标底下弹出，用户「再点一次右键」
              // 多半正落在它身上，那一下必须把它收起来（而不是毫无反应）。
              child: MouseRegion(
                onEnter: (_) => _enterCards(),
                onExit: (_) => _leaveCards(),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  onSecondaryTapDown: (_) => _close(),
                  child: _MenuCard(
                    items: items,
                    closing: _closing,
                    onClosed: widget.onClosed,
                    subIndex: _subIndex,
                    onHoverItem: _hoverItem,
                    onToggleSub: _toggleSub,
                    onActivated: (item) {
                      _close();
                      item.onTap?.call();
                    },
                  ),
                ),
              ),
            ),
            ?submenu,
          ],
        ),
      ),
    );
  }
}

/// 一张菜单卡片（主菜单和子菜单共用同一套外观与动画）
class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.items,
    required this.closing,
    required this.onActivated,
    this.onClosed,
    this.subIndex,
    this.onHoverItem,
    this.onToggleSub,
  });

  final List<AppMenuItem> items;
  final bool closing;
  final ValueChanged<AppMenuItem> onActivated;

  /// 收起动画播完的回调（只有主菜单要）
  final VoidCallback? onClosed;

  /// 当前展开的子菜单是哪一项（只有主菜单传）
  final int? subIndex;
  final ValueChanged<int>? onHoverItem;
  final ValueChanged<int?>? onToggleSub;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: closing ? 0.0 : 1.0),
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOutCubic,
      onEnd: () {
        if (closing) onClosed?.call();
      },
      builder: (ctx, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.94 + 0.06 * t,
          alignment: Alignment.topLeft,
          child: child,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          width: _kMenuWidth,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          decoration: BoxDecoration(
            // WinUI 的飞出层是**亚克力**；透明效果关掉时官方的兜底就是
            // `SolidBackgroundFillColorTertiary`（浅 #F9F9F9 / 深 #282828）——
            // 我们用的就是这份兜底色。真亚克力要窗口本身能透出背景，
            // 而 Flutter 的视图是不透明的：系统的 backdrop 画在顶层窗口背后，
            // 永远透不出来（见 `windows/runner/window_fx.cpp` 的说明）。
            color: c.flyoutBg,
            border: Border.all(color: c.flyoutBorder),
            // 弹层圆角走 `OverlayCornerRadius` = 8
            borderRadius: BorderRadius.circular(c.radiusLg),
            boxShadow: c.elevation16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (items[i].dividerBefore)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Container(height: 1, color: c.borderSubtle),
                  ),
                _MenuItem(
                  label: items[i].label,
                  icon: items[i].icon,
                  iconWidget: items[i].iconWidget,
                  danger: items[i].danger,
                  checked: items[i].checked,
                  enabled: items[i].enabled,
                  hasChildren: items[i].hasChildren,
                  expanded: subIndex == i,
                  onHover: onHoverItem == null ? null : () => onHoverItem!(i),
                  onTap: () {
                    if (items[i].hasChildren) {
                      // 父项：只开合子菜单，不关整个菜单
                      onToggleSub?.call(i);
                      return;
                    }
                    onActivated(items[i]);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuItem extends StatefulWidget {
  const _MenuItem({
    required this.label,
    required this.icon,
    required this.iconWidget,
    required this.danger,
    required this.checked,
    required this.enabled,
    required this.onTap,
    this.hasChildren = false,
    this.expanded = false,
    this.onHover,
  });

  final String label;
  final String icon;

  /// 直接给一个图标控件（比如音源那三张品牌图）
  final Widget? iconWidget;

  final bool danger;
  final bool checked;
  final bool enabled;
  final VoidCallback onTap;

  /// 有子菜单：行尾画箭头（而不是打勾）
  final bool hasChildren;

  /// 子菜单开着：这一项保持高亮，别因为鼠标移进子菜单就灭掉
  final bool expanded;

  final VoidCallback? onHover;

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final on = widget.enabled;
    // 危险项 hover 也用红的：跟着主色变蓝的话，「移除」看着就不危险了。
    // 普通项的悬停是 `SubtleFillColorSecondary`（WinUI 的菜单项悬停就是这档
    // 灰底，不是主色淡底）。
    final hoverBg = widget.danger
        ? c.danger.withValues(alpha: 0.12)
        : c.hover;
    // 禁用项一律用三级文字色，且不跟着悬停变色 —— 灰着就得一直是灰的
    final fg = !on
        ? c.textDisabled
        : (widget.danger ? c.danger : c.text);

    final hot = on && (_hovered || widget.expanded);

    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (on) setState(() => _hovered = true);
        widget.onHover?.call();
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: on ? widget.onTap : null,
        child: Container(
          height: _kItemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: hot ? hoverBg : c.hover.withValues(alpha: 0),
            // 菜单项自己的圆角是**控件档 4**（弹层才是 8）
            borderRadius: BorderRadius.circular(c.radius),
          ),
          child: Row(
            children: [
              if (widget.iconWidget != null)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: Center(child: widget.iconWidget),
                )
              else
                AppIcon(widget.icon, size: 16, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    // 菜单项文字是 Body 档（14 / 常规字重）
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: fg,
                  ),
                ),
              ),
              // 勾跟着主色走，危险项（不会有勾）不受影响
              if (widget.checked)
                AppIcon(
                  AppIcons.check,
                  size: 13,
                  color: widget.danger ? c.danger : c.accent,
                  strokeWidth: 2.5,
                ),
              // 有子菜单的行尾是箭头 —— 用户一眼就知道「这里还能再展开一层」
              if (widget.hasChildren)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: fg,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
