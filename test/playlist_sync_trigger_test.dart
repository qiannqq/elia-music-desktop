import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/app_shell.dart';

/// 两个挂在**外壳**上的触发点：F5 与切歌。
///
/// 它们只能挂在外壳（状态层拿不到键盘与播放器），所以要起真外壳来验；
/// 「拉了几次」数 `AppState.syncRunCount`，拉取本身换成假的 —— 不真打网络。
///
/// ⚠️ 这里**一律用 `pump` 而不是 `pumpAndSettle`**：外壳里挂着会一直重播的动画
/// （播放栏的加载转圈等），`pumpAndSettle` 会一直等下去。别的外壳测试
///（`now_playing_test.dart`）也是这个写法。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = app;

  const songA = Song(mid: 'a', name: 'A', artist: 'x');
  const songB = Song(mid: 'b', name: 'B', artist: 'x');

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_sync_trigger_test');
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
    // 外壳一起来就会问一次原生窗口状态（全屏 / 最大化）；测试里没有原生那层，
    // 不挡掉会走 MissingPluginException 那条路（内部会吞掉，但别让它白跑）。
    messenger.setMockMethodCallHandler(
      const MethodChannel('elia/window_fx'),
      (call) async => null,
    );
  });

  setUp(() {
    state.resetSyncState();
    state.playlists = [
      Playlist(id: 'p1', name: 'p1', songs: [songA, songB])
        ..syncEnabled = true
        ..syncSource = 'qq'
        ..syncPlaylistId = '123'
        ..syncMode = PlaylistSyncMode.add,
    ];
    state.currentPlaylistId = 'p1';
    state.page = 'search';
    state.selectedMids.clear();
    // 「正在播的是哪首」决定四个触发点拉哪个歌单，起手就挂上第一首
    player.currentSong = songA;
    player.isLoading = false;
    // 远端返回空：本地一个字都不动，正好只看「拉了几次」
    state.syncFetcher =
        (source, id) async => (list: <Song>[], total: 0);
  });

  /// 起一个外壳；返回前把两帧走完（跟其它外壳测试一样）
  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: AppShell()));
    await tester.pump();
    await tester.pump();
    tester.takeException(); // 测试字体下的 1px 溢出，与本组无关
  }

  /// 把「按键/换歌 → 通知 → 异步拉取」这一串走完。
  ///
  /// ⚠️ **不能用 `pumpEventQueue()`**：`testWidgets` 跑在假时钟里，它那串
  /// `Future.delayed(Duration.zero)` 没有 `pump` 就永远不会到期 —— 实测直接卡死。
  /// 末尾那次 200ms 是给外壳里那两个 120ms 的定时器（焦点回收、落盘防抖）收尾的，
  /// 不收干净用例结束时会报 "A Timer is still pending"。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // 播放栏在测试字体下会溢出 1px（跟本组无关），吞掉它
    tester.takeException();
  }

  testWidgets('F5：在歌单页触发一次；别的页不触发', (tester) async {
    await pumpShell(tester);
    expect(state.syncRunCount, 0, reason: '起手不该自己拉一次（那不是「切歌」）');

    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await settle(tester);
    expect(state.syncRunCount, 0, reason: '不在歌单页时 F5 不该同步');

    state.page = 'playlist';
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await settle(tester);
    expect(state.syncRunCount, 1);
    expect(state.syncLastTrigger, 'f5');

    // F5 也是自动触发：冷却窗口里再按不会真的再拉一次
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await settle(tester);
    expect(state.syncRunCount, 1, reason: '60 秒冷却窗口里 F5 不重复拉');

    // 窗口过去了（真实时钟等不满一分钟，清掉记录表等价）：再按就还能拉
    state.resetSyncState();
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await settle(tester);
    expect(state.syncRunCount, 1);
  });

  testWidgets('切歌：换一首才拉一次，冷却窗口里换也不拉', (tester) async {
    await pumpShell(tester);

    player.prepare(songA); // 还是起手那一首：mid 没变
    await settle(tester);
    expect(state.syncRunCount, 0, reason: '同一首（mid 没变）不算切歌');

    player.prepare(songB);
    await settle(tester);
    expect(state.syncRunCount, 1);
    expect(state.syncLastTrigger, 'song');

    player.prepare(songA);
    await settle(tester);
    expect(state.syncRunCount, 1, reason: '60 秒冷却窗口里换歌也不该再打网络');

    // 「窗口已经过去」：冷却比的是真实时钟（`DateTime.now()`），假时钟快进不了它，
    // 所以直接把记录表清掉 —— 等价于等满那 60 秒。
    state.resetSyncState();
    player.prepare(songB);
    await settle(tester);
    expect(state.syncRunCount, 1, reason: '过了冷却窗口，换歌就该再拉一次');
  });
}
