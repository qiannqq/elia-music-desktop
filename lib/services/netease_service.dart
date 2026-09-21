import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/file_logger.dart';
import '../models/song.dart';

const String kNeSearchUrl = 'http://music.163.com/api/cloudsearch/pc';
const String kNeSongUrlApi = 'https://interface3.music.163.com/api/song/enhance/player/url/v1';
const String kNeLyricUrl = 'https://music.163.com/api/song/lyric';
const String kNePlaylistUrl = 'https://music.163.com/api/v6/playlist/detail';
const String kNeSongDetailUrl = 'https://music.163.com/api/v3/song/detail';
const String kNeUserInfoUrl = 'https://interface.music.163.com/api/nuser/account/get';

const String kWebUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const String kAndroidUa = 'Dalvik/2.1.0 (Linux; U; Android 12; MI Build/SKQ1.211230.001)';

/// 网易云音乐服务 —— `electron/service/netease.js` 的 Dart 移植。
class NeteaseMusicService {
  NeteaseMusicService();

  static final NeteaseMusicService instance = NeteaseMusicService();

  String cookie = '';
  String userId = '';
  String nickname = '';
  bool isVip = false;

  /// 把用户填的东西整理成可用的 cookie。
  ///
  /// 三种写法都认：
  ///  * 完整 cookie 字符串（`_ntes_nuid=...; MUSIC_U=xxx; ...`）—— 原样用；
  ///  * 键值（`MUSIC_U=xxx`）—— 原样用；
  ///  * **纯值**（只有 MUSIC_U 那一长串）—— 补上 `MUSIC_U=`。
  ///
  /// 判据是「有没有等号」：cookie 一定是 `名字=值` 的形式，而 MUSIC_U 的值
  /// 是一长串十六进制，里面不会有等号。
  static String normalizeCookie(String raw) {
    final s = raw.replaceAll(RegExp(r'[\r\n\t\x00]'), '').trim();
    if (s.isEmpty) return '';
    return s.contains('=') ? s : 'MUSIC_U=$s';
  }

  NeteaseMusicService setCookie(String value) {
    cookie = normalizeCookie(value);
    return this;
  }

  Future<({List<Song> list, int total})> search(
    String keyword, [
    int page = 1,
    int pageSize = 30,
  ]) async {
    if (keyword.trim().isEmpty) throw Exception('keyword 不能为空');

    final offset = pageSize * page - pageSize;
    final body = 'offset=$offset&limit=$pageSize&type=1&s=${Uri.encodeQueryComponent(keyword.trim())}';

    final res = await _post(kNeSearchUrl, body, {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': kWebUa,
      'Referer': 'https://music.163.com/',
      'Cookie': cookie,
    });

    if (res['code'] != 200 || res['result'] == null) {
      return (list: <Song>[], total: 0);
    }

    final result = res['result'] as Map;
    final songs = (result['songs'] as List?) ?? const [];
    final total = (result['songCount'] as num?)?.toInt() ?? songs.length;

    return (
      list: songs.whereType<Map>().map((e) => normalizeSong(e.cast<String, dynamic>())).toList(),
      total: total,
    );
  }

  Song normalizeSong(Map<String, dynamic> data) {
    final artists = (data['ar'] as List?) ?? const [];
    final artist = artists
        .whereType<Map>()
        .map((e) => e['name']?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .join('/');
    final album = (data['al'] as Map?) ?? const {};
    final picUrl = (album['picUrl'] ?? '').toString();

    return Song(
      mid: '${data['id']}',
      name: (data['name'] ?? '').toString().replaceAll(RegExp(r'</?em>'), ''),
      artist: artist,
      pic: picUrl.isNotEmpty ? '$picUrl?param=300x300' : '',
      link: 'https://music.163.com/#/song?id=${data['id']}',
      source: 'netease',
      raw: data,
      fee: (((data['privilege'] as Map?)?['fee']) ?? data['fee'] as num?)?.toInt() ?? 0,
      duration: (data['dt'] as num?)?.toInt() ?? 0,
      album: (album['name'] ?? '').toString(),
    );
  }

  Future<String> getMusicUrl(Song song, {String quality = 'exhigh'}) async {
    final songId = _getSongId(song);
    if (songId.isEmpty) throw Exception('song.id 不能为空');

    try {
      final body = 'ids=${jsonEncode([songId])}&level=$quality&encodeType=mp3';
      final res = await _post(kNeSongUrlApi, body, {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': kAndroidUa,
        'Cookie': 'versioncode=8008070; os=android; channel=xiaomi; appver=8.8.70; $cookie',
      });

      if (res['code'] == 200 && res['data'] is List) {
        final data = res['data'] as List;
        if (data.isNotEmpty) {
          final url = (data.first as Map)['url'];
          if (url != null && url.toString().isNotEmpty) return url.toString();
        }
      }
    } catch (e) {
      fileLogger.error('Netease', 'getMusicUrl API error: $e');
    }

    return 'https://music.163.com/song/media/outer/url?id=$songId.mp3';
  }

  Future<({String lyric, String trans, dynamic raw})> getLyric(Song song) async {
    final songId = _getSongId(song);
    if (songId.isEmpty) throw Exception('song.id 不能为空');

    try {
      final res = await _get('$kNeLyricUrl?id=$songId&lv=-1&tv=-1', {
        'User-Agent': kWebUa,
        'Referer': 'https://music.163.com/',
        'Cookie': cookie,
      });

      if (res['code'] == 200) {
        return (
          lyric: ((res['lrc'] as Map?)?['lyric'] ?? '').toString(),
          trans: ((res['tlyric'] as Map?)?['lyric'] ?? '').toString(),
          raw: res,
        );
      }
    } catch (e) {
      fileLogger.error('Netease', 'getLyric error: $e');
    }

    return (lyric: '', trans: '', raw: null);
  }

  Future<PlaylistInfo> getPlaylist(String playlistId) async {
    if (playlistId.isEmpty) throw Exception('playlistId 不能为空');

    final body = 'id=$playlistId&n=100000&s=0';
    final res = await _post(kNePlaylistUrl, body, {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': kWebUa,
      'Referer': 'https://music.163.com/',
      'Cookie': cookie,
    });

    if (res['code'] != 200 || res['playlist'] == null) throw Exception('获取歌单失败');

    final playlist = res['playlist'] as Map;
    final trackIds = ((playlist['trackIds'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e['id'])
        .toList();
    var tracks = ((playlist['tracks'] as List?) ?? const []).whereType<Map>().toList();

    if (trackIds.isNotEmpty && tracks.length < trackIds.length) {
      tracks = await _batchGetTrackDetails(trackIds);
    }

    return PlaylistInfo(
      list: tracks.map((e) => normalizeSong(e.cast<String, dynamic>())).toList(),
      name: (playlist['name'] ?? '').toString(),
      desc: (playlist['description'] ?? '').toString(),
      pic: (playlist['coverImgUrl'] ?? '').toString(),
    );
  }

  Future<bool> validateCookie() async {
    try {
      final info = await getUserInfo();
      if (info != null && info['userId'] != null) {
        userId = '${info['userId']}';
        nickname = '${info['nickname']}';
        isVip = info['isVip'] == true;
        return true;
      }
    } catch (e) {
      fileLogger.error('Netease', 'validateCookie error: $e');
    }
    return false;
  }

  Future<Map<String, dynamic>?> getUserInfo() async {
    final res = await _get(kNeUserInfoUrl, {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': kWebUa,
      'Cookie': cookie,
    });

    if (res['code'] != 200 || res['profile'] == null) return null;

    final profile = res['profile'] as Map;
    // vipType 是**位标志**：bit0 = 音乐包、bit1 = 黑胶 VIP。
    // 只看「不等于 0」会把只买了音乐包的账号也算成黑胶，所以按位判。
    final vipType = (profile['vipType'] as num?)?.toInt() ??
        ((res['account'] as Map?)?['vipType'] as num?)?.toInt() ??
        0;

    return {
      'userId': (profile['userId'] ?? '').toString(),
      'nickname': (profile['nickname'] ?? '').toString(),
      'avatarUrl': (profile['avatarUrl'] ?? '').toString(),
      'isVip': (vipType & 2) != 0,
    };
  }

  Future<List<Map>> _batchGetTrackDetails(List<dynamic> trackIds) async {
    const batchSize = 100;
    final all = <Map>[];

    for (var i = 0; i < trackIds.length; i += batchSize) {
      final batch = trackIds.sublist(i, (i + batchSize).clamp(0, trackIds.length));
      final c = batch.map((id) => {'id': id}).toList();

      try {
        final res = await _post(kNeSongDetailUrl, 'c=${jsonEncode(c)}', {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': kWebUa,
          'Referer': 'https://music.163.com/',
          'Cookie': cookie,
        });

        if (res['code'] == 200 && res['songs'] is List) {
          all.addAll((res['songs'] as List).whereType<Map>());
        }
      } catch (e) {
        fileLogger.error('Netease', 'batchGetTrackDetails error: $e');
      }

      if (i + batchSize < trackIds.length) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    return all;
  }

  static String? extractPlaylistId(String url) {
    final m = RegExp(r'[?&]id=(\d+)').firstMatch(url);
    return m?.group(1);
  }

  static String? extractSongId(String url) {
    final m = RegExp(r'[?&]id=(\d+)').firstMatch(url);
    return m?.group(1);
  }

  String _getSongId(Song song) => song.mid.isNotEmpty ? song.mid : '${song.raw['id'] ?? ''}';

  Future<Map<String, dynamic>> _post(
    String url,
    String body,
    Map<String, String> headers,
  ) async {
    Object? lastErr;
    for (var i = 0; i < 3; i++) {
      try {
        final resp = await http
            .post(Uri.parse(url), headers: headers, body: body)
            .timeout(const Duration(seconds: 30));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw Exception('网易云接口请求失败：${resp.statusCode}');
        }
        return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      } catch (e) {
        lastErr = e;
        if (i < 2) await Future.delayed(Duration(milliseconds: 500 * (i + 1)));
      }
    }
    throw Exception('$lastErr');
  }

  Future<Map<String, dynamic>> _get(String url, Map<String, String> headers) async {
    Object? lastErr;
    for (var i = 0; i < 3; i++) {
      try {
        final resp = await http
            .get(Uri.parse(url), headers: headers)
            .timeout(const Duration(seconds: 30));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw Exception('网易云接口请求失败：${resp.statusCode}');
        }
        return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      } catch (e) {
        lastErr = e;
        if (i < 2) await Future.delayed(Duration(milliseconds: 500 * (i + 1)));
      }
    }
    throw Exception('$lastErr');
  }
}

final neteaseMusicService = NeteaseMusicService.instance;
