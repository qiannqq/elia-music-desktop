import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../icons.dart';

/// 悬停状态构建器
class HoverBuilder extends StatefulWidget {
  const HoverBuilder({super.key, required this.builder, this.cursor = SystemMouseCursors.click});

  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor cursor;

  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(context, _hovered),
    );
  }
}

enum AppButtonVariant { primary, accent, secondary, ghost }

/// 通用按钮 —— 对应 CSS `.btn` / `.btn-primary` / `.btn-accent` / `.btn-secondary` / `.btn-sm`
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = AppButtonVariant.secondary,
    this.small = false,
    this.icon,
    this.iconSize = 14,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final bool small;
  final String? icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = onPressed != null;

    late Color bg;
    late Color fg;
    BoxBorder? border;

    switch (variant) {
      case AppButtonVariant.primary:
        bg = c.accent;
        fg = c.accentText;
        break;
      case AppButtonVariant.accent:
        bg = c.accentLight;
        fg = c.accent;
        break;
      case AppButtonVariant.secondary:
        bg = c.surfaceAlt;
        fg = c.textSecondary;
        border = Border.all(color: c.border);
        break;
      case AppButtonVariant.ghost:
        // 用「hover 色 + alpha 0」而不是 Colors.transparent：
        // 后者是透明的黑，AnimatedContainer 插值时会先闪一下暗色。
        bg = c.hover.withValues(alpha: 0);
        fg = c.textSecondary;
        break;
    }

    // GestureDetector 是必需的：早期版本只写了 HoverBuilder（hover 样式），
    // 忘了接点击处理，导致全应用的按钮都点不动。
    return GestureDetector(
      onTap: enabled ? onPressed : null,
      child: HoverBuilder(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        builder: (ctx, hovered) {
          var hoverBg = bg;
          var hoverFg = fg;
          if (enabled && hovered) {
            switch (variant) {
              case AppButtonVariant.primary:
                hoverBg = c.accentHover;
                break;
              case AppButtonVariant.accent:
                hoverBg = c.accent;
                hoverFg = c.accentText;
                break;
              case AppButtonVariant.secondary:
              case AppButtonVariant.ghost:
                hoverBg = c.hover;
                hoverFg = c.text;
                break;
            }
          }
          // 进入用 120ms 淡入、**退出瞬时**：
          // 若进出都用 120ms，鼠标从按钮 A 划到 B 时，A 还在淡出、B 已淡入 ——
          // 那 120ms 里两个按钮同时高亮（和歌单「两行同时高亮」是同一个坑）。
          return AnimatedContainer(
            duration: hovered
                ? const Duration(milliseconds: 120)
                : Duration.zero,
            padding:
                EdgeInsets.symmetric(horizontal: small ? 10 : 16, vertical: small ? 4 : 6),
            decoration: BoxDecoration(
              color: hoverBg,
              borderRadius: BorderRadius.circular(c.radius),
              border: border,
            ),
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            // 必须用 Center 包住：
            // Row 是 mainAxisSize.min（只包住内容），放在固定宽度的按钮里
            // （如确认弹窗的 SizedBox(width:80)）会**靠左**，字就不居中了。
            // 等价 CSS 的 `justify-content: center` + `align-items: center`。
            // 用 Center 而不是给 Row 加 mainAxisAlignment.center：
            // Row 在 min 尺寸下没有多余空间，对齐参数不起作用。
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    AppIcon(icon!, size: iconSize, color: hoverFg),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: small ? 12 : 13,
                      fontWeight: FontWeight.w500,
                      color: hoverFg,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
          );
        },
      ),
    );
  }
}

/// 方形图标按钮 —— 对应 `.icon-btn` / `.btn-icon`（32×32，圆角 6）
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 32,
    this.iconSize = 16,
    this.tooltip,
    this.hoverBg,
    this.baseColor,
    this.hoverColor,
    this.bordered = false,
    this.accentHover = false,
    this.filled = false,
    this.viewBox = 24,
  });

  final String icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final String? tooltip;
  final Color? hoverBg;
  final Color? baseColor;
  final Color? hoverColor;
  final bool bordered;
  final bool accentHover;

  /// 实心图标（播放/上一首/下一首等 fill 型）
  final bool filled;

  /// 图标坐标系尺寸。默认 24；用 12 坐标系的图标（如 AppIcons.close）要显式传 12。
  final double viewBox;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final base = baseColor ?? c.textSecondary;

    // GestureDetector 是必需的：早期版本只写了 HoverBuilder（hover 样式），
    // 忘了接点击处理，导致全应用的图标按钮（试听/下载/歌词/删除等）都点不动。
    Widget child = GestureDetector(
      onTap: onTap,
      child: HoverBuilder(
        cursor: onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        builder: (ctx, hovered) {
          final fg = hovered ? (hoverColor ?? (accentHover ? c.accent : c.text)) : base;
          // 同上：进入淡入、退出瞬时，避免相邻按钮同时高亮
          return AnimatedContainer(
            duration: hovered
                ? const Duration(milliseconds: 120)
                : Duration.zero,
            width: size,
            height: size,
            decoration: BoxDecoration(
              // 非悬浮态不能用 Colors.transparent（透明的黑）：
              // AnimatedContainer 会在两者之间插值，悬浮瞬间先「黑」一下。
              // 用同色 + alpha 0，插值才在同一色相内。
              color: hovered
                  ? (hoverBg ?? (accentHover ? c.accentLight : c.hover))
                  : (hoverBg ?? (accentHover ? c.accentLight : c.hover))
                      .withValues(alpha: 0),
              borderRadius: BorderRadius.circular(6),
              border: bordered
                  ? Border.all(color: hovered && accentHover ? c.accent : c.borderSubtle)
                  : null,
            ),
            child: Center(
              child: AppIcon(icon, size: iconSize, color: fg, filled: filled, viewBox: viewBox),
            ),
          );
        },
      ),
    );

    if (tooltip != null) {
      child = Tooltip(message: tooltip!, child: child);
    }
    return child;
  }
}

/// 开关 —— 对应 `.toggle-switch`（40×20）
class AppToggle extends StatelessWidget {
  const AppToggle({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 40,
          height: 20,
          decoration: BoxDecoration(
            color: value ? c.accent : c.textTertiary,
            borderRadius: BorderRadius.circular(10),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.all(2),
              width: 16,
              height: 16,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}

/// 复选框 —— 对应 `.playlist-item input[type=checkbox]`（18×18，选中态主色 + 白勾）
class AppCheckbox extends StatelessWidget {
  const AppCheckbox({super.key, required this.checked, this.onChanged});

  final bool checked;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!checked),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: HoverBuilder(
          builder: (ctx, hovered) => AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: checked ? c.accent : c.surface,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: checked ? c.accent : (hovered ? c.accent : c.border),
                width: 1.5,
              ),
            ),
            child: checked
                ? Center(
                    child: CustomPaint(
                      size: const Size(5, 9),
                      painter: _CheckPainter(),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(0, size.height * 0.45)
      ..lineTo(size.width * 0.4, size.height * 0.9)
      ..lineTo(size.width, 0);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 进度条 —— 对应 `.player-progress` / `.batch-progress`
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({
    super.key,
    required this.value,
    this.height = 4,
    this.hoverHeight = 6,
    this.onSeek,
    this.onSeekStart,
    this.onSeekEnd,
    this.draggable = false,
  });

  final double value;
  final double height;
  final double hoverHeight;

  /// 拖动/点击过程中回调（用于更新本地预览值，不要在这里真的 seek）
  final ValueChanged<double>? onSeek;

  /// 开始拖动（按下或拖动起点）—— 用于暂停播放
  final VoidCallback? onSeekStart;

  /// 结束拖动（松手或点击抬起）—— 用于真正 seek + 恢复播放
  final VoidCallback? onSeekEnd;

  final bool draggable;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return LayoutBuilder(
      builder: (ctx, constraints) {
        void seekAt(Offset local) {
          if (onSeek == null || constraints.maxWidth <= 0) return;
          onSeek!((local.dx / constraints.maxWidth).clamp(0.0, 1.0));
        }

        return HoverBuilder(
          cursor: draggable ? SystemMouseCursors.click : SystemMouseCursors.basic,
          builder: (_, hovered) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: draggable ? (d) => seekAt(d.localPosition) : null,
            onTapUp: draggable ? (_) => onSeekEnd?.call() : null,
            onHorizontalDragStart: draggable
                ? (d) {
                    seekAt(d.localPosition);
                    onSeekStart?.call();
                  }
                : null,
            onHorizontalDragUpdate: draggable ? (d) => seekAt(d.localPosition) : null,
            onHorizontalDragEnd: draggable ? (_) => onSeekEnd?.call() : null,
            child: SizedBox(
              height: math.max(height, draggable ? hoverHeight : height),
              child: Center(
                // 轨道必须显式撑满宽度（width: double.infinity）：
                // 否则 Center 给的**松约束**会让轨道缩成「填充条」的宽度，
                // 而填充条又是按轨道宽度算比例 —— 两者互相约束，
                // 结果进度条只有一小截且居中（实测宽度只剩 ~15%、还跑到中间）。
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: double.infinity,
                  height: draggable && hovered ? hoverHeight : height,
                  decoration: BoxDecoration(
                    color: c.progressBg,
                    borderRadius: BorderRadius.circular(height / 2),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: value.clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: c.accent,
                        borderRadius: BorderRadius.circular(height / 2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 加载圈 —— 对应 `.loading-spinner` / `.cover-spinner`
class AppSpinner extends StatelessWidget {
  const AppSpinner({super.key, this.size = 20, this.strokeWidth = 2, this.color});

  final double size;
  final double strokeWidth;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: strokeWidth,
        valueColor: AlwaysStoppedAnimation<Color>(color ?? Colors.white),
      ),
    );
  }
}

/// 歌曲封面 —— 对应 `.song-cover` / `.song-cover-placeholder`
class SongCover extends StatelessWidget {
  const SongCover({super.key, this.url, this.size = 44, this.radius = 6});

  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (url == null || url!.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Center(child: AppIcon(AppIcons.music, size: size * 0.4, color: c.textTertiary)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: size,
          height: size,
          color: c.surfaceAlt,
          child: Center(child: AppIcon(AppIcons.music, size: size * 0.4, color: c.textTertiary)),
        ),
        loadingBuilder: (ctx, child, progress) => progress == null
            ? child
            : Container(width: size, height: size, color: c.surfaceAlt),
      ),
    );
  }
}

/// 来源角标 —— 对应 `.source-icon.source-qq` / `.source-netease`
///
/// 图标**内置在 assets 里**，不再从 `https://y.qq.com/favicon.ico` 远程加载。
/// 原版是 `<img src=favicon onerror=隐藏>`，网络一抖图标就消失/闪烁
/// （QQ音乐图标时有时无）；而且 Flutter 也解不了 ICO 格式。
/// 这里用离线 PNG，永远稳定显示。
class SourceIcon extends StatelessWidget {
  const SourceIcon({super.key, required this.source, this.size = 16});

  final String source;
  final double size;

  static const _qqAsset = 'assets/source_icons/qq.png';
  static const _neAsset = 'assets/source_icons/netease.png';

  @override
  Widget build(BuildContext context) {
    final isQq = source != 'netease';
    final letter = isQq ? 'Q' : 'N';
    final letterColor = isQq ? const Color(0xFF33C1FF) : const Color(0xFFEC4141);

    return Tooltip(
      message: isQq ? 'QQ音乐' : '网易云音乐',
      child: SizedBox(
        width: size,
        height: size,
        child: Image.asset(
          isQq ? _qqAsset : _neAsset,
          width: size,
          height: size,
          fit: BoxFit.cover,
          // 资源缺失时才退化成字母（正常不会走到）
          errorBuilder: (_, _, _) => Center(
            child: Text(
              letter,
              style: TextStyle(
                fontSize: size * 0.75,
                fontWeight: FontWeight.w700,
                color: letterColor,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 空状态 —— 对应 `.empty-state`
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.hint});

  final String icon;
  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 80),
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(icon, size: 48, color: c.textTertiary.withValues(alpha: 0.3), strokeWidth: 1.5),
          const SizedBox(height: 12),
          Text(title, style: TextStyle(fontSize: 15, color: c.textTertiary)),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint!, style: TextStyle(fontSize: 13, color: c.textTertiary)),
          ],
        ],
      ),
    );
  }
}
