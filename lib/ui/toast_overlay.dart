import 'package:flutter/material.dart';

import '../core/app_theme.dart';
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
      duration: const Duration(milliseconds: 200),
      offset: item.leaving ? const Offset(0.3, 0) : Offset.zero,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: item.leaving ? 0 : 1,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: c.toastBg,
            border: Border.all(color: c.toastBorder),
            borderRadius: BorderRadius.circular(c.radius),
            boxShadow: c.shadowLg,
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
