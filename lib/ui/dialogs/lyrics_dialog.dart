import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../../services/player_controller.dart';
import '../../state/app_state.dart';
import '../icons.dart';
import '../widgets/common.dart';
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

  bool _editing = false;
  bool _autoFollow = true;
  int _lastScrolledIdx = -1;
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
    setState(() {});
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
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _rawFocus.requestFocus();
    });
  }

  void _cancelEdit() {
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
                        onTap: () => Navigator.of(context).pop(),
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
                child: _buildLine(c, lines[i], transMap[lines[i].time] ?? '', i == activeIdx),
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
            color: active ? c.accentLight : (hovered ? c.hover : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                line.text,
                style: TextStyle(
                  fontSize: 14,
                  height: 2,
                  color: active ? c.accent : c.textTertiary,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
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

  Widget _buildEditArea(AppColors c) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Expanded(
            child: _MonoTextArea(controller: _rawCtrl, focusNode: _rawFocus),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '翻译歌词',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 140,
            child: _MonoTextArea(
              controller: _transCtrl,
              hint: '输入翻译歌词（可选，格式与原文LRC相同）',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Ctrl+S 保存 · Esc 取消',
            style: TextStyle(fontSize: 11, color: c.textTertiary.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }
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
