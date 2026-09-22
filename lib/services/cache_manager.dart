import 'package:flutter/services.dart';

import '../core/app_paths.dart';
import '../core/file_logger.dart';
import 'audio_cache.dart';
import 'cover_cache.dart';
import 'lyric_cache.dart';

/// 缓存占用的一份快照。
class CacheUsage {
  const CacheUsage({
    required this.audioBytes,
    required this.otherBytes,
    this.diskTotalBytes,
    this.diskFreeBytes,
  });

  /// 音频缓存（`data/audio_cache`）
  final int audioBytes;

  /// 歌词与其他（`data/lyrics` + `data/covers`）
  final int otherBytes;

  /// 缓存所在盘的总容量。拿不到时为 null —— 那时只是不显示百分比。
  final int? diskTotalBytes;
  final int? diskFreeBytes;

  int get totalBytes => audioBytes + otherBytes;

  /// 音频 / 其他各占总缓存的比例（0~1）
  double get audioShare => totalBytes <= 0 ? 0 : audioBytes / totalBytes;
  double get otherShare => totalBytes <= 0 ? 0 : otherBytes / totalBytes;

  /// 总缓存占整块盘的比例（0~1）
  double? get diskShare {
    final total = diskTotalBytes;
    if (total == null || total <= 0) return null;
    return totalBytes / total;
  }
}

/// 缓存统计与清理。
///
/// 只管两处：`data/audio_cache`（音频）和 `data/lyrics` + `data/covers`（其他）。
/// **不碰** `data/local_storage.json`（里面是 Cookie 和设置）和 `temp/` ——
/// 那两个不是缓存，删了要出事。
class CacheManager {
  CacheManager._();

  static final CacheManager instance = CacheManager._();

  static const _channel = MethodChannel('elia/system');

  /// 统计各处占用。磁盘容量拿不到也能用，只是没有百分比。
  static Future<CacheUsage> measure() async {
    final audio = AudioDiskCache.sizeOnDisk();
    final other = LyricCache.sizeOnDisk() + CoverCache.sizeOnDisk();

    int? total;
    int? free;
    try {
      final res = await _channel.invokeMethod<Object?>('diskInfo', {
        'path': AppPaths.dataDir,
      });
      if (res is Map) {
        final t = res['totalBytes'];
        final f = res['freeBytes'];
        if (t is num && t > 0) total = t.toInt();
        if (f is num) free = f.toInt();
      }
    } catch (e) {
      fileLogger.warn('Cache', '磁盘容量取不到（不影响清理）path=${AppPaths.dataDir} : $e');
    }

    return CacheUsage(
      audioBytes: audio,
      otherBytes: other,
      diskTotalBytes: total,
      diskFreeBytes: free,
    );
  }

  /// 清音频缓存，返回释放的字节数
  static int clearAudio() => AudioDiskCache.clearAll();

  /// 清歌词与封面，返回释放的字节数
  static int clearOther() => LyricCache.clearAll() + CoverCache.clearAll();

  /// 全部清掉，返回释放的字节数
  static int clearAll() => clearAudio() + clearOther();

  /// 人类可读的体积
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    // 到了 MB 以上留一位小数，KB 及以下取整 —— 「1.0 KB」没有意义
    final text = i >= 2 ? v.toStringAsFixed(1) : v.toStringAsFixed(0);
    return '$text ${units[i]}';
  }
}

final cacheManager = CacheManager.instance;
