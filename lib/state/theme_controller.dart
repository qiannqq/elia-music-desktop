import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/local_store.dart';
import '../services/app_background.dart';
import '../services/shell_service.dart';
import '../ui/icons.dart';

/// 主题模式 —— 对应 `theme.js`（浅色 / 深色 / 跟随系统）
enum AppThemeMode { system, light, dark }

extension AppThemeModeX on AppThemeMode {
  String get id => switch (this) {
        AppThemeMode.system => 'system',
        AppThemeMode.light => 'light',
        AppThemeMode.dark => 'dark',
      };

  String get label => switch (this) {
        AppThemeMode.system => '跟随系统',
        AppThemeMode.light => '浅色',
        AppThemeMode.dark => '深色',
      };

  String get icon => switch (this) {
        AppThemeMode.system => AppIcons.themeSystem,
        AppThemeMode.light => AppIcons.themeLight,
        AppThemeMode.dark => AppIcons.themeDark,
      };

  static AppThemeMode fromId(String? id) => switch (id) {
        'light' => AppThemeMode.light,
        'dark' => AppThemeMode.dark,
        _ => AppThemeMode.system,
      };
}

/// 主题控制器 —— 持久化键 `qqmusic_theme`（与原 localStorage 键一致）
class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  /// 主题色持久化键。存 `RRGGBB`（不带 alpha），省得以后再改格式。
  static const String _accentKey = 'qqmusic_accent';

  AppThemeMode mode = AppThemeMode.system;

  /// 用户选的主题色。默认就是旧版那个蓝 —— 没动过设置时界面与以前完全一致
  /// （`test/accent_theme_test.dart` 盯着这条）。
  Color accent = kAccentPresets.first;

  /// 上一次从**系统**取到的强调色（取不到就是 null）。
  /// 设置页靠它判断「恢复默认」这一项要不要置灰。
  Color? systemAccent;

  void init() {
    mode = AppThemeModeX.fromId(LocalStore.get('qqmusic_theme'));
    final raw = LocalStore.get(_accentKey);
    if (raw != null && raw.isNotEmpty) {
      final v = int.tryParse(raw, radix: 16);
      // 存坏了就退回默认色，不要拿一个随机值去糊整个界面
      if (v != null) accent = Color(0xFF000000 | v);
      return;
    }

    // 从来没挑过主题色（第一次启动）→ **跟一次** Windows 的强调色。
    //
    // ⚠️ 只做这一次：[_apply] 会把结果写进存储，之后启动就走上面那条分支，
    // 不再覆盖用户自己挑的颜色。取不到（老系统、注册表里没有）就一直是默认蓝，
    // 下次启动还会再试一次 —— 这比「试一次失败就永久放弃」合理。
    unawaited(useSystemAccent());
  }

  /// 取一次 Windows 的强调色并应用（首次启动与设置页的「恢复默认」都走这条）。
  ///
  /// 返回是否取到了。
  Future<bool> useSystemAccent() async {
    final c = await ShellService.systemAccentColor();
    if (c == null) return false;
    systemAccent = c;
    _apply(c);
    return true;
  }

  void setAccent(Color c) => _apply(c);

  void setMode(AppThemeMode m) {
    if (mode == m) return;
    mode = m;
    LocalStore.set('qqmusic_theme', m.id);
    notifyListeners();
  }

  /// 换主题色。**无条件落盘**（即使颜色没变）——
  /// 否则「跟系统色」取到一个正好等于默认蓝的值时不会写存储，
  /// 下次启动又会去取一遍，就变成「每次都跟」了。
  void _apply(Color c) {
    final next = Color(0xFF000000 | (c.toARGB32() & 0xFFFFFF));
    final changed = accent.toARGB32() != next.toARGB32();
    accent = next;
    LocalStore.set(
        _accentKey, (next.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0'));
    if (changed) notifyListeners();
  }

  Brightness resolveBrightness(Brightness platform) => switch (mode) {
        AppThemeMode.light => Brightness.light,
        AppThemeMode.dark => Brightness.dark,
        AppThemeMode.system => platform,
      };

  ThemeData resolve(Brightness platform) {
    final b = resolveBrightness(platform);
    final dark = b == Brightness.dark;
    var colors = AppColors.themed(accent, dark: dark);
    // 开了整体背景 → 卡片与控件那几层要透一些，否则一排「白块」把背景挡死
    // （见 `AppColors.immersive` 的说明）。主题跟着背景开关重新解析一次，
    // 所以 `EliaMusicApp` 那边要同时听 themeController 与 appBackground。
    if (appBackground.active) colors = colors.immersive(dark: dark);
    return buildTheme(colors, b);
  }
}

final themeController = ThemeController.instance;
