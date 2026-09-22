import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/state/app_state.dart';

/// 播放队列的回归测试。
///
/// 播放栏以前有**两个**隐藏池：`shufflePlaylist`（洗好的随机顺序）和
/// `playHistory`（随机模式下的回退历史）。它们各自维护一份游标，
/// 于是「上一首」在随机模式下走的是历史、在顺序模式下走的是歌单，
/// 两套语义还不一样。现在合并成一条 [AppState.playQueue]，播放栏只认它。
///
/// 这里盯的是三件容易写错的事：
///   1. 「插入到下一首」的**下标运算** —— 被插的歌原本在当前位置之前时，
///      当前位置要跟着左移，否则会把正在播的那首顶掉；
///   2. 走到队尾时各模式的分歧（顺序播放要停，列表循环要绕回）；
///   3. 换模式时队列立刻重建。
void main() {
  // 用 testWidgets 而不是 test：player 是全局单例，构造时会建 AudioPlayer，
  // 那需要初始化过的 binding（纯 test() 不建，整个文件都会挂在 binding 上）。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_queue_test');
    AppPaths.appDir = tmp.path;
    AppPaths.dataDir = tmp.path;
    AppPaths.logsDir = tmp.path;
    AppPaths.tempDir = tmp.path;

    // player 是全局单例，构造时会建 AudioPlayer —— 测试里没有原生插件，
    // 不把 audioplayers 的通道挡掉就会抛 MissingPluginException，而且是
    // **异步**抛的，会算到当时正在跑的那个用例头上（看起来像断言失败）。
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async => null);
    }
    messenger.setMockStreamHandler(
      const EventChannel('xyz.luan/audioplayers.global/events'),
      MockStreamHandler.inline(onListen: (args, sink) {}),
    );

    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  Song s(String mid) => Song(mid: mid, name: '歌$mid', artist: '歌手');

  // AppState 是单例（私有构造），测试里用全局那份，每次自己复位
  final state = app;

  setUp(() {
    state.songs = [for (final m in ['a', 'b', 'c', 'd']) s(m)];
    // app_shell 里就是这么接的 —— 模式一改，队列立刻重建
    player.onModeChange = state.onModeChanged;
    player.playMode = PlayMode.repeatAll;
    player.currentSong = null;
    state.playQueue = [];
    state.queueIndex = -1;
  });

  tearDown(() {
    player.onModeChange = null;
    player.playMode = PlayMode.repeatAll;
    player.currentSong = null;
  });

  List<String> mids() => state.playQueue.map((e) => e.mid).toList();

  testWidgets('队列按当前模式从歌单建出来', (tester) async {
    state.ensureQueue();
    expect(mids(), ['a', 'b', 'c', 'd']);
    expect(state.queueIndex, -1, reason: '还没开始播，没有「当前」这一首');
  });

  testWidgets('换模式时队列立刻刷新，切回顺序类模式恢复歌单顺序', (tester) async {
    // 用大一点的歌单：小列表洗出原顺序的概率太高，断言会偶发失败
    state.songs = [for (var i = 0; i < 40; i++) s('m-$i')];
    state.onModeChanged(player.playMode); // 换歌单后先按当前模式重建一次
    final library = mids();

    // setMode 会落盘，LocalStore 的防抖定时器要排掉 ——
    // testWidgets 结束时还有待处理的定时器会直接判失败
    player.setMode(PlayMode.shuffle);
    await tester.pump(const Duration(milliseconds: 200));
    expect(mids().toSet(), library.toSet(), reason: '随机只是换顺序，不能多也不能少');
    expect(mids(), isNot(library), reason: '40 首洗出原顺序的概率是 1/40!');

    player.setMode(PlayMode.sequential);
    await tester.pump(const Duration(milliseconds: 200));
    expect(mids(), library);
  });

  group('插入到下一首', () {
    setUp(() {
      state.ensureQueue();
      // 假装正在播 b（下标 1）
      player.currentSong = s('b');
      state.queueIndex = 1;
    });

    testWidgets('不在队列里：插到正在播的那首后面', (tester) async {
      state.insertNext(s('x'));
      expect(mids(), ['a', 'b', 'x', 'c', 'd']);
      expect(state.queueIndex, 1, reason: '正在播的还是 b');
      expect(state.playQueue[state.queueIndex].mid, 'b');
    });

    testWidgets('已经在后面：只是挪到紧挨着当前这首', (tester) async {
      state.insertNext(s('d'));
      expect(mids(), ['a', 'b', 'd', 'c']);
      expect(state.playQueue[state.queueIndex].mid, 'b');
    });

    testWidgets('原本在当前位置**之前**：当前游标要跟着左移，不能顶掉正在播的', (tester) async {
      state.insertNext(s('a'));
      expect(mids(), ['b', 'a', 'c', 'd']);
      expect(state.queueIndex, 0);
      expect(state.playQueue[state.queueIndex].mid, 'b', reason: '正在播的仍是 b');
    });

    testWidgets('原本就在下一首：等于没动', (tester) async {
      state.insertNext(s('c'));
      expect(mids(), ['a', 'b', 'c', 'd']);
      expect(state.playQueue[state.queueIndex].mid, 'b');
    });

    testWidgets('还没开始播：插到队首', (tester) async {
      state.queueIndex = -1;
      player.currentSong = null;
      state.insertNext(s('x'));
      expect(mids(), ['x', 'a', 'b', 'c', 'd']);
    });
  });

  group('走到队尾', () {
    setUp(() {
      state.ensureQueue();
      state.queueIndex = state.playQueue.length - 1; // 最后一首 d
    });

    testWidgets('顺序播放：停住，不绕回队首', (tester) async {
      player.playMode = PlayMode.sequential;
      expect(state.nextInQueue(), isNull);
      expect(state.queueIndex, 3, reason: '游标不该动');
    });

    testWidgets('列表循环：绕回队首', (tester) async {
      player.playMode = PlayMode.repeatAll;
      expect(state.nextInQueue()!.mid, 'a');
      expect(state.queueIndex, 0);
    });

    testWidgets('单曲循环：手动下一首也按列表绕回（自动重播由播放器自己处理）', (tester) async {
      player.playMode = PlayMode.repeatOne;
      expect(state.nextInQueue()!.mid, 'a');
    });

    testWidgets('随机：整池放完重洗一遍接着放', (tester) async {
      player.playMode = PlayMode.shuffle;
      state.onModeChanged(PlayMode.shuffle);
      final last = state.queueIndex = state.playQueue.length - 1;
      expect(last, 3);
      final next = state.nextInQueue();
      expect(next, isNotNull);
      expect(state.queueIndex, 0);
      expect(mids().toSet(), {'a', 'b', 'c', 'd'});
    });

    testWidgets('队列中间：就是下一首', (tester) async {
      player.playMode = PlayMode.repeatAll;
      state.queueIndex = 0;
      expect(state.nextInQueue()!.mid, 'b');
    });
  });

  group('上一首', () {
    setUp(() => state.ensureQueue());

    testWidgets('队首时顺序播放不动', (tester) async {
      player.playMode = PlayMode.sequential;
      state.queueIndex = 0;
      expect(state.prevInQueue(), isNull);
    });

    testWidgets('队首时列表循环绕到队尾', (tester) async {
      player.playMode = PlayMode.repeatAll;
      state.queueIndex = 0;
      expect(state.prevInQueue()!.mid, 'd');
    });

    testWidgets('中间就是前一首', (tester) async {
      player.playMode = PlayMode.repeatAll;
      state.queueIndex = 2;
      expect(state.prevInQueue()!.mid, 'b');
    });
  });

  group('倒序播放', () {
    setUp(() {
      player.playMode = PlayMode.reverse;
      state.onModeChanged(PlayMode.reverse);
    });

    testWidgets('队列本身就是反过来的（严格按队列内容播放）', (tester) async {
      expect(mids(), ['d', 'c', 'b', 'a']);
    });

    testWidgets('「下一首」顺着反过来的队列往下走', (tester) async {
      state.queueIndex = 0;
      expect(state.nextInQueue()!.mid, 'c');
      expect(state.queueIndex, 1);
    });

    testWidgets('走到队尾（也就是歌单第一首）就停', (tester) async {
      state.queueIndex = 3;
      expect(state.nextInQueue(), isNull);
      expect(state.queueIndex, 3, reason: '游标不该动');
    });

    testWidgets('「上一首」往回走，到队首不动', (tester) async {
      state.queueIndex = 2; // 队列是 [d,c,b,a]，这里正放着 b
      expect(state.prevInQueue()!.mid, 'c');
      state.queueIndex = 0;
      expect(state.prevInQueue(), isNull);
    });

    testWidgets('换回顺序播放时队列恢复歌单顺序', (tester) async {
      player.setMode(PlayMode.sequential);
      await tester.pump(const Duration(milliseconds: 200));
      expect(mids(), ['a', 'b', 'c', 'd']);
    });
  });

  testWidgets('随机模式：点上一首会把「当前之后」那一段重洗，已播的保留', (tester) async {
    // 上一首的语义是「这首不对，换一批」—— 不重洗的话紧接着点下一首
    // 又会回到刚才那首。
    state.songs = [for (var i = 0; i < 12; i++) s('n$i')];
    player.playMode = PlayMode.shuffle;
    state.onModeChanged(PlayMode.shuffle);

    state.queueIndex = 4;
    final head = mids().take(4).toList();
    final tailBefore = mids().skip(4).toList();
    final wantPrev = state.playQueue[3];

    final prev = state.prevInQueue();

    expect(prev!.mid, wantPrev.mid, reason: '上一首就是队列里的前一首');
    expect(state.queueIndex, 3);
    expect(mids().take(4).toList(), head, reason: '已经听过的那一段原样保留');
    expect(mids().skip(4).toSet(), tailBefore.toSet(),
        reason: '后半段只是换顺序，不多也不少');
    expect(mids().skip(4).toList(), isNot(tailBefore),
        reason: '12 首重洗出原顺序的概率是 1/12!');
  });

  testWidgets('顺序播放点上一首不会重洗队列', (tester) async {
    state.songs = [for (var i = 0; i < 12; i++) s('n$i')];
    player.playMode = PlayMode.sequential;
    state.onModeChanged(PlayMode.sequential);
    state.queueIndex = 4;
    final before = mids();

    state.prevInQueue();

    expect(mids(), before, reason: '只有随机模式才重洗');
  });

  group('从播放队列中移除', () {
    setUp(() {
      state.ensureQueue();
      state.queueIndex = 2; // 正在播 c
    });

    testWidgets('摘掉当前位置之前的：游标左移，正在播的还是那首', (tester) async {
      state.removeFromQueue(s('a'));
      expect(mids(), ['b', 'c', 'd']);
      expect(state.playQueue[state.queueIndex].mid, 'c');
    });

    testWidgets('摘掉正在播的那首：游标停在原位，下一首顶上来', (tester) async {
      state.removeFromQueue(s('c'));
      expect(mids(), ['a', 'b', 'd']);
      expect(state.playQueue[state.queueIndex].mid, 'd');
    });

    testWidgets('摘掉当前位置之后的：游标不动', (tester) async {
      state.removeFromQueue(s('d'));
      expect(mids(), ['a', 'b', 'c']);
      expect(state.playQueue[state.queueIndex].mid, 'c');
    });
  });

}
