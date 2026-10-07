import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/file_logger.dart';
import 'api_client.dart';

/// 歌曲自定义封面：每首歌只保留一个本地 override 文件。
///
/// 图片统一裁成 1:1 PNG。裁切策略是以图片中心为锚点的 cover：取较短边
/// 的正方形，但保留原始裁切分辨率，不为了界面预览擅自缩小用户图片。
/// 用户恢复默认时只删除这一首的 override。
class CustomCoverService {
  CustomCoverService._();

  static Directory get dir =>
      Directory(p.join(AppPaths.dataDir, 'custom_covers'));

  static List<File> _filesFor(String mid) {
    try {
      return dir
          .listSync()
          .whereType<File>()
          .where(
            (f) =>
                p.basename(f.path).startsWith('$mid-') &&
                p.extension(f.path).toLowerCase() == '.png',
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static File? fileFor(String mid) {
    final files = _filesFor(mid);
    if (files.isEmpty) return null;
    files.sort((a, b) => a.path.compareTo(b.path));
    return files.last;
  }

  static String uriForFile(File file) => Uri.file(file.path).toString();

  static bool exists(String mid) => fileFor(mid) != null;

  static Future<String?> cropAndSave({
    required String mid,
    required String sourcePath,
    double centerX = 0.5,
    double centerY = 0.5,
    double sideFraction = 1.0,
  }) async {
    try {
      final bytes = await File(sourcePath).readAsBytes();
      final png = await _crop(
        bytes,
        centerX: centerX,
        centerY: centerY,
        sideFraction: sideFraction,
      );
      if (png == null) return null;
      return await _write(mid, png);
    } catch (e) {
      fileLogger.warn('CustomCover', '选择封面失败 mid=$mid: $e');
      return null;
    }
  }

  static Future<String?> cropImageAndSave({
    required String mid,
    required ui.Image image,
    required ui.Rect sourceRect,
  }) async {
    try {
      final png = await _encodeCrop(image, sourceRect);
      return await _write(mid, png);
    } catch (e) {
      fileLogger.warn('CustomCover', '应用裁切失败 mid=$mid: $e');
      return null;
    }
  }

  static Future<String?> downloadAndSave({
    required String mid,
    required String sourceUrl,
  }) async {
    if (sourceUrl.isEmpty) return null;
    try {
      final res = await http
          .get(Uri.parse(ApiClient.getProxyImageUrl(sourceUrl)))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      final png = await _crop(
        res.bodyBytes,
        centerX: 0.5,
        centerY: 0.5,
        sideFraction: 1.0,
      );
      if (png == null) return null;
      return await _write(mid, png);
    } catch (e) {
      fileLogger.warn('CustomCover', '保存当前封面失败 mid=$mid: $e');
      return null;
    }
  }

  /// 导出当前显示封面到用户选择的位置，不修改应用内 override。
  static Future<bool> exportCurrent({
    required String source,
    required String targetPath,
  }) async {
    if (source.isEmpty || targetPath.isEmpty) return false;
    try {
      final bytes = source.startsWith('file://')
          ? await File.fromUri(Uri.parse(source)).readAsBytes()
          : (await http
                    .get(Uri.parse(ApiClient.getProxyImageUrl(source)))
                    .timeout(const Duration(seconds: 30)))
                .bodyBytes;
      if (bytes.isEmpty) return false;
      final target = File(targetPath);
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes, flush: true);
      return true;
    } catch (e) {
      fileLogger.warn('CustomCover', '导出当前封面失败: $e');
      return false;
    }
  }

  static void delete(String mid) {
    try {
      for (final f in _filesFor(mid)) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (e) {
      fileLogger.warn('CustomCover', '删除自定义封面失败 mid=$mid: $e');
    }
  }

  static Future<String?> _write(String mid, Uint8List png) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final target = File(p.join(dir.path, '$mid-$stamp.png'));
    final part = File('${target.path}.part');
    try {
      await dir.create(recursive: true);
      await part.writeAsBytes(png, flush: true);
      await part.rename(target.path);
      // 新文件已经完整落盘，旧版本再逐个清掉；路径变更也让 Image.file
      // 不会命中上一张图片的 ImageCache。
      for (final old in _filesFor(mid)) {
        if (old.path == target.path) continue;
        try {
          old.deleteSync();
        } catch (_) {}
      }
      return uriForFile(target);
    } catch (e) {
      fileLogger.warn('CustomCover', '写入自定义封面失败 mid=$mid: $e');
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
      return null;
    }
  }

  static Future<Uint8List> _encodeCrop(
    ui.Image image,
    ui.Rect sourceRect,
  ) async {
    final width = sourceRect.width.round();
    final height = sourceRect.height.round();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      sourceRect,
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final out = await picture.toImage(width, height);
    picture.dispose();
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    if (data == null) throw Exception('图片编码失败');
    return data.buffer.asUint8List();
  }

  static Future<Uint8List?> _crop(
    Uint8List bytes, {
    required double centerX,
    required double centerY,
    required double sideFraction,
  }) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final shortest = image.width < image.height ? image.width : image.height;
      final side = (shortest * sideFraction.clamp(0.2, 1.0)).round();
      final cx = (image.width * centerX.clamp(0.0, 1.0)).clamp(
        side / 2,
        image.width - side / 2,
      );
      final cy = (image.height * centerY.clamp(0.0, 1.0)).clamp(
        side / 2,
        image.height - side / 2,
      );
      final src = ui.Rect.fromLTWH(
        cx - side / 2,
        cy - side / 2,
        side.toDouble(),
        side.toDouble(),
      );
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final sidePx = side;
      canvas.drawImageRect(
        image,
        src,
        ui.Rect.fromLTWH(0, 0, sidePx.toDouble(), sidePx.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final picture = recorder.endRecording();
      final out = await picture.toImage(sidePx, sidePx);
      picture.dispose();
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      out.dispose();
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
      codec.dispose();
    }
  }
}
