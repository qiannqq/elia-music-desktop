import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/pages/playlist_page.dart';

/// 歌名就地编辑的下划线。
///
/// 「展开有动画、收起没动画」是踩过两次的坑：收起时线宽若跟着编辑态一起归零，
/// 线会在动画**开始之前**就没了。要记住上次量到的宽度，让动画从「满」缩到 0。
///
/// 第二次的成因更隐蔽：长按拖动的包装层如果随编辑态**进出组件树**，
/// 它下面那层 `TweenAnimationBuilder` 会连 State 一起重建 ——
/// 新 State 的「上次宽度」是 0，于是收起变成「啪」地归零。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = app;

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_name_edit_test');
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

  /// 那一行的下划线宽度（那条线的 `SizedBox` 高 1.5）；没有线时返回 -1
  double underlineWidth(WidgetTester tester, String mid) {
    final boxes = tester
        .widgetList<SizedBox>(find.descendant(
          of: find.byKey(ValueKey(mid)),
          matching: find.byType(SizedBox),
        ))
        .where((b) => b.height == 1.5);
    if (boxes.isEmpty) return -1;
    return boxes.first.width ?? -1;
  }

  testWidgets('收起编辑态：下划线是缩回去的，不是直接归零', (tester) async {
    state.songs = [
      for (var i = 0; i < 3; i++)
        Song(mid: 'mid$i', name: '歌名$i', artist: '歌手$i', pic: ''),
    ];

    final controller = ScrollController();
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

    // 悬停出铅笔 → 点进编辑态
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('mid1'))));
    await tester.pumpAndSettle();
    // 铅笔：每行都有一个，得限定到这一行
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('mid1')),
      matching: find.byTooltip('重命名'),
    ));
    await tester.pumpAndSettle();

    final full = underlineWidth(tester, 'mid1');
    expect(full, greaterThan(0), reason: '编辑态下划线要展开到名字那么长');

    // 回车提交 → 收起
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final midway = underlineWidth(tester, 'mid1');
    expect(midway, greaterThan(0), reason: '收起时线要在动画开始之前还看得见');
    expect(midway, lessThan(full), reason: '这一帧应该正在往回缩');

    await tester.pumpAndSettle();
    expect(underlineWidth(tester, 'mid1'), lessThan(0.01), reason: '收完就没线了');

    controller.dispose();
  });
}
