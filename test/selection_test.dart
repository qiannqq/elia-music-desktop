import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/state/app_state.dart';

/// 选中态的三个动作。
///
/// 反选踩过一个惰性求值的坑：`songs.where(...)` 是惰性的，先 `clear()` 再
/// `addAll(那个 where)` 的话，求值时集合已经空了 —— 每首都判成「没选中」，
/// **反选变成了全选**（全选状态下点反选就毫无变化，看着像按钮失灵）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final state = app;

  setUp(() {
    state.playlists = [Playlist(id: 'p1', name: '默认歌单')];
    state.currentPlaylistId = 'p1';
    state.selectedMids.clear();
    state.songs = [
      for (final mid in ['a', 'b', 'c', 'd'])
        Song(mid: mid, name: '歌$mid', artist: '歌手$mid'),
    ];
  });

  test('反选拿到的是补集', () {
    state.selectedMids
      ..clear()
      ..addAll(['a', 'c']);

    state.invertSelect();

    expect(state.selectedMids.toList()..sort(), ['b', 'd']);
  });

  test('全选之后反选 = 全不选', () {
    state.selectAll();
    expect(state.selectedMids.length, 4);

    state.invertSelect();

    expect(state.selectedMids, isEmpty);
  });

  test('全选是「全不选」的开关，反选不受影响', () {
    expect(state.allSelected, isFalse);
    state.selectAll();
    expect(state.allSelected, isTrue);

    state.invertSelect();
    expect(state.allSelected, isFalse);
    expect(state.selectedMids, isEmpty);
  });
}
