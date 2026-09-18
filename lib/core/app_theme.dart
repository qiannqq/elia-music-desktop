import 'package:flutter/material.dart';

/// 设计令牌 —— 原 `public/dist/css/app.css` 中 `:root` / `[data-theme="dark"]`
/// 的 CSS 变量一对一映射，保证配色、圆角、阴影与旧版完全一致。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color text;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;
  final Color accentHover;
  final Color accentLight;
  final Color accentText;
  final Color border;
  final Color borderSubtle;
  final Color hover;
  final Color active;
  final Color card;
  final Color cardHover;
  final Color titlebarBg;
  final Color sidebarBg;
  final Color playerBg;
  final Color modalOverlay;
  final Color scrollbarThumb;
  final Color inputBg;
  final Color inputBorder;
  final Color inputFocus;
  final Color badgeBg;
  final Color badgeText;
  final Color progressBg;
  final Color toastBg;
  final Color toastBorder;
  final Color success;
  final Color danger;
  final List<BoxShadow> shadow;
  final List<BoxShadow> shadowLg;
  final double radius;
  final double radiusLg;

  const AppColors({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentHover,
    required this.accentLight,
    required this.accentText,
    required this.border,
    required this.borderSubtle,
    required this.hover,
    required this.active,
    required this.card,
    required this.cardHover,
    required this.titlebarBg,
    required this.sidebarBg,
    required this.playerBg,
    required this.modalOverlay,
    required this.scrollbarThumb,
    required this.inputBg,
    required this.inputBorder,
    required this.inputFocus,
    required this.badgeBg,
    required this.badgeText,
    required this.progressBg,
    required this.toastBg,
    required this.toastBorder,
    required this.success,
    required this.danger,
    required this.shadow,
    required this.shadowLg,
    this.radius = 8,
    this.radiusLg = 12,
  });

  static const AppColors light = AppColors(
    bg: Color(0xFFF3F3F3),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF9F9F9),
    text: Color(0xFF1A1A1A),
    textSecondary: Color(0xFF616161),
    textTertiary: Color(0xFF8A8A8A),
    accent: Color(0xFF0078D4),
    accentHover: Color(0xFF106EBE),
    accentLight: Color(0x140078D4),
    accentText: Color(0xFFFFFFFF),
    border: Color(0xFFE0E0E0),
    borderSubtle: Color(0xFFEBEBEB),
    hover: Color(0xFFE9E9E9),
    active: Color(0xFFD4D4D4),
    card: Color(0xFFFFFFFF),
    cardHover: Color(0xFFF5F5F5),
    titlebarBg: Color(0xD9F3F3F3),
    sidebarBg: Color(0xFFF9F9F9),
    playerBg: Color(0xE6FFFFFF),
    modalOverlay: Color(0x4D000000),
    scrollbarThumb: Color(0xFFC1C1C1),
    inputBg: Color(0xFFFFFFFF),
    inputBorder: Color(0xFFD1D1D1),
    inputFocus: Color(0xFF0078D4),
    badgeBg: Color(0xFFE8E8E8),
    badgeText: Color(0xFF616161),
    progressBg: Color(0xFFE0E0E0),
    toastBg: Color(0xFFFFFFFF),
    toastBorder: Color(0xFFE0E0E0),
    success: Color(0xFF0F7B0F),
    danger: Color(0xFFC42B1C),
    shadow: [BoxShadow(color: Color(0x0F000000), blurRadius: 8, offset: Offset(0, 2))],
    shadowLg: [BoxShadow(color: Color(0x14000000), blurRadius: 32, offset: Offset(0, 8))],
  );

  static const AppColors dark = AppColors(
    bg: Color(0xFF202020),
    surface: Color(0xFF2D2D2D),
    surfaceAlt: Color(0xFF262626),
    text: Color(0xFFF5F5F5),
    textSecondary: Color(0xFFA0A0A0),
    textTertiary: Color(0xFF707070),
    accent: Color(0xFF60CDFF),
    accentHover: Color(0xFF7AD5FF),
    accentLight: Color(0x1A60CDFF),
    accentText: Color(0xFF003A52),
    border: Color(0xFF3D3D3D),
    borderSubtle: Color(0xFF333333),
    hover: Color(0xFF383838),
    active: Color(0xFF444444),
    card: Color(0xFF2D2D2D),
    cardHover: Color(0xFF353535),
    titlebarBg: Color(0xD9202020),
    sidebarBg: Color(0xFF262626),
    playerBg: Color(0xEB2D2D2D),
    modalOverlay: Color(0x80000000),
    scrollbarThumb: Color(0xFF555555),
    inputBg: Color(0xFF3A3A3A),
    inputBorder: Color(0xFF505050),
    inputFocus: Color(0xFF60CDFF),
    badgeBg: Color(0xFF3A3A3A),
    badgeText: Color(0xFFA0A0A0),
    progressBg: Color(0xFF3D3D3D),
    toastBg: Color(0xFF2D2D2D),
    toastBorder: Color(0xFF3D3D3D),
    success: Color(0xFF0F7B0F),
    danger: Color(0xFFC42B1C),
    shadow: [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
    shadowLg: [BoxShadow(color: Color(0x4D000000), blurRadius: 32, offset: Offset(0, 8))],
  );

  /// 主色调的 RGB（用于 glow 动画等需要 alpha 组合的场景）
  Color accentWithOpacity(double opacity) => accent.withValues(alpha: opacity);

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    // 主题切换采用整体替换（配合 0.3s 过渡），逐字段插值无实际收益
    return t < 0.5 ? this : other;
  }
}

/// 从 context 取设计令牌
extension AppColorsX on BuildContext {
  AppColors get c => Theme.of(this).extension<AppColors>() ?? AppColors.light;
}

/// 全局字体族（对应 CSS 的 font-family 栈）
const String kFontFamily = 'Segoe UI';
const List<String> kFontFallback = ['Microsoft YaHei UI', 'Microsoft YaHei'];

/// 等宽字体（Cookie 输入框 / 歌词编辑框）
const String kMonoFontFamily = 'Cascadia Code';
const List<String> kMonoFontFallback = ['Consolas', 'Courier New'];

ThemeData buildTheme(AppColors c, Brightness brightness) {
  return ThemeData(
    useMaterial3: false,
    brightness: brightness,
    fontFamily: kFontFamily,
    fontFamilyFallback: kFontFallback,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    dividerColor: c.borderSubtle,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: c.hover,
    extensions: <ThemeExtension<dynamic>>[c],
    textTheme: TextTheme(
      bodyMedium: TextStyle(fontSize: 14, color: c.text),
      bodySmall: TextStyle(fontSize: 13, color: c.textSecondary),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      textStyle: TextStyle(color: c.text, fontSize: 12),
      waitDuration: const Duration(milliseconds: 500),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered) ? c.textTertiary : c.scrollbarThumb,
      ),
      trackColor: WidgetStateProperty.all(Colors.transparent),
      crossAxisMargin: 0,
    ),
  );
}
