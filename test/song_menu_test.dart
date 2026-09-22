import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/core/app_theme.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/widgets/song_actions.dart';

void main() {
  const song = Song(mid: '001', name: '测试曲', artist: '某人');

  setUpAll(() {
    // 菜单里要看「当前播的是哪首」，于是会碰全局 player —— 它构造时会建
    // AudioPlayer，测试里没有原生插件，得把 audioplayers 的通道挡掉。
    final tmp = Directory.systemTemp.createTempSync('elia_menu_test');
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

  tearDown(() => player.currentSong = null);

  /// 菜单里的「下载」要用 context 弹保存框，所以借一棵最小 widget 树取一个。
  Future<BuildContext> takeContext(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppColors.dark, Brightness.dark),
      home: Builder(
        builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        },
      ),
    ));
    return ctx;
  }

  testWidgets('歌单里的歌：带移除 / 置顶 / 置底', (tester) async {
    final items = buildSongMenuItems(
      context: await takeContext(tester),
      state: AppState.instance,
      song: song,
      onOpenLyric: (_) {},
      onEditName: () {},
      inPlaylist: true,
    );
    final labels = items.map((e) => e.label).toList();

    expect(
      labels,
      containsAll(<String>['播放', '下载', '歌词', '编辑歌曲名', '从歌单中移除', '置顶', '置底']),
    );
    // 措辞改过：移除的是「歌单里的这一条」，不是把歌本身删掉
    expect(labels, isNot(contains('移除歌单')));
  });

  testWidgets('搜索结果：不带只有歌单里才成立的那几项', (tester) async {
    final items = buildSongMenuItems(
      context: await takeContext(tester),
      state: AppState.instance,
      song: song,
      onOpenLyric: (_) {},
      onEditName: null,
      inPlaylist: false,
    );
    final labels = items.map((e) => e.label).toList();

    expect(labels, containsAll(<String>['播放', '下载', '歌词']));
    expect(labels, isNot(contains('从歌单中移除')));
    expect(labels, isNot(contains('置顶')));
    expect(labels, isNot(contains('置底')));
    // 改名改的是歌单里那一份，搜索结果存不下来
    expect(labels, isNot(contains('编辑歌曲名')));
  });

  testWidgets('播放队列里的歌：移除的是队列里的那一条，不是歌单里的', (tester) async {
    final items = buildSongMenuItems(
      context: await takeContext(tester),
      state: AppState.instance,
      song: song,
      onOpenLyric: (_) {},
      onEditName: null,
      inQueue: true,
    );
    final labels = items.map((e) => e.label).toList();

    expect(labels, contains('从播放队列中移除'));
    // 队列里的歌不一定在歌单里，所以歌单那几项不能出现
    expect(labels, isNot(contains('从歌单中移除')));
    expect(labels, isNot(contains('置顶')));
    expect(labels, isNot(contains('置底')));
  });

  testWidgets('正在播的那首：「插入到下一首」是灰的', (tester) async {
    player.currentSong = song;
    final items = buildSongMenuItems(
      context: await takeContext(tester),
      state: AppState.instance,
      song: song,
      onOpenLyric: (_) {},
    );
    final insert = items.firstWhere((e) => e.label == '插入到下一首');
    expect(insert.enabled, isFalse, reason: '它已经在播了，插到下一首没有意义');
  });

  testWidgets('不是正在播的那首：可以插到下一首', (tester) async {
    player.currentSong = const Song(mid: '999', name: '别的歌', artist: '某人');
    final items = buildSongMenuItems(
      context: await takeContext(tester),
      state: AppState.instance,
      song: song,
      onOpenLyric: (_) {},
    );
    final insert = items.firstWhere((e) => e.label == '插入到下一首');
    expect(insert.enabled, isTrue);
  });
}
