import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/playlist_sync.dart';

/// 歌单同步的纯逻辑测试。
///
/// 这里定的三条是引擎的底线，改动时别把它们弄丢：
///  * **远端为空 = 什么都不做**（拉取失败与空歌单在接口上分不出来）；
///  * 新加进来的歌**置顶**且保持音源的内部顺序；
///  * 黑/白名单**按歌单隔离**（所以这里每次都是自己造一份输入）。
void main() {
  Song qq(String mid, [String? name]) =>
      Song(mid: mid, name: name ?? 'QQ$mid', artist: 'a', source: 'qq');
  Song ne(String mid) =>
      Song(mid: mid, name: 'NE$mid', artist: 'a', source: 'netease');

  SyncInput input({
    required List<Song> local,
    required List<Song> remote,
    PlaylistSyncMode mode = PlaylistSyncMode.compat,
    Set<String> blacklist = const {},
    Set<String> whitelist = const {},
    Set<String> touched = const {},
    String source = 'qq',
  }) =>
      SyncInput(
        local: local,
        remote: remote,
        mode: mode,
        source: source,
        blacklist: blacklist,
        whitelist: whitelist,
        userTouched: touched,
      );

  List<String> mids(List<Song> s) => s.map((x) => x.mid).toList();

  group('共同的底线', () {
    test('远端为空时什么都不做（不能把本地清空）', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('1'), qq('2')],
        remote: const [],
        mode: PlaylistSyncMode.frozen,
      ));
      expect(r.skipReason, 'empty');
      expect(r.changed, isFalse);
      expect(mids(r.songs), ['1', '2']);
    });

    test('键带音源：两个源的同名 mid 不会互相顶掉', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('100')],
        remote: [qq('100'), ne('100')],
        mode: PlaylistSyncMode.frozen,
        source: 'qq',
      ));
      // 本地那首 qq:100 保留，netease:100 作为新歌加进来 —— 两首都在
      expect(r.songs.length, 2);
      expect(r.songs.map(syncKey).toSet(), {'qq:100', 'netease:100'});
    });

    test('新加的歌置顶，且保持音源内部顺序', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('9')],
        remote: [qq('1'), qq('2'), qq('9')],
        mode: PlaylistSyncMode.add,
      ));
      // 1、2 是新歌 → 置顶，且按音源的顺序（1 在 2 前面）；9 已在本地，不动
      expect(mids(r.songs), ['1', '2', '9']);
    });
  });

  group('完全单向（frozen）', () {
    test('跟随音源的增删与顺序', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('9'), qq('1')],
        remote: [qq('1'), qq('2')],
        mode: PlaylistSyncMode.frozen,
      ));
      expect(mids(r.songs), ['1', '2'], reason: '本地多出来的 9 被删，2 补进来');
      expect(r.added, 1);
      expect(r.removed, 1);
      expect(r.changed, isTrue);
    });

    test('一模一样时不写盘（changed=false）', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('1'), qq('2')],
        remote: [qq('1'), qq('2')],
        mode: PlaylistSyncMode.frozen,
      ));
      expect(r.changed, isFalse);
    });

    test('用户改过歌名的那首：留下本地那份，别被音源覆盖', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('1', '我改过的名字')],
        remote: [qq('1', '音源的名字')],
        mode: PlaylistSyncMode.frozen,
      ));
      expect(r.songs.single.name, '我改过的名字');
    });
  });

  group('增加单向（add）', () {
    test('只加不减：音源移出的歌留在原地', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('1'), qq('9')],
        remote: [qq('1')],
        mode: PlaylistSyncMode.add,
      ));
      expect(mids(r.songs), ['1', '9'], reason: '音源没有 9 也不该删它');
      expect(r.removed, 0);
      expect(r.changed, isFalse);
    });

    test('黑名单里的歌不会再被加回来', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('9')],
        remote: [qq('1'), qq('9')],
        mode: PlaylistSyncMode.add,
        blacklist: {'qq:1'},
      ));
      expect(mids(r.songs), ['9'], reason: '1 在黑名单里，不该被加回来');
      expect(r.added, 0);
    });

    test('本地顺序不动：新歌插在最前面，其余保持原样', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('5'), qq('3')],
        remote: [qq('1'), qq('2'), qq('3'), qq('5')],
        mode: PlaylistSyncMode.add,
      ));
      expect(mids(r.songs), ['1', '2', '5', '3']);
    });
  });

  group('兼容单向（compat）', () {
    test('音源删的：本地跟着删，并补记进黑名单', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('1'), qq('2')],
        remote: [qq('1')],
        mode: PlaylistSyncMode.compat,
      ));
      expect(mids(r.songs), ['1']);
      expect(r.blacklist, contains('qq:2'), reason: '下次拉取不该又把它加回来');
      expect(r.removed, 1);
    });

    test('用户自己加的（白名单）不会被删', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('1'), qq('7')],
        remote: [qq('1')],
        mode: PlaylistSyncMode.compat,
        whitelist: {'qq:7'},
      ));
      expect(mids(r.songs), ['1', '7']);
      expect(r.removed, 0);
    });

    test('用户动过的（userTouched）也不会被当成音源删的', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('1'), qq('7')],
        remote: [qq('1')],
        mode: PlaylistSyncMode.compat,
        touched: {'qq:7'},
      ));
      expect(mids(r.songs), ['1', '7']);
      expect(r.blacklist, isNot(contains('qq:7')));
    });

    test('黑名单里的歌：即使音源还有，也不加回来', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('9')],
        remote: [qq('1'), qq('9')],
        mode: PlaylistSyncMode.compat,
        blacklist: {'qq:1'},
      ));
      expect(mids(r.songs), ['9']);
    });

    test('音源顺序变化会反映出来（新歌在前、其余跟随音源）', () {
      final r = mergeSyncedPlaylist(input(
        local: [qq('1'), qq('2')],
        remote: [qq('2'), qq('1')],
        mode: PlaylistSyncMode.compat,
      ));
      expect(mids(r.songs), ['2', '1']);
    });
  });

  group('歌单模型落盘', () {
    test('同步字段能存能读', () {
      final p = Playlist(id: 'p1', name: '我的', songs: [qq('1')])
        ..syncEnabled = true
        ..syncSource = 'qq'
        ..syncPlaylistId = '123'
        ..syncLink = 'https://y.qq.com/n/ryqq/playlist/123'
        ..syncMode = PlaylistSyncMode.add
        ..syncBlacklist = {'qq:1'}
        ..syncWhitelist = {'qq:2'}
        ..syncUserTouched = {'qq:2'}
        ..syncLastAt = 1700000000000
        ..syncLastResult = 'ok';

      final back = Playlist.fromStoreJson(p.toStoreJson())!;
      expect(back.syncEnabled, isTrue);
      expect(back.syncSource, 'qq');
      expect(back.syncPlaylistId, '123');
      expect(back.syncMode, PlaylistSyncMode.add);
      expect(back.syncBlacklist, {'qq:1'});
      expect(back.syncWhitelist, {'qq:2'});
      expect(back.syncUserTouched, {'qq:2'});
      expect(back.syncLastAt, 1700000000000);
      expect(back.syncLastResult, 'ok');
      expect(back.songs.single.mid, '1');
    });

    test('老存档（没有同步字段）读出来用默认值，不能报错', () {
      final back = Playlist.fromStoreJson({
        'id': 'p1',
        'name': '老的',
        'songs': [
          {'mid': 'm1', 'name': '歌', 'artist': 'a', 'source': 'qq'},
        ],
      })!;
      expect(back.syncEnabled, isFalse);
      expect(back.syncMode, PlaylistSyncMode.compat);
      expect(back.syncBlacklist, isEmpty);
      expect(back.songs.single.mid, 'm1');
    });

    test('同步字段被写坏时也要能读出来（读坏了会连累整个歌单列表）', () {
      final back = Playlist.fromStoreJson({
        'id': 'p1',
        'name': 'x',
        'songs': const [],
        'syncEnabled': 'yes', // 不是 bool
        'syncMode': '不认识的机制',
        'syncBlacklist': ['ok', 42, null, ''], // 混了非字符串
        'syncLastAt': '不是数字',
      })!;
      expect(back.syncEnabled, isFalse, reason: '不是 true 就当没开');
      expect(back.syncMode, PlaylistSyncMode.compat, reason: '认不出就退回默认');
      expect(back.syncBlacklist, {'ok', '42'}, reason: '只收能用的，别抛');
      expect(back.syncLastAt, 0);
    });
  });
}
