import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/state/app_state.dart';

/// 「点当前正在播的这首歌」应该是**接着播**，不是从头重来。
///
/// 场景来自实际反馈：右键菜单里对正在播的歌点「暂停」、再点「播放」，
/// 结果从头开始了 —— 因为那条路走的是完整的 `playSong`（重新取地址 → play →
/// 位置归零）。
///
/// 判据有两条，缺一不可：
///   * 是**同一首**（别的歌当然要换过去）；
///   * 音频源**已经装好**（`sourceReady`）—— 重启后的「播放态记忆」只把歌挂在
///     播放栏上、没装源，那种必须走重载，否则 resume() 放出来的是上一首的声音。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = app;

  /// 记下底层播放器收到的调用，用来判断「有没有重新加载」
  late List<String> calls;

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_resume_play');
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
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        calls.add(call.method);
        return null;
      });
    }
    messenger.setMockStreamHandler(
      const EventChannel('xyz.luan/audioplayers.global/events'),
      MockStreamHandler.inline(onListen: (args, sink) {}),
    );
  });

  const song = Song(mid: 'm1', name: '歌', artist: '手');

  setUp(() {
    calls = [];
    state.playlists = [Playlist(id: 'p1', name: '默认歌单')];
    state.currentPlaylistId = 'p1';
    state.songs = [];
    state.playQueue = [];
    state.queueIndex = -1;
    // player 是全局单例：上一个用例把「源已就绪」置过 true，
    // 不复位的话下一个用例一开始就带着它跑（实测就是这样挂的）
    player.currentSong = null;
    player.debugSetSourceReady(false);
    player.position = Duration.zero;
    player.positionNotifier.value = Duration.zero;
  });

  /// 让播放器进入「这首已经在播、源已就绪」的状态。
  ///
  /// 不走真的 `play()`：那条路会去取播放地址、拉歌词（测试里没起 API 服务），
  /// 为一个状态位把整条链路拖进来不值当。
  void markPlaying(Song s) {
    state.addToList(s);
    player.currentSong = s;
    player.debugSetSourceReady(true);
    calls.clear();
  }

  test('同一首 + 源已就绪：接着播，不重新加载', () async {
    markPlaying(song);
    player.position = const Duration(seconds: 42);
    player.positionNotifier.value = const Duration(seconds: 42);

    await state.playResolved(song);

    expect(calls, isNot(contains('play')),
        reason: '不该再走一次 play（那就是从头加载）');
    expect(player.position, const Duration(seconds: 42),
        reason: '位置要留在原地 —— 用户要的是「接着播」');
    expect(player.sourceReady, isTrue);
  });

  // 下面两条要验证的是「**必须**走重载」。测试环境里没有 API 服务，
  // 重载会止步于取播放地址（拿不到就弹错误提示），但 `player.prepare` 那一步
  // 已经跑过了 —— 用它的副作用（位置归零）来判断走的是哪条路就够了。

  test('同一首但源还没就绪（重启后的记忆态）：必须重新加载', () async {
    // 记忆态：歌挂在播放栏上，但没碰音频源
    state.addToList(song);
    player.currentSong = song;
    player.position = const Duration(seconds: 42);
    player.positionNotifier.value = const Duration(seconds: 42);
    expect(player.sourceReady, isFalse);

    await state.playResolved(song);

    expect(player.position, Duration.zero,
        reason: '这一条必须走重载（位置归零），否则 resume 放出来的是上一首');
    expect(player.sourceReady, isFalse, reason: '重载在测试里取不到地址，源仍没装上');
  });

  test('别的歌：照常切过去（不能因为「都在歌单里」就不切）', () async {
    markPlaying(song);
    player.position = const Duration(seconds: 42);
    player.positionNotifier.value = const Duration(seconds: 42);
    const other = Song(mid: 'm2', name: '另一首', artist: '手');
    state.addToList(other);

    await state.playResolved(other);

    expect(player.currentSong?.mid, 'm2', reason: '换歌就是要换过去');
    expect(player.position, Duration.zero, reason: '换歌要重新加载，不是接着上一首的位置');
  });
}
