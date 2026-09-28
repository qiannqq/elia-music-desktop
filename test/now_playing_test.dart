import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';

import 'package:elia_music/core/app_theme.dart';
import 'package:elia_music/core/lyric.dart';
import 'package:elia_music/core/window_fx.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/services/silence_probe.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/state/toast.dart';
import 'package:elia_music/ui/titlebar.dart';
import 'package:elia_music/ui/app_shell.dart';
import 'package:elia_music/ui/now_playing.dart';
import 'package:elia_music/ui/player_bar.dart';

/// 现在播放页（点播放栏封面推上来的整屏页）。
///
/// 盯三件事：
///   1. 触发路径 —— 点**封面**才推页，点歌名/歌词那一块仍然是歌词编辑弹窗；
///   2. 收起时**内容整块不建**（里面有一层全屏高斯模糊，留在树上白占光栅化）；
///   3. 歌词行的明暗梯度（当前句最亮、越远越暗、上下不对称）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const song = Song(mid: 'mid1', name: '铁花飞', artist: 'Mii/寒王唱片-MSR');

  setUpAll(() {
    // 日志要写文件；不指到临时目录的话每次都会打一行「logsDir 没初始化」
    final tmp = Directory.systemTemp.createTempSync('elia_now_playing_test');
    AppPaths.appDir = tmp.path;
    AppPaths.dataDir = tmp.path;
    AppPaths.logsDir = tmp.path;
    AppPaths.tempDir = tmp.path;
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    // player 是全局单例，构造时会建 AudioPlayer —— 测试里没有原生插件，
    // 不把通道挡掉就会异步抛 MissingPluginException，算到别的用例头上
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async => null);
    }
    messenger.setMockStreamHandler(
      const EventChannel('xyz.luan/audioplayers.global/events'),
      MockStreamHandler.inline(onListen: (args, sink) {}),
    );
  });

  setUp(() {
    player.currentSong = song;
    player.lyricLines = const [];
    player.activeLyricIndex = -1;
    player.isPlaying = false;
    player.isLoading = false;
    player.setMode(PlayMode.sequential);
    toast.clear();
    player.position = Duration.zero;
    player.positionNotifier.value = Duration.zero;
    // 全屏状态是全局的（窗口事件也会改它），用例之间要复位
    appFullscreen.value = false;
    windowFxBusy = false;
  });

  /// 页面里的查找一律**限定在 NowPlayingPage 里面** ——
  /// MaterialApp/Scaffold 自己也用 SlideTransition 和 AnimatedDefaultTextStyle
  Finder inPage(Finder matching) =>
      find.descendant(of: find.byType(NowPlayingPage), matching: matching);

  Future<void> pumpPage(
    WidgetTester tester, {
    required bool open,
    VoidCallback? onClose,
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NowPlayingPage(
          state: app,
          open: open,
          onClose: onClose ?? () {},
        ),
      ),
    ));
    await tester.pump();
  }

  group('歌词行的明暗', () {
    test('当前句最亮，越远越暗，且上下不对称', () {
      expect(lyricLineOpacity(3, 3), 1.0, reason: '当前句要满亮度');

      // 已经唱过的（在上面）比还没唱的（在下面）暗得更快
      expect(lyricLineOpacity(2, 3), lessThan(lyricLineOpacity(4, 3)));

      // 单调递减：离得越远越暗
      var prev = lyricLineOpacity(4, 3);
      for (var i = 5; i < 12; i++) {
        final cur = lyricLineOpacity(i, 3);
        expect(cur, lessThanOrEqualTo(prev));
        prev = cur;
      }
    });

    test('再远也留得住一点 —— 整句看不见会像空了几行', () {
      for (final d in [5, 20, 200]) {
        expect(lyricLineOpacity(d, 0), greaterThanOrEqualTo(0.16));
        expect(lyricLineOpacity(-d, 0), greaterThanOrEqualTo(0.16));
      }
    });

    test('还没唱到任何一句时：一律按「未唱」那一档', () {
      expect(lyricLineOpacity(0, -1), 0.6);
      expect(lyricLineOpacity(9, -1), 0.6);
    });
  });

  group('响度包络', () {
    test('按时刻取响度，两格之间插值', () {
      // 显式给 100ms 一格，免得跟着默认值（20ms）变
      final track =
          LevelTrack(Uint8List.fromList([0, 255, 255, 0]), stepMs: 100);
      expect(track.levelAt(-1), 0);
      expect(track.levelAt(0), 0);
      expect(track.levelAt(0.1), closeTo(1.0, 0.01));
      expect(track.levelAt(0.15), closeTo(1.0, 0.01));
      expect(track.levelAt(0.25), closeTo(0.5, 0.02), reason: '中间要插值，不是一格一格跳');
      expect(track.levelAt(0.3), closeTo(0.0, 0.01));
      expect(track.levelAt(99), 0, reason: '越界取最后一格');
    });

    test('默认是 20ms 一格（起音检测要这个分辨率）', () {
      // 5 格 × 20ms = 第 0.1 秒
      final track = LevelTrack(Uint8List.fromList([0, 255, 255, 255, 0]));
      expect(track.stepMs, 20);
      expect(track.levelAt(0.02), closeTo(1.0, 0.01));
      expect(track.levelAt(0.1), 0);
    });

    test('空包络不炸（首次播放时探测还没跑完就是这种状态）', () {
      final track = LevelTrack(Uint8List(0));
      expect(track.isEmpty, isTrue);
      expect(track.levelAt(3), 0);
    });

    test('亮度上得快、落得慢', () {
      final up = followLevel(0, 1, 0.05);
      final down = 1 - followLevel(1, 0, 0.05);
      expect(up, greaterThan(down), reason: '鼓点打下去要立刻亮、松开慢慢落');
      expect(up, lessThan(1));
      expect(down, greaterThan(0));
    });
  });

  group('背景律动（照 AMLL 的公式）', () {
    test('低频包络映射：−25dB 以下算 0、−5dB 以上算满', () {
      expect(bgVolume(0.5), 0); // （字节 0.5 = −25dB）
      expect(bgVolume(0.9), 1); // （字节 0.9 = −5dB）
      expect(bgVolume(0.7), closeTo(0.5, 0.001));
      expect(bgVolume(0.1), 0, reason: '安静段落不该有动作');
      expect(bgVolume(1.0), 1, reason: '再响也只是满值');
    });

    test('旋转是匀速的：约 31 秒一圈，低频最多再推 0.2 弧度', () {
      expect(bgAngle(0, 0, 1), closeTo(0.0, 1e-9));
      expect(bgAngle(31.4159, 0, 1), closeTo(6.2832, 0.01), reason: '2π ≈ 31.4 秒');
      expect(bgAngle(1, 1, 1), closeTo(0.4, 1e-9), reason: '0.2 的匀速 + 0.2 的低频');
    });

    test('低频把画面向内放大，最多 25%', () {
      expect(bgZoom(0, 1), 1);
      expect(bgZoom(1, 1), closeTo(1.25, 1e-9));
      expect(bgZoom(0.5, 1), closeTo(1.1111, 0.001));
    });

    test('幅度调成 0：不转也不缩放（完全静止）', () {
      for (final t in [0.0, 5.0, 100.0]) {
        expect(bgAngle(t, 1, 0), 0);
      }
      expect(bgZoom(1, 0), 1);
      expect(bgZoom(0.8, 0), 1);
    });

    test('旋转速度只乘在匀速那一项上（低频推角仍归幅度管）', () {
      expect(bgAngle(31.4159, 0, 1, spin: 2), closeTo(12.5664, 0.01),
          reason: '2 倍速 → 约 15.7 秒一圈');
      expect(bgAngle(0, 0, 1, spin: 3), 0, reason: '起点还是 0');
      expect(bgAngle(10, 0, 1, spin: 0), 0, reason: '转速 0 又没有低频 → 完全不转');
      expect(bgAngle(1, 1, 1, spin: 0), closeTo(0.2, 1e-9),
          reason: '转速归零时低频那一下还在 —— 它归「律动幅度」管');
      expect(bgAngle(1, 1, 1, spin: 2), closeTo(0.6, 1e-9),
          reason: '转速只加倍匀速那一项，低频仍是 0.2');
    });
  });

  group('歌词行的目标色', () {
    test('当前句：已唱纯白、未唱压暗', () {
      final a = lyricLineAlphas(active: true, opacity: 1.0);
      expect(a.sung, 1.0);
      expect(a.unsung, kActiveUnsungAlpha);
      expect(a.unsung, lessThan(lyricLineOpacity(1, 0)),
          reason: '当前句未唱的部分要比相邻行更暗，逐字点亮才看得出来');
    });

    test('其余行：整行一个色', () {
      for (final o in [0.6, 0.5, 0.37, 0.16]) {
        final a = lyricLineAlphas(active: false, opacity: o);
        expect(a.sung, o);
        expect(a.unsung, o);
      }
    });
  });

  group('逐字进度', () {
    const words = [
      LyricWord(0.0, 0.5, '春'),
      LyricWord(0.5, 0.5, '眠'),
      LyricWord(2.0, 1.0, '不'),
      LyricWord(3.0, 0.5, '觉'),
    ];

    test('还没唱到第一个字 → null', () {
      expect(karaokeWordAt(words, -1), isNull);
    });

    test('正在某个字里 → 给出这个字和它唱了多少', () {
      expect(karaokeWordAt(words, 0.25), (index: 0, t: 0.5));
      expect(karaokeWordAt(words, 2.5), (index: 2, t: 0.5));
      expect(karaokeWordAt(words, 3.25), (index: 3, t: 0.5));
    });

    test('字与字之间的空档：停在上一个字的末尾（刷亮位置不动）', () {
      // 第 2 个字 1.0 秒唱完，第 3 个字 2.0 秒才开始
      expect(karaokeWordAt(words, 1.5), (index: 1, t: 1.0));
    });

    test('整句唱完：停在最后一个字', () {
      expect(karaokeWordAt(words, 99), (index: 3, t: 1.0));
    });

    test('时长为 0 的字不会除出 NaN', () {
      final hit = karaokeWordAt(const [LyricWord(1.0, 0, '啊')], 1.0);
      expect(hit, (index: 0, t: 1.0));
    });
  });

  group('歌词滚动（每行一个弹簧 + 错峰）', () {
    /// 某一行的实际屏幕位置（这才是用户看到的）。
    /// ⚠️ 别去读内部那层 `Transform` 的矩阵：它和行内容的实际位置对不上，
    /// 拿它写断言会得出一堆假结论。
    double rowTop(WidgetTester tester, int i) =>
        tester.getRect(find.text('第 $i 句')).top;

    /// 模拟真实播放：位置一档一档地来，中间让帧跑起来
    Future<void> playTo(
      WidgetTester tester,
      double fromSecs,
      double toSecs, {
      double stepSecs = 0.1,
    }) async {
      for (var t = fromSecs; t <= toSecs + 1e-9; t += stepSecs) {
        player.position = Duration(milliseconds: (t * 1000).round());
        player.positionNotifier.value =
            Duration(milliseconds: (t * 1000).round());
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> startAt(WidgetTester tester, double secs, int active) async {
      player.isPlaying = true;
      player.duration = const Duration(minutes: 4);
      player.lyricLines = [
        for (var i = 0; i < 80; i++) LyricLine(i * 3.0, '第 $i 句'),
      ];
      player.activeLyricIndex = active;
      player.position = Duration(milliseconds: (secs * 1000).round());
      player.positionNotifier.value =
          Duration(milliseconds: (secs * 1000).round());
      await pumpPage(tester, open: true);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets('换行后当前句落在视口偏上的位置，前面的句子被推上去', (tester) async {
      // 第 21 行 = 63s
      await startAt(tester, 60.0, 20);
      await playTo(tester, 60.1, 63.4);
      // 让弹簧走完
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }

      final panel = tester.getRect(find.byType(NowPlayingPage));
      final y21 = rowTop(tester, 21);
      expect(y21, greaterThan(panel.top), reason: '当前句要在视口内');
      expect(y21, lessThan(panel.top + panel.height * 0.7),
          reason: '当前句要停在偏上的位置（锚点 35%），实测 '
              '${((y21 - panel.top) / panel.height * 100).round()}%');
      // 再往上几句应该已经被推出视口（第 21 行在 35% 处，往上 9 行约 480px）
      expect(rowTop(tester, 12), lessThan(panel.top),
          reason: '前面的句子要连续地被推上去（不是各走各的）');
      // 而且间距一致 —— 说明是整片在移，不是每行各移各的
      final gapAbove = rowTop(tester, 20) - rowTop(tester, 19);
      final gapBelow = rowTop(tester, 22) - rowTop(tester, 21);
      expect((gapAbove - gapBelow).abs(), lessThan(6),
          reason: '落位后上下行距应该一致（$gapAbove vs $gapBelow）');
      // 相邻行距应该基本一致（都落位了）
      final gap = rowTop(tester, 22) - rowTop(tester, 21);
      expect(gap, greaterThan(20), reason: '落位后行与行是正常间距，不该叠在一起');
      expect(gap, lessThan(120));
    });

    testWidgets('是弹簧滚过去的：连续推进，不是瞬移', (tester) async {
      await startAt(tester, 60.0, 20);
      await playTo(tester, 60.1, 63.2);

      final a = rowTop(tester, 21);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      final b = rowTop(tester, 21);
      await tester.pump(const Duration(milliseconds: 160));
      final c = rowTop(tester, 21);

      expect(b, lessThan(a), reason: '一帧一帧地往上走，不是一步跳过去');
      expect(c, lessThan(b));
    });

    testWidgets('错峰：动画中，越往下的行越落后（依次跟上）', (tester) async {
      await startAt(tester, 60.0, 20);
      await playTo(tester, 60.1, 63.2);
      // 动画中段
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }

      expect(rowTop(tester, 24), greaterThan(rowTop(tester, 21)),
          reason: '下面的行还停在更靠下的位置');

      // 静止时相邻行等距（约一行高）。错峰时**当前句附近**的相位差最大
      // （延迟的增量就在当前句之后开始递减），所以那里被拉开得最多；
      // 再往下几行彼此相位接近，间距基本正常。
      final gapNear = rowTop(tester, 22) - rowTop(tester, 21);
      final gapFar = rowTop(tester, 28) - rowTop(tester, 27);
      expect(gapNear, greaterThan(gapFar),
          reason: '当前句与下一句之间应该被拉开（${gapNear.round()} vs ${gapFar.round()}）');
      expect(gapNear, greaterThan(60),
          reason: '拉开的幅度要看得出来（一行高约 53px）');
    });

    testWidgets('滚到新的句子后就停下（落位后不再动）', (tester) async {
      await startAt(tester, 60.0, 20);
      await playTo(tester, 60.1, 63.2);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      final settled = rowTop(tester, 24);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      expect(rowTop(tester, 24), closeTo(settled, 0.6), reason: '落位后不该再动');
      // ⚠️ 这里不能 pumpAndSettle：`isPlaying = true` 时现在播放页的背景时钟
      // 是 `repeat()` 的（页面上永远有帧），settle 会一直等下去。
    });

    /// 拖一次进度条：**拖动会先把播放暂停**（`onSeekStart` 里就是 `player.pause()`），
    /// 松手才 seek，然后在原来在播的话接着播。
    Future<void> dragSeekTo(
      WidgetTester tester,
      double secs, {
      bool resume = true,
    }) async {
      player.isPlaying = false;
      player.notifyListeners();
      // ⚠️ 要先让帧循环**真的停下来**（拖到一半就是这样：暂停 + 弹簧已落位）。
      // 表还转着的话它下一帧就把位置追上来了，测不出「表停了之后没人发现
      // 位置被跳走」这条 bug。弹簧要收敛到 `SpringSimulation` 的容差才判 done，
      // 实测要 2 秒出头，所以这里等久一点。
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      final d = Duration(milliseconds: (secs * 1000).round());
      player.position = d;
      player.positionNotifier.value = d;
      await tester.pump(const Duration(milliseconds: 16));
      if (resume) {
        player.isPlaying = true;
        player.notifyListeners();
      }
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
    }

    testWidgets('暂停时往回拖进度条：歌词要跟过去，不会卡在旧的一句上', (tester) async {
      await startAt(tester, 60.0, 20);
      await playTo(tester, 60.1, 63.4);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }

      final panel = tester.getRect(find.byType(NowPlayingPage));
      expect(rowTop(tester, 21), lessThan(panel.top + panel.height * 0.7),
          reason: '前提：这会儿当前句是第 22 句（63s）');

      // 往回拖到第 2 句（3s）—— 千奈报的就是这个方向
      await dragSeekTo(tester, 3.0);

      final y = rowTop(tester, 1);
      expect(y, greaterThan(panel.top), reason: '往回拖之后，那一句要出现在视口里');
      expect(y, lessThan(panel.top + panel.height * 0.7),
          reason: '而且要停在锚点（35%）附近 —— 以前它根本不动，'
              '实测停在 ${((y - panel.top) / panel.height * 100).round()}%');
      expect(rowTop(tester, 21), greaterThan(panel.bottom),
          reason: '旧的那一句应该被甩出视口（不卡在它上面）');
    });

    testWidgets('暂停时往回拖之后接着播：歌词自己聚焦过来', (tester) async {
      await startAt(tester, 60.0, 20);
      await playTo(tester, 60.1, 63.4);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      // 只 seek，不接着播（暂停态下停在原地）—— 这就是「按下播放前」的状态
      await dragSeekTo(tester, 3.0, resume: false);
      final paused = rowTop(tester, 1);

      // 按下播放
      player.isPlaying = true;
      player.notifyListeners();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }

      final panel = tester.getRect(find.byType(NowPlayingPage));
      final y = rowTop(tester, 1);
      expect(y, greaterThan(panel.top));
      expect(y, lessThan(panel.top + panel.height * 0.7),
          reason: '按播放之后要自己聚焦到当前句（暂停时停在 $paused，'
              '现在 ${y.round()}）');
    });

    /// 往歌词区发一次滚轮：[dy] > 0 = 往下滚（看后面的句子）。
    ///
    /// [at] 给落点：默认落在某一行文字的中间。**面板的空白处也要能滚**
    /// （`Listener` 是 opaque；以前是 deferToChild，指针不在文字上就收不到事件）。
    ///
    /// [settle] = true（默认）会让滚动动画走完 —— 滚轮是**带弹簧滑过去**的，
    /// 事件发完那一帧还没到位。
    Future<void> wheel(
      WidgetTester tester,
      double dy, {
      String? on,
      Offset? at,
      bool settle = true,
    }) async {
      final panel = tester.getRect(find.byType(NowPlayingPage));
      final spot = at ??
          (on != null
              ? tester.getCenter(find.text(on))
              : Offset(panel.right - 220, panel.center.dy));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(spot));
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      if (!settle) return;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
    }

    testWidgets('滚轮是带弹簧滑过去的，不是一帧瞬移', (tester) async {
      await startAt(tester, 60.0, 20);
      await playTo(tester, 60.1, 63.4);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      final before = rowTop(tester, 21);

      await wheel(tester, 120, on: '第 21 句', settle: false);
      final justScrolled = rowTop(tester, 21);
      expect(justScrolled, lessThan(before), reason: '滚了就要有反应');
      expect(justScrolled, greaterThan(before - 110),
          reason: '滚完那一两帧不该已经到位 —— 千奈要的「像歌单列表那样的滚动动画」'
              '（实测这一帧只走了 ${(before - justScrolled).round()}px / 120px）');

      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      expect(rowTop(tester, 21), closeTo(before - 120, 3),
          reason: '滑完要正好落在滚轮推的距离上');
    });

    testWidgets('滚动之后按播放：重新聚焦回正在唱的那一句', (tester) async {
      await startAt(tester, 60.0, 20);
      await playTo(tester, 60.1, 63.4);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      final aligned = rowTop(tester, 21);

      // 往下滚三格，走开一点
      for (var i = 0; i < 3; i++) {
        await wheel(tester, 53, on: '第 21 句');
      }
      expect(rowTop(tester, 21), lessThan(aligned - 60), reason: '前提：滚开了');

      // 暂停 → 播放（就是用户按了一下播放键）
      player.isPlaying = false;
      player.notifyListeners();
      await tester.pump(const Duration(milliseconds: 32));
      player.isPlaying = true;
      player.notifyListeners();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }

      expect(rowTop(tester, 21), closeTo(aligned, 2.0),
          reason: '按下播放要**重新聚焦**回正在唱的那一句（以前会原地继续往下走）');
    });

    testWidgets('滚轮两个方向都能滚 —— 往上也要能把内容拉回来', (tester) async {
      await startAt(tester, 60.0, 20);
      await playTo(tester, 60.1, 63.4);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      final natural = rowTop(tester, 21);

      await wheel(tester, 53, on: '第 21 句'); // 往下滚：内容上移，看后面的句子
      final down = rowTop(tester, 21);
      expect(down, lessThan(natural - 20), reason: '往下滚要真的动');

      await wheel(tester, -53, on: '第 21 句'); // 往回滚一格：刚好回到自动对齐
      expect(rowTop(tester, 21), closeTo(natural, 1.0));

      // 再往回滚：以前 `_userScroll` 被夹在 0 上下不来，这里一点反应都没有
      await wheel(tester, -53, on: '第 21 句');
      expect(rowTop(tester, 21), greaterThan(natural + 20),
          reason: '往上滚要能把内容往下拉（回看前面几句）—— '
              '这正是「歌词几乎不响应鼠标滚轮」的一半');
    });

    testWidgets('指针停在歌词的空白处也要能滚（面板整块都收滚轮）', (tester) async {
      await startAt(tester, 60.0, 20);
      await playTo(tester, 60.1, 63.4);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      final natural = rowTop(tester, 21);

      // 面板靠右的空白处（行只有文字那么宽，这里平时打不到任何子节点）
      final panel = tester.getRect(find.byType(NowPlayingPage));
      await wheel(tester, 53, at: Offset(panel.right - 60, panel.center.dy));
      expect(rowTop(tester, 21), lessThan(natural - 20),
          reason: '指针不在文字上时滚轮也要有用 —— 以前 Listener 是 deferToChild，'
              '事件根本进不来');
    });
  });

  group('歌词排版不跳', () {
    testWidgets('长句子唱到前后行高不变（不会折行又被收回去）', (tester) async {
      // 同一段很长的文本铺 5 行，其中第一行是「当前句」
      const long = 'That we dont talk anymore we dont talk anymore we do';
      player.lyricLines = [
        for (var i = 0; i < 5; i++) LyricLine(i * 3.0, long),
      ];
      player.activeLyricIndex = 0;

      await pumpPage(tester, open: true);
      await tester.pumpAndSettle();

      final activeRect = tester.getRect(find.text(long).first);
      final otherRect = tester.getRect(find.text(long).at(1));
      expect(activeRect.height, closeTo(otherRect.height, 0.5),
          reason: '当前句和别的行必须同样高 —— 字号/字重跟着当前句变会让长句'
              '「唱到就折两行、唱完又收回去」');
      expect(activeRect.width, closeTo(otherRect.width, 0.5),
          reason: '字重也会改宽度，同样会重新折行');

      // 换到下一句：第一行变回普通行，尺寸还是那样
      player.activeLyricIndex = 1;
      player.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(find.text(long).first).height,
          closeTo(activeRect.height, 0.5),
          reason: '当前句换人之后，原来那行不该变形');
    });
  });

  group('逐字歌词的换行过渡', () {
    /// 某一行此刻**实际渲染出来**的颜色不透明度。
    ///
    /// 只有平色那一档读得到（带逐字着色器的行是 `foreground` 里的 shader，
    /// 从外面看不见）；换行的那一瞬间前后两句都在平色档上，够用了。
    double alphaOf(WidgetTester tester, String text) {
      final w = tester.widget<Text>(
        find.descendant(of: find.byType(NowPlayingPage), matching: find.text(text)),
      );
      expect(w.data, isNotNull,
          reason: '「$text」现在走的是逐字着色器（富文本），读不出颜色 —— '
              '这个用例只该在平色档上取值');
      return w.style!.color!.a;
    }

    /// 起一首歌：第 1 句 0.0s 开唱，第 2 句 3.0s 开唱（第一个字 3.4s ——
    /// 于是换行的那一瞬间第 2 句还没开始逐字刷亮，整句是平色）
    void startSong() {
      player.isPlaying = true;
      player.duration = const Duration(minutes: 4);
      player.lyricLines = const [
        LyricLine(0.0, '春眠', words: [LyricWord(0, 0.5, '春'), LyricWord(0.5, 0.5, '眠')]),
        LyricLine(3.0, '处处', words: [LyricWord(3.4, 0.5, '处'), LyricWord(3.9, 0.5, '处')]),
      ];
      player.activeLyricIndex = 0;
      player.position = Duration.zero;
      player.positionNotifier.value = Duration.zero;
    }

    /// 一档一档地把播放位置推到 [toSecs]
    Future<void> playTo(WidgetTester tester, double toSecs) async {
      for (var t = 0.0; t <= toSecs + 1e-9; t += 0.1) {
        final d = Duration(milliseconds: (t * 1000).round());
        player.position = d;
        player.positionNotifier.value = d;
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('上一句是慢慢暗下去的，不是一步掉到静止色', (tester) async {
      startSong();
      await pumpPage(tester, open: true);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // 第 1 句正在唱 → 走逐字着色器（富文本，颜色读不出来）
      expect(
        tester
            .widget<Text>(find.descendant(
              of: find.byType(NowPlayingPage),
              matching: find.text('春眠'),
            ))
            .data,
        isNull,
        reason: '正在唱的这一句应该是逐字刷亮的那条路径',
      );

      // 推到刚好换行的那一拍（3.0s）
      await playTo(tester, 3.0);
      final atSwitch = alphaOf(tester, '春眠');
      expect(atSwitch, greaterThan(0.9),
          reason: '换行那一帧它还得是亮的 —— 上一句要是当场掉到 0.5，'
              '就是千奈说的「突兀地关灯」（实测 $atSwitch）');

      // 260ms 之后才落到「唱过了」那一档
      await tester.pump(const Duration(milliseconds: 300));
      final settled = alphaOf(tester, '春眠');
      expect(settled, lessThan(atSwitch), reason: '要真的暗下去，不能只是亮着不动');
      expect(settled, closeTo(lyricLineOpacity(0, 1), 0.02));
    });

    testWidgets('下一句是慢慢亮起来的，不是一上来就整个压暗', (tester) async {
      startSong();
      await pumpPage(tester, open: true);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // 还没轮到它：和相邻的未唱行同一个亮度
      expect(alphaOf(tester, '处处'), closeTo(lyricLineOpacity(1, 0), 0.02));

      await playTo(tester, 3.0);
      final atSwitch = alphaOf(tester, '处处');
      expect(atSwitch, greaterThan(kActiveUnsungAlpha + 0.1),
          reason: '轮到它的一瞬间不该直接掉到 42% —— 那是「整个歌词突然变暗」'
              '（实测 $atSwitch）');

      await tester.pump(const Duration(milliseconds: 300));
      expect(alphaOf(tester, '处处'), closeTo(kActiveUnsungAlpha, 0.02),
          reason: '过渡完了才落到当前句的未唱色');
    });
  });

  group('全屏时的窗口按钮与 Esc', () {
    /// 记下原生桥收到的调用，用来判断「点了到底有没有动作」
    late List<String> fxCalls;

    setUp(() {
      fxCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('elia/window_fx'),
              (call) async {
        fxCalls.add(call.method);
        if (call.method == 'setFullscreen') {
          final v = (call.arguments as Map)['value'] == true;
          return {'ok': true, 'fullscreen': v, 'maximized': false};
        }
        return {'ok': true, 'maximized': false};
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('elia/window_fx'), null);
    });

    testWidgets('非全屏：标题栏是「最大化」，点了会调原生的 toggleMaximize', (tester) async {
      appFullscreen.value = false;
      appMaximized.value = false;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(AppColors.dark, Brightness.dark),
        home: const Scaffold(body: AppTitlebar()),
      ));
      await tester.pump();

      expect(find.byTooltip('最大化'), findsOneWidget);
      await tester.tap(find.byTooltip('最大化'));
      await tester.pump();
      expect(fxCalls, contains('toggleMaximize'));
    });

    testWidgets('最大化之后图标变「还原」（区分最大化 / 还原）', (tester) async {
      appFullscreen.value = false;
      appMaximized.value = true;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(AppColors.dark, Brightness.dark),
        home: const Scaffold(body: AppTitlebar()),
      ));
      await tester.pump();

      expect(find.byTooltip('还原'), findsOneWidget,
          reason: '已经最大化了就该显示「还原」——只有一个图标的话用户不知道点下去会变大还是变小');
      expect(find.byTooltip('最大化'), findsNothing);
    });

    testWidgets('全屏时三个窗口按钮整个不画（不是画出来禁用）', (tester) async {
      appFullscreen.value = true;
      appMaximized.value = false;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(AppColors.dark, Brightness.dark),
        home: const Scaffold(body: AppTitlebar()),
      ));
      await tester.pump();

      for (final tip in ['最小化', '最大化', '还原', '关闭']) {
        expect(find.byTooltip(tip), findsNothing,
            reason: '全屏是沉浸态，「$tip」不该出现在画面上 —— 灰着摆在那里等于没隐藏');
      }
      expect(fxCalls, isEmpty, reason: '而且这时候也点不到它');

      // 退出全屏要回来（别一藏就不回来了）
      appFullscreen.value = false;
      await tester.pump();
      expect(find.byTooltip('最小化'), findsOneWidget);
      expect(find.byTooltip('最大化'), findsOneWidget);
      expect(find.byTooltip('关闭'), findsOneWidget);
    });

    testWidgets('全屏时左上角的收起键整个不画', (tester) async {
      appFullscreen.value = true;
      var closed = 0;
      player.currentSong = song;
      await pumpPage(tester, open: true, onClose: () => closed++);
      await tester.pump();

      expect(inPage(find.byTooltip('收起')), findsNothing,
          reason: '全屏是沉浸态，收起键该整个不画（灰着摆在那里等于没隐藏）');
      expect(inPage(find.byTooltip('全屏中（按 Esc 退出）')), findsNothing,
          reason: '旧版那个禁用态也不该留着');

      appFullscreen.value = false;
      await tester.pump();
      await tester.tap(inPage(find.byTooltip('收起')));
      await tester.pump();
      expect(closed, 1, reason: '非全屏时它才是收起页面');
    });
  });

  group('全屏按钮的状态', () {
    testWidgets('图标跟着共享状态走（窗口被系统改变时也要回滚）', (tester) async {
      await pumpPage(tester, open: true);
      await tester.pumpAndSettle();
      expect(inPage(find.byTooltip('全屏')), findsOneWidget);

      appFullscreen.value = true;
      await tester.pump();
      expect(inPage(find.byTooltip('退出全屏')), findsOneWidget,
          reason: '全屏了就该显示「退出全屏」');

      // 系统那边把窗口改了（WindowListener 会把共享状态复位）→ 图标回滚
      appFullscreen.value = false;
      await tester.pump();
      expect(inPage(find.byTooltip('全屏')), findsOneWidget);
    });
  });

  group('传输控件', () {
    /// 五个控件在横轴上的中心 x（按顺序：模式 / 上一首 / 播放 / 下一首 / 全屏）
    List<double> centers(WidgetTester tester) {
      final mode = tester.getCenter(inPage(find.byTooltip('顺序播放')).first);
      final prev = tester.getCenter(inPage(find.byTooltip('上一首')));
      final next = tester.getCenter(inPage(find.byTooltip('下一首')));
      final full = tester.getCenter(inPage(find.byTooltip('全屏')));
      // 播放键没有 tooltip，用它的 key 找。
      // （以前是靠「圆形白底」那个 AnimatedContainer 找的 —— 圆底按需求去掉了，
      //   改成只有图标，所以判据换成 widget 自带的 key。）
      final play = tester.getCenter(
        inPage(find.byKey(const Key('now-playing-play'))),
      );
      return [mode.dx, prev.dx, play.dx, next.dx, full.dx];
    }

    testWidgets('顺序：模式 · 上一首 · 播放 · 下一首 · 全屏，且相邻间距一致', (tester) async {
      await pumpPage(tester, open: true);
      await tester.pumpAndSettle();

      final xs = centers(tester);
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]), reason: '第 $i 个控件应该在左边那个的右侧');
      }

      // 相邻两两之间的**间隙**（是中心距减各自半径，这里用中心距近似比较）：
      // 五个按钮要等间距，而不是中间三个抱团、两边甩开
      final gaps = [
        for (var i = 1; i < xs.length; i++) xs[i] - xs[i - 1],
      ];
      final minGap = gaps.reduce((a, b) => a < b ? a : b);
      final maxGap = gaps.reduce((a, b) => a > b ? a : b);
      expect(maxGap - minGap, lessThan(8),
          reason: '相邻间距应该基本一致（实测 ${gaps.map((g) => g.round()).toList()}）');
    });

    testWidgets('点模式按钮：循环切换，并在右上角提示', (tester) async {
      toast.clear();
      player.setMode(PlayMode.sequential);
      await pumpPage(tester, open: true);
      await tester.pumpAndSettle();

      await tester.tap(inPage(find.byTooltip('顺序播放')));
      await tester.pump();

      expect(player.playMode, PlayMode.reverse, reason: '按 PlayMode.values 往下切');
      expect(toast.items.any((t) => t.message == PlayMode.reverse.label), isTrue,
          reason: '切了要给个提示，否则用户不知道切到哪了');

      // 收尾：LocalStore 的 120ms 防抖 + toast 的自动消失都是「未完成的定时器」，
      // 不处理的话测试框架会判失败
      toast.clear();
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('模式切到最后一个会绕回第一个', (tester) async {
      player.setMode(PlayMode.values.last);
      await pumpPage(tester, open: true);
      await tester.pumpAndSettle();

      await tester.tap(inPage(find.byTooltip(PlayMode.values.last.label)));
      await tester.pump();
      expect(player.playMode, PlayMode.values.first);

      toast.clear();
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('全屏按钮在（点它要真调窗口，测试里只验存在与文案）', (tester) async {
      await pumpPage(tester, open: true);
      await tester.pumpAndSettle();
      expect(inPage(find.byTooltip('全屏')), findsOneWidget);
    });
  });

  group('外壳集成', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('elia/window_fx'),
              (call) async {
        if (call.method == 'setFullscreen') {
          final v = (call.arguments as Map)['value'] == true;
          return {'ok': true, 'fullscreen': v, 'maximized': false};
        }
        return {'ok': true, 'maximized': false};
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('elia/window_fx'), null);
    });

    /// 起一个 AppShell，并把播放页推出来
    Future<void> openShellWithPlayer(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      app.setZoom(100);
      appFullscreen.value = false;

      await tester.pumpWidget(const MaterialApp(home: AppShell()));
      await tester.pump();
      await tester.pump();
      tester.takeException(); // 播放栏在测试字体下的 1px 溢出，与本组无关

      final origin = tester.getTopLeft(find.byType(PlayerBar));
      await tester.tapAt(origin + const Offset(16 + 24, kPlayerBarHeight / 2));
      await tester.pumpAndSettle();
      tester.takeException();
    }

    testWidgets('点封面后整页盖住整窗，标题栏切到 over', (tester) async {
      player.isPlaying = false;
      await openShellWithPlayer(tester);

      // 播放页从窗口顶到窗口底 —— 标题栏那一块也要盖住
      final page = tester.getRect(find.byType(NowPlayingPage));
      expect(page.top, 0, reason: '播放页要盖住标题栏区域');
      expect(page.height, 900, reason: '播放页要盖住整窗');

      final bar = tester.widget<AppTitlebar>(find.byType(AppTitlebar));
      expect(bar.over, isTrue);
      final barRect = tester.getRect(find.byType(AppTitlebar));
      expect(barRect.top, 0);
      expect(barRect.height, kTitlebarHeight);

      // Esc 收起
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.widget<AppTitlebar>(find.byType(AppTitlebar)).over, isFalse);
    });

    testWidgets('全屏时 Esc 先退全屏，播放页还开着；再按一次才收起播放页',
        (tester) async {
      player.isPlaying = false;
      await openShellWithPlayer(tester);

      // 进全屏，再按 Esc —— 该退的是全屏，不是播放页
      appFullscreen.value = true;
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(appFullscreen.value, isFalse, reason: 'Esc 要先退全屏');
      expect(tester.widget<AppTitlebar>(find.byType(AppTitlebar)).over, isTrue,
          reason: '播放页不该被一起收掉');

      // 非全屏状态下的 Esc 才是收起播放页
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.widget<AppTitlebar>(find.byType(AppTitlebar)).over, isFalse,
          reason: '非全屏时 Esc 才收起播放页');
    });
  });

  group('播放栏的触发路径', () {
    testWidgets('点封面 → 推现在播放页；点歌名 → 还是歌词弹窗', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var opened = 0;
      final before = app.lyricDialogRequest;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PlayerBar(
            state: app,
            onOpenNowPlaying: () => opened++,
          ),
        ),
      ));
      await tester.pump();

      // 播放栏中间那列在**测试字体**下会溢出 1px（Ahem 的行高比真实字体高一点），
      // 与本次改动无关、release 下看不出来。收掉它，免得盖住下面真正的断言。
      final overflow = tester.takeException();
      expect(overflow, isA<FlutterError>());
      expect('$overflow', contains('overflowed'));

      // 封面是左起 16px、宽 48 的那一格，垂直居中（播放栏 72 高）——
      // 按布局算而不是按「找 Image」找：没有封面图时那里画的是个音符图标
      final origin = tester.getTopLeft(find.byType(PlayerBar));
      await tester.tapAt(origin + const Offset(16 + 24, kPlayerBarHeight / 2));
      await tester.pump();
      expect(opened, 1, reason: '点封面要推现在播放页');

      // 歌名那一块仍然是歌词编辑弹窗
      await tester.tap(find.text(song.name).first);
      await tester.pump();
      expect(app.lyricDialogRequest, greaterThan(before),
          reason: '点歌名还是打开歌词弹窗');
      expect(opened, 1, reason: '点歌名不该推现在播放页');
    });
  });
}
