import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

import '../core/file_logger.dart';
import '../models/song.dart';

const String kMusicuUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
const String kStreamHost = 'http://ws.stream.qqmusic.qq.com/';
const String kLyricUrl = 'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg';
const String kQrcLyricUrl = 'https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg';
const String kSongIdUrl = 'https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg';

/// QRC 解密密钥（24 字节 ASCII）
/// 注意用 raw string：内含 `$%`，普通字符串会被当成插值。
const String _qrcKeyStr = r'!@#)(*$%123ZXC!@!@#)(NHL';

/// QQ 音乐服务 —— `electron/service/qqmusic.js` 的 Dart 移植。
class QQMusicService {
  QQMusicService();

  static final QQMusicService instance = QQMusicService();

  Map<String, String> cookieMap = {};
  String cookie = '';
  String uin = '0';
  late String guid = _md5('000000music');
  bool highQuality = false;

  QQMusicService setCookie(String value) {
    cookieMap = parseCookie(value);
    cookie = stringifyCookie(cookieMap);
    uin = (cookieMap['uin'] ?? cookieMap['wxuin'] ?? (uin.isEmpty ? '0' : uin)).toString();
    guid = _md5('${uin.isEmpty ? '000000' : uin}music');
    return this;
  }

  // ---------------------------------------------------------------- 搜索

  Future<({List<Song> list, int total})> search(
    String keyword, [
    int page = 1,
    int pageSize = 50,
  ]) async {
    if (keyword.trim().isEmpty) {
      throw Exception('keyword 不能为空');
    }

    final body = {
      'comm': {'uin': '0', 'authst': '', 'ct': 29},
      'search': {
        'method': 'DoSearchForQQMusicMobile',
        'module': 'music.search.SearchCgiService',
        'param': {
          'grp': 1,
          'num_per_page': pageSize,
          'page_num': page,
          'query': keyword.trim(),
          'remoteplace': 'miniapp.1109523715',
          'search_type': 0,
          'searchid': '${(DateTime.now().microsecondsSinceEpoch % 10000000)}',
        }
      }
    };

    final res = await _requestMusicu(body, headers: {
      'Content-Type': 'application/json',
      'User-Agent': 'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)',
    });

    if (!_isOkCode(res['code'])) {
      return (list: <Song>[], total: 0);
    }

    final search = res['search'] as Map?;
    final data = (search?['data'] as Map?)?['body'] as Map? ?? {};
    final meta = (search?['data'] as Map?)?['meta'] as Map? ?? {};
    final rawList = (data['item_song'] as List?) ?? const [];
    final total = (meta['estimate_sum'] as num?)?.toInt() ?? rawList.length;

    return (
      list: rawList
          .whereType<Map>()
          .map((e) => normalizeSong(e.cast<String, dynamic>()))
          .toList(),
      total: total,
    );
  }

  Song normalizeSong(Map<String, dynamic> data) {
    final mid = (data['mid'] ?? data['songmid'] ?? '').toString();
    final singers = (data['singer'] as List?) ?? const [];
    final artist = singers
        .whereType<Map>()
        .map((e) => e['name']?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .join('/');
    final albumMid = ((data['album'] as Map?)?['mid'] ?? '').toString();
    final singerMid = singers.isNotEmpty ? ((singers.first as Map)['mid'] ?? '').toString() : '';
    final vs = data['vs'] as List?;
    final vsPic = (vs != null && vs.length > 1) ? (vs[1] ?? '').toString() : '';

    final picKey = vsPic.isNotEmpty
        ? 'T062R150x150M000$vsPic'
        : albumMid.isNotEmpty
            ? 'T002R150x150M000$albumMid'
            : singerMid.isNotEmpty
                ? 'T001R150x150M000$singerMid'
                : '';

    return Song(
      mid: mid,
      name: (data['title'] ?? data['name'] ?? '').toString().replaceAll(RegExp(r'</?em>'), ''),
      artist: artist,
      pic: picKey.isNotEmpty ? 'http://y.gtimg.cn/music/photo_new/$picKey.jpg' : '',
      link: mid.isNotEmpty ? 'https://y.qq.com/n/yqq/song/$mid.html' : '',
      mediaMid: ((data['file'] as Map?)?['media_mid'] ?? '').toString(),
      source: 'qq',
      raw: data,
    );
  }

  // ------------------------------------------------------------ 播放地址

  Future<String> getMusicUrl(Song song, {bool? highQuality}) async {
    final data = _getRawSong(song);
    final mid = _getSongMid(song);
    if (mid.isEmpty) throw Exception('song.mid 不能为空');

    var playUrl = _createLegacyPlayUrl(mid);
    final hq = highQuality ?? this.highQuality;

    final pay = data['pay'] as Map?;
    final needVkey = hq ||
        (data['sa'] == 0 && (pay?['price_track'] ?? -1) == 0) ||
        pay?['pay_play'] == 1;

    if (!needVkey) return playUrl;

    final result = await getVkey(song, highQuality: hq);
    if (result.url.isNotEmpty) playUrl = result.url;
    return playUrl;
  }

  Future<({String url, String purl, dynamic raw})> getVkey(
    Song song, {
    bool highQuality = false,
  }) async {
    final data = _getRawSong(song);
    final mid = _getSongMid(song);
    if (mid.isEmpty) throw Exception('song.mid 不能为空');

    final param = <String, dynamic>{
      'guid': _md5('${DateTime.now().millisecondsSinceEpoch}'),
      'songmid': [mid],
      'songtype': [0],
      'uin': uin.isEmpty ? '0' : uin,
      'ctx': 1,
    };

    if (highQuality) {
      final file = data['file'] as Map?;
      final mediaMid = (file?['media_mid'] ??
              data['mediaMid'] ??
              data['strMediaMid'] ??
              mid)
          .toString();

      const qualityList = [
        ['size_320mp3', 'M800', 'mp3'],
        ['size_192ogg', 'O600', 'ogg'],
        ['size_128mp3', 'M500', 'mp3'],
        ['size_96aac', 'C400', 'm4a'],
      ];

      final filename = <String>[];
      final songmid = <String>[];
      final songtype = <int>[];

      for (final q in qualityList) {
        final sizeKey = q[0], prefix = q[1], ext = q[2];
        if (file != null && ((file[sizeKey] as num?)?.toInt() ?? 0) < 1) continue;
        songmid.add(mid);
        songtype.add(0);
        filename.add('$prefix$mediaMid.$ext');
      }

      if (filename.isNotEmpty) {
        param['filename'] = filename;
        param['songmid'] = songmid;
        param['songtype'] = songtype;
      }
    }

    final body = {
      'comm': _createQQMusicComm(),
      'req_0': {
        'module': 'vkey.GetVkeyServer',
        'method': 'CgiGetVkey',
        'param': param,
      }
    };

    final res = await _requestMusicu(body, headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    });

    final req0 = res['req_0'] as Map?;
    if (!_isOkCode(req0?['code'])) {
      return (url: '', purl: '', raw: res);
    }

    final midurlinfo = (req0?['data'] as Map?)?['midurlinfo'] as List? ?? const [];
    Map? item;
    for (final e in midurlinfo.whereType<Map>()) {
      final purl = (e['purl'] ?? '').toString();
      if (purl.contains('.mp3')) {
        item = e;
        break;
      }
    }
    item ??= midurlinfo.whereType<Map>().firstWhere(
          (e) => (e['purl'] ?? '').toString().isNotEmpty,
          orElse: () => const {},
        );
    final purl = (item['purl'] ?? '').toString();

    return (
      url: purl.isNotEmpty ? '$kStreamHost$purl' : '',
      purl: purl,
      raw: item.isEmpty ? res : item,
    );
  }

  Future<Song?> getFirstSong(String keyword, {int page = 1, int pageSize = 10, bool? highQuality}) async {
    final result = await search(keyword, page, pageSize);
    if (result.list.isEmpty) return null;
    final song = result.list.first;
    return song;
  }

  // ---------------------------------------------------------------- 歌词

  Future<({String lyric, String trans, dynamic raw})> getLyric(Song song) async {
    final mid = _getSongMid(song);
    if (mid.isEmpty) throw Exception('song.mid 不能为空');

    var qrcLyric = '';
    var qrcTrans = '';

    try {
      final songId = await _getSongId(mid);
      if (songId != 0) {
        final qrc = await _getQrcLyric(songId);
        qrcLyric = qrc.lyric;
        qrcTrans = qrc.trans;
      }
    } catch (e) {
      fileLogger.warn('QQMusic', 'QRC lyric error: $e');
    }

    final hasValidLyric = qrcLyric.isNotEmpty && RegExp(r'\[\d{2}:\d{2}\.\d{2,3}\]').hasMatch(qrcLyric);
    final hasValidTrans = qrcTrans.isNotEmpty && RegExp(r'\[\d{2}:\d{2}\.\d{2,3}\]').hasMatch(qrcTrans);

    if (hasValidLyric) {
      return (lyric: qrcLyric, trans: qrcTrans, raw: {'source': 'qrc'});
    }

    final simple = await _getSimpleLyric(mid);
    return (
      lyric: simple.lyric.isNotEmpty ? simple.lyric : qrcLyric,
      trans: hasValidTrans ? qrcTrans : simple.trans,
      raw: simple.raw,
    );
  }

  Future<int> _getSongId(String songmid) async {
    try {
      final url = '$kSongIdUrl?songmid=${Uri.encodeComponent(songmid)}&format=jsonp&callback=cb';
      final resp = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://y.qq.com/',
        'Cookie': cookie,
      }).timeout(const Duration(seconds: 30));

      var text = resp.body;
      text = text.replaceFirst(RegExp(r'^cb\('), '');
      text = text.replaceFirst(RegExp(r'\)\s*;?\s*$'), '');
      final json = jsonDecode(text) as Map?;
      final data = json?['data'] as List?;
      if (data != null && data.isNotEmpty) {
        return ((data.first as Map)['id'] as num?)?.toInt() ?? 0;
      }
      return 0;
    } catch (e) {
      fileLogger.warn('QQMusic', '_getSongId error: $e');
      return 0;
    }
  }

  Future<({String lyric, String trans, dynamic raw})> _getQrcLyric(int songId) async {
    final params = {
      'version': '15',
      'miniversion': '82',
      'lrctype': '4',
      'musicid': '$songId',
    };

    final resp = await http.post(
      Uri.parse(kQrcLyricUrl),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://y.qq.com/',
        'Cookie': cookie,
      },
      body: params.entries
          .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'),
    ).timeout(const Duration(seconds: 30));

    final xml = resp.body;
    final clean = xml
        .replaceAll('<!--', '')
        .replaceAll('-->', '')
        .replaceAll('<![CDATA[', '')
        .replaceAll(']]>', '');

    String extract(String tag) {
      final m = RegExp('<$tag[^>]*>([\\s\\S]*?)</$tag>').firstMatch(clean);
      return (m?.group(1) ?? '').trim();
    }

    final rawOrig = extract('content');
    final rawTrans = extract('contentts');
    fileLogger.info(
      'QQMusic',
      'QRC rawOrig len=${rawOrig.length}, rawTrans len=${rawTrans.length}',
    );

    final lyric = _decryptQrc(rawOrig) ?? '';
    final decryptedTrans = _decryptQrc(rawTrans);
    final trans = (decryptedTrans != null && decryptedTrans.isNotEmpty)
        ? decryptedTrans
        : (rawTrans.startsWith('[') ? rawTrans : '');

    return (lyric: lyric, trans: trans, raw: clean);
  }

  /// QRC 解密：DES-ECB 三段密钥流水（对应原 `_decryptQrc`）
  String? _decryptQrc(String hex) {
    if (hex.isEmpty) return '';
    hex = hex.replaceAll(RegExp(r'[\s\r\n]'), '');
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex) || hex.length < 16) return null;

    try {
      final key = utf8.encode(_qrcKeyStr);
      final enc = _hexToBytes(hex);
      final out = Uint8List(enc.length);

      for (var i = 0; i + 8 <= enc.length; i += 8) {
        final blk = Uint8List.fromList(enc.sublist(i, i + 8));
        final t = _desEcb(key.sublist(16, 24), blk, false);
        final e = _desEcb(key.sublist(8, 16), t, true);
        final d = _desEcb(key.sublist(0, 8), e, false);
        out.setRange(i, i + 8, d);
      }

      Uint8List decomp;
      try {
        decomp = Uint8List.fromList(ZLibDecoder(raw: true).convert(out));
      } catch (_) {
        decomp = out;
      }

      var str = utf8.decode(decomp, allowMalformed: true);
      if (str.isNotEmpty && str.codeUnitAt(0) == 0xFEFF) str = str.substring(1);
      if (str.contains('<?xml')) {
        final m = RegExp(r'LyricContent[^>]*>([\s\S]*?)</Lyric').firstMatch(str);
        if (m != null) str = m.group(1)!;
      }
      return str.isEmpty ? null : str;
    } catch (e) {
      fileLogger.warn('QQMusic', '_decryptQrc error: $e');
      return null;
    }
  }

  Future<({String lyric, String trans, dynamic raw})> _getSimpleLyric(String mid) async {
    final url = '$kLyricUrl?_=${DateTime.now().millisecondsSinceEpoch}'
        '&cv=4747474&ct=24&format=json&inCharset=utf-8&outCharset=utf-8&notice=0'
        '&platform=yqq.json&needNewCode=1&uin=0&g_tk_new_20200303=5381&g_tk=5381'
        '&loginUin=0&songmid=${Uri.encodeComponent(mid)}';

    final resp = await http.get(Uri.parse(url), headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Referer': 'https://y.qq.com/',
      'Cookie': cookie,
    }).timeout(const Duration(seconds: 30));

    final res = jsonDecode(resp.body) as Map<String, dynamic>;
    String b64(Object? v) {
      if (v == null) return '';
      final s = v.toString();
      if (s.isEmpty) return '';
      try {
        return utf8.decode(base64Decode(s), allowMalformed: true);
      } catch (_) {
        return '';
      }
    }

    return (lyric: b64(res['lyric']), trans: b64(res['trans']), raw: res);
  }

  // ------------------------------------------------------------ Cookie

  Future<bool> validateCookie() async {
    try {
      final url = 'https://c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg'
          '?_=${DateTime.now().millisecondsSinceEpoch}&cv=4747474&ct=24&format=json'
          '&inCharset=utf-8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0'
          '&uin=0&g_tk_new_20200303=5381&g_tk=5381&cid=205360838&userid=0'
          '&reqfrom=1&reqtype=0&hostUin=0&loginUin=0';

      final resp = await http.get(Uri.parse(url), headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Cookie': cookie,
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      }).timeout(const Duration(seconds: 30));

      final res = jsonDecode(resp.body) as Map?;
      return _isOkCode(res?['code']);
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------ 歌单

  Future<PlaylistInfo> getPlaylist(String id) async {
    final body = {
      'comm': {'uin': '0', 'authst': '', 'ct': 29},
      'req_0': {
        'module': 'srf_diss_info.DissInfoServer',
        'method': 'CgiGetDiss',
        'param': {
          'disstid': int.tryParse(id) ?? 0,
          'dirid': 0,
          'onlysonglist': 0,
          'song_begin': 0,
          'song_num': 500,
          'userinfo': 1,
          'pic_dpi': 800,
          'orderlist': 1,
        }
      }
    };

    final resp = await http.post(
      Uri.parse(kMusicuUrl),
      headers: {
        'Content-Type': 'application/json',
        'Cookie': cookie,
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 30));

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final req0 = data['req_0'] as Map?;
    if (!_isOkCode(req0?['code'])) throw Exception('获取歌单失败');

    final info = req0?['data'] as Map? ?? {};
    final songList = (info['songlist'] as List?) ?? const [];

    return PlaylistInfo(
      list: songList
          .whereType<Map>()
          .map((e) => normalizeSong(e.cast<String, dynamic>()))
          .toList(),
      name: (info['dirname'] ?? '').toString(),
      desc: (info['desc'] ?? '').toString(),
      pic: (info['dir_pic_url2'] ?? '').toString(),
    );
  }

  // ------------------------------------------------------------ 工具

  static Map<String, String> parseCookie(String cookie) {
    final map = <String, String>{};
    for (final item in cookie.split(';')) {
      final text = item.trim();
      if (text.isEmpty) continue;
      final idx = text.indexOf('=');
      if (idx < 0) continue;
      map[text.substring(0, idx).trim()] = text.substring(idx + 1).trim();
    }
    return map;
  }

  static String stringifyCookie(Map<String, String> map) => map.entries
      .where((e) => e.value.isNotEmpty)
      .map((e) => '${e.key}=${e.value}')
      .join('; ');

  Future<Map<String, dynamic>> _requestMusicu(
    Map<String, dynamic> body, {
    Map<String, String> headers = const {},
  }) async {
    Object? lastErr;
    for (var i = 0; i < 3; i++) {
      try {
        final resp = await http.post(
          Uri.parse(kMusicuUrl),
          headers: {
            'Content-Type': 'application/json',
            'Cookie': cookie,
            ...headers,
          },
          body: jsonEncode(body),
        ).timeout(const Duration(seconds: 30));

        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw Exception('QQ音乐接口请求失败：${resp.statusCode}');
        }
        return jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (e) {
        lastErr = e;
        if (i < 2) await Future.delayed(Duration(milliseconds: 500 * (i + 1)));
      }
    }
    throw Exception('$lastErr');
  }

  Map<String, dynamic> _createQQMusicComm() {
    final loginType = cookieMap.containsKey('wxunionid')
        ? 1
        : int.tryParse(cookieMap['tmeLoginType'] ?? '2') ?? 2;
    final qqUnionId = cookieMap['psrf_qqunionid'] ?? '';
    final wxUnionId = cookieMap['wxunionid'] ?? '';

    return {
      '_channelid': '19',
      '_os_version': '6.2.9200-2',
      'authst': cookieMap['qqmusic_key'] ?? cookieMap['qm_keyst'] ?? '',
      'ct': '19',
      'cv': '1891',
      'guid': guid,
      'patch': '118',
      'psrf_access_token_expiresAt':
          int.tryParse(cookieMap['psrf_access_token_expiresAt'] ?? '0') ?? 0,
      'psrf_qqaccess_token': cookieMap['psrf_qqaccess_token'] ?? '',
      'psrf_qqopenid': cookieMap['psrf_qqopenid'] ?? '',
      'psrf_qqunionid': qqUnionId.isNotEmpty ? qqUnionId : wxUnionId,
      'tmeAppID': 'qqmusic',
      'tmeLoginType': loginType,
      'uin': cookieMap['uin'] ?? '0',
      'wid': cookieMap['wxuin'] ?? '0',
    };
  }

  String _createLegacyPlayUrl(String mid) {
    final code = _md5('${mid}q;z(&l~sdf2!nK').substring(0, 5).toUpperCase();
    return 'http://c6.y.qq.com/rsc/fcgi-bin/fcg_pyq_play.fcg?songid=&songmid='
        '${Uri.encodeComponent(mid)}&songtype=1&fromtag=50'
        '&uin=${Uri.encodeComponent(uin.isEmpty ? '0' : uin)}&code=$code';
  }

  Map<String, dynamic> _getRawSong(Song song) {
    if (song.raw.isNotEmpty) return song.raw;
    return song.toApiJson();
  }

  String _getSongMid(Song song) => song.mid.isNotEmpty ? song.mid : '';

  bool _isOkCode(Object? code) => code == 0 || code == '0';

  static String _md5(String text) =>
      crypto.md5.convert(utf8.encode(text)).toString();

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// DES-ECB 单块流水（autoPadding = false）
  ///
  /// pointycastle 4.x 移除了单 DES 引擎，这里用 `DESedeEngine` + 三份相同密钥
  /// 等价实现单 DES（DES-EDE 在 K1=K2=K3 时退化为 DES）。
  static Uint8List _desEcb(List<int> key, Uint8List data, bool encrypt) {
    if (key.length != 8) throw ArgumentError('DES key must be 8 bytes');
    final tripled = Uint8List(24)
      ..setRange(0, 8, key)
      ..setRange(8, 16, key)
      ..setRange(16, 24, key);

    final engine = DESedeEngine()..init(encrypt, KeyParameter(tripled));
    final out = Uint8List(data.length);
    for (var off = 0; off + 8 <= data.length; off += 8) {
      engine.processBlock(data, off, out, off);
    }
    return out;
  }
}

final qqMusicService = QQMusicService.instance;
