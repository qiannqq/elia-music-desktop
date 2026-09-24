import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/core/app_theme.dart';
import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/app_shell.dart';
import 'package:elia_music/ui/pages/playlist_page.dart';

/// 歌单内拖动排序。
///
/// 桌面端 `ReorderableListView` 默认只在行尾画一个 drag handle，**按在卡片
/// 空白处长按毫无反应** —— 所以关掉默认手柄、整张卡片自己接长按。
///
/// 自己那一套（见 `_CardDragStart` / `_LongPressDrag`）跟框架的差两处：
/// 鼠标的长按抖动阈值从 1px 放到 12px，按下区域铺满整张卡片。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = app;

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_drag_test');
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

  setUp(() {
    state.playlists = [Playlist(id: 'p1', name: '默认歌单')];
    state.currentPlaylistId = 'p1';
    state.selectedMids.clear();
    state.playQueue = [];
    state.queueIndex = -1;
    player.currentSong = null;
  });

  Song s(String mid) => Song(mid: mid, name: '歌$mid', artist: '歌手$mid', pic: '');

  List<String> order() => state.songs.map((x) => x.mid).toList();

  Future<void> pumpPage(WidgetTester tester, ScrollController controller) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlaylistPage(
          state: state,
          scrollController: controller,
          onOpenLyric: (_) {},
        ),
      ),
    ));
    await tester.pump();
  }

  /// 按住卡片（返回还没松手的 gesture）。**按下就能拖**，不用等长按。
  Future<TestGesture> pressCard(WidgetTester tester, String mid) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey(mid))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    return gesture;
  }

  /// 竖着拖 [slots] 行、松手。
  ///
  /// 位移要**分步**发（真实拖动也是几十个小位移）：框架的让位算法按几何位置
  /// 增量收敛，一次大跳会把落点算偏。落点本身有半行左右的迟滞 ——
  /// 往下拖 n 行给 n×行高就够，往上要多给一点（实测 0.25 行）。
  Future<void> dragRow(WidgetTester tester, String mid, int slots, double rowH) async {
    final up = slots < 0;
    final dist = rowH * slots.abs() + (up ? rowH * 0.25 : 0);
    final gesture = await pressCard(tester, mid);
    for (var step = 0; step < 20; step++) {
      await gesture.moveBy(Offset(0, (up ? -dist : dist) / 20));
      await tester.pump(const Duration(milliseconds: 8));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    // 等 LocalStore 的 120ms 防抖落盘：不等的话用例结束时定时器还挂着
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// 拖动代理的不透明度（代理里的那张卡片）
  double proxyOpacity(WidgetTester tester, String mid) {
    final ops = tester.widgetList<Opacity>(find.ancestor(
      of: find.byKey(ValueKey(mid)),
      matching: find.byType(Opacity),
    ));
    return ops.isEmpty ? -1 : ops.first.opacity;
  }

  /// 拖动中的那张卡片在不在 —— 它挂在拖动层的 `Opacity` 下面，
  /// 真行没有这条祖先链（`AnimatedOpacity` 是 FadeTransition，不算）。
  bool dragCardVisible(WidgetTester tester, String mid) => tester.any(find.ancestor(
        of: find.byKey(ValueKey(mid)),
        matching: find.byType(Opacity),
      ));

  /// 铺了 [color] 底色的卡片数
  int cardsWithBg(WidgetTester tester, Color color) => tester
      .widgetList<DecoratedBox>(find.byType(DecoratedBox))
      .where((d) =>
          d.decoration is BoxDecoration &&
          (d.decoration as BoxDecoration).color == color)
      .length;

  testWidgets('把卡片往下拖两行能换序（并落盘）', (tester) async {
    state.songs = [for (var i = 0; i < 5; i++) s('mid$i')];

    final controller = ScrollController();
    await pumpPage(tester, controller);

    // 拖动这一版没有默认拖手柄 —— 有的话只有行尾那一小块能拖
    expect(
      tester
          .widget<ReorderableListView>(find.byType(ReorderableListView))
          .buildDefaultDragHandles,
      isFalse,
      reason: '默认手柄只在行尾一个 12px 的小图标上生效，长按卡片本身拖不动',
    );

    final rowH = tester.getSize(find.byKey(const ValueKey('mid0'))).height;
    await dragRow(tester, 'mid0', 2, rowH);

    expect(order(), ['mid1', 'mid2', 'mid0', 'mid3', 'mid4']);

    // 顺序要落盘，不然重启就复原（落盘在 dragRow 里已经等过了）
    final stored =
        jsonDecode(File(AppPaths.storageFile).readAsStringSync()) as Map;
    final playlists = jsonDecode(stored['qqmusic_playlists'] as String) as List;
    expect(
      (playlists.first as Map)['songs']
          .map((e) => (e as Map)['mid'])
          .toList(),
      ['mid1', 'mid2', 'mid0', 'mid3', 'mid4'],
    );

    controller.dispose();
  });

  testWidgets('往上拖时落点按「被拖走之后的那一格」算', (tester) async {
    state.songs = [for (var i = 0; i < 5; i++) s('mid$i')];

    final controller = ScrollController();
    await pumpPage(tester, controller);

    final rowH = tester.getSize(find.byKey(const ValueKey('mid3'))).height;
    // 第 3 首拖到第 1 首的位置上
    await dragRow(tester, 'mid3', -2, rowH);

    // 落点是「摘掉它之后」的下标 —— 算错了会少挪一格
    expect(order(), ['mid0', 'mid3', 'mid1', 'mid2', 'mid4']);

    controller.dispose();
  });

  testWidgets('轻轻点一下、挪一两像素，不算拖动', (tester) async {
    state.songs = [for (var i = 0; i < 4; i++) s('mid$i')];

    final controller = ScrollController();
    await pumpPage(tester, controller);
    final before = order();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('mid0'))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 80)); // 远不到长按
    await gesture.moveBy(const Offset(0, 3));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(order(), before);

    controller.dispose();
  });

  testWidgets('按下就能拖（Windows 那样），不用长按', (tester) async {
    state.songs = [for (var i = 0; i < 4; i++) s('mid$i')];

    final controller = ScrollController();
    await pumpPage(tester, controller);
    final h = tester.getSize(find.byKey(const ValueKey('mid0'))).height;

    // 按下 → 立刻开始挪（不给任何停留）
    final gesture = await pressCard(tester, 'mid0');
    for (var step = 0; step < 20; step++) {
      await gesture.moveBy(Offset(0, h / 20));
      await tester.pump(const Duration(milliseconds: 8));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    expect(order(), ['mid1', 'mid0', 'mid2', 'mid3']);

    controller.dispose();
  });

  testWidgets('拖动中的卡片：底色跟着走，不透明度带渐变', (tester) async {
    state.songs = [for (var i = 0; i < 4; i++) s('mid$i')];

    final controller = ScrollController();
    await pumpPage(tester, controller);

    final gesture = await pressCard(tester, 'mid0');
    await gesture.moveBy(const Offset(0, 12)); // 超过拖动阈值，卡片出场
    await tester.pump();

    // 刚拿起来：透明度还在 1（淡出动画才刚开始）
    expect(proxyOpacity(tester, 'mid0'), closeTo(1.0, 0.05));

    // 卡片大小要跟别的卡片一模一样 —— 代理层动了布局的话会**真的**把它挤小
    // （踩过：在代理里给卡片加 padding，等于从它的高度里扣掉 2px）
    expect(
      tester.getSize(find.byKey(const ValueKey('mid0'))),
      tester.getSize(find.byKey(const ValueKey('mid1'))),
      reason: '拖动中的卡片不能被挤小',
    );

    // 卡片平时的底色来自悬停态，拖动中悬停高亮没了 —— 代理得自己补上，
    // 不补就是「那圈底色消失、看起来像卡片缩小了一圈」
    expect(
      cardsWithBg(tester, AppColors.light.hover),
      greaterThanOrEqualTo(1),
      reason: '拖动中的卡片要跟原来一样有底色',
    );

    // 淡出动画走完 → 半透明
    await tester.pump(const Duration(milliseconds: 300));
    expect(proxyOpacity(tester, 'mid0'), closeTo(0.7, 0.01));

    // 松手：归位动画把不透明度放回去
    await gesture.up();
    await tester.pump(); // 让 reverse 的 ticker 起步（第一帧 elapsed = 0）
    await tester.pump(const Duration(milliseconds: 120));
    expect(proxyOpacity(tester, 'mid0'), greaterThan(0.7));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    controller.dispose();
  });

  testWidgets('界面缩放不是 100% 时，拖动中的卡片也要跟真行一样大、对得齐', (tester) async {
    state.songs = [for (var i = 0; i < 4; i++) s('mid$i')];

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = ScrollController();
    // 真机上页面内容是套在 ZoomWrapper 里的（缩放 110%），
    // 而 Overlay 在它外面 —— 坐标系不一致，代理会小一圈还会跑偏
    await tester.pumpWidget(MaterialApp(
      home: ZoomWrapper(
        scale: 1.1,
        child: Scaffold(
          body: PlaylistPage(
            state: state,
            scrollController: controller,
            onOpenLyric: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();

    final gesture = await pressCard(tester, 'mid0');
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump(const Duration(milliseconds: 300));

    final row = tester.getRect(find.byKey(const ValueKey('mid1')));
    final card = tester.getRect(find.byKey(const ValueKey('mid0')));
    expect(card.width, closeTo(row.width, 1), reason: '卡片宽度要跟真行一致');
    expect(card.height, closeTo(row.height, 1), reason: '卡片高度要跟真行一致');
    expect(card.left, closeTo(row.left, 1), reason: '卡片要跟真行左右对齐');

    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    controller.dispose();
  });

  testWidgets('松手后卡片与真行同帧交接，中间不留空洞', (tester) async {
    state.songs = [for (var i = 0; i < 4; i++) s('mid$i')];

    final controller = ScrollController();
    await pumpPage(tester, controller);
    final h = tester.getSize(find.byKey(const ValueKey('mid0'))).height;

    final gesture = await pressCard(tester, 'mid0');
    for (var step = 0; step < 20; step++) {
      await gesture.moveBy(Offset(0, h / 20));
      await tester.pump(const Duration(milliseconds: 8));
    }
    // 拖久一点再松手：让「拿起来」那段淡出先跑完。真机上拖一次通常不止 0.25 秒，
    // 而两个动画从各自"满值"往回退时，时长差才会原封不动地露出来
    // （都还没跑到满值时，回退时长会按比例缩短，差值被压进一帧里看不出来）。
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();

    // 一帧一帧看：任何一帧都得有东西在（要么是拖动中的卡片，要么是真行）。
    // 卡片撤早了（比如动画时长跟框架的落点动画不一致）就会露出一帧空缺，
    // 观感上就是「闪一下」。
    var sawRow = false;
    for (var f = 0; f < 40; f++) {
      await tester.pump(const Duration(milliseconds: 16));
      final card = dragCardVisible(tester, 'mid0');
      final row = !card && tester.any(find.byKey(const ValueKey('mid0')));
      expect(card || row, isTrue, reason: '第 $f 帧出现了空洞：卡片和真行都不在');
      if (row) sawRow = true;
    }
    expect(sawRow, isTrue, reason: '归位之后真行得回来');

    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    controller.dispose();
  });

  testWidgets('拖动中鼠标掠过别的卡片，那些卡片不高亮', (tester) async {
    state.songs = [for (var i = 0; i < 4; i++) s('mid$i')];

    final controller = ScrollController();
    await pumpPage(tester, controller);
    final h = tester.getSize(find.byKey(const ValueKey('mid0'))).height;

    // 悬停机制本身是好的（拖之前先证一下，否则下面那条断言可能是假通过）
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer();
    await hover.moveTo(tester.getCenter(find.byKey(const ValueKey('mid1'))));
    await tester.pumpAndSettle();
    expect(cardsWithBg(tester, AppColors.light.hover), 1, reason: '悬停要能高亮');
    await hover.removePointer();
    await tester.pumpAndSettle();

    final gesture = await pressCard(tester, 'mid0');
    // 从第 0 行拖到第 2 行附近：指针会依次掠过第 1、2 行
    for (var step = 0; step < 20; step++) {
      await gesture.moveBy(Offset(0, h * 1.6 / 20));
      await tester.pump(const Duration(milliseconds: 8));
    }
    await tester.pump(const Duration(milliseconds: 300));

    // 拖动中只该有被拖的那张卡片有底色 —— 鼠标正停在别的卡片上面，
    // 但那不是「选中」，它们不该亮
    expect(
      cardsWithBg(tester, AppColors.light.hover),
      1,
      reason: '拖动中只有被拖的卡片该高亮',
    );
    // 被拖的那张确实亮着（不是"一张都没亮"）
    expect(dragCardVisible(tester, 'mid0'), isTrue);

    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    controller.dispose();
  });

  testWidgets('拖正在播放的那一首：归位前后不会有「两张叠一帧」', (tester) async {
    state.songs = [for (var i = 0; i < 4; i++) s('mid$i')];
    // 正在播放的那一行有一圈主题色光晕（BoxShadow alpha 0.3）。
    // 卡片和真行只要叠上一帧，alpha 合成就从 0.3 变成 0.51 ——
    // 观感是「归位之后突然高亮一下」。
    player.currentSong = state.songs[0];

    final controller = ScrollController();
    await pumpPage(tester, controller);
    final h = tester.getSize(find.byKey(const ValueKey('mid0'))).height;

    int glowing(WidgetTester t) => t
        .widgetList<Container>(find.byType(Container))
        .where((c) =>
            c.decoration is BoxDecoration &&
            ((c.decoration! as BoxDecoration).boxShadow?.isNotEmpty ?? false))
        .length;
    expect(glowing(tester), 1, reason: '正在播放的那张卡片本身有一圈光晕');

    Future<void> dragAndWatch(String mid, double distance) async {
      final gesture = await pressCard(tester, mid);
      for (var step = 0; step < 20; step++) {
        await gesture.moveBy(Offset(0, distance / 20));
        await tester.pump(const Duration(milliseconds: 8));
      }
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      for (var f = 0; f < 40; f++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(glowing(tester), lessThanOrEqualTo(1),
            reason: '第 $f 帧有两张带光晕的卡片叠在一起');
      }
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
    }

    // ① 拖到别的位置（框架会回调 onReorderItem）
    await dragAndWatch('mid0', h);
    // ② 拖了但回到原位（框架**不**回调，只能靠「行回来了」这个信号交接）
    await dragAndWatch('mid0', h * 0.35);

    player.currentSong = null;
    controller.dispose();
  });

  testWidgets('歌单内搜索过滤中退回普通列表，也不给拖', (tester) async {
    state.songs = [for (var i = 0; i < 5; i++) s('mid$i')];

    final controller = ScrollController();
    await pumpPage(tester, controller);

    await tester.tap(find.byTooltip('在歌单里搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'mid1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // 过滤后的下标跟歌单下标不是一回事，拖了会挪错位置 —— 这一支不给拖
    expect(find.byType(ReorderableListView), findsNothing);
    expect(
      tester.widget<ListView>(find.byType(ListView)).prototypeItem,
      isNotNull,
      reason: '普通分支同样得告诉列表行高',
    );

    final before = order();
    await tester.longPress(find.byKey(const ValueKey('mid1')));
    await tester.pumpAndSettle();
    expect(order(), before);

    controller.dispose();
  });
}
