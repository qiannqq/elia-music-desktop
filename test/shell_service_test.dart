import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/shell_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('B站歌曲指向原视频，mid 就是 BV 号', () {
    const song = Song(
      mid: 'BV1xx411c7mD',
      name: '歌',
      artist: '人',
      source: 'bilibili',
    );
    expect(
      ShellService.bilibiliVideoUrl(song),
      'https://www.bilibili.com/video/BV1xx411c7mD',
    );
  });

  test('搜索链接带歌名和歌手，并做过转义', () {
    const song = Song(mid: 'x', name: '月が綺麗ね', artist: 'A & B');
    final url = ShellService.bilibiliSearchUrl(song);
    expect(url.startsWith('https://search.bilibili.com/all?keyword='), isTrue);
    // 空格和 & 必须转义：直接拼进 URL 会被当成参数分隔符截断
    expect(url.contains('A & B'), isFalse);
    expect(url.contains('A%20%26%20B'), isTrue);
  });

  test('歌手为空时只用歌名', () {
    const song = Song(mid: 'x', name: '只有歌名', artist: '  ');
    expect(
      ShellService.bilibiliSearchUrl(song),
      'https://search.bilibili.com/all?keyword=${Uri.encodeComponent('只有歌名')}',
    );
  });
}
