import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/pages/playlist_page.dart';

/// 歌单内搜索。
///
/// 放大镜点开后在它右边划出一条线（宽度跟着输入内容走、有最小长度），
/// 回车才过滤 —— 没有搜索按钮。再点一下连输入内容一起收起。
void main() {
  setUpAll(() {
    // 页面要看「当前播的是哪首」，于是会碰全局 player —— 它构造时会建
    // AudioPlayer，测试里没有原生插件，得把 audioplayers 的通道挡掉。
    final tmp = Directory.systemTemp.createTempSync('elia_search_test');
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

  Future<void> pumpPage(WidgetTester tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlaylistPage(
          state: app,
          scrollController: controller,
          onOpenLyric: (_) {},
        ),
      ),
    ));
    await tester.pump();
  }

  double searchWidth(WidgetTester tester) =>
      tester.getSize(find.byType(TextField)).width;

  setUp(() {
    player.currentSong = null;
    app.songs = const [
      Song(mid: 'a', name: '晴天', artist: '周杰伦'),
      Song(mid: 'b', name: '雨天', artist: '孙燕姿'),
      Song(mid: 'c', name: '七里香', artist: '周杰伦'),
    ];
  });

  tearDown(() => app.songs = []);

  testWidgets('默认收着：线宽度为 0，三首都在', (tester) async {
    await pumpPage(tester);
    expect(searchWidth(tester), 0);
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('七里香'), findsOneWidget);
  });

  testWidgets('点放大镜展开，回车按歌名过滤', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byTooltip('在歌单里搜索'));
    await tester.pumpAndSettle();
    expect(searchWidth(tester), greaterThan(100), reason: '有最小长度');

    await tester.enterText(find.byType(TextField), '天');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('雨天'), findsOneWidget);
    expect(find.text('七里香'), findsNothing, reason: '不含关键词的那首该被滤掉');
  });

  testWidgets('按歌手也能搜到', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byTooltip('在歌单里搜索'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '周杰伦');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('七里香'), findsOneWidget);
    expect(find.text('雨天'), findsNothing);
  });

  testWidgets('搜不到时给出提示，而不是空白', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byTooltip('在歌单里搜索'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '不存在的歌');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('没有匹配的歌曲'), findsOneWidget);
  });

  testWidgets('再点一次收起：线和输入内容一起回去，过滤也一并撤销', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byTooltip('在歌单里搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '天');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('七里香'), findsNothing);

    await tester.tap(find.byTooltip('收起搜索'));
    await tester.pumpAndSettle();

    expect(searchWidth(tester), 0, reason: '线要收回去');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '',
        reason: '输入内容一并清掉');
    expect(find.text('七里香'), findsOneWidget, reason: '过滤要撤销');
  });
}
