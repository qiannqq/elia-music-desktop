import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/core/local_store.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/state/app_state.dart';

/// 旧数据迁移：多歌单之前只有一份歌单（`qqmusic_songs`），
/// 升级后必须原样出现在「默认歌单」里 —— 迁移写错就是用户丢歌单。
///
/// 单独一个文件：`AppState.init()` 有 `_inited` 守卫，一个进程只能跑一次。
void main() {
  // 用 test()：init() 会落盘，LocalStore 的防抖定时器不该让用例失败
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_migrate_test');
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

  test('老的单份歌单会搬进「默认歌单」', () async {
    // 造一份老结构的数据
    LocalStore.set(
      'qqmusic_songs',
      jsonEncode([
        const Song(mid: 'old1', name: '老歌一', artist: '某人').toStoreJson(),
        const Song(mid: 'old2', name: '老歌二', artist: '某人').toStoreJson(),
      ]),
    );

    await app.init();

    expect(app.playlists.length, 1, reason: '升级后应该正好有一个歌单');
    expect(app.playlists.first.name, AppState.kDefaultPlaylistName);
    expect(app.currentPlaylist.name, AppState.kDefaultPlaylistName);
    expect(app.songs.map((s) => s.mid).toList(), ['old1', 'old2'],
        reason: '老数据要一首不落地搬过来');
    expect(app.currentPlaylistId, app.playlists.first.id,
        reason: '当前歌单要指向它，否则页面是空的');
  });
}
