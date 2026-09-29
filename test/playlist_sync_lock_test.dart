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
import 'package:elia_music/ui/icons.dart';
import 'package:elia_music/ui/pages/playlist_page.dart';
import 'package:elia_music/ui/widgets/common.dart';
import 'package:elia_music/ui/widgets/song_actions.dart';

/// 「完全单向」（frozen）在**界面上**的拦截。
///
/// 状态层那道（`AppState` 的增删排接口）在 `playlist_sync_state_test.dart` 里验；
/// 这里验的是「入口点得动点不动」：灰掉的项必须真的不响应，而不是看起来灰、点了还生效。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = app;

  Song qq(String mid) => Song(mid: mid, name: '歌$mid', artist: 'a', source: 'qq');

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_sync_lock_test');
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

  /// [mode] 为 null 表示这是个没开同步的歌单
  void arm(PlaylistSyncMode? mode) {
    state.playlists = [
      Playlist(id: 'p1', name: 'p1', songs: [qq('1'), qq('2')])
        ..syncEnabled = mode != null
        ..syncSource = 'qq'
        ..syncPlaylistId = '123'
        ..syncMode = mode ?? PlaylistSyncMode.compat,
      Playlist(id: 'p2', name: 'p2', songs: [qq('9')]),
    ];
    state.currentPlaylistId = 'p1';
    state.selectedMids.clear();
    player.currentSong = null;
  }

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

  group('歌曲右键菜单', () {
    testWidgets('frozen：移除 / 置顶 / 置底 都是灰的，改名与歌词照旧', (tester) async {
      arm(PlaylistSyncMode.frozen);
      final items = buildSongMenuItems(
        context: await takeContext(tester),
        state: state,
        song: qq('1'),
        onOpenLyric: (_) {},
        onEditName: () {},
        inPlaylist: true,
      );
      for (final label in ['从歌单中移除', '置顶', '置底']) {
        expect(
          items.firstWhere((e) => e.label == label).enabled,
          isFalse,
          reason: '「完全单向」的 $label 必须点不动',
        );
      }
      // 允许的那几项还在
      for (final label in ['歌词', '编辑歌曲名', '下载', '播放']) {
        expect(items.firstWhere((e) => e.label == label).enabled, isTrue);
      }
    });

    testWidgets('兼容单向：那三项是能点的', (tester) async {
      arm(PlaylistSyncMode.compat);
      final items = buildSongMenuItems(
        context: await takeContext(tester),
        state: state,
        song: qq('1'),
        onOpenLyric: (_) {},
        inPlaylist: true,
      );
      for (final label in ['从歌单中移除', '置顶', '置底']) {
        expect(items.firstWhere((e) => e.label == label).enabled, isTrue);
      }
    });

    testWidgets('「添加到歌单」：frozen 的那个歌单是灰的', (tester) async {
      arm(PlaylistSyncMode.frozen);
      state.playlists[1]
        ..syncEnabled = true
        ..syncSource = 'qq'
        ..syncPlaylistId = '456'
        ..syncMode = PlaylistSyncMode.frozen;
      final items = buildSongMenuItems(
        context: await takeContext(tester),
        state: state,
        song: qq('1'),
        onOpenLyric: (_) {},
      );
      final add = items.firstWhere((e) => e.label == '添加到歌单');
      expect(add.children!.firstWhere((e) => e.label == 'p1').enabled, isFalse);
      expect(add.children!.firstWhere((e) => e.label == 'p2').enabled, isFalse);
    });

    testWidgets('没开同步的歌单：照样能往里加', (tester) async {
      arm(null);
      final items = buildSongMenuItems(
        context: await takeContext(tester),
        state: state,
        song: qq('1'),
        onOpenLyric: (_) {},
      );
      final add = items.firstWhere((e) => e.label == '添加到歌单');
      expect(add.children!.firstWhere((e) => e.label == 'p2').enabled, isTrue);
    });
  });

  group('歌单页', () {
    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(AppColors.dark, Brightness.dark),
        home: Scaffold(
          body: PlaylistPage(
            state: state,
            scrollController: ScrollController(),
            onOpenLyric: (_) {},
          ),
        ),
      ));
      await tester.pump();
    }

    AppButton button(WidgetTester tester, String label) => tester
        .widgetList<AppButton>(find.byType(AppButton))
        .firstWhere((b) => b.label == label);

    testWidgets('frozen：行内删除键是灰的', (tester) async {
      arm(PlaylistSyncMode.frozen);
      await pumpPage(tester);

      final trash = tester
          .widgetList<AppIconButton>(find.byType(AppIconButton))
          .where((b) => b.icon == AppIcons.trash)
          .toList();
      expect(trash, isNotEmpty, reason: '行内那个删除键应该在树上');
      expect(trash.every((b) => b.onTap == null), isTrue,
          reason: '灰掉必须是真的点不动（onTap 传 null）');
    });

    testWidgets('兼容单向：行内删除键能点', (tester) async {
      arm(PlaylistSyncMode.compat);
      await pumpPage(tester);

      final trash = tester
          .widgetList<AppIconButton>(find.byType(AppIconButton))
          .where((b) => b.icon == AppIcons.trash)
          .toList();
      expect(trash.any((b) => b.onTap != null), isTrue);
    });

    testWidgets('frozen：批量栏的删除与倒序是灰的，反选与批量下载照旧', (tester) async {
      arm(PlaylistSyncMode.frozen);
      state.selectedMids.add('1');
      await pumpPage(tester);

      expect(button(tester, '删除').onPressed, isNull);
      expect(button(tester, '倒序').onPressed, isNull);
      expect(button(tester, '反选').onPressed, isNotNull);
      expect(button(tester, '批量下载').onPressed, isNotNull);
    });

    testWidgets('frozen：拖不动（卡片上不再挂拖动那一层）', (tester) async {
      arm(PlaylistSyncMode.frozen);
      await pumpPage(tester);

      // 拖动层是按行挂的 `Listener`（opaque），它的 onPointerDown 就是「抓手」。
      // 锁着时 dragIndex 传 null，行内只剩别的点击处理 —— 这里直接验按下不产生拖动：
      final before = state.songs.map((s) => s.mid).toList();
      final card = tester.getCenter(find.byKey(const ValueKey('1')));
      final gesture = await tester.startGesture(card);
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(state.songs.map((s) => s.mid).toList(), before,
          reason: '拖完顺序不该变（状态层也有拦截，两层都要在）');
    });
  });
}
