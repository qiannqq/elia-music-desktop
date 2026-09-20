import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_theme.dart';
import '../services/player_controller.dart';
import '../state/app_state.dart';
import '../state/theme_controller.dart';
import 'dialogs/lyrics_dialog.dart';
import 'pages/about_page.dart';
import 'pages/playlist_page.dart';
import 'pages/search_page.dart';
import 'pages/settings_page.dart';
import 'player_bar.dart';
import 'sidebar.dart';
import 'titlebar.dart';
import 'toast_overlay.dart';
import 'widgets/modal.dart';
import 'widgets/smooth_scroll.dart';
import 'widgets/keyboard_scroll.dart';

/// 应用外壳：标题栏 + 侧边栏 + 主内容 + 播放器栏 + Toast
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with SingleTickerProviderStateMixin {
  final AppState state = app;

  // 用 SmoothScrollController：滚轮与键盘共用**同一条连续动画**
  // （逐个事件起 animateTo 会让曲线反复重置，连发时就是一顿一顿的感觉）
  late final SmoothScrollController _searchScroll =
      SmoothScrollController(vsync: this);
  late final SmoothScrollController _playlistScroll =
      SmoothScrollController(vsync: this);
  late final SmoothScrollController _settingsScroll =
      SmoothScrollController(vsync: this);
  late final SmoothScrollController _aboutScroll =
      SmoothScrollController(vsync: this);

  // 输入框控制器与滚动控制器同理，必须由 shell 持有：
  // 页面是按 `switch (state.page)` 构建的，切走就 dispose，
  // 控制器若归页面自己管，切回来时输入内容就没了 ——
  // 表现为「搜索结果还在、输入框却空了」。
  final TextEditingController _searchInput = TextEditingController();
  final TextEditingController _qqCookie = TextEditingController();
  final TextEditingController _neteaseCookie = TextEditingController();
  final TextEditingController _savePath = TextEditingController();

  final FocusNode _rootFocus = FocusNode();

  int _lastLyricRequest = 0;
  int _zoomWheelAccum = 0;
  String _lastPage = 'search';

  @override
  void initState() {
    super.initState();
    state.addListener(_onState);
    player.addListener(_onPlayer);
    player.onEnded = (action) => state.handleEndedAction(action);
    player.onModeChange = state.onModeChanged;
    _lastLyricRequest = state.lyricDialogRequest;
    // 设置页的 ck 只在启动时灌一次；之后输入框里的内容就是「编辑中的那份」，
    // 切页面回来不能再从状态里覆盖一遍，否则没保存的编辑会被冲掉。
    _qqCookie.text = state.qqCookie;
    _neteaseCookie.text = state.neteaseCookie;
    FocusManager.instance.addListener(_reclaimFocusIfLost);
  }

  /// 焦点跑丢时把它收回根节点。
  ///
  /// 点一下页面空白（或者点过输入框再点别处），EditableText 会自己 unfocus，
  /// 此时**没有任何节点持有焦点**：键盘事件没有起点，也就冒泡不到根节点，
  /// 空格 / PgUp / PgDn 全部失灵 —— 明明焦点不在输入框里，却什么都按不动。
  /// 把焦点收回根节点就恢复了。
  ///
  /// 两个都不能省：
  ///  * 同步 requestFocus 会重入（焦点变化正在派发）；
  ///  * 但只等一帧也不够 —— 点击输入框时，焦点会**先**短暂地落到 rootScope，
  ///    再交给输入框。这时候立刻收回，就把输入框刚要到的焦点抢走了，
  ///    表现为「点输入框点不进去、一个字也打不了」。所以要等一小会儿，
  ///    确认焦点**真的**没人要，才收回。
  void _reclaimFocusIfLost() {
    Future.delayed(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      final primary = FocusManager.instance.primaryFocus;
      if (_isUnderRoot(primary)) return;
      _rootFocus.requestFocus();
    });
  }

  /// 焦点是不是落在根节点自己或它的后代上。
  ///
  /// 不能用「是不是 rootScope」来判断：点一下页面空白，焦点会落到
  /// **Navigator 的 FocusScopeNode** 上 —— 那是根节点的**祖先**，
  /// 键盘事件从它往上冒，永远不经过根节点，PgUp/PgDn 就此失灵。
  /// 反过来，焦点在输入框里时它是根节点的后代，就该原样不动。
  bool _isUnderRoot(FocusNode? node) {
    for (var n = node; n != null; n = n.parent) {
      if (identical(n, _rootFocus)) return true;
    }
    return false;
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    player.removeListener(_onPlayer);
    FocusManager.instance.removeListener(_reclaimFocusIfLost);
    _searchScroll.dispose();
    _playlistScroll.dispose();
    _settingsScroll.dispose();
    _aboutScroll.dispose();
    _rootFocus.dispose();
    _searchInput.dispose();
    _qqCookie.dispose();
    _neteaseCookie.dispose();
    _savePath.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    if (state.lyricDialogRequest != _lastLyricRequest) {
      _lastLyricRequest = state.lyricDialogRequest;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openLyricsDialog());
    }
    // 只挂载当前页（等价原 `.page{display:none}`），因此切换时需手动
    // 保存/恢复各页滚动位置 —— 对应原 `state.pageScrolls`
    if (state.page != _lastPage) {
      _saveScroll(_lastPage);
      _lastPage = state.page;
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreScroll(state.page));
    }
    setState(() {});
  }

  // ------------------------------------------------------------ 键盘滚动
  //
  // 页面用的是 SmoothWheelScroll，它为了让滚轮不被 Scrollable 重复处理，
  // 把 physics 的 `shouldAcceptUserOffset` 关成了 false —— 而框架的
  // ScrollAction 拿**同一个**判断来决定「用户能不能滚」，于是 PgUp/PgDn、
  // 方向键、空格被一起拦掉了（scrollable_helpers.dart 里那句
  // "Don't do anything if the user isn't allowed to scroll"）。
  // 所以这里显式补回来，顺便沿用滚轮那套缓动。
  void _scrollBy(double delta) {
    // 只累加目标，动画由控制器那条连续曲线负责 —— 连发时曲线不会被打断
    _controllerFor(state.page).scrollBy(delta);
  }

  void _scrollToEdge({required bool top}) {
    final ctrl = _controllerFor(state.page);
    if (!ctrl.hasClients) return;
    ctrl.scrollTo(
        top ? ctrl.position.minScrollExtent : ctrl.position.maxScrollExtent);
  }

  /// 一屏的高度（翻页键走这么多）
  double _pageStep() {
    final ctrl = _controllerFor(state.page);
    if (!ctrl.hasClients) return 400;
    return ctrl.position.viewportDimension * 0.9;
  }

  /// 挂在根 Focus 上的键盘滚动。
  ///
  /// 用 `onKeyEvent` 而不是 Shortcuts：键事件从**当前焦点节点**往上冒，
  /// 挂在根节点上，无论焦点在根节点还是页面里某个控件上都能收到。
  ///
  /// 但「能收到」不等于「都该处理」：这个节点在冒泡链上比 WidgetsApp 那层
  /// `DefaultTextEditingShortcuts` **更靠近焦点**，也就是滚动处理先于文本编辑
  /// 拿到按键。所以焦点在输入框里时必须原样放行，否则空格、方向键、
  /// PgUp/PgDn 全被抢去滚动，输入框一个字都打不进去。
  KeyEventResult _onRootKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (isTextFieldFocused()) return KeyEventResult.ignored;
    switch (scrollIntentFor(event.logicalKey)) {
      case KeyScrollIntent.pageDown:
        _scrollBy(_pageStep());
      case KeyScrollIntent.pageUp:
        _scrollBy(-_pageStep());
      case KeyScrollIntent.lineDown:
        _scrollBy(48);
      case KeyScrollIntent.lineUp:
        _scrollBy(-48);
      case KeyScrollIntent.top:
        _scrollToEdge(top: true);
      case KeyScrollIntent.bottom:
        _scrollToEdge(top: false);
      case null:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  SmoothScrollController _controllerFor(String page) => switch (page) {
        'playlist' => _playlistScroll,
        'settings' => _settingsScroll,
        'about' => _aboutScroll,
        _ => _searchScroll,
      };

  void _saveScroll(String page) {
    final ctrl = _controllerFor(page);
    if (ctrl.hasClients) state.pageScrolls[page] = ctrl.offset;
  }

  void _restoreScroll(String page) {
    final ctrl = _controllerFor(page);
    final saved = state.pageScrolls[page];
    if (!ctrl.hasClients || saved == null) return;
    ctrl.jumpTo(saved.clamp(
      ctrl.position.minScrollExtent,
      ctrl.position.maxScrollExtent,
    ));
    // 程序改了位置，清掉动画基准，免得下一次滚动从过期的目标起步
    ctrl.invalidateTarget();
  }

  void _onPlayer() {
    if (mounted) setState(() {});
  }

  Future<void> _openLyricsDialog() async {
    if (!mounted) return;
    // 用统一 modal 外壳：深色遮罩 + 入场动画（等价原版 showModal('lyrics-overlay')）
    await showAppModal<void>(context, LyricsDialog(state: state));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.digit0, control: true):
            const _ResetZoomIntent(),
        const SingleActivator(LogicalKeyboardKey.escape): const _EscapeIntent(),
      },
      child: Actions(
        actions: {
          _ResetZoomIntent: CallbackAction<_ResetZoomIntent>(
            onInvoke: (_) {
              state.setZoom(100);
              return null;
            },
          ),
          _EscapeIntent: CallbackAction<_EscapeIntent>(onInvoke: (_) => null),
        },
        child: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          onKeyEvent: _onRootKey,
          child: Listener(
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent) return;
              if (!HardwareKeyboard.instance.isControlPressed) return;
              _zoomWheelAccum += event.scrollDelta.dy < 0 ? 1 : -1;
              final accum = _zoomWheelAccum;
              _zoomWheelAccum = 0;
              state.setZoom(state.zoom + accum * 5);
            },
            // 用 Material 而非 Container 作为根：TextField / Tooltip 等
            // Material 组件需要 Material 祖先，否则报
            // "No Material widget found. TextField widgets require a Material widget ancestor"
            child: Material(
              color: c.bg,
              child: Column(
                children: [
                  const AppTitlebar(),
                  Expanded(
                    child: ZoomWrapper(
                      scale: state.zoom / 100,
                      child: Stack(
                        children: [
                          // 播放栏出现时**必须为它让出高度**（等价原版
                          // `body.has-player .page.active{padding-bottom:88px}`），
                          // 否则它会盖住页面底部内容（设置页的「外观」区）。
                          // 注意只让出**播放栏本体高度**：多让的部分在页面外层，
                          // 露出的是窗口底色，会变成播放栏上方一条灰边。
                          Padding(
                            padding: EdgeInsets.only(
                              bottom: player.currentSong != null ? kPlayerBarHeight : 0,
                            ),
                            child: Row(
                              children: [
                                AppSidebar(state: state),
                                Expanded(
                                  child: ClipRect(
                                    child: Stack(
                                      children: [
                                        _PageSlot(
                                          key: ValueKey(state.page),
                                          direction: state.pageDirection,
                                          child: switch (state.page) {
                                            'playlist' => PlaylistPage(
                                                state: state,
                                                scrollController: _playlistScroll,
                                                onOpenLyric: state.requestLyricDialog,
                                              ),
                                            'settings' => SettingsPage(
                                                state: state,
                                                scrollController: _settingsScroll,
                                                qqCookie: _qqCookie,
                                                neteaseCookie: _neteaseCookie,
                                                savePath: _savePath,
                                              ),
                                          'about' =>
                                            AboutPage(scrollController: _aboutScroll),
                                          _ => SearchPage(
                                              state: state,
                                              scrollController: _searchScroll,
                                              inputController: _searchInput,
                                            ),
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                            ),
                          ),
                          // 播放器栏（有歌曲时显示，等价 body.has-player）
                          if (player.currentSong != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: PlayerBar(state: state),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 页面槽位 —— 等价 CSS `.page.active` 的入场过渡
/// （`translateX(30px) → 0` + `opacity 0 → 1`，250ms）
///
/// 注意：**只挂载当前页**，与原始实现的 `.page{display:none}` 一致。
/// 早期版本为了让滚动位置自然保留而把 4 个页面全部常驻挂载，
/// 会让渲染树与无障碍语义树大出数倍（并伴随 Windows 无障碍桥报错）。
class _PageSlot extends StatelessWidget {
  const _PageSlot({
    super.key,
    required this.direction,
    required this.child,
  });

  /// 1 = 向右进入，-1 = 向左进入
  final int direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: direction * 30.0, end: 0),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        builder: (ctx, x, inner) => Transform.translate(
          offset: Offset(x, 0),
          child: Opacity(
            opacity: (1 - (x.abs() / 30.0)).clamp(0.0, 1.0),
            child: inner,
          ),
        ),
        child: child,
      ),
    );
  }
}

/// 界面缩放包装器 —— 等价 `webFrame.setZoomFactor(scale)`
///
/// 做法：以 `1/scale` 的虚拟尺寸布局整棵树，再整体放大，
/// 效果与浏览器 zoom（文字与控件一起缩放）一致。
class ZoomWrapper extends StatelessWidget {
  const ZoomWrapper({super.key, required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // **不能**在 scale==1 时直接 return child：
    // 那样 widget 树的结构会变（少掉 LayoutBuilder/OverflowBox 两层），
    // Flutter 会把整棵子树卸载重建 —— 表现为「缩放到 100% 时页面刷新」。
    // 始终走同一套结构，scale=1 时下面就是个恒等变换。
    return LayoutBuilder(
      builder: (ctx, constraints) {
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            minHeight: 0,
            maxWidth: constraints.maxWidth / scale,
            maxHeight: constraints.maxHeight / scale,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: constraints.maxWidth / scale,
                height: constraints.maxHeight / scale,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ResetZoomIntent extends Intent {
  const _ResetZoomIntent();
}

class _EscapeIntent extends Intent {
  const _EscapeIntent();
}

/// Toast 覆盖层（放在最外层，避免被页面裁剪）
///
/// 三个关键点（前两个曾导致「界面正常但什么都点不动」，第三个导致崩溃）：
///  1. `Material` 默认是 `MaterialType.canvas`，其 `_InkFeatures.absorbHitTest = true`，
///     `_RenderInkFeatures.hitTestSelf` 恒为 true —— 即**会吸收命中测试**。
///     透明背景也必须显式用 `MaterialType.transparency` 才不会吃掉点击。
///  2. Toast 本身是纯展示、不需要交互，外面再包一层 `IgnorePointer` 双保险。
///  3. 它作为 `MaterialApp.builder` 的 Stack 子节点，位于应用语义根**之外**，
///     会让 Windows 无障碍桥出现 "0 will not be in the tree and is not the new root"
///     并最终在引擎层触发 ACCESS_VIOLATION 崩溃（0xC0000005）。
///     用 `ExcludeSemantics` 让它不参与语义树即可。
class ToastLayer extends StatelessWidget {
  const ToastLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return const ExcludeSemantics(
      child: IgnorePointer(
        child: Material(
          type: MaterialType.transparency,
          child: Stack(children: [ToastOverlay()]),
        ),
      ),
    );
  }
}

/// 供 main.dart 使用：把主题与全局状态串起来
class EliaMusicApp extends StatelessWidget {
  const EliaMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeController,
      builder: (ctx, _) {
        return MaterialApp(
          title: 'Elia Music',
          debugShowCheckedModeBanner: false,
          theme: themeController.resolve(Brightness.light),
          darkTheme: themeController.resolve(Brightness.dark),
          themeMode: switch (themeController.mode) {
            AppThemeMode.light => ThemeMode.light,
            AppThemeMode.dark => ThemeMode.dark,
            AppThemeMode.system => ThemeMode.system,
          },
          builder: (context, child) {
            return Stack(
              children: [
                ?child,
                const ToastLayer(),
              ],
            );
          },
          home: const AppShell(),
        );
      },
    );
  }
}
