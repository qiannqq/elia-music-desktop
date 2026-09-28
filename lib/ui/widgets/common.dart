import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../services/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/motion.dart';
import '../icons.dart';
import 'fluent.dart';

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

/// 行 / 卡片上的鼠标点击区域：右键（按下即触发）与双击左键。
///
/// **不要换成 `GestureDetector.onDoubleTap`**：双击识别器在第一次抬手后会
/// `hold` 住手势竞技场（见 SDK `multitap.dart` 的 `_registerFirstTap`），
/// 在等第二次点击的那 300ms 里，同一区域里**子控件的 onTap 全被压住** ——
/// 表现为「点播放 / 下载要顿一下才响应」。整行本来就没有单击行为，
/// 不必和子控件争手势，所以直接读裸指针事件自己数。
class ClickRegion extends StatefulWidget {
  const ClickRegion({
    super.key,
    required this.child,
    this.onDoubleClick,
    this.onSecondaryClick,
  });

  final Widget child;

  /// 双击左键
  final VoidCallback? onDoubleClick;

  /// 按下右键，参数是全局坐标（用来定位菜单）
  final ValueChanged<Offset>? onSecondaryClick;

  @override
  State<ClickRegion> createState() => _ClickRegionState();
}

class _ClickRegionState extends State<ClickRegion> {
  /// 两次点击的最大间隔。Windows 默认的双击间隔是 500ms，
  /// 这里收紧一点：既跟手，也不至于把两次独立的点击连成一次双击。
  static const Duration _interval = Duration(milliseconds: 400);

  /// 两次点击的位置容差 —— 差得远就当不是同一处（拖过、或换了地方点）
  static const double _slop = 8;

  Duration? _lastDown;
  Offset? _lastPos;

  void _onDown(PointerDownEvent e) {
    // 右键按下即报，与系统菜单一致，不等抬手
    if (e.buttons == kSecondaryButton) {
      _lastDown = null;
      _lastPos = null;
      widget.onSecondaryClick?.call(e.position);
      return;
    }
    if (e.buttons != kPrimaryButton) return;

    final last = _lastDown;
    final pos = _lastPos;
    _lastDown = e.timeStamp;
    _lastPos = e.position;
    if (last == null || pos == null) return;
    if (e.timeStamp - last > _interval) return;
    if ((e.position - pos).distance > _slop) return;
    // 用完就清：连点三下不该被算成两次双击
    _lastDown = null;
    _lastPos = null;
    widget.onDoubleClick?.call();
  }

  @override
  Widget build(BuildContext context) {
    final active =
        widget.onDoubleClick != null || widget.onSecondaryClick != null;
    return Listener(
      // opaque：整块区域的空白处也要收得到事件；子控件仍然先被命中，
      // 各自的按钮不受影响（Listener 不参与手势竞技场，也不会抢滚动）。
      behavior: HitTestBehavior.opaque,
      onPointerDown: active ? _onDown : null,
      child: widget.child,
    );
  }
}

enum AppButtonVariant { primary, accent, secondary, ghost }

/// 通用按钮 —— 对应 WinUI 的 `Button` / `AccentButtonStyle` / `SubtleButtonStyle`
class AppButton extends StatefulWidget {
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
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  /// 按下态要单独记：WinUI 的按下底（`ControlFillColorTertiary`）比悬停还淡，
  /// 而且它在**松手之前**一直保持 —— 光靠 hover 画不出来。
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final variant = widget.variant;
    final small = widget.small;
    final icon = widget.icon;
    final iconSize = widget.iconSize;
    final label = widget.label;
    final onPressed = widget.onPressed;
    final enabled = onPressed != null;

    // WinUI 的按钮三态 = 「控件填充」的三档（`ControlFillColorDefault /
    // Secondary / Tertiary`）外加 1px 描边；只有**强调按钮**才用 accentFill，
    // 它的悬停/按下走自己那套 0.9 / 0.8 透明度（`AccentFillColorSecondary/Tertiary`）——
    // 观感是「往背景里淡一点」，不是变深。
    late Color bg;
    late Color bgHover;
    late Color bgPressed;
    late Color fg;
    Color? border;

    switch (variant) {
      case AppButtonVariant.primary:
        bg = c.accentFill;
        bgHover = c.accentFillHover;
        bgPressed = c.accentFillPressed;
        fg = c.accentText;
        break;
      case AppButtonVariant.accent:
        // 「主色淡底」：Win11 里对应 NavigationView 那种选中态，不是实心按钮
        bg = c.accentLight;
        bgHover = c.accent.withValues(alpha: 0.20);
        bgPressed = c.accent.withValues(alpha: 0.26);
        fg = c.accent;
        border = c.accent.withValues(alpha: 0.32);
        break;
      case AppButtonVariant.secondary:
        bg = c.controlFill;
        bgHover = c.controlFillHover;
        bgPressed = c.controlFillPressed;
        fg = c.text;
        border = c.border;
        break;
      case AppButtonVariant.ghost:
        // 用「hover 色 + alpha 0」而不是 Colors.transparent：
        // 后者是透明的黑，AnimatedContainer 插值时会先闪一下暗色。
        bg = c.hover.withValues(alpha: 0);
        bgHover = c.hover;
        bgPressed = c.active;
        fg = c.textSecondary;
        break;
    }

    // 高度按 WinUI：正文按钮 32（`ControlThemeMinHeight`），工具条里的紧凑档 28。
    final height = small ? 28.0 : 32.0;

    // GestureDetector 是必需的：早期版本只写了 HoverBuilder（hover 样式），
    // 忘了接点击处理，导致全应用的按钮都点不动。
    return FluentFocus(
      enabled: enabled,
      radius: c.radius,
      child: GestureDetector(
        onTap: enabled ? onPressed : null,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: () => setState(() => _pressed = false),
        child: HoverBuilder(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          builder: (ctx, hovered) {
            final fill = !enabled
                ? c.controlFillDisabled
                : (_pressed ? bgPressed : (hovered ? bgHover : bg));
            return AnimatedContainer(
              duration: kStateFade,
              curve: Motion.easyEase,
              height: height,
              padding: EdgeInsets.symmetric(horizontal: small ? 9 : 11),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(c.radius),
                border: border == null ? null : Border.all(color: border),
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
                        AppIcon(icon, size: iconSize, color: fg),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        label,
                        style: TextStyle(
                          // `ControlContentThemeFontSize` = 14；紧凑档降到 12.5
                          fontSize: small ? 12.5 : 14,
                          fontWeight: FontWeight.w400,
                          color: fg,
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
    Widget child = FluentFocus(
      enabled: onTap != null,
      radius: c.radius,
      child: GestureDetector(
        onTap: onTap,
        child: HoverBuilder(
          cursor: onTap == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          builder: (ctx, hovered) {
            final fg = hovered ? (hoverColor ?? (accentHover ? c.accent : c.text)) : base;
            // 非悬浮态不能用 Colors.transparent（透明的黑）：
            // AnimatedContainer 会在两者之间插值，悬浮瞬间先「黑」一下。
            // 用同色 + alpha 0，插值才在同一色相内。
            final idleBg = hoverBg ?? (accentHover ? c.accentLight : c.hover);
            return AnimatedContainer(
              duration: kStateFade,
              curve: Motion.easyEase,
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: hovered ? idleBg : idleBg.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(c.radius),
                border: bordered
                    ? Border.all(color: hovered && accentHover ? c.accent : c.border)
                    : null,
              ),
              child: Center(
                child: AppIcon(icon, size: iconSize, color: fg, filled: filled, viewBox: viewBox),
              ),
            );
          },
        ),
      ),
    );

    if (tooltip != null) {
      child = Tooltip(message: tooltip!, child: child);
    }
    return child;
  }
}

/// 开关 —— WinUI 的 `ToggleSwitch`。
///
/// 官方几何（`controls/dev/CommonStyles/ToggleSwitch_themeresources.xaml`）：
/// 轨道 **40×20、圆角 10**，旋钮 **12×12、圆角 7**，位移 **0 → 20**，
/// 状态色补间 **83ms**（`ControlFasterAnimationDuration`）。四个独立实现
/// （wpfui / ModernWpf / Qt FluentUI / Sun-Valley）的取值完全一致。
///
/// 两种状态的观感差别不只是颜色：
///  * **关** = 很淡的底（`ControlAltFillColorSecondary`）+ **明显的 1px 描边**
///    （`ControlStrongStrokeColorDefault`），旋钮是深灰；
///  * **开** = 实心主色填充（`accentFill`）+ 几乎看不见的描边，旋钮是反色白。
class AppToggle extends StatefulWidget {
  const AppToggle({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  /// 轨道尺寸与旋钮位移（官方值，别改）
  static const double trackWidth = 40;
  static const double trackHeight = 20;
  static const double knobSize = 12;
  static const double knobTravel = 20;

  @override
  State<AppToggle> createState() => _AppToggleState();
}

class _AppToggleState extends State<AppToggle> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final on = widget.value;

    // 轨道底：开 = 主色（悬停/按下分别降到 0.9 / 0.8），关 = 淡底三档
    final track = on
        ? (_pressed
            ? c.accentFillPressed
            : (_hovered ? c.accentFillHover : c.accentFill))
        : (_pressed
            ? c.altFillPressed
            : (_hovered ? c.altFillHover : c.altFill));
    final stroke = on ? c.accentFill.withValues(alpha: 0.08) : c.strokeStrong;
    final knob = on ? c.accentText : c.textSecondary;

    return FluentFocus(
      radius: AppToggle.trackHeight / 2,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) {
          setState(() {
            _hovered = false;
            _pressed = false;
          });
        },
        child: GestureDetector(
          onTap: () => widget.onChanged(!on),
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: kStateFade,
            curve: Motion.easyEase,
            width: AppToggle.trackWidth,
            height: AppToggle.trackHeight,
            decoration: BoxDecoration(
              color: track,
              border: Border.all(color: stroke),
              borderRadius: BorderRadius.circular(AppToggle.trackHeight / 2),
            ),
            child: AnimatedAlign(
              duration: kStateFade,
              curve: Motion.easyEase,
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                // 旋钮自己是「轨道内缩 4」的圆 —— 4 + 12 + 4 = 20 正好是轨道高
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: AppToggle.knobSize,
                height: AppToggle.knobSize,
                decoration: BoxDecoration(
                  color: knob,
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 复选框 —— WinUI 的 `CheckBox`：**20×20、圆角 4**、1.5px 描边。
///
/// 选中态就是 `AccentFillColorDefault`（=`accentFill`）+ 反色对勾；
/// 悬停/按下按官方的 0.9 / 0.8 透明度走。未选中的底是
/// `ControlAltFillColorSecondary`、描边是 `ControlStrongStrokeColorDefault`。
class AppCheckbox extends StatelessWidget {
  const AppCheckbox({super.key, required this.checked, this.onChanged});

  final bool checked;
  final ValueChanged<bool>? onChanged;

  static const double size = 20;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!checked),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: HoverBuilder(
          builder: (ctx, hovered) => FluentFocus(
            enabled: onChanged != null,
            radius: c.radius,
            child: AnimatedContainer(
              duration: kStateFade,
              curve: Motion.easyEase,
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: checked
                    ? (hovered ? c.accentFillHover : c.accentFill)
                    : (hovered ? c.altFillHover : c.altFill),
                borderRadius: BorderRadius.circular(c.radius),
                border: Border.all(
                  color: checked
                      ? c.accentFill.withValues(alpha: hovered ? 0.08 : 0.12)
                      : (hovered ? c.accent : c.strokeStrong),
                  width: 1.5,
                ),
              ),
              child: checked
                  ? Center(
                      child: CustomPaint(
                        size: const Size(5, 9),
                        painter: _CheckPainter(c.accentText),
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    // 对勾的折点比原来低一点、两臂更收 —— 对齐 Segoe Fluent Icons 里那个
    // `CheckMark` 的形态（原来那版太「尖」，20px 下会显得头重脚轻）
    final path = Path()
      ..moveTo(0, size.height * 0.5)
      ..lineTo(size.width * 0.38, size.height * 0.86)
      ..lineTo(size.width, size.height * 0.08);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CheckPainter old) => old.color != color;
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
    this.trackColor,
    this.fillColor,
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

  /// 轨道与填充色。不给就用主题里的（现在播放页整页是封面底色，需要白色系）。
  final Color? trackColor;
  final Color? fillColor;

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
                    color: trackColor ?? c.progressBg,
                    borderRadius: BorderRadius.circular(height / 2),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: value.clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: fillColor ?? c.accentFill,
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
  const SongCover({
    super.key,
    this.pic,
    this.size = 44,
    this.radius = 4,
    this.px,
  });

  /// **原始**封面地址（不是代理地址）—— 内部要按显示尺寸重新挑一档。
  ///
  /// QQ 音乐那套封面有固定档位（150/300/…/1500，以及不带尺寸的原图），
  /// 存的母版是原图；小格子用原图纯属浪费流量，所以这里按 [size] 降档。
  final String? pic;

  final double size;
  final double radius;

  /// 强制指定要哪一档（不传就按 [size] 自动算）。
  ///
  /// ⚠️ 同一个歌在不同地方要**用同一档**，否则 URL 不同 = 下两张图、两次解码。
  /// 播放页的封面、背景、预热就是靠这个参数对齐的（见 `kNowPlayingCoverPx`）。
  final int? px;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final raw = pic ?? '';
    if (raw.isEmpty) return _placeholder(c);

    // 按显示尺寸解码。封面原图常有 300~3000px，为一个 40px 的格子解出整张，
    // 几百首歌就能把图片缓存挤爆、反复重新解码。
    //
    // 只给 cacheWidth：同时给 width/height 会按指定尺寸拉伸（等同 BoxFit.fill），
    // 宽封面会被压扁。留 2 倍余量，16:9 的封面填进方格时也仍是缩小采样。
    //
    // 尺寸再**取整到 2 的幂**：歌单是 40px、搜索页是 44px，直接算出来 80 / 88，
    // 缓存键不同 —— 同一个封面在两个页面之间来回切会被反复重新解码。
    // 取整到同一档就能共用一份。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final wanted = size * dpr * 2;
    var cachePx = 64;
    while (cachePx < wanted && cachePx < 512) {
      cachePx *= 2;
    }

    // 请求的尺寸档跟解码尺寸用**同一个** `wanted`：
    // 40px 的歌单行拿 150 档（约 11KB），播放页那个大封面拿 1200 档
    // （实测 800 档 183KB、1200 档约 400KB、原图 1.5MB+）—— 刚好够清晰又不白下。
    final url = ApiClient.getProxyImageUrl(
      ApiClient.coverUrlFor(raw, px: px ?? wanted.round()),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: cachePx,
        errorBuilder: (_, _, _) => _placeholder(c),
        loadingBuilder: (ctx, child, progress) => progress == null
            ? child
            : Container(width: size, height: size, color: c.surfaceAlt),
      ),
    );
  }

  Widget _placeholder(AppColors c) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Center(
        child: AppIcon(AppIcons.music, size: size * 0.4, color: c.textTertiary),
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
  static const _biliAsset = 'assets/source_icons/bilibili.png';

  @override
  Widget build(BuildContext context) {
    // 三个源各自的外观。字母只是图标资源缺失时的兜底。
    final (letter, color, asset, label) = switch (source) {
      'netease' => ('N', const Color(0xFFEC4141), _neAsset, '网易云音乐'),
      'bilibili' => ('B', const Color(0xFFFB7299), _biliAsset, 'B站'),
      _ => ('Q', const Color(0xFF33C1FF), _qqAsset, 'QQ音乐'),
    };

    final fallback = Center(
      child: Text(
        letter,
        style: TextStyle(
          fontSize: size * 0.75,
          fontWeight: FontWeight.w600,
          color: color,
          height: 1,
        ),
      ),
    );

    return Tooltip(
      message: label,
      child: SizedBox(
        width: size,
        height: size,
        child: Image.asset(
          asset,
          width: size,
          height: size,
          fit: BoxFit.cover,
          // 资源缺失时才退化成字母（正常不会走到）
          errorBuilder: (_, _, _) => fallback,
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
          AppIcon(icon, size: 48, color: c.textTertiary.withValues(alpha: 0.35), strokeWidth: 1.5),
          const SizedBox(height: 12),
          // WinUI 的空状态：标题走 Body（14）、说明走 Caption（12），
          // 两级都用次级/三级文字色 —— 以前是 15 + 13，比正文还大。
          Text(title, style: TextStyle(fontSize: 14, color: c.textSecondary)),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint!, style: TextStyle(fontSize: 12, color: c.textTertiary)),
          ],
        ],
      ),
    );
  }
}
