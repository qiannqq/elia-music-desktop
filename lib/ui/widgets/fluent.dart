import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/motion.dart';

/// 页面槽位的入场过渡 —— 侧边栏切主页面用的就是这一条：
/// **横向滑入 30px + 淡入，250ms `easeOut`**（位移越小越不透明）。
///
/// 抽出来是因为设置页切分栏也要用同一套（千奈要求两处观感一致，
/// 不要各写一个不同的过场）。用法：给它一个**每次切换都会变**的 `key`
/// ——`TweenAnimationBuilder` 只在 tween 的端点变化时重跑，
/// 而每次切换端点都一样（`direction*30 → 0`），所以必须靠换 key
/// 把 State 换掉，动画才会重新播。
class AppPageTransition extends StatelessWidget {
  const AppPageTransition({
    super.key,
    required this.direction,
    required this.child,
  });

  /// 1 = 从右边进入（内容向左滑到位），-1 = 从左边进入
  final int direction;

  final Widget child;

  /// 滑入距离。两侧一致 —— 两处过场看起来才像同一个东西。
  static const double slideDistance = 30;

  /// 时长。与原侧边栏切页保持一致。
  static const Duration duration = Duration(milliseconds: 250);

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: direction * slideDistance, end: 0),
      duration: duration,
      curve: Curves.easeOut,
      builder: (ctx, x, inner) => Transform.translate(
        offset: Offset(x, 0),
        child: Opacity(
          opacity: (1 - (x.abs() / slideDistance)).clamp(0.0, 1.0),
          child: inner,
        ),
      ),
      child: child,
    );
  }
}

/// Fluent 的**焦点框**：内外双环。
///
/// 这是 Win11 里最容易被忽略、又最能露馅的一处细节：
/// 官方（`FocusStrokeColorOuter` / `Inner`）用的是**两圈**——
/// 外环 2px、内环 1px，而且两圈的颜色在深浅主题里刚好**反过来**。
/// 于是不管控件压在什么底色上（白卡片、深色工具条、彩色的专辑封面），
/// 总有一圈是看得见的。单画一圈主色做不到这点。
///
/// 只在「键盘导航」时出现（`FocusHighlightMode.traditional`）——
/// 用鼠标点出来的焦点不该带着一圈框，Windows 自己也是这么区分的。
class FluentFocus extends StatefulWidget {
  const FluentFocus({
    super.key,
    required this.child,
    this.radius = 4,
    this.enabled = true,
    this.focusNode,
    this.autofocus = false,
    this.ringInset = 0,
  });

  final Widget child;

  /// 焦点框的圆角。官方要求它比控件的圆角**大一圈**，看起来才是「裹住」控件。
  final double radius;

  final bool enabled;
  final FocusNode? focusNode;
  final bool autofocus;

  /// 焦点框相对控件外框内缩多少（官方默认外扩，这里给 0 表示贴着画）
  final double ringInset;

  @override
  State<FluentFocus> createState() => _FluentFocusState();
}

class _FluentFocusState extends State<FluentFocus> {
  bool _focused = false;

  /// 键盘导航模式下才画焦点框
  bool get _showRing =>
      _focused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      canRequestFocus: widget.enabled,
      onFocusChange: (v) {
        if (v != _focused) setState(() => _focused = v);
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (_showRing)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: FocusRingPainter(
                    radius: widget.radius,
                    inset: widget.ringInset,
                    outer: context.c.focusOuter,
                    inner: context.c.focusInner,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 画那道双环。
class FocusRingPainter extends CustomPainter {
  FocusRingPainter({
    required this.radius,
    required this.outer,
    required this.inner,
    this.inset = 0,
  });

  final double radius;
  final Color outer;
  final Color inner;
  final double inset;

  /// 外环 2px、内环 1px（官方 FocusVisual 的两段厚度）
  static const double outerWidth = 2;
  static const double innerWidth = 1;
  static const double gap = 1;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height).deflate(inset);

    // 内环：贴控件那一圈，1px，和控件自己的圆角对齐
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(innerWidth / 2),
        Radius.circular(radius - innerWidth / 2),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = innerWidth
        ..color = inner,
    );

    // 外环：往外让出「内环 + 间隙」，2px，圆角同步放大
    final outerOffset = innerWidth + gap;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.inflate(outerOffset + outerWidth / 2),
        Radius.circular(radius + outerOffset + outerWidth / 2),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = outerWidth
        ..color = outer,
    );
  }

  @override
  bool shouldRepaint(covariant FocusRingPainter old) =>
      old.radius != radius ||
      old.outer != outer ||
      old.inner != inner ||
      old.inset != inset;
}

/// 悬停 / 按下 / 选中 的叠加色 —— Fluent 里所有「可点区域」的状态底
/// 都是这三种之一，集中在这里省得每处各写一遍。
Color stateFill(
  AppColors c, {
  required bool hovered,
  required bool pressed,
  bool selected = false,
}) {
  if (pressed) return c.active;
  if (hovered || selected) return c.hover;
  // 用同色 + alpha 0 而不是 Colors.transparent：后者是「透明的黑」，
  // AnimatedContainer 插值时会先闪一下暗色。
  return c.hover.withValues(alpha: 0);
}

/// 状态切换的补间时长 —— 官方 `ControlFasterAnimationDuration`（83ms）。
const Duration kStateFade = Motion.controlFaster;
