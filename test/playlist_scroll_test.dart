import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/pages/playlist_page.dart';

/// 歌单列表必须知道行高。
///
/// `RenderSliverList` 没法由偏移反推行号，只能从第 0 行逐行往下量。
/// 切页回来恢复滚动位置那一次 `jumpTo`，几百首就要在一帧里把前面几百行
/// 全建出来 —— 表现为「歌单里歌一多，点进去卡一下」。
/// 实测 376 首跳到最后：不给行高建 300 行（2.6s），给了只建 19 行。
void main() {
  testWidgets('歌单列表知道行高，跳转不必从第 0 行量起', (tester) async {
    app.songs = [
      for (var i = 0; i < 376; i++)
        Song(mid: 'mid$i', name: '歌名 $i', artist: '歌手 $i'),
    ];

    final controller = ScrollController();
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

    expect(
      tester.widget<ListView>(find.byType(ListView)).prototypeItem,
      isNotNull,
      reason: '没有行高，jumpTo 只能从第 0 行一路量到目标位置',
    );

    // 原型量出来的高度必须就是真实行的高度，否则滚动条长度与总长度都会偏。
    final rowH = tester.getSize(find.byKey(const ValueKey('mid0'))).height;
    final viewportH = tester.getSize(find.byType(ListView)).height;
    expect(
      controller.position.maxScrollExtent,
      closeTo(376 * rowH - viewportH, 2),
      reason: '行高与真实行不符（真实行 $rowH）',
    );

    // 跳到第 300 首附近 —— 这一步不能卡
    controller.jumpTo(rowH * 300);
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey('mid300'))).height, rowH);

    controller.dispose();
  });

  testWidgets('点「定位到正在播放」是滚过去的，不是直接跳', (tester) async {
    app.songs = [
      for (var i = 0; i < 200; i++)
        Song(mid: 'mid$i', name: '歌名 $i', artist: '歌手 $i'),
    ];
    // 正在播第 120 首
    player.currentSong = app.songs[120];

    final controller = ScrollController();
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

    // 有播放栏 → 按钮在
    final target = find.byTooltip('定位到正在播放');
    expect(target, findsOneWidget);

    final rowH = tester.getSize(find.byKey(const ValueKey('mid0'))).height;
    expect(controller.offset, 0);

    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    // 动画跑到一半：位置应该已经动了，但还没到终点 —— 说明是滚过去的
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(120 * rowH), reason: '不该一帧跳到终点');

    await tester.pumpAndSettle();
    // 目标位置按「行高 × 下标」算，所以那一行正好落到视野顶部
    expect(controller.offset, closeTo(120 * rowH, rowH));
    expect(tester.getSize(find.byKey(const ValueKey('mid120'))).height, rowH);

    player.currentSong = null;
    controller.dispose();
  });

  testWidgets('没有播放栏时「定位到正在播放」不出现', (tester) async {
    app.songs = [Song(mid: 'mid0', name: '歌名', artist: '歌手')];
    player.currentSong = null;

    final controller = ScrollController();
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

    expect(find.byTooltip('定位到正在播放'), findsNothing);
    controller.dispose();
  });
}
