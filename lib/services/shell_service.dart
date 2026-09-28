import 'package:flutter/services.dart';

import '../core/file_logger.dart';
import '../models/song.dart';

/// 交给系统去「打开」的动作。
///
/// 走原生（`ShellExecuteW`）而不是拼命令行：URL 里带 `&` 和空格，
/// 套进 `cmd /c start` 会被拆成好几段。
class ShellService {
  ShellService._();

  static const _channel = MethodChannel('elia/system');

  /// 用默认浏览器打开一个链接
  static Future<bool> openUrl(String url) async {
    if (url.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } catch (e) {
      fileLogger.warn('Shell', '打开链接失败 url=$url : $e');
      return false;
    }
  }

  /// Windows「设置 → 个性化 → 颜色」里那个主题色。取不到返回 null。
  ///
  /// 原生那边读的是 `HKCU\...\DWM\AccentColor`（实在没有才退到窗口着色色），
  /// 原因见 `windows/runner/system_bridge.cpp` 里 `SystemAccent` 的说明。
  static Future<Color?> systemAccentColor() async {
    try {
      final v = await _channel.invokeMethod<num>('systemAccent');
      if (v == null) return null;
      return Color(0xFF000000 | (v.toInt() & 0xFFFFFF));
    } catch (e) {
      fileLogger.warn('Shell', '读取系统主题色失败：$e');
      return null;
    }
  }

  /// 这首歌在 B站的原视频地址。
  ///
  /// B站音源的 mid 就是 BV 号，直接拼即可。
  static String bilibiliVideoUrl(Song song) =>
      'https://www.bilibili.com/video/${song.mid}';

  /// 去 B站搜这首歌。
  ///
  /// 用在非 B站音源上：那边的歌在 B站有没有投稿、是哪一版，只能搜出来看。
  static String bilibiliSearchUrl(Song song) {
    final key = [song.name, song.artist]
        .where((s) => s.trim().isNotEmpty)
        .join(' ')
        .trim();
    return 'https://search.bilibili.com/all?keyword=${Uri.encodeComponent(key)}';
  }
}
