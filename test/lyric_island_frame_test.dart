import 'package:elia_music/core/lyric.dart';
import 'package:elia_music/services/lyric_island_service.dart';
import 'package:flutter_test/flutter_test.dart';

LyricIslandFrame frame({
  bool playing = true,
  bool loading = false,
  bool hasSong = true,
  String title = '歌名',
  String artist = '歌手',
  List<LyricLine> lines = const [],
  int index = -1,
  Map<double, String> trans = const {},
}) {
  return LyricIslandFrame.compose(
    playing: playing,
    loading: loading,
    hasSong: hasSong,
    title: title,
    artist: artist,
    lines: lines,
    index: index,
    transMap: trans,
  );
}

void main() {
  test('没在放、正在换歌、没有歌，都不显示', () {
    expect(frame(playing: false).visible, isFalse);
    expect(frame(loading: true).visible, isFalse);
    expect(frame(hasSong: false).visible, isFalse);
  });

  test('有当前句就用当前句，翻译跟着这一句', () {
    final f = frame(
      lines: const [
        LyricLine(1, '第一句'),
        LyricLine(2, '第二句'),
      ],
      index: 1,
      trans: {2: '第二句的翻译'},
    );
    expect(f.visible, isTrue);
    expect(f.text, '第二句');
    expect(f.trans, '第二句的翻译');
    expect(f.lineIndex, 1);
  });

  test('当前句是空行时往前找，翻译也跟着那一句', () {
    final f = frame(
      lines: const [
        LyricLine(1, '还有字'),
        LyricLine(2, '   '),
      ],
      index: 1,
      trans: {1: '翻译'},
    );
    expect(f.text, '还有字');
    expect(f.trans, '翻译');
    expect(f.lineIndex, 0);
  });

  test('还没唱到时退到歌名和歌手，不带翻译', () {
    final f = frame(trans: {0: '不该出现'});
    expect(f.visible, isTrue);
    expect(f.text, '歌名 · 歌手');
    expect(f.trans, isEmpty);
    expect(f.lineIndex, -1);
  });

  test('歌手和歌名一样时不重复', () {
    expect(frame(title: '同名', artist: '同名').text, '同名');
  });
}
