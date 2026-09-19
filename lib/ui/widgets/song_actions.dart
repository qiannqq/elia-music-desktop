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
  /// 用于触发 _Popup 的收起动画（见 _close）
  final GlobalKey<_PopupState> _popupKey = GlobalKey<_PopupState>();
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

  /// 收起动画播完后由 _Popup 回调
  void _removeEntryAndReset() {
    _removeEntry();
    if (mounted) setState(() => _expanded = false);
  }

  void _close() {
    if (!_expanded) return;
    // ⚠️ 不能直接移除 OverlayEntry：那样收起是「啪一下没了」，
    // 展开有 250ms 动画、收起却是瞬时的，观感很割裂（用户反馈）。
    // 改为先让 _Popup 播收起动画，动画结束再移除。
    final popup = _popupKey.currentState;
    if (popup == null) {
      _removeEntryAndReset();
      return;
    }
    popup.requestClose();
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
              key: _popupKey,
              state: widget.state,
              mid: widget.mid,
              flipLeft: flipLeft,
              flipUp: flipUp,
              onClose: _close,
              // 收起动画播完才真正移除 OverlayEntry
              onClosed: _removeEntryAndReset,
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
          // 与弹层动画（250ms）以及叉号旋转保持一致：
          // 之前盒子 200ms、叉号 350ms，展开时方框先停、叉号还在转，观感不同步
          duration: const Duration(milliseconds: 250),
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
              duration: const Duration(milliseconds: 250),
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

class _Popup extends StatefulWidget {
  const _Popup({
    super.key,
    required this.state,
    required this.mid,
    required this.flipLeft,
    required this.flipUp,
    required this.onClose,
    required this.onClosed,
  });

  final AppState state;
  final String mid;
  final bool flipLeft;
  final bool flipUp;

  /// 请求关闭（由外部调用，会先播收起动画）
  final VoidCallback onClose;

  /// 收起动画播完 —— 此时外部才真正移除 OverlayEntry
  final VoidCallback onClosed;

  @override
  State<_Popup> createState() => _PopupState();
}

class _PopupState extends State<_Popup> {
  static const _animDuration = Duration(milliseconds: 250);

  bool _closing = false;

  /// 请求关闭：先播收起动画，动画结束由 onEnd 通知外部移除。
  void requestClose() {
    if (_closing) return;
    setState(() => _closing = true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final state = widget.state;
    final mid = widget.mid;
    final flipLeft = widget.flipLeft;
    final flipUp = widget.flipUp;
    final song = state.findSong(mid);

    // 等价原 CSS `.add-btn-popup`：
    //   transform: scale(0.8) → scale(1) + opacity 0 → 1，
    //   250ms，cubic-bezier(0.16,1,0.3,1)，transform-origin 按翻转方向取角。
    // ⚠️ end 必须跟随 _closing：
    // 原来写死 end: 1.0，只在**创建时**播一次展开；关闭时整个 OverlayEntry
    // 被直接移除 → 收起没有动画、啪一下就没了（用户反馈）。
    // 现在关闭时把 end 改成 0，TweenAnimationBuilder 会从当前值动画回去，
    // 动画结束后再通过 onEnd 通知外部移除。
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: _closing ? 0.0 : 1.0),
      duration: _animDuration,
      curve: const Cubic(0.16, 1, 0.3, 1),
      onEnd: () {
        if (_closing) widget.onClosed();
      },
      builder: (ctx, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.8 + 0.2 * t,
          alignment: flipUp
              ? (flipLeft ? Alignment.bottomRight : Alignment.bottomLeft)
              : (flipLeft ? Alignment.topRight : Alignment.topLeft),
          child: child,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 168,
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
          // Stack 放在 padding 外层：原版的 `.add-btn-popup-header` 是相对弹窗
          // 左上角（0,0）定位的，不在 36px 留白之内。
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: EdgeInsets.only(
                  left: 6,
                  right: 6,
                  top: flipUp ? 6 : 36,
                  bottom: flipUp ? 36 : 6,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PopupItem(
                      label: '添加到歌单顶部',
                      onTap: () {
                        requestClose();
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
                        requestClose();
                        if (song == null) return;
                        if (state.addToList(song)) {
                          state.showSuccess('已添加: ${song.name}');
                        }
                      },
                    ),
                  ],
                ),
              ),
              // 展开态的头像按钮：弹窗背景会盖住原来那个「+」，
              // 所以这里按原版渲染一个已旋转 45°（即「×」）的关闭按钮。
              Positioned(
                left: flipLeft ? null : 0,
                right: flipLeft ? 0 : null,
                top: flipUp ? null : 0,
                bottom: flipUp ? 0 : null,
                child: GestureDetector(
                  onTap: requestClose,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(
                        child: Transform.rotate(
                          angle: 0.7853981633974483, // 45°
                          child: _PlusIcon(color: c.accent),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
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
