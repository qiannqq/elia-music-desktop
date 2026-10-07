import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 原图、预览和输出共用的坐标变换。缩放始终只用一个比例。
class CoverCropController extends ChangeNotifier {
  CoverCropController(this.imageSize);

  final Size imageSize;
  Size viewport = Size.zero;
  double zoom = 1;
  Offset offset = Offset.zero;
  Offset _startFocal = Offset.zero;
  Offset _startOffset = Offset.zero;
  double _startZoom = 1;

  double get fitScale => math.min(
    viewport.width / imageSize.width,
    viewport.height / imageSize.height,
  );

  // 初始展示完整原图，裁切框在当前选图期间固定不动。
  double get frameSide =>
      math.min(viewport.shortestSide, imageSize.shortestSide * fitScale);
  Rect get frame => Rect.fromCenter(
    center: viewport.center(Offset.zero),
    width: frameSide,
    height: frameSide,
  );
  Rect get imageRect => Rect.fromCenter(
    center: viewport.center(Offset.zero) + offset,
    width: imageSize.width * fitScale * zoom,
    height: imageSize.height * fitScale * zoom,
  );
  Rect get sourceRect {
    final dst = imageRect;
    final scale = fitScale * zoom;
    final side = (frameSide / scale).round().clamp(
      1,
      imageSize.shortestSide.toInt(),
    );
    final left = ((frame.left - dst.left) / scale).round().clamp(
      0,
      imageSize.width.toInt() - side,
    );
    final top = ((frame.top - dst.top) / scale).round().clamp(
      0,
      imageSize.height.toInt() - side,
    );
    return Rect.fromLTWH(
      left.toDouble(),
      top.toDouble(),
      side.toDouble(),
      side.toDouble(),
    );
  }

  void layout(Size size) {
    if (viewport == size) return;
    final old = viewport;
    viewport = size;
    if (!old.isEmpty) offset *= size.shortestSide / old.shortestSide;
    offset = _clamp(offset);
  }

  Offset _clamp(Offset value) {
    final halfX = math.max(
      0.0,
      (imageSize.width * fitScale * zoom - frameSide) / 2,
    );
    final halfY = math.max(
      0.0,
      (imageSize.height * fitScale * zoom - frameSide) / 2,
    );
    return Offset(value.dx.clamp(-halfX, halfX), value.dy.clamp(-halfY, halfY));
  }

  void startGesture(Offset focal) {
    _startFocal = focal;
    _startOffset = offset;
    _startZoom = zoom;
  }

  void updateGesture(Offset focal, double scale) {
    zoom = (_startZoom * scale).clamp(1.0, 8.0);
    final center = viewport.center(Offset.zero);
    offset = _clamp(
      focal -
          center -
          (_startFocal - center - _startOffset) * (zoom / _startZoom),
    );
    notifyListeners();
  }

  void scrollZoom(Offset focal, double delta) {
    if (delta == 0) return;
    final next = (zoom * math.exp(-delta * 0.002)).clamp(1.0, 8.0);
    final center = viewport.center(Offset.zero);
    final translated =
        focal - center - (focal - center - offset) * (next / zoom);
    zoom = next;
    offset = _clamp(translated);
    notifyListeners();
  }
}

/// 整张原图作为背景，框外压暗而不是提前裁掉；不参与 Image 的尺寸约束。
class CoverCropEditor extends StatelessWidget {
  const CoverCropEditor({
    super.key,
    required this.image,
    required this.controller,
    this.enabled = true,
  });
  final ui.Image image;
  final CoverCropController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      controller.layout(constraints.biggest);
      return MouseRegion(
        cursor: enabled ? SystemMouseCursors.move : SystemMouseCursors.basic,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (event) {
            if (!enabled || event is! PointerScrollEvent) return;
            GestureBinding.instance.pointerSignalResolver.register(event, (
              signal,
            ) {
              final scroll = signal as PointerScrollEvent;
              controller.scrollZoom(
                scroll.localPosition,
                scroll.scrollDelta.dy,
              );
            });
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: enabled
                ? (d) => controller.startGesture(d.localFocalPoint)
                : null,
            onScaleUpdate: enabled
                ? (d) => controller.updateGesture(d.localFocalPoint, d.scale)
                : null,
            child: ClipRect(
              child: CustomPaint(
                key: const Key('cover-crop-canvas'),
                painter: _CropPainter(image, controller),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.controller) : super(repaint: controller);
  final ui.Image image;
  final CoverCropController controller;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xFF101010), BlendMode.src);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      controller.imageRect,
      Paint()..filterQuality = FilterQuality.high,
    );
    final frame = controller.frame;
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(frame);
    canvas.drawPath(mask, Paint()..color = const Color(0x88000000));
    canvas.drawRect(
      frame,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final grid = Paint()
      ..color = const Color(0x55FFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = frame.left + frame.width * i / 3;
      final y = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), grid);
      canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), grid);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) =>
      image != old.image || controller != old.controller;
}
