import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../state/app_state.dart';
import '../../state/toast.dart';
import '../icons.dart';
import 'common.dart';
import 'modal.dart';

// ================================================================ 输入框

/// 通用输入框 —— 对应 `.path-input-row input` / `.save-dialog-body input`
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    this.hint,
    this.readOnly = false,
    this.obscure = false,
    this.mono = false,
    this.onChanged,
    this.onSubmitted,
    this.trailing,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String? hint;
  final bool readOnly;
  final bool obscure;
  final bool mono;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? trailing;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Stack(
      children: [
        TextField(
          controller: controller,
          readOnly: readOnly,
          obscureText: obscure,
          autofocus: autofocus,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          cursorColor: c.accent,
          style: TextStyle(
            fontSize: 13,
            color: c.text,
            fontFamily: mono ? kMonoFontFamily : kFontFamily,
            fontFamilyFallback: mono ? kMonoFontFallback : kFontFallback,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: TextStyle(fontSize: 13, color: c.textTertiary),
            filled: true,
            fillColor: c.inputBg,
            contentPadding: EdgeInsets.only(
              left: 12,
              top: 10,
              bottom: 10,
              right: trailing != null ? 40 : 12,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(c.radius),
              borderSide: BorderSide(color: c.inputBorder, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(c.radius),
              borderSide: BorderSide(color: c.inputFocus, width: 1.5),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(c.radius),
              borderSide: BorderSide(color: c.inputBorder, width: 1.5),
            ),
          ),
        ),
        if (trailing != null)
          Positioned(
            right: 8,
            top: 0,
            bottom: 0,
            child: Center(child: trailing!),
          ),
      ],
    );
  }
}

// ================================================================ 确认框

/// 确认对话框 —— 对应 `showConfirm()` / `#confirm-overlay`
Future<bool> showConfirmDialog(BuildContext context, String message) async {
  final c = context.c;
  final result = await showAppModal<bool>(
    context,
    AppModalCard(
      maxWidth: 360,
      // 上下对称，内容才是真正居中（原来 32/20 会让内容偏下）
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AppIcon(AppIcons.warning, size: 32, color: c.danger),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: c.text, height: 1.6),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 80,
                child: AppButton(
                  label: '取消',
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 80,
                child: AppButton(
                  label: '确认',
                  variant: AppButtonVariant.primary,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  return result ?? false;
}

// ================================================================ 保存对话框

/// 保存位置对话框 —— 对应 `showSaveDialog()` / `#save-dialog-overlay`
Future<({String path, String filename})?> showSaveDialog(
  BuildContext context,
  AppState state,
  String defaultFilename,
) async {
  final c = context.c;
  final pathCtrl = TextEditingController(text: state.savePath);
  final nameCtrl = TextEditingController(text: defaultFilename);

  final result = await showAppModal<({String path, String filename})>(
    context,
    StatefulBuilder(
      builder: (ctx, setLocal) {
        return AppModalCard(
          maxWidth: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppModalHeader(
                title: '选择保存位置',
                onClose: () => Navigator.of(ctx).pop(),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _FieldLabel('保存路径', c),
                      Row(
                        children: [
                          Expanded(
                            child: AppTextField(controller: pathCtrl, readOnly: true),
                          ),
                          const SizedBox(width: 8),
                          AppButton(
                            label: '浏览',
                            onPressed: () async {
                              final dir = await AppState.pickDirectory();
                              if (dir != null && dir.isNotEmpty) {
                                pathCtrl.text = dir;
                                setLocal(() {});
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _FieldLabel('文件名', c),
                      AppTextField(controller: nameCtrl),
                      if (state.recentDirs.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _FieldLabel('常用目录', c),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final dir in state.recentDirs)
                              HoverBuilder(
                                builder: (_, hovered) => GestureDetector(
                                  onTap: () {
                                    pathCtrl.text = dir;
                                    setLocal(() {});
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: hovered ? c.hover : Colors.transparent,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Row(
                                      children: [
                                        AppIcon(AppIcons.folder,
                                            size: 14,
                                            color: c.textSecondary.withValues(alpha: 0.5)),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            dir,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontSize: 12, color: c.textSecondary),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.borderSubtle)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    AppButton(
                      label: '取消',
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                    const SizedBox(width: 8),
                    AppButton(
                      label: '保存',
                      variant: AppButtonVariant.primary,
                      onPressed: () {
                        final path = pathCtrl.text.trim();
                        final filename = nameCtrl.text.trim();
                        if (path.isEmpty) {
                          toast.show('请选择保存路径', type: ToastType.error);
                          return;
                        }
                        if (filename.isEmpty) {
                          toast.show('请输入文件名', type: ToastType.error);
                          return;
                        }
                        Navigator.of(ctx).pop((path: path, filename: filename));
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  pathCtrl.dispose();
  nameCtrl.dispose();
  return result;
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text, this.c);
  final String text;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: c.textSecondary,
        ),
      ),
    );
  }
}
