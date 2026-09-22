import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_theme.dart';

/// 主题色推导必须**逐位**还原旧版那套蓝。
///
/// 这条是硬约束：用户没换主题色时，界面必须和以前一模一样。
/// 标定常数一旦被谁动了，这里会立刻红 —— 而不是等到肉眼发现「蓝变了」。
void main() {
  const blueLight = Color(0xFF0078D4);
  const blueDark = Color(0xFF60CDFF);

  String hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  test('深色主题的主色 = 浅色主色淡一号', () {
    expect(hex(AccentShades.forDark(blueLight)), hex(blueDark),
        reason: '标定自 #0078D4 → #60CDFF');
  });

  test('悬停色：浅色更沉、深色更亮', () {
    expect(hex(AccentShades.hover(blueLight, dark: false)), '#106EBE',
        reason: '标定自 #0078D4 → #106EBE');
    expect(hex(AccentShades.hover(blueDark, dark: true)), '#7AD5FF',
        reason: '标定自 #60CDFF → #7AD5FF');
  });

  test('反色文字按对比度选：暗底白字、亮底用主色的深色版', () {
    expect(hex(AccentShades.onAccent(blueLight)), '#FFFFFF',
        reason: '浅色主题主色偏深，白字');
    expect(hex(AccentShades.onAccent(blueDark)), '#003A52',
        reason: '标定自 #60CDFF → #003A52');
  });

  test('淡色底就是主色压透明度，深浅两套的 alpha 不同', () {
    expect(AccentShades.wash(blueLight, dark: false).toARGB32(),
        const Color(0x140078D4).toARGB32());
    expect(AccentShades.wash(blueDark, dark: true).toARGB32(),
        const Color(0x1A60CDFF).toARGB32());
  });

  test('默认蓝生成的整套令牌与旧版常量完全一致', () {
    for (final (dark, base) in [(false, AppColors.light), (true, AppColors.dark)]) {
      final t = AppColors.themed(blueLight, dark: dark);
      final label = dark ? '深色' : '浅色';
      expect(hex(t.accent), hex(base.accent), reason: '$label accent');
      expect(hex(t.accentHover), hex(base.accentHover), reason: '$label accentHover');
      expect(hex(t.accentText), hex(base.accentText), reason: '$label accentText');
      expect(hex(t.inputFocus), hex(base.inputFocus), reason: '$label inputFocus');
      expect(t.accentLight.toARGB32(), base.accentLight.toARGB32(),
          reason: '$label accentLight');
      // 非 accent 家族一个都不该动
      expect(t.bg, base.bg);
      expect(t.text, base.text);
      expect(t.success, base.success);
      expect(t.danger, base.danger);
    }
  });

  test('换别的主题色时，派生色仍然可用（不撞顶、不透明、有对比）', () {
    for (final preset in kAccentPresets) {
      final dark = AccentShades.forDark(preset);
      final light = AppColors.themed(preset, dark: false);
      final darkSet = AppColors.themed(preset, dark: true);

      // 深色档必须比浅色档亮，否则深色底上会糊住
      expect(HSLColor.fromColor(dark).lightness,
          greaterThan(HSLColor.fromColor(preset).lightness),
          reason: '$preset 的深色档没有变亮');

      for (final c in [light.accent, light.accentHover, light.accentText,
                       darkSet.accent, darkSet.accentHover, darkSet.accentText]) {
        expect(c.a, 1.0, reason: '派生色不该带透明');
      }

      // 主色上的字必须读得清：对比度按 WCAG 至少 3:1
      double contrast(Color a, Color b) {
        final la = a.computeLuminance(), lb = b.computeLuminance();
        final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
      }

      expect(contrast(light.accent, light.accentText), greaterThan(3.0),
          reason: '$preset 浅色主色上的字对比度不够');
      expect(contrast(darkSet.accent, darkSet.accentText), greaterThan(3.0),
          reason: '$preset 深色主色上的字对比度不够');
    }
  });
}
