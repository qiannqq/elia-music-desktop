import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../../core/lyric.dart';
import '../widgets/karaoke_text.dart';
import '../../services/player_controller.dart';
import '../../state/app_state.dart';
import '../icons.dart';
import '../widgets/common.dart';
import '../widgets/dialogs.dart';
import '../widgets/modal.dart';

/// 歌词弹窗 —— 对应 `#lyrics-overlay`（查看态 / 编辑态双模式）
class LyricsDialog extends StatefulWidget {
  const LyricsDialog({super.key, required this.state});

  final AppState state;

  @override
  State<LyricsDialog> createState() => _LyricsDialogState();
}

class _LyricsDialogState extends State<LyricsDialog> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _rawCtrl = TextEditingController();
  final TextEditingController _transCtrl = TextEditingController();
  final FocusNode _rawFocus = FocusNode();
  final FocusNode _transFocus = FocusNode();

  bool _editing = false;

  /// 编辑态显示哪一块：false = 原歌词，true = 翻译歌词。
  /// 两块内容各在自己的输入框里，切换只是把视图滑过去，**不丢任何编辑**。
  bool _showTrans = false;
  bool _autoFollow = true;
  int _lastScrolledIdx = -1;
  /// 上次同步到的歌词行 —— 用来避免「位置每变一次就重建整首歌词」
  int _lastSyncedIdx = -2;
  bool _programmaticScroll = false;
  int _scrollResumeTimer = 0;

  /// 每行一个 GlobalKey —— 自动跟随靠 `Scrollable.ensureVisible` 按**实际布局**
  /// 定位，而不是用假定的行高去算偏移。
  /// （带翻译的行高约为不带翻译的两倍，用固定行高会让当前行慢慢跑出视野。）
  final Map<int, GlobalKey> _lineKeys = {};
  String? _keyMid;

  GlobalKey _keyFor(int i) => _lineKeys.putIfAbsent(i, () => GlobalKey());

  @override
  void initState() {
    super.initState();
    player.addListener(_onPlayer);
    _scroll.addListener(_onUserScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncActive(scroll: true));
  }

  @override
  void dispose() {
    player.removeListener(_onPlayer);
    _scroll.removeListener(_onUserScroll);
    _scroll.dispose();
    _rawCtrl.dispose();
    _transCtrl.dispose();
    _rawFocus.dispose();
    _transFocus.dispose();
    super.dispose();
  }

  void _onPlayer() {
    if (mounted) _syncActive(scroll: true);
  }

  void _onUserScroll() {
    if (_programmaticScroll) return;
    _autoFollow = false;
    _scrollResumeTimer++;
    final token = _scrollResumeTimer;
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && token == _scrollResumeTimer) _autoFollow = true;
    });
  }

  int _activeIndex() {
    final lines = widget.state.currentLyricParsed;
    if (lines.isEmpty) return -1;
    if (player.currentSong?.mid != widget.state.currentLyricMid) return -1;
    final ct = player.position.inMilliseconds / 1000.0;
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].time <= ct) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  void _syncActive({bool scroll = false}) {
    // 换歌后重置跟随状态
    final mid = widget.state.currentLyricMid;
    if (mid != _keyMid) {
      _keyMid = mid;
      _lastScrolledIdx = -1;
      _autoFollow = true;
    }

    final idx = _activeIndex();
    // 只有「唱到下一句」才需要重建：位置每秒变化几十次，而这个弹窗一重建
    // 就是整首歌词（几十行）。当前行的逐字高亮由它自己的
    // ValueListenableBuilder 驱动，不依赖这里的 setState。
    if (idx != _lastSyncedIdx) {
      _lastSyncedIdx = idx;
      setState(() {});
    }
    if (!scroll || idx < 0 || idx == _lastScrolledIdx || !_autoFollow) return;

    final ctx = _lineKeys[idx]?.currentContext;
    if (ctx == null) return;
    _lastScrolledIdx = idx;
    _programmaticScroll = true;
    // 等价原版 `activeEl.scrollIntoView({block:'center'})`：把当前行居中
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    ).whenComplete(() => _programmaticScroll = false);
  }

  void _startEdit() {
    _rawCtrl.text = widget.state.currentLyricRaw;
    _transCtrl.text = widget.state.currentLyricTrans;
    setState(() {
      _editing = true;
      _showTrans = false; // 每次进来都从原歌词开始
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _rawFocus.requestFocus();
    });
  }

  /// 编辑态里有没有未保存的改动
  bool get _dirty =>
      _editing &&
      (_rawCtrl.text != widget.state.currentLyricRaw ||
          _transCtrl.text != widget.state.currentLyricTrans);

  /// 退出编辑前问一句。
  ///
  /// 只拦「真的要离开编辑态」——**切换原歌词/翻译不拦**：
  /// 两块内容都还在各自的输入框里，切回来一模一样。
  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return showConfirmDialog(context, '有未保存的修改，确定放弃吗？');
  }

  Future<void> _closeDialog() async {
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _cancelEdit() async {
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    setState(() => _editing = false);
    widget.state.reloadLyricFromStore();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _lastScrolledIdx = -1;
      _autoFollow = true;
      _syncActive(scroll: true);
    });
  }

  void _saveEdit() {
    widget.state.saveLyric(_rawCtrl.text, _transCtrl.text);
    setState(() => _editing = false);
    widget.state.reloadLyricFromStore();
  }

  void _seekTo(double time) {
    final mid = widget.state.currentLyricMid;
    if (mid == null) return;
    if (player.currentSong?.mid == mid) {
      if (player.duration.inMilliseconds > 0) {
        player.seekPercent(time / (player.duration.inMilliseconds / 1000.0));
      }
    } else {
      widget.state.playSong(mid);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final lines = widget.state.currentLyricParsed;
    final transMap = widget.state.currentLyricTransMap;
    final activeIdx = _activeIndex();

    return Shortcuts(
      shortcuts: {
        if (_editing) ...{
          const SingleActivator(LogicalKeyboardKey.escape): const _CancelIntent(),
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): const _SaveIntent(),
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): const _SaveIntent(),
        },
      },
      child: Actions(
        actions: {
          _CancelIntent: CallbackAction<_CancelIntent>(
            onInvoke: (_) {
              _cancelEdit();
              return null;
            },
          ),
          _SaveIntent: CallbackAction<_SaveIntent>(
            onInvoke: (_) {
              _saveEdit();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: AppModalCard(
            maxWidth: 520,
            height: MediaQuery.sizeOf(context).height * 0.7,
            maxHeightFactor: 1,
            child: Column(
              children: [
                // ---- 标题栏 ----
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.borderSubtle)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.state.lyricTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600, color: c.text),
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (!_editing)
                        AppButton(
                          label: '编辑',
                          small: true,
                          icon: AppIcons.edit,
                          onPressed: _startEdit,
                        )
                      else ...[
                        AppButton(
                          label: '保存',
                          small: true,
                          variant: AppButtonVariant.primary,
                          onPressed: _saveEdit,
                        ),
                        const SizedBox(width: 6),
                        AppButton(
                          label: '取消',
                          small: true,
                          onPressed: _cancelEdit,
                        ),
                      ],
                      const SizedBox(width: 8),
                      AppIconButton(
                        icon: AppIcons.trash,
                        size: 28,
                        iconSize: 14,
                        onTap: _closeDialog,
                      ),
                    ],
                  ),
                ),
                // ---- 内容 ----
                Expanded(
                  child: _editing ? _buildEditArea(c) : _buildDisplayArea(c, lines, transMap, activeIdx),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDisplayArea(
    AppColors c,
    List<LyricLineBox> lines,
    Map<double, String> transMap,
    int activeIdx,
  ) {
    if (lines.isEmpty) {
      // 未命中缓存时先显示加载态，避免「点了没反应」
      if (widget.state.lyricLoading) {
        return Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: c.accent,
            ),
          ),
        );
      }
      return Center(
        child: Text(
          '暂无歌词',
          style: TextStyle(fontSize: 14, color: c.textTertiary),
        ),
      );
    }

    // 刻意**不做虚拟化**（与原版一致：所有行都在 DOM 里）：
    // 只有全部行都挂载，`Scrollable.ensureVisible` 才能按真实布局把当前行居中。
    // 歌词行数通常在几百以内，性能没有问题。
    return Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < lines.length; i++)
              KeyedSubtree(
                key: _keyFor(i),
                // 用 transAt 容差匹配：QRC 行时间是毫秒、翻译是厘秒，
                // 精确查 map[time] 会几乎全部落空（见 lyric.dart 的说明）
                child: _buildLine(c, lines[i], transAt(transMap, lines[i].time),
                    i == activeIdx),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLine(AppColors c, LyricLineBox line, String trans, bool active) {
    return HoverBuilder(
      builder: (_, hovered) => GestureDetector(
        onTap: () => _seekTo(line.time),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: active
                ? c.accentLight
                : (hovered ? c.hover : c.hover.withValues(alpha: 0)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 当前行且有逐字数据 → 逐字高亮（与播放栏同一套组件与过渡）
              (active && line.hasWords)
                  // 只有这一行跟着播放位置走 —— 重建范围压到当前行，
                  // 其余几十行保持不动
                  ? ValueListenableBuilder<Duration>(
                      valueListenable: player.positionNotifier,
                      builder: (_, pos, _) => KaraokeText(
                        line: LyricLine(line.time, line.text, words: line.words),
                        position: pos.inMilliseconds / 1000.0,
                        activeColor: c.accent,
                        inactiveColor: c.textTertiary,
                        fontSize: 15,
                        height: 1.7,
                        // 弹窗宽度足够：长句换行显示完整内容，不截断
                        maxLines: null,
                      ),
                    )
                  : Text(
                      line.text,
                      style: TextStyle(
                        // 字体放大 + 行高收紧：原来 14/2.0 的行距过大，
                        // 选中行背景框里上方会空出一大块。
                        fontSize: 15,
                        height: 1.7,
                        color: active ? c.accent : c.textTertiary,
                        // 加粗用**描边**而不是 fontWeight：CJK 字形请求粗体时
                        // 常常换一套字面、字宽随之变化，于是「加粗了整行反而变窄」。
                        // 阴影不参与布局，字形度量与未选中时完全一致。
                        shadows: active ? karaokeStroke(c.accent) : null,
                      ),
                    ),
              if (trans.isNotEmpty)
                Text(
                  trans,
                  style: TextStyle(fontSize: 12, color: c.textTertiary, height: 1.8),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 编辑区：原歌词与翻译歌词**各占整块**，用左右两个箭头图标按钮切换。
  ///
  /// 原来是上下两块堆着、翻译那块只有 140px —— 长歌词和长翻译都看不全。
  Widget _buildEditArea(AppColors c) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Expanded(
            child: Row(
              // 不 stretch：两个箭头按钮垂直居中，编辑框自己撑满高度
              children: [
                KeyedSubtree(
                  key: const ValueKey('switch-left'),
                  child: _switchStrip(
                  c,
                  pointsLeft: true,
                  label: '原歌词',
                  // 左侧只负责「切回去」：已经在原歌词时置灰
                  enabled: _showTrans,
                  onTap: () => _showEditor(false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _buildSlidingEditors()),
                const SizedBox(width: 8),
                KeyedSubtree(
                  key: const ValueKey('switch-right'),
                  child: _switchStrip(
                  c,
                  pointsLeft: false,
                  label: '翻译歌词',
                  // 右侧负责「切到翻译」：已经在翻译时置灰
                  enabled: !_showTrans,
                  onTap: () => _showEditor(true),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Ctrl+S 保存 · Esc 取消',
            style: TextStyle(
                fontSize: 11, color: c.textTertiary.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }

  /// 左右切换键：贴着编辑区两侧的**整条**竖条。
  ///
  /// 做成竖条而不是小方块按钮：点击区域大得多（整条都能点），
  /// 而且它本身就在提示「这一侧还有另一块内容」，比一个小箭头显眼。
  ///
  /// 不可用的一侧（已经在这一页了）**置灰 + 吃掉所有指针事件** ——
  /// 只把颜色调暗是不够的：鼠标划过去还会亮起来，看着像能点。
  Widget _switchStrip(
    AppColors c, {
    required bool pointsLeft,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final dim = c.textTertiary.withValues(alpha: 0.3);
    final strip = Tooltip(
      message: label,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 46,
            decoration: BoxDecoration(
              // **不能**用 Colors.transparent：它是「透明黑」，
              // 插值到浅色的中途会经过一段发灰发暗的颜色 —— 浅色模式下
              // 就是「点一下按钮，两个按钮同时闪一下深色」。
              // 用同色零透明代替，插值全程都在同一个色相上。
              color: enabled ? c.surfaceAlt : c.surfaceAlt.withValues(alpha: 0),
              border: Border.all(
                color: enabled
                    ? c.inputBorder
                    : c.inputBorder.withValues(alpha: 0),
              ),
              borderRadius: BorderRadius.circular(c.radius),
            ),
            child: Column(
              children: [
                Expanded(
                  // 长箭头撑满整条高度（自己画，不用缩放图标 ——
                  // 图标是 24×24 坐标系，拉伸会把描边一起拉变形）
                  child: _LongChevron(
                    pointsLeft: pointsLeft,
                    color: enabled ? c.textSecondary : dim,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 10, left: 2, right: 2),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.25,
                      color: enabled ? c.textTertiary : dim,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // 必须**永远**返回同一种 widget 类型：早先在启用/禁用之间切换返回
    // Tooltip ↔ IgnorePointer 两种类型，导致 Row 的兄弟节点匹配被打乱、
    // 编辑区的 element 被重建 —— 表现就是「切换动画没了、一步到位」。
    return IgnorePointer(ignoring: !enabled, child: strip);
  }

  /// 两块编辑区并排放在一个 2 倍宽的 Row 里，整体左移一个宽度 ——
  /// 效果是「新的一块从右边挤进来、旧的一块被完全挤出去」。
  Widget _buildSlidingEditors() {
    return LayoutBuilder(
      builder: (ctx, cons) {
        final w = cons.maxWidth;
        return ClipRect(
          key: const Key('lyric-editor-viewport'),
          // 必须用 OverflowBox 解除宽度约束：否则 SizedBox(width: 2w) 会被
          // 父级的 maxWidth 夹回 w，Row 里两块各占 w/2，滑过去也只走一半
          // —— 表现就是「两块各露一半」。
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            maxWidth: double.infinity,
            child: AnimatedSlide(
              // 子节点宽 2w，所以 -0.5 正好等于「移动一整块的宽度」
              offset: Offset(_showTrans ? -0.5 : 0, 0),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: SizedBox(
                width: w * 2,
                child: Row(
                  children: [
                    SizedBox(
                      width: w,
                      // 隐藏时排除出焦点：否则 Tab 键还会跑到看不见的那个框里
                      child: ExcludeFocus(
                        excluding: _showTrans,
                        child: _MonoTextArea(
                          controller: _rawCtrl,
                          focusNode: _rawFocus,
                          hint: '原歌词（LRC / QRC）',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: w,
                      child: ExcludeFocus(
                        excluding: !_showTrans,
                        child: _MonoTextArea(
                          controller: _transCtrl,
                          focusNode: _transFocus,
                          hint: '翻译歌词（可选，格式与原文 LRC 相同）',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showEditor(bool trans) {
    if (_showTrans == trans) return;
    setState(() => _showTrans = trans);
    // 焦点必须跟着走：不然键盘输入会打到那个已经滑出视野的框里
    if (trans) {
      _rawFocus.unfocus();
      _transFocus.requestFocus();
    } else {
      _transFocus.unfocus();
      _rawFocus.requestFocus();
    }
  }

}

/// 竖条里的**长箭头**：撑满整条高度。
///
/// 自己画两条线而不是缩放图标 —— 图标按 24×24 坐标系绘制，
/// 纵向拉伸会把描边粗细一起拉变形（横细竖粗），很难看。
class _LongChevron extends StatelessWidget {
  const _LongChevron({required this.pointsLeft, required this.color});

  final bool pointsLeft;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 14,
        height: double.infinity,
        child: CustomPaint(
          painter: _ChevronPainter(pointsLeft: pointsLeft, color: color),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _ChevronPainter extends CustomPainter {
  _ChevronPainter({required this.pointsLeft, required this.color});

  final bool pointsLeft;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      // 线要够粗：箭头是拉长到整条高度的，细线（1.6）摊在几百像素上
      // 会细得像根头发，看着很别扭。这里按高度取一点比例，兼顾长条与短条。
      ..strokeWidth = (size.height * 0.011).clamp(2.2, 3.6)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    // 上下各留 6% 边距，别把线条顶死在两端
    final top = size.height * 0.06;
    final bottom = size.height * 0.94;
    final midY = size.height / 2;
    final nearX = pointsLeft ? 0.0 : size.width;
    final farX = pointsLeft ? size.width : 0.0;
    canvas.drawPath(
      Path()
        ..moveTo(farX, top)
        ..lineTo(nearX, midY)
        ..lineTo(farX, bottom),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ChevronPainter old) =>
      old.color != color || old.pointsLeft != pointsLeft;
}

class _MonoTextArea extends StatelessWidget {
  const _MonoTextArea({required this.controller, this.focusNode, this.hint});

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      cursorColor: c.accent,
      style: TextStyle(
        fontSize: 13,
        height: 1.8,
        color: c.text,
        fontFamily: kMonoFontFamily,
        fontFamilyFallback: kMonoFontFallback,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(fontSize: 13, color: c.textTertiary),
        filled: true,
        fillColor: c.inputBg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(c.radius),
          borderSide: BorderSide(color: c.inputBorder, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(c.radius),
          borderSide: BorderSide(color: c.accent, width: 1.5),
        ),
      ),
    );
  }
}

class _CancelIntent extends Intent {
  const _CancelIntent();
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}
