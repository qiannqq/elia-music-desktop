import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_theme.dart';
import '../core/perf_probe.dart';
import '../core/window_fx.dart';
import '../services/app_background.dart';
import '../services/player_controller.dart';
import '../services/video_bg.dart';
import '../state/app_state.dart';
import '../state/theme_controller.dart';
import 'dialogs/lyrics_dialog.dart';
import 'now_playing.dart';
import 'pages/about_page.dart';
import 'pages/playlist_page.dart';
import 'pages/search_page.dart';
import 'pages/settings_page.dart';
import 'player_bar.dart';
import 'sidebar.dart';
import 'titlebar.dart';
import 'toast_overlay.dart';
import 'widgets/app_backdrop.dart';
import 'widgets/modal.dart';
import 'widgets/fluent.dart';
import 'widgets/queue_panel.dart';
import 'widgets/smooth_scroll.dart';
import 'widgets/keyboard_scroll.dart';

/// 应用外壳：标题栏 + 侧边栏 + 主内容 + 播放器栏 + Toast
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    // 必须是 TickerProviderStateMixin（复数）：下面那 5 个 SmoothScrollController
    // 每个都会 createTicker。Single 那个版本第二次就 assert 失败 ——
    // release 下 assert 被跳过，所以「切到歌单页再切设置页」这种路径一直没炸，
    // debug 下一进去就红。
    with TickerProviderStateMixin {
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
  /// 播放列表面板的滚动条。归 shell 持有是因为面板开着时那几个翻页键要作用
  /// 在它身上 —— 键处理挂在 shell 的根 Focus 上，得够得着这条控制器。
  late final SmoothScrollController _queueScroll =
      SmoothScrollController(vsync: this);

  // 输入框控制器与滚动控制器同理，必须由 shell 持有：
  // 页面是按 `switch (state.page)` 构建的，切走就 dispose，
  // 控制器若归页面自己管，切回来时输入内容就没了 ——
  // 表现为「搜索结果还在、输入框却空了」。
  final TextEditingController _searchInput = TextEditingController();
  final TextEditingController _qqCookie = TextEditingController();
  final TextEditingController _neteaseCookie = TextEditingController();
  final TextEditingController _biliCookie = TextEditingController();
  final TextEditingController _savePath = TextEditingController();

  final FocusNode _rootFocus = FocusNode();

  int _lastLyricRequest = 0;
  int _zoomWheelAccum = 0;
  String _lastPage = 'search';

  /// 「播放列表」面板是否展开。面板由 shell 托管：它要盖在页面之上、
  /// 播放栏之下 —— 放进页面里会被 `ClipRect` 裁掉。
  bool _queueOpen = false;

  /// 现在播放页（点播放栏封面推上来的整屏页）。
  ///
  /// 同样归 shell 托管：它要盖住播放栏和所有页面，而且在 ZoomWrapper 里面 ——
  /// 走 Navigator 的弹窗是挂在根 Overlay 上的，那个在缩放之外。
  bool _nowPlayingOpen = false;

  /// 开合现在播放页。**统一走这里**：除了本地开关，还要告诉状态层「页面开着」——
  /// 它决定要不要去算低频包络（背景要律动才用得上），以及整窗背景那一路的
  /// 视频需求要不要让位给页面。
  void _setNowPlaying(bool open) {
    if (_nowPlayingOpen == open) return;
    setState(() => _nowPlayingOpen = open);
    state.nowPlayingOpen = open;
    if (open) state.ensureEnvelope();
    _syncVideoDemand();
  }

  /// 整窗背景（封面模式）那一路的视频需求。
  ///
  /// ⚠️ **不要**把「播放页开着」也算进条件：那样页面一开一关，需求会经历
  /// 「有 → 空 → 有」—— 而服务里空需求等于「谁都不要了」，它会当场
  /// `_stopDecoding()` + 清帧，紧接着再重新拉一遍流。表现就是
  /// 「展开播放页又拉了一次 B站视频」（千奈报的）。
  /// 两处要的是**同一首歌同一条流**，一起要着就行，本来就该只拉一次。
  void _syncVideoDemand() {
    videoBackground.sync(
      who: 'app-bg',
      want: appBackground.mode == AppBgMode.cover && state.bgVideo,
      song: player.currentSong,
    );
  }

  void _onBackgroundChanged() {
    if (!mounted) return;
    // 刚切成封面模式 → 这首歌可能还没探过包络（用户以前没开过「跳过首尾无声」）
    if (appBackground.mode == AppBgMode.cover) state.ensureEnvelope();
    _syncVideoDemand();
    _markPerf();
  }

  /// 给帧探针（`--dart-define=ELIA_PERF=true`）打标签。
  ///
  /// 探针每 5 秒往日志写一行汇总，但数字本身不知道对应什么场景 ——
  /// 打上「播放/暂停 + 背景模式」之后，同一次运行里开/关背景的数字可以直接对比。
  /// 探针关着时 `mark` 只是一次赋值，没有开销。
  void _markPerf() {
    PerfProbe.mark('${player.isPlaying ? '播放' : '暂停'}/背景=${appBackground.mode.name}');
  }

  /// 点播放栏那个按钮：开着就收回，收起就展开。
  void _toggleQueue() {
    if (_queueOpen) {
      setState(() => _queueOpen = false);
      return;
    }
    // 启动后还没播过东西时队列是空的，先按当前模式建一次
    state.ensureQueue();
    setState(() => _queueOpen = true);
  }

  @override
  void initState() {
    super.initState();
    // 问一次原生当前状态（正常启动时两个都是 false，但热重载 / 异常退出
    // 之后再进来可能对不上，顺手同步一下）
    unawaited(syncWindowFxState());
    state.addListener(_onState);
    appBackground.addListener(_onBackgroundChanged);
    // 启动时也要报一次视频需求：`_syncVideoDemand` 挂在播放器与背景的**变化**上，
    // 而开机时「已经在放的那首 + 已经开着的封面背景」没有任何变化会触发它
    // —— 少了这一句，恢复播放的情况下整窗背景的视频永远不会开始拉。
    _syncVideoDemand();
    player.addListener(_onPlayer);
    player.onEnded = (action) => state.handleEndedAction(action);
    player.onModeChange = state.onModeChanged;
    player.onShortAudio = state.onShortAudio;
    // 播放栏停在「记忆态」或上次取地址失败时，点播放要重新取一次地址 ——
    // 回到状态层走一遍正常的播放流程
    player.onReloadRequested = (song) => state.playSong(song.mid);
    _lastLyricRequest = state.lyricDialogRequest;
    // 设置页的 ck 只在启动时灌一次；之后输入框里的内容就是「编辑中的那份」，
    // 切页面回来不能再从状态里覆盖一遍，否则没保存的编辑会被冲掉。
    _qqCookie.text = state.qqCookie;
    _neteaseCookie.text = state.neteaseCookie;
    _biliCookie.text = state.biliCookie;
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
      // 焦点在输入框里就绝不能碰。
      //
      // 弹窗（歌词编辑、重命名……）挂在 Navigator 的 overlay 上，本来就不在
      // 根节点之下 —— 只看「在不在根之下」会把输入框刚要到的焦点抢回来，
      // 表现为「点编辑框，光标闪一下就没了」，而且每次重试都一样。
      if (isTextFieldFocused()) return;
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
    appBackground.removeListener(_onBackgroundChanged);
    player.removeListener(_onPlayer);
    FocusManager.instance.removeListener(_reclaimFocusIfLost);
    _searchScroll.dispose();
    _playlistScroll.dispose();
    _settingsScroll.dispose();
    _aboutScroll.dispose();
    _queueScroll.dispose();
    _rootFocus.dispose();
    _searchInput.dispose();
    _qqCookie.dispose();
    _neteaseCookie.dispose();
    _biliCookie.dispose();
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
    _activeScroll().scrollBy(delta);
  }

  /// 翻页键 / 首尾键当前该作用在哪条滚动上。
  ///
  /// 面板开着的时候一律作用于队列 —— 面板是盖在页面之上的，
  /// 这时候还去滚背后的歌单页，用户看到的是「键没反应」。
  SmoothScrollController _activeScroll() =>
      _queueOpen ? _queueScroll : _controllerFor(state.page);

  void _scrollToEdge({required bool top}) {
    final ctrl = _activeScroll();
    if (!ctrl.hasClients) return;
    ctrl.scrollTo(
        top ? ctrl.position.minScrollExtent : ctrl.position.maxScrollExtent);
  }

  /// 一屏的高度（翻页键走这么多）
  double _pageStep() {
    final ctrl = _activeScroll();
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
    // ⚠️ **全屏是窗口级状态**：不管播放页开没开，Esc 都先退全屏 ——
    // 全屏是沉浸态，用户按 Esc 想先回到普通窗口；只有非全屏时
    // Esc 才是「收起播放页」。
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        appFullscreen.value) {
      unawaited(exitFullscreen());
      return KeyEventResult.handled;
    }
    // 现在播放页开着时：Esc 收起，别的滚动键**不作用到下面的页面**上
    // （页面还在树上，不管的话 PgDn 会把看不见的那一页滚走）
    if (_nowPlayingOpen) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        _setNowPlaying(false);
        return KeyEventResult.handled;
      }
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

  bool _lastHasSong = false;

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

  /// 这个 shell 只关心「有没有歌在放」——它决定播放栏的留白与显示。
  ///
  /// 不能无条件 setState：播放位置每秒变化几十次，会把整个页面（含几十行
  /// 列表）一起重建。位置相关的变化由各自的 `ValueListenableBuilder` 处理。
  void _onPlayer() {
    // 换歌要重新报一次视频需求（同一首歌重复报是空操作）——
    // 下面那个「有没有歌」的早退会把换歌挡掉，而视频背景要跟着新歌走。
    _syncVideoDemand();
    _markPerf();
    final hasSong = player.currentSong != null;
    if (hasSong == _lastHasSong) return;
    _lastHasSong = hasSong;
    // 歌没了（点了关闭）：现在播放页留着就是个空壳
    if (!hasSong) _setNowPlaying(false);
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
            //
            // ⚠️ 底色**留在原地不要动**（`color: c.bg`）：Material 的底色画在它自己
            // 子树的**下面**，而整体背景层是 Stack 的第一个子节点 —— 盖得住。
            // 于是窗口输出仍然不透明，DWM 走的是「不透明快速合成」那条路。
            // （云母那一版必须把它改成透明，是因为云母层自己带 alpha、整窗要跟着透明；
            //   这里是一张不透明的图 + 压暗罩，不需要付那份代价。）
            child: AnimatedBuilder(
              animation: appBackground,
              builder: (_, _) {
                return Material(
                  color: c.bg,
                  child: Stack(
                    children: [
                      // ---- 整体背景：整窗最底一层 ----
                      //
                      // **无条件存在**（关着时它自己返回 `SizedBox.shrink()`）：
                      // 条件插入会让 Stack 的兄弟节点错位、整棵 shell 子树重挂。
                      // 现在播放页开着时它整个被盖住 —— Offstage 掉，别让它继续转。
                      Positioned.fill(
                        child: IgnorePointer(
                          child: TickerMode(
                            // ⚠️ `Offstage` **只省绘制、不停表**：被盖住的那份背景
                            // 仍在 60fps 地转（`AnimationController.repeat()`）。
                            // 这里连时钟一起停掉 —— 背景画面是**播放时刻的纯函数**，
                            // 停表再启不会跳角度。
                            enabled: !_nowPlayingOpen,
                            child: Offstage(
                              offstage: _nowPlayingOpen,
                              child: const AppBackdropLayer(),
                            ),
                          ),
                        ),
                      ),
                      // ---- 内容区：顶部给标题栏让出高度 ----
                      //
                      // 标题栏从 Column 的一个子项改成了**浮层**（见下面），
                      // 这样现在播放页才能盖住它 —— 否则播放页只能从标题栏下沿开始。
                      //
                      // 播放页开着时整块 Offstage：它被盖住了，可播放栏的进度条
                      // 还在每秒重画几十次 —— 白画的那些帧正好跟出场动画抢时间。
                      Positioned.fill(
                        child: Offstage(
                          offstage: _nowPlayingOpen,
                          child: Padding(
                            padding: const EdgeInsets.only(top: kTitlebarHeight),
                            child: ZoomWrapper(
                              scale: state.zoom / 100,
                              child: Stack(
                                children: [
                                  // ⚠️ 这里**不要**再铺一层内容底色：标题栏与侧边栏
                                  // 本来就是透明的，只有内容区和播放栏各套了自己的
                                  // 半透明底 —— 于是同一张背景在几处呈现的明暗不一样
                                  // （千奈真机看出来的：播放栏偏暗、标题栏偏亮）。
                                  // 现在整窗只有背景层那一层统一叠色（明暗滑块），
                                  // 其余 chrome 一律透明，亮度才真正统一。
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
                                                    biliCookie: _biliCookie,
                                                    savePath: _savePath,
                                                  ),
                                              'about' =>
                                                AboutPage(scrollController: _aboutScroll),
                                              _ => SearchPage(
                                                  state: state,
                                                  scrollController: _searchScroll,
                                                  inputController: _searchInput,
                                                  onOpenLyric:
                                                      state.requestLyricDialog,
                                                ),
                                            },
                                          ),
                                          // 播放列表面板：盖在页面之上，从右侧滑出。
                                          // 放在 ClipRect 里面 —— 滑出的过程正好被
                                          // 页面区裁掉，看起来才是「从边上推出来」。
                                          QueuePanel(
                                            state: state,
                                            open: _queueOpen,
                                            onClose: () =>
                                                setState(() => _queueOpen = false),
                                            onOpenLyric: state.requestLyricDialog,
                                            scrollController: _queueScroll,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                                ),
                              ),
                              // 播放器栏（有歌曲时显示，等价 body.has-player）
                              //
                              // ⚠️ 自己关一层重绘边界：进度条与时间按位置事件
                              // （30Hz）在变，而外壳这一层原本**一个重绘边界都没有**
                              // —— 不关起来的话它们每变一次都会把整窗内容层的绘制
                              // 记录标脏，白白重录一遍整屏。
                              if (player.currentSong != null)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: RepaintBoundary(
                                    child: PlayerBar(
                                      state: state,
                                      onOpenQueue: _toggleQueue,
                                      onOpenNowPlaying: () => _setNowPlaying(true),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // ---- 现在播放页：盖住整窗（含标题栏区域）----
                  //
                  // 常驻组件树、只切 open —— 摘挂会重建整棵子树。
                  Positioned.fill(
                    child: NowPlayingPage(
                      state: state,
                      open: _nowPlayingOpen,
                      onClose: () => _setNowPlaying(false),
                    ),
                  ),
                  // ---- 标题栏：永远在最上层 ----
                  //
                  // 播放页开着时它透明 + 内容物转白，窗口按钮仍然可点 ——
                  // 全屏页把标题栏吃掉的话，用户连关窗都做不到。
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: AppTitlebar(over: _nowPlayingOpen),
                  ),
                ],
              ),
            );
              },
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
/// 过渡本体在 [AppPageTransition]（设置页切分栏复用同一份，两处观感一致），
/// 这里只负责把它按「铺满整个内容区」摆好。
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
      child: AppPageTransition(direction: direction, child: child),
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
      // 主题色、深/浅、以及「有没有整体背景」都会影响令牌（有背景时卡片要透一些），
      // 所以两个都要听。
      animation: Listenable.merge([themeController, appBackground]),
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
