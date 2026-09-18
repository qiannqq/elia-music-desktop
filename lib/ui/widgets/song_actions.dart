import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../state/app_state.dart';
import '../icons.dart';
import 'common.dart';
import 'dialogs.dart';

// ================================================================ 下载按钮

/// 下载按钮 —— 对应 `.dl-btn` / `.dl-ring` / `song-progress-fail`
///
/// 三种形态：
/// - 未下载：下载箭头
/// - 下载中：环形进度（28×28，r=10，dasharray 62.83）
/// - 已下载：文件夹图标（点击打开所在目录）
class DownloadButton extends StatefulWidget {
  const DownloadButton({super.key, required this.mid, required this.state});

  final String mid;
  final AppState state;

  @override
  State<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<DownloadButton> {
  bool _showFail = false;
  int _failToken = 0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final downloaded = widget.state.downloadedPaths[widget.mid];
    final status = widget.state.downloadStatuses[widget.mid] ?? DownloadStatus.idle;
    final pct = widget.state.downloadProgress[widget.mid] ?? 0;

    if (downloaded != null) {
      return AppIconButton(
        icon: AppIcons.folder,
        size: 32,
        iconSize: 16,
        baseColor: c.textTertiary,
        tooltip: '打开文件夹',
        onTap: () => widget.state.openFileFolder(widget.mid),
      );
    }

    if (status == DownloadStatus.running) {
      return SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: CustomPaint(
            size: const Size(28, 28),
            painter: _RingPainter(progress: pct / 100, bg: c.border, fg: c.accent),
          ),
        ),
      );
    }

    if (_showFail) {
      return SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: Text(
            '✗',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.danger),
          ),
        ),
      );
    }

    return AppIconButton(
      icon: AppIcons.download,
      size: 32,
      iconSize: 16,
      baseColor: c.accent,
      tooltip: '下载',
      onTap: () => _startDownload(),
    );
  }

  Future<void> _startDownload() async {
    final ok = await widget.state.downloadSong(
      widget.mid,
      askSaveLocation: (filename) async {
        if (!mounted) return null;
        return showSaveDialog(context, widget.state, filename);
      },
    );
    if (!mounted) return;
    if (!ok && (widget.state.downloadStatuses[widget.mid] == DownloadStatus.fail)) {
      final token = ++_failToken;
      setState(() => _showFail = true);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && token == _failToken) setState(() => _showFail = false);
      });
    }
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.bg, required this.fg});

  final double progress;
  final Color bg;
  final Color fg;

  /// 圆半径，与原 SVG `<circle r="10">` 一致
  /// （周长 2πr ≈ 62.83，对应原 `stroke-dasharray:62.83`）
  static const double _r = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final bgPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = bg;
    canvas.drawCircle(center, _r, bgPaint);

    final fgPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = fg;

    final sweep = (progress.clamp(0.0, 1.0)) * 2 * math.pi;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: _r),
      -math.pi / 2,
      sweep,
      false,
      fgPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.fg != fg || old.bg != bg;
}

// ================================================================ 添加按钮

/// 添加到歌单按钮 —— 对应 `.add-btn` + `.add-btn-popup`
///
/// 展开态：十字旋转 45°（变为 ×），弹出 168px 宽菜单，
/// 含「添加到歌单顶部」「添加到歌单底部」两项；空间不足时自动左/上翻转。
class AddButton extends StatefulWidget {
  const AddButton({super.key, required this.mid, required this.state, this.size = 32});

  final String mid;
  final AppState state;
  final double size;

  @override
  State<AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<AddButton> {
  OverlayEntry? _entry;
  bool _expanded = false;

  @override
  void dispose() {
    _removeEntry();
    super.dispose();
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  void _close() {
    if (!_expanded) return;
    _removeEntry();
    if (mounted) setState(() => _expanded = false);
  }

  void _toggle() {
    if (_expanded) {
      _close();
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay = Overlay.of(context);
    final origin = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context);

    const popupWidth = 168.0;
    final popupHeight = 36 + 6 + 2 * 33.0; // 顶部留白 + 两个菜单项
    final flipLeft = origin.dx + popupWidth > screen.width;
    final flipUp = origin.dy + popupHeight > screen.height - 8;

    setState(() => _expanded = true);

    _entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          // 点击外部关闭
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _close,
            ),
          ),
          Positioned(
            left: flipLeft ? null : origin.dx,
            right: flipLeft ? screen.width - origin.dx - widget.size : null,
            top: flipUp ? null : origin.dy,
            bottom: flipUp ? screen.height - origin.dy - widget.size : null,
            child: _Popup(
              state: widget.state,
              mid: widget.mid,
              flipLeft: flipLeft,
              flipUp: flipUp,
              onClose: _close,
            ),
          ),
        ],
      ),
    );
    overlay.insert(_entry!);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final added = widget.state.isAdded(widget.mid);

    if (added) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: Center(
          child: AppIcon(AppIcons.check, size: 14, color: c.textTertiary, strokeWidth: 2.5),
        ),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _toggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            border: Border.all(color: c.borderSubtle),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(
            child: AnimatedRotation(
              turns: _expanded ? 0.125 : 0,
              duration: const Duration(milliseconds: 350),
              curve: const Cubic(0.16, 1, 0.3, 1),
              child: _PlusIcon(color: _expanded ? c.textTertiary : c.accent),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlusIcon extends StatelessWidget {
  const _PlusIcon({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(width: 14, height: 2, color: color),
          Container(width: 2, height: 14, color: color),
        ],
      ),
    );
  }
}

class _Popup extends StatelessWidget {
  const _Popup({
    required this.state,
    required this.mid,
    required this.flipLeft,
    required this.flipUp,
    required this.onClose,
  });

  final AppState state;
  final String mid;
  final bool flipLeft;
  final bool flipUp;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final song = state.findSong(mid);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 168,
        padding: EdgeInsets.only(
          left: 6,
          right: 6,
          top: flipUp ? 6 : 36,
          bottom: flipUp ? 36 : 6,
        ),
        decoration: BoxDecoration(
          color: c.card,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PopupItem(
              label: '添加到歌单顶部',
              onTap: () {
                onClose();
                if (song == null) return;
                if (state.isAdded(song.mid)) {
                  state.showInfo('已存在: ${song.name}');
                  return;
                }
                state.addToTop(song);
                state.showSuccess('已置顶: ${song.name}');
              },
            ),
            _PopupItem(
              label: '添加到歌单底部',
              onTap: () {
                onClose();
                if (song == null) return;
                if (state.addToList(song)) {
                  state.showSuccess('已添加: ${song.name}');
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PopupItem extends StatefulWidget {
  const _PopupItem({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_PopupItem> createState() => _PopupItemState();
}

class _PopupItemState extends State<_PopupItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _hovered ? c.accentLight : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: _hovered ? c.accent : c.text,
            ),
          ),
        ),
      ),
    );
  }
}
