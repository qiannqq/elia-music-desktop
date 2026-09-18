import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// 模态框容器 —— 对应 `.modal-overlay` + `.modal`
///
/// 入场动画：`translateY(20px) scale(0.96)` → `translateY(0) scale(1)`，
/// 250ms，缓动 `cubic-bezier(0.25,0.1,0.25,1)`，与 CSS 一致。
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
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (ctx, _, _) => const SizedBox.shrink(),
    transitionBuilder: (ctx, animation, _, _) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: const Cubic(0.25, 0.1, 0.25, 1),
      );
      return BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: 4 * animation.value,
          sigmaY: 4 * animation.value,
        ),
        child: FadeTransition(
          opacity: animation,
          child: Center(
            child: Transform.translate(
              offset: Offset(0, 20 * (1 - curved.value)),
              child: Transform.scale(
                scale: 0.96 + 0.04 * curved.value,
                child: child,
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// 模态框外壳 —— 对应 `.modal`（surface 背景、12 圆角、最大高 80vh）
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
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth,
        maxHeight: screen.height * maxHeightFactor,
        minHeight: 0,
      ),
      // Material 祖先：模态框内的 TextField / 涟漪等需要它
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: maxWidth,
          height: height,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(c.radiusLg),
            boxShadow: c.shadowLg,
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 模态框标题栏 —— 对应 `.modal-header`
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.text),
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
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: _hovered ? c.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(
            child: CustomPaint(
              size: const Size(14, 14),
              painter: _XPainter(_hovered ? c.text : c.textSecondary),
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
