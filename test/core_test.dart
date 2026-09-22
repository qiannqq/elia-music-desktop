import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elia_music/core/lyric.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/netease_service.dart';
import 'package:elia_music/services/qqmusic_service.dart';
import 'package:elia_music/state/app_state.dart';

void main() {
  group('LRC 解析', () {
    test('解析两位与三位毫秒并排序', () {
      const raw = '[00:12.50]第二行\n[00:01.123]第一行\n[00:30.00]第三行\n';
      final lines = parseLrc(raw);
      expect(lines.length, 3);
      expect(lines[0].text, '第一行');
      expect(lines[0].time, closeTo(1.123, 1e-6));
      expect(lines[1].text, '第二行');
      expect(lines[1].time, closeTo(12.5, 1e-6));
      expect(lines[2].text, '第三行');
    });

    test('忽略无时间戳与空内容行', () {
      const raw = '[00:01.00]有效\n无时间戳\n[00:02.00]   \n';
      final lines = parseLrc(raw);
      expect(lines.length, 1);
      expect(lines.first.text, '有效');
    });

    test('翻译歌词映射', () {
      final map = parseTransLrc('[00:01.00]译文\n[00:02.50]译文二\n');
      expect(map[1.0], '译文');
      expect(map[2.5], '译文二');
    });
  });

  group('时间格式化', () {
    test('formatTime', () {
      expect(formatTime(0), '0:00');
      expect(formatTime(59), '0:59');
      expect(formatTime(60), '1:00');
      expect(formatTime(125), '2:05');
      expect(formatTime(null), '0:00');
      expect(formatTime(double.nan), '0:00');
    });
  });

  group('文件名清洗', () {
    test('替换非法字符并压缩空白', () {
      expect(AppState.sanitizeFilename('a/b\\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
      expect(AppState.sanitizeFilename('  多   空格  '), '多 空格');
    });
  });

  group('Song 序列化', () {
    test('持久化只保留裁剪字段', () {
      const song = Song(
        mid: 'abc',
        name: '歌名',
        artist: '歌手',
        pic: 'http://x/y.jpg',
        link: 'https://y.qq.com/n/yqq/song/abc.html',
        mediaMid: 'm1',
        source: 'qq',
        raw: {'file': {'media_mid': 'm1'}},
      );
      final stored = song.toStoreJson();
      expect(stored.keys.toSet(), {
        'mid', 'name', 'artist', 'pic', 'link', 'mediaMid', 'source',
      });
      expect(stored['raw'], isNull);

      final restored = Song.fromStoreJson(stored);
      expect(restored.mid, 'abc');
      expect(restored.name, '歌名');
      expect(restored.raw, isEmpty);
    });

    test('请求体携带 raw（取 vkey 需要 media_mid）', () {
      const song = Song(
        mid: 'abc',
        name: 'n',
        artist: 'a',
        raw: {'file': {'media_mid': 'mm'}},
      );
      final api = song.toApiJson();
      expect(api['raw'], isNotNull);
      expect(api['mid'], 'abc');
    });
  });

  group('Cookie 解析', () {
    test('parseCookie / stringifyCookie 往返', () {
      const raw = 'a=1; b=2;  c = 3 ;;d=';
      final map = QQMusicService.parseCookie(raw);
      expect(map['a'], '1');
      expect(map['b'], '2');
      expect(map['c'], '3');
      expect(map['d'], '');
      // 空值在序列化时被丢弃
      expect(QQMusicService.stringifyCookie(map), 'a=1; b=2; c=3');
    });
  });

  group('QQ ck 校验结论', () {
    // 结构上就不合法的 ck 应当在**发请求之前**被判成 rejected。
    // 这一条是给「重启后误报失效」留的护栏：那时如果把「发不出去」和
    // 「服务端不认」混成一件事，用户每次开机都会看到一条假的失效提示。
    test('空 ck → rejected（不是 unreachable）', () async {
      final r = await QQMusicService.instance.fetchUserInfo(ck: '');
      expect(r.outcome, CkOutcome.rejected);
      expect(r.nickname, isEmpty);
    });

    test('缺 unionid → rejected', () async {
      final r = await QQMusicService.instance
          .fetchUserInfo(ck: 'uin=1; qqmusic_key=abc');
      expect(r.outcome, CkOutcome.rejected);
    });

    test('缺 musickey → rejected', () async {
      final r = await QQMusicService.instance
          .fetchUserInfo(ck: 'psrf_qqunionid=DEADBEEF; uin=1');
      expect(r.outcome, CkOutcome.rejected);
    });

    test('连不上 → unreachable，而不是 rejected', () async {
      // 指到一个没人监听的端口：连接立刻被拒。结构合法的 ck 走到这一步时
      // 结论必须是「未知」—— 上层才不会拿一次网络抖动去标失效。
      final saved = QQMusicService.profileEndpoint;
      QQMusicService.profileEndpoint = 'http://127.0.0.1:1/nope';
      try {
        final r = await QQMusicService.instance.fetchUserInfo(
            ck: 'uin=1; qqmusic_key=abc; psrf_qqunionid=DEADBEEF');
        expect(r.outcome, CkOutcome.unreachable);
        expect(r.nickname, isEmpty);
      } finally {
        QQMusicService.profileEndpoint = saved;
      }
    });
  });

  group('QRC 解密密钥', () {
    test('密钥为 24 字节 ASCII（与 Node 版 Buffer.from(...,"ascii") 一致）',
        () {
      const key = r'!@#)(*$%123ZXC!@!@#)(NHL';
      expect(utf8.encode(key).length, 24);
      // 与 Node 中 crypto.createHash('md5') 的输入一致，确保未被 Dart 插值破坏
      expect(md5.convert(utf8.encode(key)).toString().length, 32);
    });
  });

  group('网易云 cookie 归一化', () {
    // 三种写法都得认：纯值、键值、完整 cookie 串。
    // 判据是「有没有等号」—— MUSIC_U 的值是一长串十六进制，里面不会有等号。
    test('纯值自动补上 MUSIC_U=', () {
      expect(NeteaseMusicService.normalizeCookie('ABC123'), 'MUSIC_U=ABC123');
    });

    test('键值原样保留', () {
      expect(NeteaseMusicService.normalizeCookie('MUSIC_U=ABC'), 'MUSIC_U=ABC');
    });

    test('完整 cookie 串原样保留', () {
      const full = '__csrf=x; MUSIC_U=ABC; NMTID=y';
      expect(NeteaseMusicService.normalizeCookie(full), full);
    });

    test('先清掉换行与空白', () {
      expect(NeteaseMusicService.normalizeCookie('  ABC\n123\t  '), 'MUSIC_U=ABC123');
    });

    test('空串还是空串（不补成 MUSIC_U=）', () {
      expect(NeteaseMusicService.normalizeCookie('   '), '');
      expect(NeteaseMusicService.normalizeCookie(''), '');
    });
  });
}
