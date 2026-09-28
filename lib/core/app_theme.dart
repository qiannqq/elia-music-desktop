import 'package:flutter/material.dart';

/// 设计令牌 —— Fluent 2（Windows 11 / WinUI 3）的语义色。
///
/// 取值来自 WinUI 官方样式表 `microsoft-ui-xaml` 的
/// `controls/dev/CommonStyles/Common_themeresources_any.xaml`
/// （浅色 / 深色两套 `ResourceDictionary`），颜色写成 `#AARRGGBB` ——
/// 注意和 CSS 的 `#RRGGBBAA` 相反，官方那套的 alpha 是**第一位**。
///
/// 三件事和旧版（照搬旧 CSS 的那一套）不一样，改的时候别退回去：
///
///  1. **不是每个颜色都不透明**。Fluent 的 `TextFillColorPrimary` 浅色下是
///     `#E4000000`（89% 黑）、卡片底是 `#B3FFFFFF`（70% 白）—— 它们**本来
///     就带 alpha**，叠在「云母」背景上才是 Windows 11 的那种层次感。
///     所以别随手 `withValues(alpha: 1)` 把它们拍实。
///  2. **圆角分两档**：控件与卡片 **4**（`ControlCornerRadius`），
///     弹层 / 对话框 / 菜单 **8**（`OverlayCornerRadius`）。旧版是 8 / 12。
///  3. **强调色分两个家族**：`accent` 是用户挑的那个色（
///     `SystemAccentColor`，用于文字、图标、指示条）；`accentFill` 是**填充档**
///     （`AccentFillColorDefault` = 浅色 `SystemAccentColorDark1` /
///     深色 `SystemAccentColorLight2`，用于实心按钮、进度、开关）。
///     浅色主题下这两个差一档，直接用 `accent` 画实心按钮会比原生「亮」。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  // ---- 窗口与图层 ----
  /// 窗口底色（`SolidBackgroundFillColorBase`）。没开云母背景时它就是整窗的底。
  final Color bg;
  /// 页面内容层（`LayerFillColorDefault`）—— 云母之上那一层，半透明。
  final Color layer;
  /// 导航栏底色。官方展开态的 pane 是 `SolidBackgroundFillColorTransparent`：
  /// **完全透明**，让云母直接透上来，只靠一条分隔线跟内容区分。
  final Color sidebarBg;
  /// 标题栏底色。Win11 的标题栏同样是透明的（云母透上来）。
  final Color titlebarBg;
  /// 面板底（`SolidBackgroundFillColorTertiary`）—— 侧滑面板、弹出层这类实心面。
  final Color surface;
  final Color surfaceAlt;
  final Color playerBg;
  final Color modalOverlay;

  // ---- 卡片 ----
  /// 卡片底（`CardBackgroundFillColorDefault`）
  final Color card;
  /// 卡片悬停底（`CardBackgroundFillColorSecondary`）
  final Color cardHover;
  /// 卡片描边（`CardStrokeColorDefault`）
  final Color cardStroke;

  // ---- 文字 ----
  final Color text;
  final Color textSecondary;
  final Color textTertiary;
  final Color textDisabled;
  /// 主色上的字（`TextOnAccentFillColorPrimary`）
  final Color accentText;

  // ---- 强调色 ----
  final Color accent;
  final Color accentHover;
  final Color accentLight;
  /// 实心强调填充（`AccentFillColorDefault`）
  final Color accentFill;
  /// 悬停 / 按下：官方就是同一档填充压到 0.9 / 0.8 透明度
  /// （`AccentFillColorSecondary` / `Tertiary`）—— 观感是「往背景里淡一点」。
  final Color accentFillHover;
  final Color accentFillPressed;
  final Color accentFillDisabled;

  // ---- 控件填充（`ControlFillColor*`）----
  final Color controlFill;
  final Color controlFillHover;
  final Color controlFillPressed;
  final Color controlFillDisabled;

  // ---- 次级控件填充（`ControlAltFillColor*`）----
  /// 开关的「关」轨道、复选框未选中的底 —— 比 [controlFill] 淡得多，
  /// 这两套填充**不能混用**（一个是 70% 白，一个是 2% 黑）。
  final Color altFill;
  final Color altFillHover;
  final Color altFillPressed;

  // ---- 描边 ----
  /// 控件描边（`ControlStrokeColorDefault`）
  final Color border;
  /// 强调描边（开关的「开」轨道、复选框选中）
  final Color strokeStrong;
  final Color strokeStrongDisabled;
  /// 分隔线（`DividerStrokeColorDefault`）
  final Color borderSubtle;
  final Color inputBg;
  final Color inputBorder;
  final Color inputFocus;

  // ---- 交互叠加 ----
  /// 悬停（`SubtleFillColorSecondary`）
  final Color hover;
  /// 按下（`SubtleFillColorTertiary`）
  final Color active;

  // ---- 焦点 ----
  /// 焦点框外环（`FocusStrokeColorOuter`）—— 浅色主题下是**深色**那圈
  final Color focusOuter;
  /// 焦点框内环（`FocusStrokeColorInner`）
  final Color focusInner;

  // ---- 弹出层 ----
  /// 菜单 / 飞出层的底（WinUI 是亚克力，透明效果关掉时退回到
  /// `SolidBackgroundFillColorTertiary` —— 我们就用这份「官方兜底色」）
  final Color flyoutBg;
  /// 飞出层描边（`SurfaceStrokeColorFlyout`）
  final Color flyoutBorder;
  final Color scrollbarThumb;

  // ---- 状态色 ----
  final Color success;
  final Color successBg;
  final Color danger;
  final Color dangerBg;
  final Color caution;
  final Color badgeBg;
  final Color badgeText;
  final Color progressBg;
  final Color toastBg;
  final Color toastBorder;

  // ---- 阴影（Fluent 2 的 6 档 elevation）----
  final List<BoxShadow> elevation2;
  final List<BoxShadow> elevation4;
  final List<BoxShadow> elevation8;
  final List<BoxShadow> elevation16;
  final List<BoxShadow> elevation28;
  final List<BoxShadow> elevation64;

  /// 兼容旧名字：卡片/控件用 2 档
  List<BoxShadow> get shadow => elevation2;
  /// 兼容旧名字：对话框/面板用 16 档
  List<BoxShadow> get shadowLg => elevation16;

  // ---- 圆角 ----
  /// 控件与列表行圆角（官方 `ControlCornerRadius` 是 4 —— 这里取 6：
  /// 4 在 32px 高的按钮上看着接近直角，千奈真机看过之后要求「更圆一点点」。
  /// 要改回去就是这一个数）。
  final double radius;

  /// 卡片 / 弹层 / 对话框 / 菜单圆角（`OverlayCornerRadius` = 8）
  final double radiusLg;

  const AppColors({
    required this.bg,
    required this.layer,
    required this.sidebarBg,
    required this.titlebarBg,
    required this.surface,
    required this.surfaceAlt,
    required this.playerBg,
    required this.modalOverlay,
    required this.card,
    required this.cardHover,
    required this.cardStroke,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.textDisabled,
    required this.accentText,
    required this.accent,
    required this.accentHover,
    required this.accentLight,
    required this.accentFill,
    required this.accentFillHover,
    required this.accentFillPressed,
    required this.accentFillDisabled,
    required this.controlFill,
    required this.controlFillHover,
    required this.controlFillPressed,
    required this.controlFillDisabled,
    required this.altFill,
    required this.altFillHover,
    required this.altFillPressed,
    required this.border,
    required this.strokeStrong,
    required this.strokeStrongDisabled,
    required this.borderSubtle,
    required this.inputBg,
    required this.inputBorder,
    required this.inputFocus,
    required this.hover,
    required this.active,
    required this.focusOuter,
    required this.focusInner,
    required this.flyoutBg,
    required this.flyoutBorder,
    required this.scrollbarThumb,
    required this.success,
    required this.successBg,
    required this.danger,
    required this.dangerBg,
    required this.caution,
    required this.badgeBg,
    required this.badgeText,
    required this.progressBg,
    required this.toastBg,
    required this.toastBorder,
    required this.elevation2,
    required this.elevation4,
    required this.elevation8,
    required this.elevation16,
    required this.elevation28,
    required this.elevation64,
    this.radius = 6,
    this.radiusLg = 8,
  });

  static const AppColors light = AppColors(
    bg: Color(0xFFF3F3F3), // SolidBackgroundFillColorBase
    layer: Color(0x80FFFFFF), // LayerFillColorDefault
    sidebarBg: Color(0x00F3F3F3), // SolidBackgroundFillColorTransparent
    titlebarBg: Color(0x00F3F3F3),
    surface: Color(0xFFF9F9F9), // SolidBackgroundFillColorTertiary
    surfaceAlt: Color(0xFFEEEEEE), // SolidBackgroundFillColorSecondary
    playerBg: Color(0x80FFFFFF),
    modalOverlay: Color(0x4D000000), // SmokeFillColorDefault
    card: Color(0xB3FFFFFF), // CardBackgroundFillColorDefault
    cardHover: Color(0x80F6F6F6), // CardBackgroundFillColorSecondary
    cardStroke: Color(0x0F000000), // CardStrokeColorDefault
    text: Color(0xE4000000), // TextFillColorPrimary
    textSecondary: Color(0x9E000000), // TextFillColorSecondary
    textTertiary: Color(0x72000000), // TextFillColorTertiary
    textDisabled: Color(0x5C000000), // TextFillColorDisabled
    accentText: Color(0xFFFFFFFF),
    accent: Color(0xFF0078D4), // SystemAccentColor（默认那颗蓝）
    accentHover: Color(0xFF106EBE),
    accentLight: Color(0x140078D4),
    accentFill: Color(0xFF005FB8), // AccentFillColorDefault = SystemAccentColorDark1
    accentFillHover: Color(0xE6005FB8), // AccentFillColorSecondary（0.9）
    accentFillPressed: Color(0xCC005FB8), // AccentFillColorTertiary（0.8）
    accentFillDisabled: Color(0x37000000), // AccentFillColorDisabled
    controlFill: Color(0xB3FFFFFF), // ControlFillColorDefault
    controlFillHover: Color(0x80F9F9F9), // ControlFillColorSecondary
    controlFillPressed: Color(0x4DF9F9F9), // ControlFillColorTertiary
    controlFillDisabled: Color(0x4DF9F9F9), // ControlFillColorDisabled
    altFill: Color(0x06000000), // ControlAltFillColorSecondary
    altFillHover: Color(0x0F000000), // ControlAltFillColorTertiary
    altFillPressed: Color(0x18000000), // ControlAltFillColorQuarternary
    border: Color(0x0F000000), // ControlStrokeColorDefault
    strokeStrong: Color(0x72000000), // ControlStrongStrokeColorDefault
    strokeStrongDisabled: Color(0x37000000), // ControlStrongStrokeColorDisabled
    borderSubtle: Color(0x0F000000), // DividerStrokeColorDefault
    inputBg: Color(0xFFFFFFFF), // ControlFillColorInputActive
    inputBorder: Color(0x0F000000),
    inputFocus: Color(0xFF005FB8),
    hover: Color(0x09000000), // SubtleFillColorSecondary
    active: Color(0x06000000), // SubtleFillColorTertiary
    focusOuter: Color(0xE4000000), // FocusStrokeColorOuter
    focusInner: Color(0xB3FFFFFF), // FocusStrokeColorInner
    flyoutBg: Color(0xFFF9F9F9),
    flyoutBorder: Color(0x0F000000), // SurfaceStrokeColorFlyout
    scrollbarThumb: Color(0x72000000),
    success: Color(0xFF0F7B0F), // SystemFillColorSuccess
    successBg: Color(0xFFDFF6DD),
    danger: Color(0xFFC42B1C), // SystemFillColorCritical
    dangerBg: Color(0xFFFDE7E9),
    caution: Color(0xFF9D5D00), // SystemFillColorCaution
    badgeBg: Color(0x0F000000),
    badgeText: Color(0x9E000000),
    progressBg: Color(0x0F000000),
    toastBg: Color(0xFFF9F9F9),
    toastBorder: Color(0x0F000000),
    elevation2: [
      BoxShadow(color: Color(0x0F000000), blurRadius: 2),
      BoxShadow(color: Color(0x14000000), blurRadius: 2, offset: Offset(0, 1)),
    ],
    elevation4: [
      BoxShadow(color: Color(0x0F000000), blurRadius: 2),
      BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 2)),
    ],
    elevation8: [
      BoxShadow(color: Color(0x0F000000), blurRadius: 2),
      BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 4)),
    ],
    elevation16: [
      BoxShadow(color: Color(0x0F000000), blurRadius: 2),
      BoxShadow(color: Color(0x14000000), blurRadius: 16, offset: Offset(0, 8)),
    ],
    elevation28: [
      BoxShadow(color: Color(0x14000000), blurRadius: 8),
      BoxShadow(color: Color(0x24000000), blurRadius: 28, offset: Offset(0, 14)),
    ],
    elevation64: [
      BoxShadow(color: Color(0x14000000), blurRadius: 8),
      BoxShadow(color: Color(0x24000000), blurRadius: 64, offset: Offset(0, 32)),
    ],
  );

  static const AppColors dark = AppColors(
    bg: Color(0xFF202020),
    layer: Color(0x4C3A3A3A),
    sidebarBg: Color(0x00202020),
    titlebarBg: Color(0x00202020),
    surface: Color(0xFF282828),
    surfaceAlt: Color(0xFF1C1C1C),
    playerBg: Color(0x4C3A3A3A),
    modalOverlay: Color(0x4D000000),
    card: Color(0x0DFFFFFF),
    cardHover: Color(0x08FFFFFF),
    cardStroke: Color(0x19000000),
    text: Color(0xFFFFFFFF),
    textSecondary: Color(0xC5FFFFFF),
    textTertiary: Color(0x87FFFFFF),
    textDisabled: Color(0x5DFFFFFF),
    accentText: Color(0xFF003A52),
    accent: Color(0xFF60CDFF), // SystemAccentColorLight2
    accentHover: Color(0xFF7AD5FF),
    accentLight: Color(0x1A60CDFF),
    accentFill: Color(0xFF60CDFF),
    accentFillHover: Color(0xE660CDFF),
    accentFillPressed: Color(0xCC60CDFF),
    accentFillDisabled: Color(0x28FFFFFF),
    controlFill: Color(0x0FFFFFFF),
    controlFillHover: Color(0x15FFFFFF),
    controlFillPressed: Color(0x08FFFFFF),
    controlFillDisabled: Color(0x0BFFFFFF),
    altFill: Color(0x19000000),
    altFillHover: Color(0x0BFFFFFF),
    altFillPressed: Color(0x12FFFFFF),
    border: Color(0x12FFFFFF),
    strokeStrong: Color(0x8BFFFFFF),
    strokeStrongDisabled: Color(0x28FFFFFF),
    borderSubtle: Color(0x15FFFFFF),
    inputBg: Color(0xB31E1E1E),
    inputBorder: Color(0x12FFFFFF),
    inputFocus: Color(0xFF60CDFF),
    hover: Color(0x0FFFFFFF),
    active: Color(0x0AFFFFFF),
    focusOuter: Color(0xFFFFFFFF),
    focusInner: Color(0xB3000000),
    flyoutBg: Color(0xFF282828),
    flyoutBorder: Color(0x33000000),
    scrollbarThumb: Color(0x87FFFFFF),
    success: Color(0xFF6CCB5F),
    successBg: Color(0xFF393D1B),
    danger: Color(0xFFFF99A4),
    dangerBg: Color(0xFF442726),
    caution: Color(0xFFFCE100),
    badgeBg: Color(0x0FFFFFFF),
    badgeText: Color(0xC5FFFFFF),
    progressBg: Color(0x12FFFFFF),
    toastBg: Color(0xFF2C2C2C),
    toastBorder: Color(0x33000000),
    elevation2: [
      BoxShadow(color: Color(0x14000000), blurRadius: 2),
      BoxShadow(color: Color(0x1F000000), blurRadius: 2, offset: Offset(0, 1)),
    ],
    elevation4: [
      BoxShadow(color: Color(0x14000000), blurRadius: 2),
      BoxShadow(color: Color(0x1F000000), blurRadius: 4, offset: Offset(0, 2)),
    ],
    elevation8: [
      BoxShadow(color: Color(0x14000000), blurRadius: 2),
      BoxShadow(color: Color(0x1F000000), blurRadius: 8, offset: Offset(0, 4)),
    ],
    elevation16: [
      BoxShadow(color: Color(0x14000000), blurRadius: 2),
      BoxShadow(color: Color(0x1F000000), blurRadius: 16, offset: Offset(0, 8)),
    ],
    elevation28: [
      BoxShadow(color: Color(0x29000000), blurRadius: 8),
      BoxShadow(color: Color(0x40000000), blurRadius: 28, offset: Offset(0, 14)),
    ],
    elevation64: [
      BoxShadow(color: Color(0x29000000), blurRadius: 8),
      BoxShadow(color: Color(0x40000000), blurRadius: 64, offset: Offset(0, 32)),
    ],
  );
  /// 「有整体背景」时的那一套底：把几个**近乎不透明**的面变透。
  ///
  /// 为什么需要它：卡片（`card` 浅色 70% 白）、控件填充（`controlFill` 70% 白）、
  /// 输入框（`inputBg` 纯白）在纯色底上正好，一旦底下铺了照片，它们就是一排
  /// 「不透的白块」，把用户自己挑的背景挡死了（千奈报的「卡片基本不透明」）。
  ///
  /// 取值参照官方的 `LayerOnAcrylicFillColorDefault`（浅 `#40FFFFFF` /
  /// 深 `#09FFFFFF`）—— 那正是「压在亚克力上的一层」的官方值。
  /// 深色那档比官方稍厚：照片的亮部透上来会把白字的对比度吃掉。
  AppColors immersive({required bool dark}) => AppColors(
        bg: bg,
        layer: layer,
        sidebarBg: sidebarBg,
        titlebarBg: titlebarBg,
        surface: surface.withValues(alpha: dark ? 0.72 : 0.66),
        // ⚠️ 深色那档**不能**只是把原来的深色压透明：`surfaceAlt` 深色是
        // `#1C1C1C`，压在照片上就是一坨不透明的黑（千奈报的「CK 状态气泡
        // 在深色下是不透明的黑」）。有背景时它改用「淡淡的提亮」——
        // 和卡片同一档，看起来才像同一套材料。
        surfaceAlt:
            dark ? const Color(0x1FFFFFFF) : surfaceAlt.withValues(alpha: 0.45),
        playerBg: playerBg,
        modalOverlay: modalOverlay,
        card: dark ? const Color(0x1AFFFFFF) : const Color(0x59FFFFFF),
        cardHover: dark ? const Color(0x26FFFFFF) : const Color(0x73FFFFFF),
        cardStroke: cardStroke,
        text: text,
        textSecondary: textSecondary,
        textTertiary: textTertiary,
        textDisabled: textDisabled,
        accentText: accentText,
        accent: accent,
        accentHover: accentHover,
        accentLight: accentLight,
        accentFill: accentFill,
        accentFillHover: accentFillHover,
        accentFillPressed: accentFillPressed,
        accentFillDisabled: accentFillDisabled,
        controlFill: dark ? const Color(0x17FFFFFF) : const Color(0x4DFFFFFF),
        controlFillHover: dark ? const Color(0x26FFFFFF) : const Color(0x66FFFFFF),
        controlFillPressed: dark ? const Color(0x0DFFFFFF) : const Color(0x3DFFFFFF),
        controlFillDisabled: controlFillDisabled,
        altFill: altFill,
        altFillHover: altFillHover,
        altFillPressed: altFillPressed,
        border: border,
        strokeStrong: strokeStrong,
        strokeStrongDisabled: strokeStrongDisabled,
        borderSubtle: borderSubtle,
        inputBg: dark ? const Color(0x1FFFFFFF) : const Color(0x66FFFFFF),
        inputBorder: inputBorder,
        inputFocus: inputFocus,
        hover: hover,
        active: active,
        focusOuter: focusOuter,
        focusInner: focusInner,
        // 弹出层（菜单/对话框）**保持不透明**：它们要盖在照片上、又要一眼看清
        // 内容，透出来只会变成一锅粥。
        flyoutBg: flyoutBg,
        flyoutBorder: flyoutBorder,
        scrollbarThumb: scrollbarThumb,
        success: success,
        successBg: successBg,
        danger: danger,
        dangerBg: dangerBg,
        caution: caution,
        badgeBg: badgeBg,
        badgeText: badgeText,
        progressBg: progressBg,
        toastBg: toastBg,
        toastBorder: toastBorder,
        elevation2: elevation2,
        elevation4: elevation4,
        elevation8: elevation8,
        elevation16: elevation16,
        elevation28: elevation28,
        elevation64: elevation64,
        radius: radius,
        radiusLg: radiusLg,
      );

  @override
  AppColors copyWith() => this;

  /// 换掉整套 accent 家族，其余令牌沿用当前这套。
  ///
  /// [a] 是**已经定好的**那一档主色（深色主题要传深色档），
  /// 由 [themed] 负责挑档。
  AppColors withAccent(Color a, {required bool dark}) {
    final fill = AccentShades.fill(a, dark: dark);
    return AppColors(
      bg: bg,
      layer: layer,
      sidebarBg: sidebarBg,
      titlebarBg: titlebarBg,
      surface: surface,
      surfaceAlt: surfaceAlt,
      playerBg: playerBg,
      modalOverlay: modalOverlay,
      card: card,
      cardHover: cardHover,
      cardStroke: cardStroke,
      text: text,
      textSecondary: textSecondary,
      textTertiary: textTertiary,
      textDisabled: textDisabled,
      accentText: AccentShades.onAccent(a),
      accent: a,
      accentHover: AccentShades.hover(a, dark: dark),
      accentLight: AccentShades.wash(a, dark: dark),
      accentFill: fill,
      accentFillHover: fill.withValues(alpha: 0.9),
      accentFillPressed: fill.withValues(alpha: 0.8),
      accentFillDisabled: accentFillDisabled,
      controlFill: controlFill,
      controlFillHover: controlFillHover,
      controlFillPressed: controlFillPressed,
      controlFillDisabled: controlFillDisabled,
      altFill: altFill,
      altFillHover: altFillHover,
      altFillPressed: altFillPressed,
      border: border,
      strokeStrong: strokeStrong,
      strokeStrongDisabled: strokeStrongDisabled,
      borderSubtle: borderSubtle,
      inputBg: inputBg,
      inputBorder: inputBorder,
      // 聚焦时那条下划线走**填充档**：浅色主题下 #0078D4 压在卡片上偏亮，
      // 官方 FocusStroke/下划线用的是同一档填充色。
      inputFocus: fill,
      hover: hover,
      active: active,
      focusOuter: focusOuter,
      focusInner: focusInner,
      flyoutBg: flyoutBg,
      flyoutBorder: flyoutBorder,
      scrollbarThumb: scrollbarThumb,
      success: success,
      successBg: successBg,
      danger: danger,
      dangerBg: dangerBg,
      caution: caution,
      badgeBg: badgeBg,
      badgeText: badgeText,
      progressBg: progressBg,
      toastBg: toastBg,
      toastBorder: toastBorder,
      elevation2: elevation2,
      elevation4: elevation4,
      elevation8: elevation8,
      elevation16: elevation16,
      elevation28: elevation28,
      elevation64: elevation64,
      radius: radius,
      radiusLg: radiusLg,
    );
  }

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

  /// **填充档** —— WinUI 的 `AccentFillColorDefault`：浅色主题用
  /// `SystemAccentColorDark1`、深色主题用 `SystemAccentColorLight2`。
  ///
  /// 标定自 `#0078D4` → `#005FB8`：色相 +2.984°、亮度 ×0.867925、饱和度不动
  /// （`test/accent_theme_test.dart` 钉着这条，改常数会立刻红）。
  /// 深色那一档不用动 —— 传进来的深色主色**本身就是** `Light2`。
  static Color fill(Color accent, {required bool dark}) {
    if (dark) return accent;
    final h = HSLColor.fromColor(accent);
    return HSLColor.fromAHSL(
      h.alpha,
      _hue(h.hue + 2.984),
      h.saturation,
      (h.lightness * 0.867925).clamp(0.0, 1.0),
    ).toColor();
  }
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

/// 全局字体族 —— Windows 11 的界面字体是 **Segoe UI Variable**（光学尺寸分三档）。
///
/// 正文用 `Text` 那一档（12~36px 的界面文字都在这里），标题理论上该用
/// `Display` 那一档 —— 但两档在 Flutter 里要分别指定 family，
/// 换来的是每处标题都得记着换字体，收益不值得；统一用 Text 档，
/// `Display` 那一档只在真正的大标题（关于页那个 20px 的名字）上用。
///
/// ⚠️ 回退链要留 `Segoe UI`：Win10 上没有 Variable 那套字体，
/// 缺了它 Flutter 会退到一个和界面完全不搭的默认字体。
const String kFontFamily = 'Segoe UI Variable Text';
const List<String> kFontFallback = [
  'Segoe UI Variable',
  'Segoe UI',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
];

/// 标题用的那一档（光学尺寸更大、字距更松）
const String kFontDisplay = 'Segoe UI Variable Display';

/// Segoe Fluent Icons —— 标题栏那四个窗口按钮的**真字形**就在这个字体里
/// （`\uE921` 最小化 / `\uE922` 最大化 / `\uE923` 还原 / `\uE8BB` 关闭）。
/// Win10 上退到 `Segoe MDL2 Assets`，那几个码点在两套字体里是同一批。
const String kFluentIconsFont = 'Segoe Fluent Icons';
const List<String> kFluentIconsFallback = ['Segoe MDL2 Assets'];

/// 等宽字体（Cookie 输入框 / 歌词编辑框）
const String kMonoFontFamily = 'Cascadia Code';
const List<String> kMonoFontFallback = ['Consolas', 'Courier New'];

/// 间距标尺 —— 全应用只用这几档。
///
/// 立这一套是因为「间距不一」是肉眼最先看出来的毛病：同一个页面里
/// 一会儿 16、一会儿 20、一会儿 24，单看每一处都说得过去，摆在一起就乱。
/// 需要间距时从这里面挑一档，别随手写数字。
///
/// 页面级的用法（也是这次统一后的口径）：
///  * 页面左右外边距 [page] = 24 —— 窗口边缘到内容的留白；
///  * 页头统一「上 20、下 16」；
///  * 卡片之间 [gap] = 12，卡片内边距 [`cardPadH`, `cardPadV`] = 20 / 16；
///  * 控件之间 [inline] = 8，图标与文字之间 [tight] = 6。
abstract final class AppSpace {
  /// 4 —— 紧贴的图标与徽标
  static const double xxs = 4;

  /// 8 —— 并排控件之间
  static const double inline = 8;

  /// 12 —— 卡片之间
  static const double gap = 12;

  /// 16 —— 段落内部的行距
  static const double line = 16;

  /// 16 —— 卡片上下内边距
  static const double cardPadV = 16;

  /// 20 —— 卡片左右内边距
  static const double cardPadH = 20;

  /// 24 —— 页面左右外边距（窗口边缘到内容的那圈留白）
  static const double page = 24;

  /// 20 —— 页头上边距
  static const double pageTop = 20;

  /// 16 —— 页头下边距
  static const double pageHeaderBottom = 16;
}

/// 窗口按钮宽度。Win11 官方是 46×32，这里取 **40**：46 那版在自绘标题栏上
/// 显得比系统的还大一圈（千奈真机看出来的），窄一点更贴合。
const double kWindowButtonWidth = 40;

/// 标题栏高度。现在播放页要盖住整窗（含标题栏区域），所以这个数字
/// 两边都得用 —— 别各写各的。
const double kTitlebarHeight = 32;

ThemeData buildTheme(AppColors c, Brightness brightness) {
  final dark = brightness == Brightness.dark;
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
    // 光标与文本选择：官方是主色填充 + 反色文字，不是半透明高亮
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: dark ? 0.45 : 0.32),
    ),
    textTheme: TextTheme(
      // Fluent 2 的字号阶梯：Body 14 / Caption 12
      bodyMedium: TextStyle(fontSize: 14, height: 1.43, color: c.text),
      bodySmall: TextStyle(fontSize: 12, height: 1.33, color: c.textSecondary),
      titleMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.text),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: c.text),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.flyoutBg,
        borderRadius: BorderRadius.circular(c.radius),
        border: Border.all(color: c.flyoutBorder),
        boxShadow: c.elevation16,
      ),
      textStyle: TextStyle(fontSize: 12, height: 1.33, color: c.text),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      waitDuration: const Duration(milliseconds: 400),
    ),
    // 滚动条：Win11 的是一条**很细的条**，鼠标进到它上面才变粗
    // （官方 `ScrollBarVerticalThumbMinWidth` = 8，收起态更细）。
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.dragged) ||
                states.contains(WidgetState.hovered)
            ? 8
            : 4,
      ),
      radius: const Radius.circular(4),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.dragged)
            ? c.scrollbarThumb
            : c.scrollbarThumb.withValues(alpha: 0.5),
      ),
      trackColor: WidgetStateProperty.all(Colors.transparent),
      trackBorderColor: WidgetStateProperty.all(Colors.transparent),
      crossAxisMargin: 2,
    ),
    // 动画时长：material 的默认值（200/300/...）跟 Fluent 的档位对不上，
    // 统一压到 Fluent 那一套，省得同一个界面里两种节奏打架。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.windows: _NoAnimationPageTransitionsBuilder(),
      },
    ),
  );
}

/// 页面切换**不做**过渡：Win11 的应用里，内容区换页是瞬间替换的，
/// 只有导航项自己的选中态在动。这里禁掉 Material 默认的滑动/淡入。
class _NoAnimationPageTransitionsBuilder extends PageTransitionsBuilder {
  const _NoAnimationPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}
