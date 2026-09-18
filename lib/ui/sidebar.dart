import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../state/app_state.dart';
import 'icons.dart';

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
          decoration: BoxDecoration(
            color: c.sidebarBg,
            border: Border(right: BorderSide(color: c.borderSubtle)),
          ),
          padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 8, vertical: 8),
          child: Column(
            children: [
              for (final item in kNavItems)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: _NavItem(
                    item: item,
                    active: state.page == item.page,
                    compact: compact,
                    badge: item.page == 'playlist' ? state.songs.length : 0,
                    onTap: () => state.navigate(item.page),
                  ),
                ),
            ],
          ),
        );
      },
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
    final bg = active ? c.accentLight : (_hovered ? c.hover : Colors.transparent);

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
