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

/// 应用外壳：标题栏 + 侧边栏 + 主内容 + 播放器栏 + Toast
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final AppState state = app;

  final ScrollController _searchScroll = ScrollController();
  final ScrollController _playlistScroll = ScrollController();
  final ScrollController _settingsScroll = ScrollController();
  final ScrollController _aboutScroll = ScrollController();

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
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    player.removeListener(_onPlayer);
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

  ScrollController _controllerFor(String page) => switch (page) {
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
