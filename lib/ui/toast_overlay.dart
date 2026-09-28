import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/motion.dart';
import '../state/toast.dart';
import 'icons.dart';

/// Toast 容器 —— 对应 `.toast-container`（top:44 / right:16，纵向排列）
class ToastOverlay extends StatelessWidget {
  const ToastOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: toast,
      builder: (ctx, _) {
        return Positioned(
          top: 44,
          right: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final item in toast.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ToastCard(item: item),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.item});

  final ToastItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    late String icon;
    late Color iconColor;
    switch (item.type) {
      case ToastType.success:
        icon = AppIcons.toastSuccess;
        iconColor = c.success;
        break;
      case ToastType.error:
        icon = AppIcons.toastError;
        iconColor = c.danger;
        break;
      case ToastType.progress:
        icon = AppIcons.toastProgress;
        iconColor = c.accent;
        break;
      case ToastType.info:
        icon = AppIcons.toastInfo;
        iconColor = c.accent;
        break;
    }

    return AnimatedSlide(
      // 出入场时长：进 250 / 退 300（官方的通知是「进得略快、退得更从容」）
      duration: item.leaving ? Motion.slow : Motion.controlNormal,
      curve: item.leaving ? Motion.accelerate : Motion.decelerate,
      offset: item.leaving ? const Offset(0.3, 0) : Offset.zero,
      child: AnimatedOpacity(
        duration: item.leaving ? Motion.slow : Motion.controlNormal,
        opacity: item.leaving ? 0 : 1,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360, minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: c.toastBg,
            border: Border.all(color: c.toastBorder),
            // 通知是控件档圆角（4），不是弹层档
            borderRadius: BorderRadius.circular(c.radius),
            boxShadow: c.elevation16,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.type == ToastType.progress)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(iconColor),
                  ),
                )
              else
                AppIcon(icon, size: 16, color: iconColor),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  item.message,
                  style: TextStyle(fontSize: 13, color: c.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
