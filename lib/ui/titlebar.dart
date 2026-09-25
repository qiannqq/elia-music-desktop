import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_theme.dart';
import '../core/window_fx.dart';
import 'icons.dart';

/// 标题栏高度。现在播放页要盖住整窗（含标题栏区域），所以这个数字
/// 两边都得用 —— 别各写各的。
const double kTitlebarHeight = 32;

/// 自绘标题栏 —— 对应 `.titlebar`（高 32，左图标+标题，右三个 46 宽按钮）
///
/// 原版由 Electron `frame:false` + `-webkit-app-region:drag` 实现；
/// 这里用 `window_manager` 的 `startDragging()` 等价替换。
class AppTitlebar extends StatelessWidget {
  const AppTitlebar({super.key, this.over = false});

  /// 浮在「现在播放页」之上时用：**背景透明、内容物转白**。
  ///
  /// 播放页的底色是封面，深浅不定 —— 标题栏还按主题色画的话，
  /// 浅色主题下就是一条灰白条横在封面上，字还可能看不见。
  final bool over;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fg = over ? Colors.white : c.textSecondary;
    // 两个状态都要看：全屏时整条标题栏（含拖动区）失效；
    // 最大化与否决定那个方框按钮是「最大化」还是「还原」。
    return ValueListenableBuilder<bool>(
      valueListenable: appFullscreen,
      builder: (_, full, _) => ValueListenableBuilder<bool>(
        valueListenable: appMaximized,
        builder: (_, maximized, _) => Container(
      height: kTitlebarHeight,
      decoration: BoxDecoration(
        color: over ? Colors.transparent : c.titlebarBg,
        border: over
            ? null
            : Border(bottom: BorderSide(color: c.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              // ⚠️ 全屏时不给拖、也不给双击最大化：那会儿窗口是 WS_POPUP，
              // 拖/最大化会把它变成一坨（而且状态还不了原）。
              onPanStart: full ? null : (_) => windowManager.startDragging(),
              onDoubleTap: full ? null : toggleMaximize,
              child: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: over ? 0.9 : 0.7,
                      child: AppIcon(AppIcons.music, size: 16, color: fg),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Elia Music',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 全屏是沉浸态：三个窗口按钮**直接不画**。
          // 以前是「画出来但禁用」（变灰），千奈看到的是「只是屏蔽、没有隐藏」——
          // 那三个灰块横在封面和歌词上很扎眼，而且禁用态本身也没法解释给用户。
          if (!full) ...[
            _TitlebarButton(
              icon: AppIcons.minimize,
              tooltip: '最小化',
              over: over,
              onTap: () => windowManager.minimize(),
            ),
            // 图标跟着窗口状态换：正常时是「最大化」，最大化之后是「还原」
            // （两个错开的方框）—— 只有一个图标的话，用户根本不知道点下去
            // 会变大还是变小。
            _TitlebarButton(
              icon: maximized ? AppIcons.restore : AppIcons.maximize,
              tooltip: maximized ? '还原' : '最大化',
              over: over,
              viewBox: maximized ? 24 : 12,
              onTap: toggleMaximize,
            ),
            _TitlebarButton(
              icon: AppIcons.close,
              tooltip: '关闭',
              isClose: true,
              over: over,
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
        ],
      ),
        ),
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
    this.over = false,
    this.viewBox = 12,
  });

  final String icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool isClose;

  /// 盖在现在播放页上时用白系配色（见 [AppTitlebar.over]）
  final bool over;

  /// 图标坐标系（窗口按钮同族是 12；「还原」那个是 24）
  final double viewBox;

  @override
  State<_TitlebarButton> createState() => _TitlebarButtonState();
}

class _TitlebarButtonState extends State<_TitlebarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final over = widget.over;
    // 非悬浮态用「同色 + alpha 0」而不是 Colors.transparent：
    // 后者是透明的黑，动画插值时会让标题栏按钮先闪一下暗色。
    final idleBg = widget.isClose
        ? const Color(0xFFC42B1C).withValues(alpha: 0)
        : (over ? Colors.white : c.hover).withValues(alpha: 0);
    final hoverBg = widget.isClose
        ? const Color(0xFFC42B1C)
        : (over ? Colors.white.withValues(alpha: 0.18) : c.hover);
    final bg = _hovered ? hoverBg : idleBg;
    final fg = (_hovered && widget.isClose)
        ? Colors.white
        : (over ? Colors.white.withValues(alpha: 0.9) : c.textSecondary);

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
          child: Center(
            child: AppIcon(
              widget.icon,
              size: widget.viewBox == 12 ? 12 : 14,
              color: fg,
              viewBox: widget.viewBox,
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) btn = Tooltip(message: widget.tooltip!, child: btn);
    return btn;
  }
}
