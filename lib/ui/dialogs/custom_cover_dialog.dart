import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../models/song.dart';
import '../../services/custom_cover.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/cover_crop_editor.dart';
import '../widgets/modal.dart';

Future<void> showCustomCoverDialog(
  BuildContext context,
  AppState state,
  Song song,
) async {
  await showAppModal<void>(
    context,
    CustomCoverDialog(state: state, song: song),
  );
}

/// 歌曲封面管理：完整原图作为背景，固定 1:1 框内拖动/缩放；
///「保存当前封面」导出当前显示内容，「恢复默认」只清本地 override。
class CustomCoverDialog extends StatefulWidget {
  const CustomCoverDialog({super.key, required this.state, required this.song});

  final AppState state;
  final Song song;

  @override
  State<CustomCoverDialog> createState() => _CustomCoverDialogState();
}

class _CustomCoverDialogState extends State<CustomCoverDialog> {
  ui.Image? _previewImage;
  CoverCropController? _crop;
  bool _busy = false;
  String _message = '';

  Song get _song => widget.state.findSong(widget.song.mid) ?? widget.song;

  bool get _hasPendingCrop => _previewImage != null && _crop != null;

  @override
  void dispose() {
    _previewImage?.dispose();
    _crop?.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final path = await AppState.pickImageFile();
    if (path == null || path.isEmpty || !mounted) return;
    try {
      final bytes = await XFile(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final old = _previewImage;
      final crop = CoverCropController(
        Size(frame.image.width.toDouble(), frame.image.height.toDouble()),
      );
      if (!mounted) {
        frame.image.dispose();
        crop.dispose();
        return;
      }
      old?.dispose();
      _crop?.dispose();
      setState(() {
        _previewImage = frame.image;
        _crop = crop;
        _message = '拖动图片调整区域，滚轮或双指调整缩放';
      });
    } catch (e) {
      if (mounted) setState(() => _message = '图片无法读取：$e');
    }
  }

  Future<void> _applyCrop() async {
    final image = _previewImage;
    final crop = _crop;
    if (image == null || crop == null) return;
    final rect = crop.sourceRect;
    await _run('正在应用裁剪…', () async {
      final uri = await CustomCoverService.cropImageAndSave(
        mid: widget.song.mid,
        image: image,
        sourceRect: rect,
      );
      if (uri == null) throw Exception('图片处理失败');
      widget.state.setSongCoverOverride(widget.song.mid, uri);
      _message = '已应用当前裁剪';
    });
  }

  void _cancelCrop() {
    setState(() {
      _previewImage?.dispose();
      _previewImage = null;
      _crop?.dispose();
      _crop = null;
      _message = '已取消裁剪';
    });
  }

  Future<void> _saveCurrent() async {
    final source = _song.coverPic;
    if (source.isEmpty) {
      setState(() => _message = '这首歌没有可保存的封面');
      return;
    }
    const group = XTypeGroup(
      label: '图片',
      extensions: ['png', 'jpg', 'jpeg', 'webp'],
    );
    final location = await getSaveLocation(
      suggestedName: '${AppState.sanitizeFilename(_song.name)}.png',
      acceptedTypeGroups: const [group],
    );
    if (location == null || !mounted) return;
    await _run('正在保存当前封面…', () async {
      final ok = await CustomCoverService.exportCurrent(
        source: source,
        targetPath: location.path,
      );
      if (!ok) throw Exception('封面保存失败');
      _message = '已保存到 ${location.path}';
    });
  }

  void _restore() {
    widget.state.clearSongCoverOverride(widget.song.mid);
    _cancelCrop();
    setState(() => _message = '已恢复默认封面');
  }

  Future<void> _run(String message, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = message;
    });
    try {
      await action();
    } catch (e) {
      _message = '$e'.replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _preview(AppColors c) {
    final crop = _crop;
    final image = _previewImage;
    if (crop == null || image == null) {
      return SizedBox(
        width: 420,
        height: 320,
        child: Center(
          child: SongCover(
            pic: _song.coverPic,
            size: 260,
            radius: c.radiusLg,
            px: 512,
          ),
        ),
      );
    }
    return SizedBox(
      width: 420,
      height: 320,
      child: CoverCropEditor(image: image, controller: crop, enabled: !_busy),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AppModalCard(
      maxWidth: 520,
      height: 570,
      child: Column(
        children: [
          AppModalHeader(
            title: '自定义封面',
            onClose: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
              child: Column(
                children: [
                  Expanded(child: Center(child: _preview(c))),
                  const SizedBox(height: 12),
                  Text(
                    _hasPendingCrop
                        ? '完整图片在框后显示，拖动图片调整区域，滚轮或双指调整缩放。'
                        : '选择图片后，在固定 1:1 矩形框内调整裁切。',
                    style: TextStyle(fontSize: 12, color: c.textTertiary),
                  ),
                  if (_message.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _message,
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: AppButton(
                          label: '选择',
                          small: true,
                          onPressed: _busy ? null : _pick,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: AppButton(
                          label: '保存当前封面',
                          small: true,
                          variant: AppButtonVariant.ghost,
                          onPressed: _busy || _song.coverPic.isEmpty
                              ? null
                              : _saveCurrent,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: AppButton(
                          label: '恢复默认',
                          small: true,
                          variant: AppButtonVariant.ghost,
                          onPressed: _busy || _song.coverOverride.isEmpty
                              ? null
                              : _restore,
                        ),
                      ),
                    ],
                  ),
                  if (_hasPendingCrop) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: AppButton(
                            label: '取消裁剪',
                            small: true,
                            variant: AppButtonVariant.ghost,
                            onPressed: _busy ? null : _cancelCrop,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: AppButton(
                            label: '应用裁剪',
                            small: true,
                            variant: AppButtonVariant.primary,
                            onPressed: _busy ? null : _applyCrop,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
