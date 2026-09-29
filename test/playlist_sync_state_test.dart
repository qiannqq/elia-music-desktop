import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/state/app_state.dart';

/// 歌单同步的状态层：拉取 → 合并 → 写回、冷却/去重、以及「完全单向」的拦截。
///
/// 网络那一层用 `syncFetcher` 顶掉 —— 这里要验的是**次数、写回和拦截**，
/// 真打网络既慢又不确定（QQ 那边还有频控）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = app;

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_sync_state_test');
    AppPaths.appDir = tmp.path;
    AppPaths.dataDir = tmp.path;
    AppPaths.logsDir = tmp.path;
    AppPaths.tempDir = tmp.path;
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    // player 是全局单例，构造时会建 AudioPlayer —— 测试里没有原生插件，
    // 不挡掉通道就会异步抛 MissingPluginException，算到别的用例头上。
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

  Song qq(String mid) => Song(mid: mid, name: 'QQ$mid', artist: 'a', source: 'qq');

  /// 造一个开了同步的歌单
  Playlist armed(
    String id, {
    String remoteId = '123',
    PlaylistSyncMode mode = PlaylistSyncMode.add,
    List<Song> songs = const [],
  }) =>
      Playlist(id: id, name: id, songs: [...songs])
        ..syncEnabled = true
        ..syncSource = 'qq'
        ..syncPlaylistId = remoteId
        ..syncMode = mode;

  /// 远端固定返回这几首
  void fetcher(List<Song> remote, {int? total}) {
    state.syncFetcher =
        (source, id) async => (list: remote, total: total ?? remote.length);
  }

  setUp(() {
    state.resetSyncState();
    state.syncFetcher = null;
    state.playlists = [armed('p1', songs: [qq('9')])];
    state.currentPlaylistId = 'p1';
    state.selectedMids.clear();
    state.searchResults = [];
    player.currentSong = null;
  });

  List<String> mids(List<Song> s) => s.map((x) => x.mid).toList();

  group('拉取与写回', () {
    test('远端返回空：本地一个字都不动，只记状态', () async {
      fetcher(const []);
      final run = await state.syncPlaylist('p1', trigger: 'f5');

      expect(run!.reason, 'empty');
      expect(mids(state.songs), ['9'], reason: '空远端绝不能当成「音源清空了」');
      expect(state.playlists.first.syncLastResult, 'empty');
      expect(state.playlists.first.syncLastAt, greaterThan(0));
    });

    test('新歌置顶写回，时间和结果都落在歌单上', () async {
      fetcher([qq('1'), qq('2'), qq('9')]);
      final run = await state.syncPlaylist('p1', trigger: 'f5');

      expect(run!.added, 2);
      expect(mids(state.songs), ['1', '2', '9']);
      expect(state.playlists.first.syncLastResult, 'ok');
      expect(state.playlists.first.syncLastAt, greaterThan(0));
    });

    test('拉了但没有变化：不写盘（连 changed 标志都不给）', () async {
      fetcher([qq('9')]);
      final run = await state.syncPlaylist('p1', trigger: 'f5');

      expect(run!.added, 0);
      expect(mids(state.songs), ['9']);
    });

    test('拉取失败：不动歌单，只记 fail', () async {
      state.syncFetcher = (source, id) async => throw Exception('boom');
      final run = await state.syncPlaylist('p1', trigger: 'f5');

      expect(run!.reason, 'fail');
      expect(mids(state.songs), ['9']);
      expect(state.playlists.first.syncLastResult, 'fail');
    });

    test('只信这个音源的歌：别的 source 混进来会被丢掉', () async {
      fetcher([qq('1'), const Song(mid: '2', name: 'NE2', artist: 'a', source: 'netease')]);
      await state.syncPlaylist('p1', trigger: 'f5');

      expect(mids(state.songs), ['1', '9'], reason: 'netease 那首不该进 QQ 同步的歌单');
    });

    test('音源与链接没配齐：不拉（连次数都不记）', () async {
      state.playlists = [Playlist(id: 'p1', name: 'p1', songs: [qq('9')])
        ..syncEnabled = true];
      fetcher([qq('1')]);
      await state.syncPlaylist('p1', trigger: 'switch');

      expect(state.syncRunCount, 0);
      expect(mids(state.songs), ['9']);
    });

    test('没开同步：自动触发不拉，但用户自己按的「立即同步」照拉', () async {
      final p = state.playlists.first..syncEnabled = false;
      fetcher([qq('1')]);

      await state.syncPlaylist('p1', trigger: 'switch');
      expect(state.syncRunCount, 0, reason: '关着的话自动触发点都不该动');

      await state.syncPlaylist('p1', trigger: 'f5');
      expect(state.syncRunCount, 0, reason: 'F5 也是自动触发，开关关着它同样不拉');

      await state.syncPlaylist('p1', trigger: 'manual');
      expect(state.syncRunCount, 1, reason: '弹窗里按了「立即同步」，用户说了算');
      expect(mids(p.songs), ['1', '9']);
    });
  });

  group('冷却与去重', () {
    test('四种自动触发共用同一个冷却窗口；只有手动不受它管', () async {
      fetcher([qq('1')]);

      await state.syncPlaylist('p1', trigger: 'switch');
      expect(state.syncRunCount, 1);

      // 切歌、窗口聚焦、F5 与切歌单是同一档：F5 只是「用户按的」，
      // 不等于「用户要同步」—— 冷却窗口里一样不重复拉。
      await state.syncPlaylist('p1', trigger: 'song');
      await state.syncPlaylist('p1', trigger: 'focus');
      await state.syncPlaylist('p1', trigger: 'f5');
      expect(state.syncRunCount, 1, reason: '冷却窗口里不该再打网络');

      await state.syncPlaylist('p1', trigger: 'manual');
      expect(state.syncRunCount, 2, reason: '弹窗里按的「立即同步」用户说了算');
    });

    test('冷却至少一分钟（比的是真实时钟，用例里只能清掉记录来等价「过窗」）', () async {
      expect(AppState.kSyncAutoCooldown.inSeconds, greaterThanOrEqualTo(60));

      fetcher([qq('1')]);
      await state.syncPlaylist('p1', trigger: 'switch');
      expect(state.syncRunCount, 1);

      state.resetSyncState();
      await state.syncPlaylist('p1', trigger: 'song');
      expect(state.syncRunCount, 1, reason: '窗口过了就能拉');
    });

    test('正在拉的时候再来一次：直接返回（去重）', () async {
      var running = 0;
      var maxRunning = 0;
      state.syncFetcher = (source, id) async {
        running++;
        maxRunning = running > maxRunning ? running : maxRunning;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        running--;
        return (list: [qq('1')], total: 1);
      };

      final a = state.syncPlaylist('p1', trigger: 'f5');
      final b = state.syncPlaylist('p1', trigger: 'f5');
      await Future.wait([a, b]);

      expect(maxRunning, 1, reason: '同一个歌单的拉取不能叠起来');
      expect(state.syncRunCount, 1);
    });

    test('拉取失败也按同一个冷却走：失败之后自动触发照样被挡住', () async {
      state.syncFetcher = (source, id) async => throw Exception('boom');
      await state.syncPlaylist('p1', trigger: 'switch');
      expect(state.syncRunCount, 1);

      // 失败的那一次同样会刷新记录表：QQ 有频控，连着失败还打只会更糟。
      await state.syncPlaylist('p1', trigger: 'song');
      await state.syncPlaylist('p1', trigger: 'f5');
      expect(state.syncRunCount, 1, reason: '失败不重置冷却窗口');

      await state.syncPlaylist('p1', trigger: 'manual');
      expect(state.syncRunCount, 2, reason: '手动不看冷却');
    });

    test('改了音源 / 链接之后，冷却记录不再作数', () async {
      fetcher([qq('1')]);
      await state.syncPlaylist('p1', trigger: 'switch');
      expect(state.syncRunCount, 1);

      state.setPlaylistSync('p1', playlistId: '456');
      await state.syncPlaylist('p1', trigger: 'switch');
      expect(state.syncRunCount, 2, reason: '换的是另一个远端，不该被上一个的冷却拦住');
    });
  });

  group('触发点的口径', () {
    test('切歌单触发一次；点同一个歌单不会重复触发', () async {
      state.playlists = [armed('p1', songs: [qq('9')]), armed('p2', remoteId: '222')];
      state.currentPlaylistId = 'p1';
      fetcher([qq('1')]);

      state.switchPlaylist('p2');
      await pumpEventQueue();
      expect(state.syncRunCount, 1);
      expect(state.syncLastTrigger, 'switch');

      state.switchPlaylist('p2'); // 同一个 id：switchPlaylist 自己就早退了
      await pumpEventQueue();
      expect(state.syncRunCount, 1);
    });

    test('切歌：只拉「正在播的这首」所属的那个歌单', () async {
      state.playlists = [
        armed('p1', remoteId: '111', songs: [qq('a')]),
        armed('p2', remoteId: '222', songs: [qq('b')]),
      ];
      state.currentPlaylistId = 'p1';

      final asked = <String>[];
      state.syncFetcher = (source, id) async {
        asked.add(id);
        return (list: [qq('x')], total: 1);
      };

      player.currentSong = qq('b'); // 在 p2 里
      await state.syncCurrentPlaylist(trigger: 'song');

      expect(asked, ['222'], reason: '不是在放的那首所属的歌单就不该动');
      expect(mids(state.playlists[1].songs), ['x', 'b']);
      expect(mids(state.playlists[0].songs), ['a'], reason: '另一个歌单一个字都不该动');
    });

    test('正在播的那首不在任何歌单里（搜索页直接播的）：不拉', () async {
      fetcher([qq('1')]);
      player.currentSong = qq('zzz');
      await state.syncCurrentPlaylist(trigger: 'song');
      expect(state.syncRunCount, 0);
    });

    test('当前歌单里也有这首歌时：优先拉当前歌单', () async {
      state.playlists = [
        armed('p1', remoteId: '111', songs: [qq('dup')]),
        armed('p2', remoteId: '222', songs: [qq('dup')]),
      ];
      state.currentPlaylistId = 'p1';
      final asked = <String>[];
      state.syncFetcher = (source, id) async {
        asked.add(id);
        return (list: <Song>[], total: 0);
      };

      player.currentSong = qq('dup');
      await state.syncCurrentPlaylist(trigger: 'song');
      expect(asked, ['111']);
    });
  });

  group('名单记账（add / compat 机制）', () {
    test('手动加进来的记白名单，手动移出的记黑名单', () {
      final p = state.playlists.first..syncMode = PlaylistSyncMode.compat;

      state.addToList(qq('7'));
      expect(p.syncWhitelist, contains('qq:7'));
      expect(p.syncUserTouched, contains('qq:7'));

      state.removeFromList('7');
      expect(p.syncBlacklist, contains('qq:7'), reason: '不记的话下次拉取又回来了');
      expect(p.syncWhitelist, isNot(contains('qq:7')));
    });

    test('黑名单里的歌：即使音源还有也不加回来', () async {
      state.playlists = [
        armed('p1', mode: PlaylistSyncMode.compat, songs: [qq('1')])
          ..syncBlacklist = {'qq:2'},
      ];
      fetcher([qq('1'), qq('2')]);
      await state.syncPlaylist('p1', trigger: 'f5');
      expect(mids(state.songs), ['1']);
    });

    test('白名单里的歌（用户自己加的）：音源没有也不删', () async {
      state.playlists = [
        armed('p1', mode: PlaylistSyncMode.compat, songs: [qq('1'), qq('7')])
          ..syncWhitelist = {'qq:7'}
          ..syncUserTouched = {'qq:7'},
      ];
      fetcher([qq('1')]);
      await state.syncPlaylist('p1', trigger: 'f5');
      expect(mids(state.songs), ['1', '7']);
    });

    test('名单是按歌单隔离的：p2 的黑名单不影响 p1', () async {
      state.playlists = [
        armed('p1', mode: PlaylistSyncMode.compat, songs: [qq('1')]),
        armed('p2', remoteId: '222', mode: PlaylistSyncMode.compat, songs: [qq('1')])
          ..syncBlacklist = {'qq:2'},
      ];
      fetcher([qq('1'), qq('2')]);
      await state.syncPlaylist('p1', trigger: 'f5');
      expect(mids(state.playlists[0].songs), ['1', '2'], reason: 'p1 自己没有这条黑名单');
    });
  });

  group('完全单向（frozen）：状态层的增删排全部挡住', () {
    setUp(() {
      state.playlists = [
        armed('p1', mode: PlaylistSyncMode.frozen, songs: [qq('1'), qq('2')]),
        armed('p2', remoteId: '222', mode: PlaylistSyncMode.compat, songs: [qq('1')]),
      ];
      state.currentPlaylistId = 'p1';
      state.searchResults = [qq('8')];
      state.selectedMids.add('1');
    });

    test('增删排接口一律不改歌单', () {
      expect(state.songsLocked, isTrue);

      expect(state.addToList(qq('3')), isFalse);
      state.addToTop(qq('4'));
      state.addAllResults();
      state.addToPlaylist('p1', qq('5'));
      state.addAllToPlaylist('p1');
      state.moveSong(0, 1);
      state.moveToTop('2');
      state.moveToBottom('1');
      state.reversePlaylist();
      state.removeFromList('1');
      state.deleteSelected();

      expect(mids(state.songs), ['1', '2']);
    });

    test('改名 / 改封面照常允许', () {
      state.renameSong('1', '我改的');
      expect(state.songs.first.name, '我改的');
    });

    test('别的歌单没被锁：往 p2 加还是可以的', () {
      expect(state.playlistLocked('p2'), isFalse);
      state.addToPlaylist('p2', qq('5'));
      expect(mids(state.playlists[1].songs), ['5', '1']);
    });

    test('frozen 的同步照常写回（锁只拦用户，不拦同步自己）', () async {
      state.playlists[0].songs = [qq('9')];
      fetcher([qq('1'), qq('2')]);
      await state.syncPlaylist('p1', trigger: 'f5');
      expect(mids(state.songs), ['1', '2']);
    });
  });
}
