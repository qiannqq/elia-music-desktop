import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/core/app_theme.dart';
import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/sidebar.dart';

/// 多歌单的冒烟测试。
///
/// 分三层：
///   1. 数据层 —— 建 / 切 / 改名 / 删，以及 `songs` 跟着当前歌单走；
///   2. 耦合 —— 别处依赖歌单的地方（缓存淘汰的 mid 集合、跨歌单找歌、
///      选中态）在多歌单下还成不成立；
///   3. 连击 —— 在两个歌单之间来回切、加歌、改名、删除，看会不会串味。
void main() {
  // 纯逻辑用例用 test()：不检查待处理定时器（LocalStore 有 120ms 防抖）
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = app;

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_multi_pl_test');
    AppPaths.appDir = tmp.path;
    AppPaths.dataDir = tmp.path;
    AppPaths.logsDir = tmp.path;
    AppPaths.tempDir = tmp.path;
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
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

  Song s(String mid) => Song(mid: mid, name: '歌$mid', artist: '歌手$mid');

  /// 每个用例都从「一个空歌单」开始，避免互相影响
  setUp(() {
    state.playlists = [Playlist(id: 'p1', name: '默认歌单')];
    state.currentPlaylistId = 'p1';
    state.playlistsExpanded = false; // 是单例上的状态，上一个用例可能留成展开了
    state.selectedMids.clear();
    state.playQueue = [];
    state.queueIndex = -1;
    player.currentSong = null;
  });

  group('数据层', () {
    test('新建歌单会追加到末尾并可以切过去', () async {
      final p = state.createPlaylist('我的收藏');
      expect(state.playlists.length, 2);
      expect(state.playlists.last.name, '我的收藏');

      state.switchPlaylist(p.id);
      expect(state.currentPlaylist.name, '我的收藏');
      expect(state.songs, isEmpty);
    });

    test('songs 始终是当前歌单的歌', () async {
      final b = state.createPlaylist('B');
      state.addToList(s('a1')); // 加进默认歌单
      state.switchPlaylist(b.id);
      expect(state.songs, isEmpty, reason: 'B 是空的，不该看到 A 的歌');
      state.addToList(s('b1'));
      expect(state.songs.map((x) => x.mid).toList(), ['b1']);

      state.switchPlaylist('p1');
      expect(state.songs.map((x) => x.mid).toList(), ['a1'],
          reason: '切回来还是 A 自己的那一首');
    });

    test('改名只改名字，歌不动', () async {
      state.addToList(s('a1'));
      state.renamePlaylist('p1', '  改过的名字  ');
      expect(state.currentPlaylist.name, '改过的名字', reason: '两端空白要去掉');
      expect(state.songs.length, 1);
      state.renamePlaylist('p1', '   ');
      expect(state.currentPlaylist.name, '改过的名字', reason: '空名字不接受');
    });

    test('删歌单：当前那个被删就切到第一个', () async {
      final b = state.createPlaylist('B');
      state.switchPlaylist(b.id);
      expect(state.deletePlaylist(b.id), isTrue);
      expect(state.playlists.length, 1);
      expect(state.currentPlaylist.id, 'p1', reason: '要自动切到还活着的那个');
    });

    test('最后一个歌单不给删', () async {
      expect(state.deletePlaylist('p1'), isFalse);
      expect(state.playlists.length, 1);
    });
  });

  group('耦合', () {
    test('缓存淘汰用的是**全部**歌单的 mid', () async {
      final b = state.createPlaylist('B');
      state.addToList(s('a1'));
      state.switchPlaylist(b.id);
      state.addToList(s('b1'));

      // 只看当前歌单的话，a1 会被判成「已经不在歌单里」而清掉缓存
      expect(state.allPlaylistMids, containsAll(<String>['a1', 'b1']));
    });

    test('跨歌单也能按 mid 找到歌（恢复上次播放态要用）', () async {
      final b = state.createPlaylist('B');
      state.addToList(s('a1'));
      state.switchPlaylist(b.id);
      state.addToList(s('b1'));

      expect(state.findSong('a1')?.mid, 'a1', reason: '不在当前歌单里也要找得到');
      expect(state.findSong('b1')?.mid, 'b1');
    });

    test('切歌单会清掉选中态', () async {
      final b = state.createPlaylist('B');
      state.addToList(s('a1'));
      state.toggleSelect('a1');
      expect(state.selectedMids, isNotEmpty);

      state.switchPlaylist(b.id);
      expect(state.selectedMids, isEmpty,
          reason: '选中的是「这个歌单里的哪几首」，跨歌单留着会张冠李戴');
    });

    test('isAdded 只看当前歌单', () async {
      final b = state.createPlaylist('B');
      state.addToList(s('a1'));
      expect(state.isAdded('a1'), isTrue);
      state.switchPlaylist(b.id);
      expect(state.isAdded('a1'), isFalse,
          reason: '搜索结果里的「已添加」是相对当前歌单说的');
    });
  });

  group('连击', () {
    test('来回切 + 两边都加歌 + 改名，互不串味', () async {
      final b = state.createPlaylist('B');
      state.addToList(s('a1'));
      state.switchPlaylist(b.id);
      state.addToList(s('b1'));
      state.addToList(s('b2'));
      state.renamePlaylist(b.id, '乙');
      state.switchPlaylist('p1');
      state.renamePlaylist('p1', '甲');

      expect(state.playlists.map((p) => p.name).toList(), ['甲', '乙']);
      expect(state.playlists[0].songs.map((x) => x.mid).toList(), ['a1']);
      expect(state.playlists[1].songs.map((x) => x.mid).toList(), ['b1', 'b2']);
    });

    test('删掉一个之后剩下的歌单内容不动', () async {
      final b = state.createPlaylist('B');
      final c = state.createPlaylist('C');
      state.switchPlaylist(c.id);
      state.addToList(s('c1'));

      state.deletePlaylist(b.id);
      expect(state.playlists.map((p) => p.name).toList(), ['默认歌单', 'C']);
      expect(state.songs.map((x) => x.mid).toList(), ['c1'],
          reason: '删的是 B，C 的内容不该受影响');
    });
  });

  group('顺序与添加', () {
    test('倒序把整个歌单反过来', () async {
      for (final m in ['a', 'b', 'c']) {
        state.addToList(s(m));
      }
      state.reversePlaylist();
      expect(state.songs.map((x) => x.mid).toList(), ['c', 'b', 'a']);
    });

    test('可以加到**指定**歌单，不动当前歌单', () async {
      final b = state.createPlaylist('B');
      state.addToPlaylist(b.id, s('x1'));
      expect(state.playlists[1].songs.map((x) => x.mid).toList(), ['x1']);
      expect(state.songs, isEmpty, reason: '当前歌单不该被影响');
    });

    test('某个歌单已经有这首歌就不再重复加', () async {
      final b = state.createPlaylist('B');
      state.addToPlaylist(b.id, s('x1'));
      expect(state.playlistHasSong(b.id, 'x1'), isTrue, reason: '菜单要靠它置灰');
      state.addToPlaylist(b.id, s('x1'));
      expect(state.playlists[1].songs.length, 1,
          reason: '重复加就会有两首一样的');
    });

    test('全部添加只加还没有的，已有的不动', () async {
      final b = state.createPlaylist('B');
      state.addToPlaylist(b.id, s('r2'));
      state.searchResults = [s('r1'), s('r2'), s('r3')];

      state.addAllToPlaylist(b.id);

      expect(state.playlists[1].songs.map((x) => x.mid).toList(),
          ['r1', 'r3', 'r2'],
          reason: 'r2 已经有了就不动；新加的那两首放在顶部');
      state.searchResults = [];
    });
  });

  group('侧边栏', () {
    Future<void> pumpSidebar(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(AppColors.light, Brightness.light),
        // 真实应用里是 AppShell 在监听 state 重建整棵树；
        // 这里裸 pump 侧边栏，得自己接上，否则点了不刷新。
        home: Scaffold(
          body: AnimatedBuilder(
            animation: state,
            builder: (_, _) => AppSidebar(state: state),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('点「歌单」延伸出子项，最下方是新建歌单', (tester) async {
      state.createPlaylist('我的收藏');
      await pumpSidebar(tester);

      expect(find.text('我的收藏'), findsNothing, reason: '默认是收着的');

      await tester.tap(find.text('歌单'));
      await tester.pumpAndSettle();

      expect(find.text('默认歌单'), findsOneWidget);
      expect(find.text('我的收藏'), findsOneWidget);
      expect(find.text('新建歌单'), findsOneWidget);

      // 再点一次收起
      await tester.tap(find.text('歌单'));
      await tester.pumpAndSettle();
      expect(find.text('我的收藏'), findsNothing);
    });

    testWidgets('点子项切换当前歌单；点「新建歌单」会多出一个', (tester) async {
      final b = state.createPlaylist('我的收藏');
      await pumpSidebar(tester);
      await tester.tap(find.text('歌单'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('我的收藏'));
      await tester.pumpAndSettle();
      expect(state.currentPlaylistId, b.id);

      await tester.tap(find.text('新建歌单'));
      await tester.pumpAndSettle();
      expect(state.playlists.length, 3);
      expect(state.currentPlaylist.name, '新歌单');
      expect(find.text('新歌单'), findsOneWidget);

      // 新建会弹 toast、也会触发 LocalStore 的防抖落盘，把这两个定时器跑完，
      // 否则用例结束时会报「还有定时器没处理」。
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('子列表是「长出来」的，不是一步跳出来', (tester) async {
      state.createPlaylist('我的收藏');
      await pumpSidebar(tester);

      double listH() => tester.getSize(find.byType(AnimatedSize)).height;
      expect(listH(), 0, reason: '默认收着，高度为 0');

      // 只 pump 一帧（时间不推进）：动画刚开始，高度还没长到终点
      await tester.tap(find.text('歌单'));
      await tester.pump();
      final mid = listH();
      await tester.pumpAndSettle();
      final full = listH();

      expect(full, greaterThan(0));
      expect(mid, lessThan(full), reason: '一帧就到终点的话说明根本没动画');

      // 收起同理
      await tester.tap(find.text('歌单'));
      await tester.pump();
      expect(listH(), greaterThan(0));
      await tester.pumpAndSettle();
      expect(listH(), 0);
    });

    testWidgets('切到别的页面时子列表自动收起，回歌单页自动展开', (tester) async {
      state.navigate('playlist');
      expect(state.playlistsExpanded, isTrue, reason: '进歌单页要能看到有哪些歌单');

      state.navigate('settings');
      expect(state.playlistsExpanded, isFalse, reason: '离开歌单页就该收起来');

      state.navigate('playlist');
      expect(state.playlistsExpanded, isTrue);
    });

    testWidgets('歌单很多时在子菜单内部滚，【新建歌单】始终露在最下面', (tester) async {
      for (var i = 0; i < 40; i++) {
        state.createPlaylist('歌单$i');
      }
      await pumpSidebar(tester);
      await tester.tap(find.text('歌单'));
      await tester.pumpAndSettle();

      // 40 条 × 32px ≈ 1280，远超 800 的窗口：没有长度上限的话
      // 「新建歌单」会被顶到可视区外面去
      expect(tester.getBottomLeft(find.text('新建歌单')).dy, lessThan(800),
          reason: '它在滚动区外面，歌单再多也得露着');
      // 侧边栏自己一个滚动区 + 子列表一个
      expect(find.byType(SingleChildScrollView), findsNWidgets(2));
    });
  });
}
