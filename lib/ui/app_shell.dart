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

  final FocusNode _rootFocus = FocusNode();

  int _lastLyricRequest = 0;
  int _zoomWheelAccum = 0;

  @override
  void initState() {
    super.initState();
    state.addListener(_onState);
    player.addListener(_onPlayer);
    player.onEnded = (action) => state.handleEndedAction(action);
    player.onModeChange = state.onModeChanged;
    _lastLyricRequest = state.lyricDialogRequest;
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
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    if (state.lyricDialogRequest != _lastLyricRequest) {
      _lastLyricRequest = state.lyricDialogRequest;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openLyricsDialog());
    }
    setState(() {});
  }

  void _onPlayer() {
    if (mounted) setState(() {});
  }

  Future<void> _openLyricsDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => LyricsDialog(state: state),
    );
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
                          Row(
                            children: [
                              AppSidebar(state: state),
                              Expanded(
                                child: ClipRect(
                                  child: Stack(
                                    children: [
                                      _PageSlot(
                                        active: state.page == 'search',
                                        direction: state.pageDirection,
                                        child: SearchPage(
                                          state: state,
                                          scrollController: _searchScroll,
                                        ),
                                      ),
                                      _PageSlot(
                                        active: state.page == 'playlist',
                                        direction: state.pageDirection,
                                        child: PlaylistPage(
                                          state: state,
                                          scrollController: _playlistScroll,
                                          onOpenLyric: state.requestLyricDialog,
                                        ),
                                      ),
                                      _PageSlot(
                                        active: state.page == 'settings',
                                        direction: state.pageDirection,
                                        child: SettingsPage(
                                          state: state,
                                          scrollController: _settingsScroll,
                                        ),
                                      ),
                                      _PageSlot(
                                        active: state.page == 'about',
                                        direction: state.pageDirection,
                                        child: AboutPage(scrollController: _aboutScroll),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
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

/// 页面槽位 —— 等价 CSS `.page` 的 `opacity/translateX` 过渡
class _PageSlot extends StatelessWidget {
  const _PageSlot({
    required this.active,
    required this.direction,
    required this.child,
  });

  final bool active;
  final int direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final targetX = active ? 0.0 : -direction * 30.0;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !active,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: targetX, end: targetX),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          builder: (ctx, x, inner) => Transform.translate(
            offset: Offset(x, 0),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              opacity: active ? 1 : 0,
              child: inner,
            ),
          ),
          child: child,
        ),
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
    if ((scale - 1).abs() < 0.001) return child;
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
class ToastLayer extends StatelessWidget {
  const ToastLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return const Material(
      color: Colors.transparent,
      child: Stack(children: [ToastOverlay()]),
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
