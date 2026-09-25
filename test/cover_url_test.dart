import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/services/api_client.dart';

/// QQ 音乐封面地址的**档位**选择。
///
/// 背景：我们存的 `pic` 是「原图母版」（`T002M000{mid}.jpg`，实测能到
/// 3000×3000、1.5~4.7MB）。列表行只有 40px，直接拿原图纯属浪费流量；而
/// 播放页那个 320px 的大封面又需要比 150 档清楚得多。所以按显示尺寸选档。
///
/// 实测过的档位（别的尺寸一律 404，不是任意缩放服务）：
///   150/300/500/800/1200/1500，以及不带尺寸的原图。
void main() {
  const album = 'https://y.gtimg.cn/music/photo_new/T002M000000MkMni19ClKG.jpg';
  const legacy =
      'http://y.gtimg.cn/music/photo_new/T002R150x150M000000MkMni19ClKG.jpg';

  group('coverUrlFor', () {
    test('要原图：去掉尺寸段', () {
      expect(ApiClient.coverUrlFor(album), contains('/T002M000000MkMni19ClKG.jpg'));
      // 老数据存的是 150 档，也该能升上来
      expect(ApiClient.coverUrlFor(legacy), contains('/T002M000000MkMni19ClKG.jpg'));
      expect(ApiClient.coverUrlFor(legacy), isNot(contains('R150x150')));
    });

    test('小图就近降档：40px 的行拿 150 档，别下大图', () {
      // 40px × dpr2 × 2 = 160 → 取 300 档（>=160 的第一档）
      expect(ApiClient.coverUrlFor(album, px: 160), contains('R300x300'));
      expect(ApiClient.coverUrlFor(album, px: 100), contains('R150x150'));
      expect(ApiClient.coverUrlFor(album, px: 640), contains('R800x800'));
    });

    test('播放页的大封面拿 1200 档（实测 800 档 183KB、原图 1.5MB+）', () {
      expect(ApiClient.coverUrlFor(album, px: 960), contains('R1200x1200'));
      // 超过最大档就给 1500
      expect(ApiClient.coverUrlFor(album, px: 4000), contains('R1500x1500'));
    });

    test('保留了原地址的 host', () {
      const qq = 'https://y.qq.com/music/photo_new/T002R150x150M000abc.jpg';
      expect(ApiClient.coverUrlFor(qq, px: 150), startsWith('https://y.qq.com/'));
    });

    test('歌手头像：大图走原图（实测 R800 以上会 404）', () {
      const singer =
          'https://y.gtimg.cn/music/photo_new/T001R150x150M00000singer.jpg';
      expect(ApiClient.coverUrlFor(singer, px: 960), contains('/T001M000'));
      // 小图仍然降档，省流量
      expect(ApiClient.coverUrlFor(singer, px: 300), contains('R300x300'));
    });

    test('vs 那种少见封面：大图退到 1500 档，不赌原图接口', () {
      const vs = 'https://y.gtimg.cn/music/photo_new/T062R1500x1500M00000vs.jpg';
      expect(ApiClient.coverUrlFor(vs), contains('R1500x1500'));
      expect(ApiClient.coverUrlFor(vs, px: 960), contains('R1200x1200'));
    });

    test('不是 QQ 的地址原样返回（网易云、B站）', () {
      const ne = 'https://p1.music.126.net/abc/cover.jpg';
      expect(ApiClient.coverUrlFor(ne, px: 300), ne);
      expect(ApiClient.coverUrlFor(ne), ne);
      const bili = 'https://i0.hdslb.com/bfs/archive/abc.jpg';
      expect(ApiClient.coverUrlFor(bili, px: 300), bili);
    });

    test('空地址不炸', () {
      expect(ApiClient.coverUrlFor('', px: 300), '');
      expect(ApiClient.coverUrlFor(null), '');
    });
  });
}
