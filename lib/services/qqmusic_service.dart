import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

import '../core/file_logger.dart';
import '../models/song.dart';

/// QQ 音乐 musicu 接口入口列表（**主 u，备用 u6**）。
///
/// 主备依据来自千奈逆向 QQ 音乐的结论：`u.y.qq.com` 是正规主入口，
/// `u6.y.qq.com`（小程序入口）作为备用。
///
/// 补充一条实测（2026-09-19，**匿名请求、无 Cookie**）：
///   u.y.qq.com  → 连续 8 次全部返回空列表（item_song 为空）
///   u6.y.qq.com → 8 次里成功 7 次
/// 推测差异在于登录态 —— `u` 对匿名流量的限流更狠，登录后应当正常。
/// 无论如何，配合下面的**入口轮换重试**，主入口抖动时会自动落到备用入口。
const List<String> kMusicuUrls = [
  'https://u.y.qq.com/cgi-bin/musicu.fcg',
  'https://u6.y.qq.com/cgi-bin/musicu.fcg',
];

/// 兼容旧引用（默认入口 = 主入口）
const String kMusicuUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
const String kStreamHost = 'http://ws.stream.qqmusic.qq.com/';
const String kLyricUrl = 'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg';
const String kQrcLyricUrl = 'https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg';
const String kSongIdUrl = 'https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg';

/// QRC 解密密钥（24 字节 ASCII）
/// 注意用 raw string：内含 `$%`，普通字符串会被当成插值。
const String _qrcKeyStr = r'!@#)(*$%123ZXC!@!@#)(NHL';

/// QQ 音乐服务 —— `electron/service/qqmusic.js` 的 Dart 移植。
///
/// ⚠️ 所有响应体都用 `utf8.decode(resp.bodyBytes)` 解码，**不要用 `resp.body`**：
/// QQ 音乐接口返回的响应头是 `text/plain; charset=utf-8;`（**末尾多一个分号**），
/// 而 `package:http` 的 `Response.body` 会用 `ContentType.parse()` 解析该头，
/// Dart 的解析器遇到多余分号会抛
/// `FormatException: Invalid media type: expected /; ...`，
/// 导致所有接口调用直接失败。
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

    // QQ 搜索接口会**偶发返回「空列表 + 非零 total」**（疑似限流/服务端抖动），
    // 用户看到的现象就是「点了搜索转圈后什么都没发生」。
    // 这里对「total>0 却一条都没返回」这种明确异常做几次重试；
    // 真正没有结果时 total 会是 0，不会触发重试。
    Map<String, dynamic>? lastRes;
    var lastTotal = 0;
    for (var attempt = 0; attempt < 3; attempt++) {
      // 每次重试都换一个 searchid，避免命中同一份缓存
      (body['search']! as Map)['param'] = {
        ...(body['search']! as Map)['param'] as Map,
        'searchid': '${DateTime.now().microsecondsSinceEpoch % 10000000}',
      };

      final res = await _requestMusicu(
        body,
        headers: {
          'Content-Type': 'application/json',
          'User-Agent':
              'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)',
        },
        // 每次重试从不同入口开始，避免连续撞在同一个被限流的入口上
        hostOffset: attempt,
      );
      lastRes = res;

      if (!_isOkCode(res['code'])) {
        return (list: <Song>[], total: 0);
      }

      final search = res['search'] as Map?;
      final data = (search?['data'] as Map?)?['body'] as Map? ?? {};
      final meta = (search?['data'] as Map?)?['meta'] as Map? ?? {};
      final rawList = (data['item_song'] as List?) ?? const [];
      final total = (meta['estimate_sum'] as num?)?.toInt() ?? rawList.length;
      lastTotal = total;

      final list = rawList
          .whereType<Map>()
          .map((e) => normalizeSong(e.cast<String, dynamic>()))
          .toList();

      if (list.isNotEmpty || total == 0) {
        return (list: list, total: total);
      }

      fileLogger.warn('QQMusic',
          'search "$keyword" 返回空列表但 total=$total，重试 ${attempt + 1}/3');
      await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
    }

    fileLogger.error('QQMusic',
        'search "$keyword" 连续 3 次返回空列表（total=$lastTotal），放弃；'
        'response keys=${lastRes?.keys.toList()}');
    // ⚠️ 抛异常而不是返回「0 条结果」：
    // 返回空结果会让界面显示「没有找到 xxx」，误导用户以为真的没有这首歌；
    // 实际这是接口异常（限流/返回结构异常），应当明确报错。
    throw Exception('搜索接口返回异常（连续 3 次空列表），请稍后重试');
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

    final sw = Stopwatch()..start();

    // 并行发起两条线：
    //  * QRC（逐字歌词，需要先取 songId 再解密，**明显更慢**）
    //  * 普通 LRC（快）
    // QRC 超过 10s 就放弃、直接用普通歌词 —— 否则慢的时候用户会长时间
    // 看不到歌词 / 拉不到翻译（用户反馈过）。
    final Future<({String lyric, String trans, dynamic raw})> qrcFuture = _fetchQrc(mid);

    final simpleFuture = () async {
      try {
        return await _getSimpleLyric(mid);
      } catch (e) {
        fileLogger.warn('QQMusic', 'simple lyric error: $e');
        return (lyric: '', trans: '', raw: null);
      }
    }();

    var qrcLyric = '';
    var qrcTrans = '';
    var qrcTimedOut = false;
    try {
      final qrc = await qrcFuture.timeout(const Duration(seconds: 10));
      qrcLyric = qrc.lyric;
      qrcTrans = qrc.trans;
    } on TimeoutException {
      qrcTimedOut = true;
      fileLogger.warn('QQMusic', 'QRC 歌词 10s 未返回，改用普通歌词 mid=$mid');
    }

    final hasValidLyric = _hasTimestamp(qrcLyric);
    final hasValidTrans = _hasTimestamp(qrcTrans);

    if (hasValidLyric) {
      fileLogger.info('QQMusic',
          'lyric(qrc) mid=$mid ${sw.elapsedMilliseconds}ms '
          'lyric=${qrcLyric.length} trans=${qrcTrans.length}');
      return (lyric: qrcLyric, trans: qrcTrans, raw: {'source': 'qrc'});
    }

    final simple = await simpleFuture;
    fileLogger.info('QQMusic',
        'lyric(${qrcTimedOut ? 'simple-after-qrc-timeout' : 'simple'}) mid=$mid '
        '${sw.elapsedMilliseconds}ms lyric=${simple.lyric.length} trans=${simple.trans.length}');
    return (
      lyric: simple.lyric.isNotEmpty ? simple.lyric : qrcLyric,
      trans: hasValidTrans ? qrcTrans : simple.trans,
      raw: simple.raw,
    );
  }

  /// 取 QRC 逐字歌词（内部已吞掉异常，失败返回空串）
  Future<({String lyric, String trans, dynamic raw})> _fetchQrc(String mid) async {
    try {
      final songId = await _getSongId(mid);
      if (songId == 0) return (lyric: '', trans: '', raw: null);
      return await _getQrcLyric(songId);
    } catch (e) {
      fileLogger.warn('QQMusic', 'QRC lyric error: $e');
      return (lyric: '', trans: '', raw: null);
    }
  }

  /// 歌词是否含时间戳（`[mm:ss.xx]` 或网易云那种 `[mm:ss:xx]`）
  static bool _hasTimestamp(String text) =>
      text.isNotEmpty && RegExp(r'\[\d{1,2}:\d{1,2}[.:]\d{1,3}\]').hasMatch(text);

  Future<int> _getSongId(String songmid) async {
    try {
      final url = '$kSongIdUrl?songmid=${Uri.encodeComponent(songmid)}&format=jsonp&callback=cb';
      final resp = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://y.qq.com/',
        'Cookie': cookie,
      }).timeout(const Duration(seconds: 30));

      var text = utf8.decode(resp.bodyBytes);
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

    final xml = utf8.decode(resp.bodyBytes);
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

    final res = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
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

      final res = jsonDecode(utf8.decode(resp.bodyBytes)) as Map?;
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

    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
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

  /// musicu 接口请求，**多入口轮换**。
  ///
  /// ⚠️ 关键：`u.y.qq.com` 已被限流/降级 —— 实测同一请求体、同一时间：
  ///   u.y.qq.com  → 连续 8 次全部返回空列表（item_song 为空）
  ///   u6.y.qq.com → 8 次里成功 7 次
  /// 原版 Electron 用的是 `u`（写的时候还能用）。因此这里**主用 u6、备用 u**，
  /// 并且每次重试轮换入口，避免连续撞在同一个坏入口上。
  Future<Map<String, dynamic>> _requestMusicu(
    Map<String, dynamic> body, {
    Map<String, String> headers = const {},
    int hostOffset = 0,
  }) async {
    Object? lastErr;
    const attempts = 4;
    for (var i = 0; i < attempts; i++) {
      final host = kMusicuUrls[(i + hostOffset) % kMusicuUrls.length];
      try {
        final resp = await http.post(
          Uri.parse(host),
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
        return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      } catch (e) {
        lastErr = e;
        fileLogger.warn('QQMusic', 'musicu 入口 ${Uri.parse(host).host} 第 ${i + 1} 次失败: $e');
        if (i < attempts - 1) {
          await Future<void>.delayed(Duration(milliseconds: 400 * (i + 1)));
        }
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
