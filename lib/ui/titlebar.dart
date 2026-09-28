import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_theme.dart';
import '../core/motion.dart';
import '../core/window_fx.dart';
import 'icons.dart';
import 'widgets/fluent.dart';

/// 自绘标题栏 —— 对齐 Win11 的窗口 chrome。
///
/// 三个官方取值：
///  * 窗口按钮 **46×32**（`AppWindowTitleBar` 的固定尺寸，连高度都跟着标题栏走）；
///  * 图标是 **10×10 的 1px 线**，来自 Segoe Fluent Icons 字体
///    （`E921` 最小化 / `E922` 最大化 / `E923` 还原 / `E8BB` 关闭）；
///  * 悬停底是「亮底黑 6% / 暗底白 6%」那一档，**关闭键是单独的红** `#C42B1C`，
///    而且只有它悬停时字变白。
///
/// 标题栏本身**不画底色**：Win11 的标题栏是透明的，云母直接透上来。
/// 只有盖在「现在播放页」上时（[over]）才把内容物转白 —— 那页的底色是封面。
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
        builder: (_, maximized, _) => SizedBox(
          height: kTitlebarHeight,
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  // ⚠️ 全屏时不给拖、也不给双击最大化：那会儿窗口是 WS_POPUP，
                  // 拖/最大化会把它变成一坨（而且状态还不了原）。
                  onPanStart: full ? null : (_) => windowManager.startDragging(),
                  onDoubleTap: full ? null : toggleMaximize,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Opacity(
                          opacity: over ? 0.9 : 0.85,
                          child: AppIcon(AppIcons.music, size: 16, color: fg),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Elia Music',
                          style: TextStyle(
                            // Win11 标题栏文字是 Caption 档（12 / 常规字重）
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
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
                _CaptionButton(
                  glyph: kGlyphMinimize,
                  tooltip: '最小化',
                  over: over,
                  onTap: () => windowManager.minimize(),
                ),
                // 图标跟着窗口状态换：正常时是「最大化」，最大化之后是「还原」
                // （两个错开的方框）—— 只有一个图标的话，用户根本不知道点下去
                // 会变大还是变小。
                _CaptionButton(
                  glyph: maximized ? kGlyphRestore : kGlyphMaximize,
                  tooltip: maximized ? '还原' : '最大化',
                  over: over,
                  onTap: toggleMaximize,
                ),
                _CaptionButton(
                  glyph: kGlyphClose,
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

// ---- Segoe Fluent Icons 的字形码位（官方表逐个核对过）----
const String kGlyphMinimize = '\uE921';
const String kGlyphMaximize = '\uE922';
const String kGlyphRestore = '\uE923';
const String kGlyphClose = '\uE8BB';

/// 窗口按钮 —— 46×32，悬停/按下各一档底色。
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.glyph,
    required this.onTap,
    this.tooltip,
    this.isClose = false,
    this.over = false,
  });

  final String glyph;
  final VoidCallback onTap;
  final String? tooltip;
  final bool isClose;

  /// 盖在现在播放页上时用白系配色（见 [AppTitlebar.over]）
  final bool over;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;
  bool _pressed = false;

  /// 关闭键的红：Win11 用 `#C42B1C`，按下再沉一档。
  static const Color _closeRed = Color(0xFFC42B1C);
  static const Color _closeRedPressed = Color(0xFFB0241A);

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final over = widget.over;

    final Color bg;
    final Color fg;
    if (widget.isClose) {
      bg = _pressed
          ? _closeRedPressed
          : (_hovered ? _closeRed : _closeRed.withValues(alpha: 0));
      fg = _hovered || _pressed
          ? Colors.white
          : (over ? Colors.white : c.textTertiary);
    } else {
      // 非悬浮态用「同色 + alpha 0」而不是 Colors.transparent：
      // 后者是透明的黑，动画插值时会让标题栏按钮先闪一下暗色。
      final idle = (over ? Colors.white : Colors.black).withValues(alpha: 0);
      final hot = over
          ? Colors.white.withValues(alpha: _pressed ? 0.16 : 0.10)
          : (c.hover.withValues(alpha: _pressed ? 0.16 : 0.10));
      bg = _hovered ? hot : idle;
      // 平时比正文还暗一档（`TextFillColorTertiary`），**鼠标悬浮才亮起来** ——
      // 这三个是系统 chrome，不该跟内容抢注意力。
      fg = over
          ? Colors.white.withValues(alpha: _hovered ? 0.92 : 0.62)
          : (_hovered ? c.text : c.textTertiary);
    }

    Widget btn = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: kStateFade,
          curve: Motion.easyEase,
          width: kWindowButtonWidth,
          height: kTitlebarHeight,
          color: bg,
          child: Center(
            child: Text(
              widget.glyph,
              style: TextStyle(
                // 10：字形在 em 方框里占 10/16，于是画出来约 6px ——
                // 比 Win11 官方的 10px 小一圈半（千奈要的「图标再小一档、
                // 但按钮本身别动」）。按钮尺寸仍是 40×32。
                fontSize: 10,
                height: 1,
                fontFamily: kFluentIconsFont,
                fontFamilyFallback: kFluentIconsFallback,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) btn = Tooltip(message: widget.tooltip!, child: btn);
    return btn;
  }
}
