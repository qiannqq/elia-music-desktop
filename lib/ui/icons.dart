import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 图标 —— 直接沿用原版内联 SVG 的路径数据，保证图形形态与旧版一致。
class AppIcons {
  AppIcons._();

  // 品牌 / 标题栏
  static const music =
      '<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>';

  // 窗口按钮（viewBox 0 0 12 12）
  static const minimize = '<line x1="1" y1="6" x2="11" y2="6"/>';
  static const maximize = '<rect x="1.5" y="1.5" width="9" height="9" rx="1"/>';
  // ⚠️ 本图标是 **12 见方**坐标系，与标题栏的 minimize / maximize 同族
  // （标题栏的 _TitlebarButton 显式传 viewBox: 12）。
  // 在 24 坐标系的地方用它，必须显式传 viewBox: 12 ——
  // 否则 12 的路径会被当成 24 的画布，只画在左上角四分之一里
  // （看起来「又小又偏」，播放栏的关闭按钮就踩过这个坑）。
  static const close =
      '<line x1="2" y1="2" x2="10" y2="10"/><line x1="10" y1="2" x2="2" y2="10"/>';

  // 导航
  static const search = '<circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>';
  static const playlist =
      '<path d="M21 15V6"/><path d="M18.5 18a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z"/><path d="M12 12H3"/><path d="M16 6H3"/><path d="M12 18H3"/>';
  static const settings =
      '<circle cx="12" cy="12" r="3"/><path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42"/>';
  static const info =
      '<circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/>';

  // 播放控制（fill 型）
  static const play = '<polygon points="5 3 19 12 5 21 5 3"/>';
  static const pause = '<rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/>';
  static const prev =
      '<polygon points="19 20 9 12 19 4 19 20"/><line x1="5" y1="19" x2="5" y2="5" stroke-width="2"/>';
  static const next =
      '<polygon points="5 4 15 12 5 20 5 4"/><line x1="19" y1="5" x2="19" y2="19" stroke-width="2"/>';

  // 播放模式
  static const repeatAll =
      '<polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7 23 3 19 7 15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/>';
  static const repeatOne =
      '<polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7 23 3 19 7 15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/><text x="12" y="15" text-anchor="middle" font-size="8">1</text>';
  static const shuffle =
      '<polyline points="16 3 21 3 21 8"/><line x1="4" y1="20" x2="21" y2="3"/><polyline points="21 16 21 21 16 21"/><line x1="15" y1="15" x2="21" y2="21"/><line x1="4" y1="4" x2="9" y2="9"/>';

  // 操作
  static const download =
      '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>';
  static const folder =
      '<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>';
  static const check = '<path d="M20 6L9 17l-5-5"/>';
  static const trash =
      '<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>';
  static const lyricDoc =
      '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/>';
  static const edit =
      '<path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/>';
  static const volume =
      '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07"/>';

  // 眼睛（Cookie 显隐）
  static const eyeOpen =
      '<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/>';
  static const eyeClosed =
      '<path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/>';

  // Toast
  static const toastSuccess = check;
  static const toastError =
      '<circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/>';
  static const toastInfo =
      '<circle cx="12" cy="12" r="10"/><line x1="12" y1="17" x2="12" y2="12"/><circle cx="12" cy="6.5" r="1.5" fill="currentColor" stroke="none"/>';
  static const toastProgress =
      '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>';

  // 确认框
  static const warning =
      '<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>';

  // 主题
  static const themeSystem =
      '<rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>';
  static const themeLight =
      '<circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/>';
  static const themeDark = '<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>';

  static const sources = {
    'qq': '<span/>',
    'netease': '<span/>',
  };
}

String _hex(Color c) {
  final v = c.toARGB32();
  final r = (v >> 16) & 0xFF;
  final g = (v >> 8) & 0xFF;
  final b = v & 0xFF;
  return '#${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')}';
}

String _alphaOf(Color c) {
  final a = ((c.toARGB32() >> 24) & 0xFF) / 255.0;
  return a.toStringAsFixed(3);
}

/// 用原始 SVG 路径渲染图标。
///
/// - [body] 为 SVG 内部标记（不含 `<svg>` 外壳）
/// - [filled] 为 true 时按填充绘制（播放/暂停等实心图标）
/// - [viewBox] 默认 24，窗口按钮使用 12
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.body, {
    super.key,
    this.size = 16,
    this.color = const Color(0xFF000000),
    this.strokeWidth = 2,
    this.filled = false,
    this.viewBox = 24,
  });

  final String body;
  final double size;
  final Color color;
  final double strokeWidth;
  final bool filled;
  final double viewBox;

  @override
  Widget build(BuildContext context) {
    final hex = _hex(color);
    final opacity = _alphaOf(color);
    final op = opacity == '1.000' ? '' : ' opacity="$opacity"';

    // 内联 `stroke-width` / `fill="currentColor"` 的覆盖处理
    var inner = body.replaceAll('currentColor', hex);
    inner = inner.replaceAllMapped(
      RegExp(r'stroke-width="([\d.]+)"'),
      (m) => 'stroke-width="${m.group(1)}"',
    );

    final svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $viewBox $viewBox"'
        ' fill="${filled ? hex : 'none'}"'
        ' stroke="${filled ? 'none' : hex}"'
        ' stroke-width="$strokeWidth"'
        ' stroke-linecap="round" stroke-linejoin="round"$op>$inner</svg>';

    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      fit: BoxFit.contain,
      allowDrawingOutsideViewBox: true,
    );
  }
}
