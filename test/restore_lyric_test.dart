import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/core/lyric.dart';
import 'package:elia_music/core/local_store.dart';
import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/lyric_cache.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/state/toast.dart';

/// 「恢复默认歌词」（右键菜单里那一条）。
///
/// 它是「丢掉本地改过的歌词 → 从音源重取」，链路有三个容易做漏的点：
///   1. `custom_lyric_<mid>` 必须删掉 —— 取词时**自定义歌词优先**，
///      不删的话重取多少次拿到的还是本地那份；
///   2. 内存 + 磁盘的歌词缓存要一起作废；
///   3. 取不到的时候要**如实报错**，不能悄悄留着旧歌词让人以为成功了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = app;

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_restore_lyric');
    AppPaths.appDir = tmp.path;
    AppPaths.dataDir = tmp.path;
    AppPaths.logsDir = tmp.path;
    AppPaths.tempDir = tmp.path;
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    // player 是全局单例，构造时会建 AudioPlayer；测试里没有原生插件，
    // 不把通道挡掉就会异步抛 MissingPluginException。
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
    toast.clear();
    LyricCache.invalidate('m1');
    LocalStore.remove('custom_lyric_m1');
    LocalStore.remove('custom_lyric_trans_m1');
    state.playlists = [Playlist(id: 'p1', name: '默认歌单')];
    state.currentPlaylistId = 'p1';
    state.songs = [];
    state.currentLyricMid = null;
    player.currentSong = null;
  });

  test('清掉本地改过的歌词与缓存，再从音源重取', () async {
    const song = Song(mid: 'm1', name: '歌', artist: '手');
    state.addToList(song);

    // 用户改过歌词：本地存了一份（这就是取词链路里最优先的那份）
    LocalStore.set('custom_lyric_m1', '[00:01.00]我改过的');
    LocalStore.set('custom_lyric_trans_m1', '改过的翻译');
    final before = await LyricCache.load('m1', source: 'qq');
    expect(before!.raw, contains('我改过的'),
        reason: '自定义歌词优先，这一步不该碰网络');

    // 测试环境里没有本地 API 服务，所以「重取」必然失败 —— 正合我意：
    // 要验证的正是「旧的那份确实被丢掉了」
    final ok = await state.restoreDefaultLyric('m1');

    expect(LocalStore.get('custom_lyric_m1'), isNull,
        reason: '自定义歌词要删掉，否则重取回来的还是本地那份');
    expect(LocalStore.get('custom_lyric_trans_m1'), isNull);
    expect(LyricCache.peek('m1'), isNull, reason: '内存缓存要作废');
    expect(ok, isFalse, reason: '取不到就得如实失败');
    expect(
      toast.items.any((t) => t.type == ToastType.error),
      isTrue,
      reason: '取不到要给用户一条错误提示，不能默默当成功',
    );
    expect(
      toast.items.any((t) => t.type == ToastType.success),
      isFalse,
      reason: '没真取到就不该报成功',
    );
  });

  test('本来就没有本地歌词：也要去音源取一次，取不到就报错', () async {
    state.addToList(const Song(mid: 'm1', name: '歌', artist: '手'));
    expect(LocalStore.get('custom_lyric_m1'), isNull);

    final ok = await state.restoreDefaultLyric('m1');
    expect(ok, isFalse);
    expect(toast.items.any((t) => t.type == ToastType.error), isTrue);
  });

  test('找不到这首歌：直接报错，不去动缓存', () async {
    LocalStore.set('custom_lyric_m1', '[00:01.00]我改过的');

    final ok = await state.restoreDefaultLyric('m1'); // 不在任何歌单里
    expect(ok, isFalse);
    expect(LocalStore.get('custom_lyric_m1'), isNotNull,
        reason: '连歌都找不到，不该白删用户改过的歌词');
  });

  test('正在播的这首歌：会连带让播放器重读歌词', () async {
    const song = Song(mid: 'm1', name: '歌', artist: '手');
    state.addToList(song);
    player.currentSong = song;
    player.lyricLines = [const LyricLine(0, '旧的歌词')];

    await state.restoreDefaultLyric('m1');
    // 取不到歌词 → 播放器那份被清空（而不是留着旧歌词）
    expect(player.lyricLines, isEmpty);
  });
}
