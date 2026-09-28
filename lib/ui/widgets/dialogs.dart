import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/motion.dart';
import '../../state/app_state.dart';
import '../../state/toast.dart';
import '../icons.dart';
import 'common.dart';
import 'fluent.dart';
import 'modal.dart';

// ================================================================ 输入框

/// 通用输入框 —— WinUI 的 `TextBox`。
///
/// 三处官方细节：
///  * 高度 **32**（`TextControlThemeMinHeight`），内边距 `10,5,6,6`
///    （`TextControlThemePadding`）；
///  * 左/上/右恒定 1px，**聚焦时只有底边加粗到 2px 并变主色**
///    （`TextControlBorderThemeThicknessFocused = 1,1,1,2`）——
///    这是 Win11 输入框最显眼的标志，整圈变色反而不像；
///  * 填充三档：静止 `ControlFillColorDefault` → 聚焦 `ControlFillColorInputActive`
///    （浅色下是纯白、深色下更深）。
class AppTextField extends StatefulWidget {
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
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final focused = _focus.hasFocus;
    final line = focused ? c.inputFocus : c.inputBorder;
    final mono = widget.mono;

    return AnimatedContainer(
      duration: kStateFade,
      curve: Motion.easyEase,
      constraints: const BoxConstraints(minHeight: 32),
      decoration: BoxDecoration(
        color: focused ? c.inputBg : c.controlFill,
        borderRadius: BorderRadius.circular(c.radius),
        border: Border(
          top: BorderSide(color: line),
          left: BorderSide(color: line),
          right: BorderSide(color: line),
          // 聚焦时底边 1 → 2px，WinUI 就是靠这一条表示「光标在这里」
          bottom: BorderSide(color: line, width: focused ? 2 : 1),
        ),
      ),
      child: Stack(
        children: [
          TextField(
            controller: widget.controller,
            focusNode: _focus,
            readOnly: widget.readOnly,
            obscureText: widget.obscure,
            autofocus: widget.autofocus,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            cursorColor: c.accent,
            cursorWidth: 1.5,
            style: TextStyle(
              fontSize: 14,
              color: c.text,
              fontFamily: mono ? kMonoFontFamily : kFontFamily,
              fontFamilyFallback: mono ? kMonoFontFallback : kFontFallback,
            ),
            decoration: InputDecoration(
              isDense: true,
              hintText: widget.hint,
              hintStyle: TextStyle(fontSize: 14, color: c.textTertiary),
              // 外观完全交给外面那层 Container：这样「底边加粗」才好画
              border: InputBorder.none,
              contentPadding: EdgeInsets.only(
                left: 10,
                top: 7,
                bottom: 7,
                right: widget.trailing != null ? 36 : 8,
              ),
            ),
          ),
          if (widget.trailing != null)
            Positioned(
              right: 6,
              top: 0,
              bottom: 0,
              child: Center(child: widget.trailing!),
            ),
        ],
      ),
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
      // 官方 ContentDialog 的内边距是 24
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AppIcon(AppIcons.warning, size: 32, color: c.danger),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: c.text, height: 1.5),
          ),
          const SizedBox(height: 24),
          // WinUI 的对话框按钮在**右下角**（不是居中）
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SizedBox(
                width: 110,
                child: AppButton(
                  label: '取消',
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 110,
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
                                      color: hovered ? c.hover : c.hover.withValues(alpha: 0),
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
