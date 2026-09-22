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

  @override
  AppColors copyWith() => this;

  /// 换掉整套 accent 家族，其余令牌沿用当前这套。
  ///
  /// [a] 是**已经定好的**那一档主色（深色主题要传深色档），
  /// 由 [themed] 负责挑档。
  AppColors withAccent(Color a, {required bool dark}) => AppColors(
        bg: bg,
        surface: surface,
        surfaceAlt: surfaceAlt,
        text: text,
        textSecondary: textSecondary,
        textTertiary: textTertiary,
        accent: a,
        accentHover: AccentShades.hover(a, dark: dark),
        accentLight: AccentShades.wash(a, dark: dark),
        accentText: AccentShades.onAccent(a),
        border: border,
        borderSubtle: borderSubtle,
        hover: hover,
        active: active,
        card: card,
        cardHover: cardHover,
        titlebarBg: titlebarBg,
        sidebarBg: sidebarBg,
        playerBg: playerBg,
        modalOverlay: modalOverlay,
        scrollbarThumb: scrollbarThumb,
        inputBg: inputBg,
        inputBorder: inputBorder,
        inputFocus: a,
        badgeBg: badgeBg,
        badgeText: badgeText,
        progressBg: progressBg,
        toastBg: toastBg,
        toastBorder: toastBorder,
        success: success,
        danger: danger,
        shadow: shadow,
        shadowLg: shadowLg,
        radius: radius,
        radiusLg: radiusLg,
      );

  /// 按用户选的主题色生成一整套令牌。
  ///
  /// [accent] 传用户选的**那个**色（浅色主题下直接就是它）；深色主题这一档
  /// 由 [AccentShades.forDark] 现推 —— 用户只挑一个色，两套主题都得能用。
  factory AppColors.themed(Color accent, {required bool dark}) {
    final base = dark ? AppColors.dark : AppColors.light;
    return base.withAccent(
      dark ? AccentShades.forDark(accent) : accent,
      dark: dark,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    // 主题切换采用整体替换（配合 0.3s 过渡），逐字段插值无实际收益
    return t < 0.5 ? this : other;
  }
}

/// accent 家族的派生规则。
///
/// 旧版 CSS 里那组蓝是**手调**的：`#0078D4`（浅色主色）、`#106EBE`（浅色悬停）、
/// `#60CDFF`（深色主色）、`#7AD5FF`（深色悬停）、`#003A52`（深色下的反色文字）。
/// 它们各自的色相偏移是 `+1.55° / +0.08° / −7.17° / −1.31°` —— 互相矛盾，
/// 不存在单一公式能同时解释这四对，所以别指望「反推出一个漂亮算法」。
///
/// 做法反过来：在 HSL 里用一组**标定过的常数**去拟合，让默认蓝能被逐位还原
/// （`test/accent_theme_test.dart` 盯着这件事，改坏会立刻红），
/// 再把这组常数套到用户选的任何主题色上。每个常数后面都写着它是从哪一对
/// 颜色标定出来的，这样以后想微调也能知道动了什么。
abstract final class AccentShades {
  /// 色相绕回 [0, 360)。红色系（色相 < 7°）减一档就成负数，
  /// 而 `HSLColor` 会直接断言失败 —— 必须绕，不能让它越界。
  static double _hue(double v) {
    if (v < 0) return v + 360;
    if (v >= 360) return v - 360;
    return v;
  }

  /// 深色主题的主色 —— 用户选的色「淡一号」。
  ///
  /// 标定自 `#0078D4` → `#60CDFF`：往白走 46.64%，色相 −7.17°，饱和度不动。
  /// 往白走用比例（而不是加一个固定值）是为了不撞顶：很亮的色再往上加会直接
  /// 被钳成纯白，比例式只会越来越接近白，不会一步撞死。
  static Color forDark(Color accent) {
    final h = HSLColor.fromColor(accent);
    return HSLColor.fromAHSL(
      h.alpha,
      _hue(h.hue - 7.17),
      h.saturation,
      h.lightness + (1 - h.lightness) * 0.4664,
    ).toColor();
  }

  /// 悬停态。
  ///
  /// * 浅色标定自 `#0078D4` → `#106EBE`：色相 +1.55°、亮度 ×0.9717、饱和度 ×0.8447。
  /// * 深色标定自 `#60CDFF` → `#7AD5FF`：色相 +0.08°、亮度 ×1.0741、饱和度不动。
  ///
  /// 两边方向相反不是笔误：浅色主题的主色本来就偏深，悬停该更沉；
  /// 深色主题的主色是亮蓝，悬停该更亮。这是两套主题各自的观感需求。
  static Color hover(Color accent, {required bool dark}) {
    final h = HSLColor.fromColor(accent);
    final dH = dark ? 0.08 : 1.55;
    final kL = dark ? 1.0741 : 0.9717;
    final kS = dark ? 1.0 : 0.8447;
    return HSLColor.fromAHSL(
      h.alpha,
      _hue(h.hue + dH),
      (h.saturation * kS).clamp(0.0, 1.0),
      (h.lightness * kL).clamp(0.0, 1.0),
    ).toColor();
  }

  /// 主色上的文字色。
  ///
  /// 按**对比度**选，不按主题选：主色够亮就用它的深色版当字，否则用白字。
  /// 阈值 0.30 是算出来的 —— 白字要够用需要主色的相对亮度低于 0.30
  /// （再高就只有 3:1 以下，读不清）。
  ///
  /// 深色版的标定：`#60CDFF` → `#003A52`，色相 −1.31°、亮度 ×0.2336。
  static Color onAccent(Color accent) {
    if (accent.computeLuminance() < 0.30) return const Color(0xFFFFFFFF);
    final h = HSLColor.fromColor(accent);
    return HSLColor.fromAHSL(
      h.alpha,
      _hue(h.hue - 1.31),
      h.saturation,
      h.lightness * 0.2336,
    ).toColor();
  }

  /// 选中底 / 光晕用的淡色 —— 就是主色本身压到很低的透明度。
  ///
  /// 标定自 `Color(0x140078D4)` / `Color(0x1A60CDFF)`：深浅两套的 alpha 不同
  /// （20 / 26），因为深色底上淡色更难看出来，得给厚一点。
  static Color wash(Color accent, {required bool dark}) =>
      accent.withAlpha(dark ? 0x1A : 0x14);
}

/// 调色板预设。第一个是默认蓝 —— 与旧版完全一致，也是 [ThemeController] 的初值。
const List<Color> kAccentPresets = [
  Color(0xFF0078D4), // 默认蓝（旧版配色）
  Color(0xFF2B88D8), // 天蓝
  Color(0xFF00B7C3), // 青
  Color(0xFF038387), // 深青
  Color(0xFF0F7B0F), // 绿
  Color(0xFF498205), // 橄榄
  Color(0xFF7B3FE4), // 紫
  Color(0xFF8764B8), // 藕荷
  Color(0xFFC239B3), // 品红
  Color(0xFFE8115A), // 玫红
  Color(0xFFC42B1C), // 红
  Color(0xFFE8590C), // 橙
  Color(0xFFB8860B), // 金
  Color(0xFF6B6B6B), // 灰
  Color(0xFF8E562E), // 棕
  Color(0xFF1A1A1A), // 近黑
];

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
