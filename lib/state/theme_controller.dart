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

  /// 主题色持久化键。存 `RRGGBB`（不带 alpha），省得以后再改格式。
  static const String _accentKey = 'qqmusic_accent';

  AppThemeMode mode = AppThemeMode.system;

  /// 用户选的主题色。默认就是旧版那个蓝 —— 没动过设置时界面与以前完全一致
  /// （`test/accent_theme_test.dart` 盯着这条）。
  Color accent = kAccentPresets.first;

  void init() {
    mode = AppThemeModeX.fromId(LocalStore.get('qqmusic_theme'));
    final raw = LocalStore.get(_accentKey);
    if (raw != null && raw.isNotEmpty) {
      final v = int.tryParse(raw, radix: 16);
      // 存坏了就退回默认色，不要拿一个随机值去糊整个界面
      if (v != null) accent = Color(0xFF000000 | v);
    }
  }

  void setMode(AppThemeMode m) {
    if (mode == m) return;
    mode = m;
    LocalStore.set('qqmusic_theme', m.id);
    notifyListeners();
  }

  void setAccent(Color c) {
    final next = Color(0xFF000000 | (c.toARGB32() & 0xFFFFFF));
    if (accent.toARGB32() == next.toARGB32()) return;
    accent = next;
    LocalStore.set(
        _accentKey, (next.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0'));
    notifyListeners();
  }

  Brightness resolveBrightness(Brightness platform) => switch (mode) {
        AppThemeMode.light => Brightness.light,
        AppThemeMode.dark => Brightness.dark,
        AppThemeMode.system => platform,
      };

  ThemeData resolve(Brightness platform) {
    final b = resolveBrightness(platform);
    return buildTheme(AppColors.themed(accent, dark: b == Brightness.dark), b);
  }
}

final themeController = ThemeController.instance;
