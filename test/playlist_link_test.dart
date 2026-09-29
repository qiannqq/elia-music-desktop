import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/playlist_link.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/playlist_pull.dart';

/// 同步那两步「不带状态」的纯逻辑：链接解析与分页拉全。
///
/// 链接那几条形态是照着 `AppState.handleSearch` 里那串 else-if 抄的 ——
/// 顺序错了就会把单曲当歌单、或者把「只认出 id」当成「音源也认出来了」。
void main() {
  group('链接 → 音源 + 歌单 id', () {
    test('网易云歌单', () {
      expect(
        parsePlaylistLink('https://music.163.com/#/playlist?id=24381616'),
        (source: 'netease', id: '24381616'),
      );
      expect(
        parsePlaylistLink('分享 https://music.163.com/playlist?id=5027564 来自网易云'),
        (source: 'netease', id: '5027564'),
      );
    });

    test('QQ 歌单', () {
      expect(
        parsePlaylistLink('https://y.qq.com/n/ryqq/playlist/8743216163'),
        (source: 'qq', id: '8743216163'),
      );
    });

    test('纯数字 id：只认 id，音源留给调用方', () {
      expect(parsePlaylistLink('  8743216163 '), (source: '', id: '8743216163'));
    });

    test('`?id=` 兜底：认 id 不认音源', () {
      expect(
        parsePlaylistLink('https://example.com/x?foo=1&id=998877'),
        (source: '', id: '998877'),
      );
    });

    test('单曲链接不能被当成歌单', () {
      expect(
        parsePlaylistLink('https://y.qq.com/n/ryqq/songDetail/003OUlho2HcRHC'),
        isNull,
      );
      expect(parsePlaylistLink('https://music.163.com/#/song?id=123456'), isNull);
    });

    test('别的一律拒（B站 / 关键词 / 空）', () {
      expect(
        parsePlaylistLink('https://www.bilibili.com/video/BV1xx411c7mD'),
        isNull,
      );
      expect(parsePlaylistLink('周杰伦'), isNull);
      expect(parsePlaylistLink('   '), isNull);
    });
  });

  group('分页拉全', () {
    Song s(int i) => Song(mid: 'm$i', name: '歌$i', artist: 'a');

    List<Song> from(int begin, int count) =>
        [for (var i = begin; i < begin + count; i++) s(i)];

    test('超过一页时按 offset 翻到底', () async {
      final calls = <int>[];
      final r = await pullAllPlaylistSongs(
        fetchPage: (begin, count) async {
          calls.add(begin);
          final want = 1200 - begin;
          final n = want <= 0 ? 0 : (want > count ? count : want);
          return (list: from(begin, n), total: 1200);
        },
      );
      expect(calls, [0, 500, 1000], reason: '按 500 一页，取够 1200 就收手');
      expect(r.list.length, 1200);
      expect(r.truncated, isFalse);
    });

    test('音源没给总数时：取到短页就停', () async {
      final r = await pullAllPlaylistSongs(
        fetchPage: (begin, count) async =>
            (list: from(begin, begin == 0 ? 12 : 0), total: 0),
      );
      expect(r.list.length, 12);
      expect(r.total, 12, reason: '音源没报总数就拿实际条数顶上');
    });

    test('页数上限是保险丝：截断了要说出来', () async {
      final r = await pullAllPlaylistSongs(
        pageSize: 2,
        maxPages: 3,
        fetchPage: (begin, count) async => (list: from(begin, count), total: 0),
      );
      expect(r.list.length, 6);
      expect(r.truncated, isTrue);
    });

    test('接口忽略 begin 时不会死循环', () async {
      var calls = 0;
      final r = await pullAllPlaylistSongs(
        pageSize: 2,
        fetchPage: (begin, count) async {
          calls++;
          return (list: from(0, count), total: 0); // 每次都发同一页
        },
      );
      expect(calls, 2, reason: '第二页一首新的都没有，再翻也是白打');
      expect(r.list.length, 2);
    });

    test('中途失败要整体抛出（半份结果会被 frozen 当成「音源删了」）', () async {
      await expectLater(
        pullAllPlaylistSongs(
          pageSize: 2,
          fetchPage: (begin, count) async {
            if (begin > 0) throw Exception('boom');
            return (list: from(0, count), total: 0);
          },
        ),
        throwsException,
      );
    });
  });
}
