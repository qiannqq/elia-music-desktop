import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_theme.dart';
import 'icons.dart';

/// 自绘标题栏 —— 对应 `.titlebar`（高 32，左图标+标题，右三个 46 宽按钮）
///
/// 原版由 Electron `frame:false` + `-webkit-app-region:drag` 实现；
/// 这里用 `window_manager` 的 `startDragging()` 等价替换。
class AppTitlebar extends StatelessWidget {
  const AppTitlebar({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: c.titlebarBg,
        border: Border(bottom: BorderSide(color: c.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
              child: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: 0.7,
                      child: AppIcon(AppIcons.music, size: 16, color: c.textSecondary),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Elia Music',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _TitlebarButton(
            icon: AppIcons.minimize,
            tooltip: '最小化',
            onTap: () => windowManager.minimize(),
          ),
          _TitlebarButton(
            icon: AppIcons.maximize,
            tooltip: '最大化',
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _TitlebarButton(
            icon: AppIcons.close,
            tooltip: '关闭',
            isClose: true,
            onTap: () async {
              // 先把窗口收掉，再走关闭流程。
              //
              // 关闭时要落盘（LocalStore.flush），那一步可能要几百毫秒到几秒；
              // 让用户盯着一个「点了没反应」的窗口，就是那种卡顿感的来源。
              // 窗口一收，剩下的慢活都发生在看不见的地方。
              await windowManager.hide();
              await windowManager.close();
            },
          ),
        ],
      ),
    );
  }
}

class _TitlebarButton extends StatefulWidget {
  const _TitlebarButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.isClose = false,
  });

  final String icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool isClose;

  @override
  State<_TitlebarButton> createState() => _TitlebarButtonState();
}

class _TitlebarButtonState extends State<_TitlebarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    // 非悬浮态用「同色 + alpha 0」而不是 Colors.transparent：
    // 后者是透明的黑，动画插值时会让标题栏按钮先闪一下暗色。
    final idleBg = widget.isClose
        ? const Color(0xFFC42B1C).withValues(alpha: 0)
        : c.hover.withValues(alpha: 0);
    final bg = _hovered ? (widget.isClose ? const Color(0xFFC42B1C) : c.hover) : idleBg;
    final fg = (_hovered && widget.isClose) ? Colors.white : c.textSecondary;

    Widget btn = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: 32,
          color: bg,
          child: Center(child: AppIcon(widget.icon, size: 12, color: fg, viewBox: 12)),
        ),
      ),
    );
    if (widget.tooltip != null) btn = Tooltip(message: widget.tooltip!, child: btn);
    return btn;
  }
}
