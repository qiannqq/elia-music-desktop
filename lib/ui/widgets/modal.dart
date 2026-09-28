import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/motion.dart';
import 'fluent.dart';

/// 模态框容器 —— WinUI 的 `ContentDialog`。
///
/// 入场：`scale 0.96 → 1` + 淡入，250ms（`ControlNormalAnimationDuration`），
/// 曲线走官方的 `cubic-bezier(0,0,0,1)` —— 起步快、末端极缓。
///
/// ⚠️ 遮罩用的是 **Smoke**（纯色 40% 黑），不是模糊：Win11 的对话框背后是一层
/// 压暗的烟，内容本身不糊。原来那版套了 `BackdropFilter(blur 4)`，
/// 既不像 Windows，又每帧多一次离屏合成 —— 拿掉了。
Future<T?> showAppModal<T>(
  BuildContext context,
  Widget child, {
  bool barrierDismissible = true,
  double? maxWidth,
}) {
  final c = context.c;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: 'modal',
    barrierColor: c.modalOverlay,
    transitionDuration: Motion.controlNormal,
    pageBuilder: (ctx, _, _) => const SizedBox.shrink(),
    transitionBuilder: (ctx, animation, _, _) {
      final curved = CurvedAnimation(parent: animation, curve: Motion.decelerate);
      return FadeTransition(
        opacity: animation,
        child: Transform.scale(
          scale: 0.96 + 0.04 * curved.value,
          child: child,
        ),
      );
    },
  );
}

/// 模态框外壳 —— WinUI 的 ContentDialog：**弹层圆角 8** + 1px 描边 + 大投影。
///
/// 底色用 `SolidBackgroundFillColorTertiary`（浅 #F9F9F9 / 深 #282828）而不是
/// 官方的 `SolidBackgroundFillColorBase`：后者是**窗口底**色，深色主题下它
/// 比云母上的内容层还暗，压上去像一个洞。
class AppModalCard extends StatelessWidget {
  const AppModalCard({
    super.key,
    required this.child,
    this.maxWidth = 480,
    this.height,
    this.maxHeightFactor = 0.8,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double maxWidth;
  final double? height;
  final double maxHeightFactor;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final screen = MediaQuery.sizeOf(context);
    // 必须先用 Align 把**紧约束**放松，ConstrainedBox 才压得住尺寸。
    // `showDialog` 给子节点的是紧约束（整屏），而 `BoxConstraints.enforce`
    // 会把 maxWidth 向上钳到父级 min —— 结果 maxWidth:520 被钳成整屏宽，
    // 弹窗直接铺满整个客户端（歌词弹窗就踩过这个坑）。
    // Align 自身撑满父级、却给子节点**松约束**，于是 520 才真正生效。
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: screen.height * maxHeightFactor,
          minHeight: 0,
        ),
        // Material 祖先：模态框内的 TextField / 涟漪等需要它
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: maxWidth,
            height: height,
            decoration: BoxDecoration(
              // 弹窗一律**不透明**：`surface` 在开了整窗背景时是半透明的，
            // 用在弹窗上会把底下的照片透上来（千奈报的「弹窗不需要半透明」）。
            // 这里走弹出层那一档 —— 菜单、对话框共用，两种主题下都是实色。
            color: c.flyoutBg,
              border: Border.all(color: c.flyoutBorder),
              borderRadius: BorderRadius.circular(c.radiusLg),
              boxShadow: c.elevation64,
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// 模态框标题栏 —— 标题走 `Subtitle` 档（20 / semibold），内边距 24。
class AppModalHeader extends StatelessWidget {
  const AppModalHeader({
    super.key,
    required this.title,
    this.left,
    this.onClose,
  });

  final String title;
  final Widget? left;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 12, 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: c.text),
                  ),
                ),
                if (left != null) ...[const SizedBox(width: 12), left!],
              ],
            ),
          ),
          if (onClose != null)
            _CloseButton(onTap: onClose!),
        ],
      ),
    );
  }
}

class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return FluentFocus(
      radius: c.radius,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _hovered ? c.hover : c.hover.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(c.radius),
            ),
            child: Center(
              child: CustomPaint(
                size: const Size(14, 14),
                painter: _XPainter(_hovered ? c.text : c.textSecondary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _XPainter extends CustomPainter {
  _XPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(1, 1), Offset(size.width - 1, size.height - 1), p);
    canvas.drawLine(Offset(size.width - 1, 1), Offset(1, size.height - 1), p);
  }

  @override
  bool shouldRepaint(covariant _XPainter old) => old.color != color;
}
