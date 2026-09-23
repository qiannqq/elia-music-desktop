import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/state/app_state.dart';

/// mid 为空的歌（第三方平台上用户自己上传的作品）**不显示也不添加**。
///
/// 全应用认歌都靠 mid：取流按 mid 走、去重按 mid 比、列表行的 key 也是 mid。
/// 空 mid 的条目既点不动（取不到流），又会跟别的空 mid 条目撞 key，
/// 所以不能进搜索结果、更不能进歌单。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = app;

  Song s(String mid) => Song(mid: mid, name: '歌$mid', artist: '歌手$mid');

  setUp(() {
    state.playlists = [Playlist(id: 'p1', name: '默认歌单')];
    state.currentPlaylistId = 'p1';
    state.selectedMids.clear();
    state.playQueue = [];
    state.queueIndex = -1;
  });

  test('搜索结果里的空 mid 条目直接丢掉', () {
    state.searchResults = [
      s('ok1'),
      s(''),
      s('ok2'),
      const Song(mid: '   ', name: '一片空白', artist: ''),
    ];

    expect(state.searchResults.map((x) => x.mid).toList(), ['ok1', 'ok2']);
  });

  test('加进歌单的入口都拦着空 mid', () {
    final ghost = s('');

    expect(state.addToList(ghost), isFalse);
    state.addToTop(ghost);
    state.addToPlaylist('p1', ghost);
    state.insertNext(ghost);

    expect(state.songs, isEmpty);
    expect(state.playQueue, isEmpty);
  });

  test('存档里的空 mid 条目读出来就没了', () {
    final p = Playlist.fromStoreJson({
      'id': 'old',
      'name': '旧歌单',
      'songs': [
        {'mid': 'a', 'name': 'A', 'artist': ''},
        {'mid': '', 'name': '幽灵', 'artist': ''},
        {'mid': 'b', 'name': 'B', 'artist': ''},
      ],
    });

    expect(p, isNotNull);
    expect(p!.songs.map((x) => x.mid).toList(), ['a', 'b']);
  });
}
