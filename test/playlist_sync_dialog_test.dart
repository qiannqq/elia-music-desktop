import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/core/app_theme.dart';
import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/dialogs/playlist_sync_dialog.dart';
import 'package:elia_music/ui/widgets/common.dart';

/// 同步设置弹窗。
///
/// 样式由千奈真机验收，这里只钉住**功能面**：粘链接能解出 id 与音源、
/// 「立即同步」真的会拉一次并把结果写在状态行上。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = app;

  Song qq(String mid) => Song(mid: mid, name: '歌$mid', artist: 'a', source: 'qq');

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_sync_dialog_test');
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
    state.resetSyncState();
    state.playlists = [
      Playlist(id: 'p1', name: '一号', songs: [qq('9')]),
    ];
    state.currentPlaylistId = 'p1';
    state.syncFetcher = (source, id) async => (list: [qq('1')], total: 1);
  });

  /// 弹窗挂在 Navigator 的 overlay 上，得从一棵真的 widget 树里推
  Future<void> openDialog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppColors.dark, Brightness.dark),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: AppButton(
              label: '打开',
              onPressed: () => showPlaylistSyncDialog(ctx, state, 'p1'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  /// 收尾：`LocalStore` 落盘是 120ms 防抖，不收干净用例结束时会报
  /// "A Timer is still pending"。每个用例末尾都要过一次。
  Future<void> drain(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 200));

  testWidgets('粘一条链接：解出音源与 id，并回显「已识别」', (tester) async {
    await openDialog(tester);
    expect(find.textContaining('同步设置'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'https://y.qq.com/n/ryqq/playlist/8743216163',
    );
    await tester.pump();

    final p = state.playlists.first;
    expect(p.syncPlaylistId, '8743216163');
    expect(p.syncSource, 'qq');
    expect(p.syncLink, 'https://y.qq.com/n/ryqq/playlist/8743216163');
    expect(find.textContaining('已识别'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('网易云的链接会把音源切过去；认不出的链接只留原文', (tester) async {
    await openDialog(tester);

    await tester.enterText(
      find.byType(TextField),
      'https://music.163.com/#/playlist?id=24381616',
    );
    await tester.pump();
    expect(state.playlists.first.syncSource, 'netease');
    expect(state.playlists.first.syncPlaylistId, '24381616');

    await tester.enterText(find.byType(TextField), '随手打的一段话');
    await tester.pump();
    expect(state.playlists.first.syncSource, 'netease', reason: '认不出来就别动配置');
    expect(state.playlists.first.syncPlaylistId, '24381616');
    expect(state.playlists.first.syncLink, '随手打的一段话', reason: '原文要留着，用户还在编辑');
    expect(find.textContaining('没认出'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('B站链接：明说暂不支持', (tester) async {
    await openDialog(tester);
    await tester.enterText(
      find.byType(TextField),
      'https://www.bilibili.com/video/BV1xx411c7mD',
    );
    await tester.pump();
    expect(find.textContaining('暂不支持 B站'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('三种机制点一下就写进去', (tester) async {
    await openDialog(tester);
    await tester.tap(find.text('完全单向同步'));
    await tester.pump();
    expect(state.playlists.first.syncMode, PlaylistSyncMode.frozen);

    await tester.tap(find.text('增加单向同步'));
    await tester.pump();
    expect(state.playlists.first.syncMode, PlaylistSyncMode.add);
    await drain(tester);
  });

  testWidgets('同步开关写进去', (tester) async {
    await openDialog(tester);
    expect(state.playlists.first.syncEnabled, isFalse);

    await tester.tap(find.byType(AppToggle));
    await tester.pump();
    expect(state.playlists.first.syncEnabled, isTrue);
    await drain(tester);
  });

  testWidgets('立即同步：拉一次、把新歌写进歌单、状态行给出结果', (tester) async {
    await openDialog(tester);
    // 用「增加单向」：新歌置顶拉进来，本地已有的不动（兼容单向会跟着音源删）
    state.setPlaylistSync('p1',
        source: 'qq', playlistId: '123', link: '123', mode: PlaylistSyncMode.add);

    await tester.tap(find.text('立即同步'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(state.syncRunCount, 1);
    expect(state.syncLastTrigger, 'manual');
    expect(state.songs.map((s) => s.mid).toList(), ['1', '9'],
        reason: '新歌置顶拉进来');
    expect(find.textContaining('新增 1 首'), findsOneWidget);
    // 「立即同步」是手动路径，会报一次成功提示 —— toast 自带 3 秒自动关，
    // 一起走完，免得收尾时还剩一个定时器
    await tester.pump(const Duration(seconds: 4));
    await drain(tester);
  });

  testWidgets('歌单已经被删掉：弹窗不开，也不抛', (tester) async {
    state.playlists = [Playlist(id: 'p2', name: '二号')];
    state.currentPlaylistId = 'p2';
    await openDialog(tester);
    expect(find.textContaining('同步设置'), findsNothing);
    await drain(tester);
  });
}
