import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../models/song.dart';
import '../../services/player_controller.dart';
import '../../services/shell_service.dart';
import '../../state/app_state.dart';
import '../icons.dart';
import 'common.dart';
import 'context_menu.dart';
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
    final status =
        widget.state.downloadStatuses[widget.mid] ?? DownloadStatus.idle;
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
            painter: _RingPainter(
              progress: pct / 100,
              bg: c.border,
              fg: c.accent,
            ),
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
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: c.danger,
            ),
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
    if (!ok &&
        (widget.state.downloadStatuses[widget.mid] == DownloadStatus.fail)) {
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
  const AddButton({
    super.key,
    required this.mid,
    required this.state,
    this.size = 32,
  });

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
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _removeEntry();
    super.dispose();
  }

  /// 别处把这个菜单的状态清掉时（例如在行上按右键），跟着收起。
  ///
  /// `_entry == null` 时直接返回：收起动画播完后状态也会被清一次，
  /// 那一刻 entry 已经移除，再 _close() 是空转。
  void _onState() {
    if (!_expanded || _entry == null) return;
    if (widget.state.openAddMenuMid != widget.mid) _close();
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  /// 收起动画播完后由 _Popup 回调
  void _removeEntryAndReset() {
    _removeEntry();
    if (widget.state.openAddMenuMid == widget.mid) {
      widget.state.setOpenAddMenu(null);
    }
    if (mounted) setState(() => _expanded = false);
  }

  void _close() {
    if (!_expanded) return;
    // 不能直接移除 OverlayEntry：那样收起是「啪一下没了」，
    // 展开有 250ms 动画、收起却是瞬时的，观感很割裂。
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
    widget.state.setOpenAddMenu(widget.mid);

    _entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          // 点击外部关闭
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _close,
              // 右键也要关：二级菜单展开着的时候，在别处按右键
              // 应该把它收起来，而不是留着它又去响应别的目标。
              onSecondaryTap: _close,
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

    // ⚠️ 这里**不要**因为「当前歌单已经有这首歌」就把按钮换成 ✓（那一版会被
    // 当成禁用：想把它加到**别的**歌单时先得切歌单，很不讲道理）。
    // 「已经在哪些歌单里」的信息在弹层里 —— 那一行本来就是置灰的。
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
    // end 必须跟随 _closing：
    // 原来写死 end: 1.0，只在**创建时**播一次展开；关闭时整个 OverlayEntry
    // 被直接移除 → 收起没有动画、啪一下就没了。
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
        type: MaterialType.transparency,
        child: Container(
          width: 168,
          decoration: BoxDecoration(
            // 这是一个飞出层：底与描边都跟右键菜单同一套
            color: c.flyoutBg,
            border: Border.all(color: c.flyoutBorder),
            borderRadius: BorderRadius.circular(c.radiusLg),
            boxShadow: c.elevation16,
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
                    // 每个歌单一项。已经有这首歌的那个置灰 ——
                    // 否则会重复加进去，出现两首一样的。
                    //
                    // 注意这里判断的是**各个歌单自己**有没有，不是「当前歌单」：
                    // 用户在这儿选的就是要加到哪个歌单。
                    for (final p in state.playlists)
                      _PopupItem(
                        label: p.name,
                        // 已有这首歌的置灰（加了会出现两首一样的）；
                        // 「完全单向」的歌单也置灰（加了会被下一次同步清掉）
                        enabled: song == null
                            ? false
                            : !state.playlistHasSong(p.id, song.mid) &&
                                  !state.playlistLocked(p.id),
                        onTap: () {
                          requestClose();
                          if (song == null) return;
                          state.addToPlaylist(p.id, song);
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
  const _PopupItem({
    required this.label,
    required this.onTap,
    this.enabled = true,
  });
  final String label;
  final VoidCallback onTap;

  /// 禁用项置灰、不响应悬停与点击（某个歌单已经有这首歌时用它）
  final bool enabled;

  @override
  State<_PopupItem> createState() => _PopupItemState();
}

class _PopupItemState extends State<_PopupItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final on = widget.enabled;
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (on) setState(() => _hovered = true);
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: on ? widget.onTap : null,
        child: Container(
          width: double.infinity,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            // 与右键菜单同一档悬停底（不是主色淡底）
            color: (on && _hovered) ? c.hover : c.hover.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(c.radius),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                // 灰着就得一直是灰的，不能跟着悬停变色
                color: on ? c.text : c.textDisabled,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ================================================================ 右键菜单条目

/// 构造歌曲右键菜单的条目 —— 歌单页、搜索页与播放列表面板共用。
///
/// [inPlaylist] 决定要不要带上「从歌单中移除 / 置顶 / 置底」，
/// [inQueue] 是播放列表面板里那一份：把上面那组换成「从播放队列中移除」——
/// 队列里的歌**不一定在歌单里**，置顶置底更是歌单的事。
/// [onEditName] 为 null 时不显示「编辑歌曲名」：改名要就地展开输入框，
/// 只有歌单行和搜索行有那套东西。
List<AppMenuItem> buildSongMenuItems({
  required BuildContext context,
  required AppState state,
  required Song song,
  required ValueChanged<String> onOpenLyric,
  VoidCallback? onEditName,
  bool inPlaylist = false,
  bool inQueue = false,
}) {
  final downloaded = state.downloadedPaths[song.mid];
  final hasFile = downloaded != null && downloaded.isNotEmpty;

  // 正在播的这首要给「暂停」而不是「播放」——
  // 写成「播放」的话，点了会从头重放一遍（`playSong` 是重新加载），
  // 而用户想的显然是「按下暂停键」。
  final isCurrent = song.mid == player.currentSong?.mid;
  final showingPause = isCurrent && player.isPlaying;

  return [
    AppMenuItem(
      label: showingPause ? '暂停' : '播放',
      icon: showingPause ? AppIcons.pause : AppIcons.play,
      // 正在播的这首本身就是「当前这首」，点「播放」等于重播；
      // 但它已经在播了，所以这时给的是「暂停」，走 toggle。
      onTap: () =>
          showingPause ? player.togglePlay() : state.playSong(song.mid),
    ),
    // 插到「正在播的那首」后面。已经在队列里的话会先把它从原位置摘掉 ——
    // 不摘会出现同一首歌占两处。正在播的那首本身不给点：它已经在播了。
    AppMenuItem(
      label: '插入到下一首',
      icon: AppIcons.playOrder,
      enabled: song.mid != player.currentSong?.mid,
      onTap: () => state.insertNext(song),
    ),
    // 已经下载过的，这一项变成「打开所在文件夹」——
    // 再点一次「下载」没有意义。
    hasFile
        ? AppMenuItem(
            label: '打开所在文件夹',
            icon: AppIcons.folder,
            onTap: () => state.openFileFolder(song.mid),
          )
        : AppMenuItem(
            label: '下载',
            icon: AppIcons.download,
            onTap: () => downloadSongFromMenu(context, state, song.mid),
          ),
    AppMenuItem(
      label: '刷新缓存',
      icon: AppIcons.refresh,
      dividerBefore: true,
      onTap: () => refreshSongCacheFromMenu(state, song),
    ),
    AppMenuItem(
      label: '歌词',
      icon: AppIcons.lyricDoc,
      onTap: () => onOpenLyric(song.mid),
    ),
    // 「添加到歌单」展开成二级菜单，直接列所有歌单 ——
    // 在歌单页右键时尤其需要这条：否则想加进别的歌单只能切过去再加。
    AppMenuItem(
      label: '添加到歌单',
      icon: AppIcons.plus,
      children: [
        for (final p in state.playlists)
          AppMenuItem(
            label: p.name,
            // 已经在里面的用对勾 + 置灰：不用点进去才发现重复；
            // 「完全单向」的歌单也不能加（加了会被下一次同步清掉）
            icon: state.playlistHasSong(p.id, song.mid)
                ? AppIcons.check
                : AppIcons.plus,
            enabled:
                !state.playlistHasSong(p.id, song.mid) &&
                !state.playlistLocked(p.id),
            onTap: () => state.addToPlaylist(p.id, song),
          ),
      ],
    ),
    AppMenuItem(
      label: '恢复默认歌词',
      icon: AppIcons.refresh,
      onTap: () => restoreLyricFromMenu(context, state, song),
    ),
    if (onEditName != null)
      AppMenuItem(label: '编辑歌曲名', icon: AppIcons.edit, onTap: onEditName),
    if (inQueue)
      AppMenuItem(
        label: '从播放队列中移除',
        icon: AppIcons.trash,
        danger: true,
        dividerBefore: true,
        onTap: () => state.removeFromQueue(song),
      )
    else if (inPlaylist) ...[
      // 「完全单向」的歌单不能增删排序 —— 危险项直接置灰，
      // 连点击都不该响应（`AppMenuItem.enabled` 就是干这个的）
      AppMenuItem(
        label: '从歌单中移除',
        icon: AppIcons.trash,
        danger: true,
        dividerBefore: true,
        enabled: !state.songsLocked,
        onTap: () => state.removeFromList(song.mid),
      ),
      AppMenuItem(
        label: '置顶',
        icon: AppIcons.arrowUpToLine,
        enabled: !state.songsLocked,
        onTap: () => state.moveToTop(song.mid),
      ),
      AppMenuItem(
        label: '置底',
        icon: AppIcons.arrowDownToLine,
        enabled: !state.songsLocked,
        onTap: () => state.moveToBottom(song.mid),
      ),
    ],
    // B站音源直接开原视频；别的音源去 B站搜 ——
    // 想找这一版在 B站有没有投稿，只能搜出来看。
    song.isBilibili
        ? AppMenuItem(
            label: '通过浏览器打开原视频',
            icon: AppIcons.externalLink,
            dividerBefore: true,
            onTap: () =>
                ShellService.openUrl(ShellService.bilibiliVideoUrl(song)),
          )
        : AppMenuItem(
            label: '通过B站搜索该歌曲',
            icon: AppIcons.search,
            dividerBefore: true,
            onTap: () =>
                ShellService.openUrl(ShellService.bilibiliSearchUrl(song)),
          ),
  ];
}

/// 菜单里的「恢复默认歌词」—— 先弹一次确认，再从音源重取。
///
/// 要确认是因为它会**丢掉本地改过的歌词**（用户在歌词弹窗里编辑保存过的那份），
/// 这个动作没法撤销。
Future<void> restoreLyricFromMenu(
  BuildContext context,
  AppState state,
  Song song,
) async {
  final ok = await showConfirmDialog(context, '放弃这首歌已修改的歌词，重新从音源获取？');
  if (!ok || !context.mounted) return;
  await state.restoreDefaultLyric(song.mid);
}

/// 菜单里的「刷新缓存」：只刷新当前歌曲已有的缓存项。
Future<void> refreshSongCacheFromMenu(AppState state, Song song) async {
  final result = await state.refreshSongCache(song);
  final refreshed = <String>[
    if (result.audio) '音频',
    if (result.cover) '封面',
    if (result.lyric) '歌词',
  ];
  if (refreshed.isEmpty) {
    state.showInfo('没有可刷新的缓存，或远端内容获取失败');
  } else {
    state.showSuccess('已刷新${refreshed.join('、')}缓存');
  }
}

/// 菜单里的「下载」—— 与下载按钮走同一条路，只是这里不显示环形进度，
/// 进度由按钮那边呈现（状态是共用的）。
Future<void> downloadSongFromMenu(
  BuildContext context,
  AppState state,
  String mid,
) async {
  await state.downloadSong(
    mid,
    askSaveLocation: (filename) async {
      if (!context.mounted) return null;
      return showSaveDialog(context, state, filename);
    },
  );
}
