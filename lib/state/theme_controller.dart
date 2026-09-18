import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/local_store.dart';
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

  AppThemeMode mode = AppThemeMode.system;

  void init() {
    mode = AppThemeModeX.fromId(LocalStore.get('qqmusic_theme'));
  }

  void setMode(AppThemeMode m) {
    if (mode == m) return;
    mode = m;
    LocalStore.set('qqmusic_theme', m.id);
    notifyListeners();
  }

  Brightness resolveBrightness(Brightness platform) => switch (mode) {
        AppThemeMode.light => Brightness.light,
        AppThemeMode.dark => Brightness.dark,
        AppThemeMode.system => platform,
      };

  ThemeData resolve(Brightness platform) {
    final b = resolveBrightness(platform);
    return buildTheme(b == Brightness.dark ? AppColors.dark : AppColors.light, b);
  }
}

final themeController = ThemeController.instance;
