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
    required this.onTap,
    this.danger = false,
    this.dividerBefore = false,
    this.checked = false,
    this.enabled = true,
  });

  final String label;

  /// 图标（`AppIcons` 里的 SVG 路径数据）。每一项都有，位置也固定，
  /// 免得文字左右参差。
  final String icon;
  final VoidCallback onTap;

  /// 破坏性操作（移除之类）用警示色
  final bool danger;

  /// 在这一项之前画一条分隔线
  final bool dividerBefore;

  /// 当前生效的那一项 —— 行尾打勾（播放模式这类「多选一」的菜单用）
  final bool checked;

  /// 禁用项：置灰、不响应悬停与点击。比如「正在播的那首」不能再「插入到下一首」。
  final bool enabled;
}

const double _kItemHeight = 33;
const double _kMenuWidth = 176;
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

  void _close() {
    if (_closing) return;
    setState(() => _closing = true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final screen = MediaQuery.sizeOf(context);
    // 上下各 6 的内边距
    final height = widget.items.fold<double>(
      12,
      (sum, it) => sum + _kItemHeight + (it.dividerBefore ? _kDividerHeight : 0),
    );

    var left = widget.position.dx;
    var top = widget.position.dy;
    // 向上长：position.dy 是锚点顶边，菜单底边贴在它上面（留 6 的缝）
    if (widget.above) top -= height + 6;
    // 贴边就往回收，别让菜单跑出屏幕
    if (left + _kMenuWidth > screen.width - 8) left = screen.width - 8 - _kMenuWidth;
    if (top + height > screen.height - 8) top = screen.height - 8 - height;
    if (left < 8) left = 8;
    if (top < 8) top = 8;

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
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
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                onSecondaryTapDown: (_) => _close(),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: _closing ? 0.0 : 1.0),
                  duration: const Duration(milliseconds: 130),
                  curve: Curves.easeOutCubic,
                  onEnd: () {
                    if (_closing) widget.onClosed();
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
                    color: Colors.transparent,
                    child: Container(
                      width: _kMenuWidth,
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                      decoration: BoxDecoration(
                        color: c.card,
                        border: Border.all(color: c.border),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final item in widget.items) ...[
                            if (item.dividerBefore)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Container(height: 1, color: c.borderSubtle),
                              ),
                            _MenuItem(
                              label: item.label,
                              icon: item.icon,
                              danger: item.danger,
                              checked: item.checked,
                              enabled: item.enabled,
                              onTap: () {
                                _close();
                                item.onTap();
                              },
                            ),
                          ],
                        ],
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
}

class _MenuItem extends StatefulWidget {
  const _MenuItem({
    required this.label,
    required this.icon,
    required this.danger,
    required this.checked,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String icon;
  final bool danger;
  final bool checked;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final on = widget.enabled;
    // 危险项 hover 也用红的：跟着主色变蓝的话，「移除」看着就不危险了
    final hoverBg = widget.danger
        ? c.danger.withValues(alpha: 0.12)
        : c.accentLight;
    // 禁用项一律用三级文字色，且不跟着悬停变色 —— 灰着就得一直是灰的
    final fg = !on
        ? c.textTertiary
        : (widget.danger ? c.danger : (_hovered ? c.accent : c.text));

    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (on) setState(() => _hovered = true);
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: on ? widget.onTap : null,
        child: Container(
          height: _kItemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: (on && _hovered) ? hoverBg : c.accentLight.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              AppIcon(widget.icon, size: 14, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
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
            ],
          ),
        ),
      ),
    );
  }
}
