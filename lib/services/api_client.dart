import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/local_store.dart';
import '../models/song.dart';

const String kApiBase = 'http://127.0.0.1:17071';

String sanitizeCookie(String? raw) =>
    (raw ?? '').replaceAll(RegExp(r'[\r\n\t\x00]'), '').trim();

/// 本地 HTTP API 客户端 —— `public/dist/js/api.js` 的 Dart 移植。
///
/// 请求头、参数、错误语义与原实现保持一致。
class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();

  static final http.Client _http = http.Client();

  static String getCookie() => sanitizeCookie(LocalStore.get('qqmusic_cookie'));
  static String getNeteaseCookie() => sanitizeCookie(LocalStore.get('netease_cookie'));

  static Map<String, String> _headers([Map<String, String>? extra]) {
    final h = <String, String>{'Content-Type': 'application/json'};
    final c = getCookie();
    if (c.isNotEmpty) h['X-QQMusic-Cookie'] = c;
    final nc = getNeteaseCookie();
    if (nc.isNotEmpty) h['X-NetEase-Cookie'] = nc;
    if (extra != null) h.addAll(extra);
    return h;
  }

  static String _enc(Object? v) => Uri.encodeComponent('${v ?? ''}');

  static Future<Map<String, dynamic>> _request(
    String url, {
    String method = 'GET',
    Object? body,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final h = _headers(headers);
    late http.Response resp;
    if (method == 'POST') {
      resp = await _http
          .post(Uri.parse(url), headers: h, body: body ?? '{}')
          .timeout(timeout);
    } else {
      resp = await _http.get(Uri.parse(url), headers: h).timeout(timeout);
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      Map<String, dynamic> err = {};
      try {
        err = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      } catch (_) {}
      throw Exception(err['error']?.toString() ?? '请求失败: ${resp.statusCode}');
    }
    return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 保留 raw 的完整解析（播放地址依赖 raw.file.media_mid）
  static List<Song> parseSongsFull(Object? data) {
    if (data is! List) return const [];
    return data.whereType<Map>().map((e) {
      final m = e.cast<String, dynamic>();
      final rawData = m['raw'] ?? m['data'];
      return Song(
        mid: (m['mid'] ?? m['id'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        artist: (m['artist'] ?? '').toString(),
        pic: (m['pic'] ?? '').toString(),
        link: (m['link'] ?? '').toString(),
        mediaMid: (m['mediaMid'] ?? '').toString(),
        source: (m['source'] ?? 'qq').toString(),
        fee: (m['fee'] as num?)?.toInt() ?? 0,
        duration: (m['duration'] as num?)?.toInt() ?? 0,
        album: (m['album'] ?? '').toString(),
        raw: rawData is Map ? rawData.cast<String, dynamic>() : const {},
      );
    }).toList();
  }

  // ------------------------------------------------------------ QQ 音乐

  static Future<({List<Song> list, int total})> search(
    String keyword, [
    int page = 1,
    int pageSize = 50,
  ]) async {
    if (keyword.isEmpty) throw Exception('keyword 不能为空');
    final res = await _request(
      '$kApiBase/api/search?keyword=${_enc(keyword)}&page=$page&pageSize=$pageSize',
    );
    return (
      list: parseSongsFull(res['data']),
      total: (res['total'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<String> getSongUrl(String mid, bool highQuality, Song? songData) async {
    if (mid.isEmpty) throw Exception('mid 不能为空');
    final url = '$kApiBase/api/song/url?mid=${_enc(mid)}&highQuality=$highQuality';
    final res = await _request(
      url,
      method: 'POST',
      body: jsonEncode({'song': songData?.toApiJson() ?? {}}),
    );
    return (res['data']?['url'] ?? '').toString();
  }

  static Future<List<Map<String, dynamic>>> getBatchUrls(
    List<Song> songs,
    bool highQuality,
  ) async {
    if (songs.isEmpty) throw Exception('songs 不能为空');
    final res = await _request(
      '$kApiBase/api/song/batch-url',
      method: 'POST',
      body: jsonEncode({
        'songs': songs.map((e) => e.toApiJson()).toList(),
        'highQuality': highQuality,
      }),
      timeout: const Duration(minutes: 5),
    );
    final data = res['data'];
    if (data is! List) return const [];
    return data.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  static Future<Song?> getSongDetail(String mid, [bool highQuality = false]) async {
    if (mid.isEmpty) throw Exception('mid 不能为空');
    final res = await _request(
      '$kApiBase/api/song/detail?mid=${_enc(mid)}&highQuality=$highQuality',
    );
    final data = res['data'];
    if (data is! Map) return null;
    return parseSongsFull([data]).firstOrNull;
  }

  static Future<({String lyric, String trans})> getLyric(String mid, [String? source]) async {
    if (mid.isEmpty) throw Exception('mid 不能为空');
    var url = '$kApiBase/api/song/lyric?mid=${_enc(mid)}';
    if (source != null && source.isNotEmpty) url += '&source=${_enc(source)}';
    final res = await _request(url);
    final data = res['data'] as Map?;
    return (
      lyric: (data?['lyric'] ?? '').toString(),
      trans: (data?['trans'] ?? '').toString(),
    );
  }

  static Future<({List<Song> list, String name, String desc, String pic})> getPlaylist(
    String id,
  ) async {
    if (id.isEmpty) throw Exception('id 不能为空');
    final res = await _request('$kApiBase/api/playlist?id=${_enc(id)}');
    final data = res['data'] as Map?;
    return (
      list: parseSongsFull(data?['list']),
      name: (data?['name'] ?? '').toString(),
      desc: (data?['desc'] ?? '').toString(),
      pic: (data?['pic'] ?? '').toString(),
    );
  }

  static Future<Map<String, dynamic>> parseUrl(String url) =>
      _request('$kApiBase/api/parse-url', method: 'POST', body: jsonEncode({'url': url}));

  static Future<bool> setCookie(String cookie) async {
    final res = await _request(
      '$kApiBase/api/set-cookie',
      method: 'POST',
      body: jsonEncode({'cookie': sanitizeCookie(cookie)}),
    );
    return res['data']?['isValid'] == true;
  }

  static Future<Map<String, dynamic>> getCookieStatus() =>
      _request('$kApiBase/api/cookie-status');

  // ------------------------------------------------------------ 网易云

  static Future<({List<Song> list, int total})> neSearch(
    String keyword, [
    int page = 1,
    int pageSize = 30,
  ]) async {
    if (keyword.isEmpty) throw Exception('keyword 不能为空');
    final res = await _request(
      '$kApiBase/api/netease/search?keyword=${_enc(keyword)}&page=$page&pageSize=$pageSize',
    );
    return (
      list: parseSongsFull(res['data']),
      total: (res['total'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<String> neSongUrl(Song song, [String quality = 'exhigh']) async {
    if (song.mid.isEmpty) throw Exception('song.id 不能为空');
    final res = await _request(
      '$kApiBase/api/netease/song/url',
      method: 'POST',
      body: jsonEncode({'song': song.toApiJson(), 'quality': quality}),
    );
    return (res['data']?['url'] ?? '').toString();
  }

  static Future<({String lyric, String trans})> neLyric(String id) async {
    if (id.isEmpty) throw Exception('id 不能为空');
    final res = await _request('$kApiBase/api/netease/song/lyric?id=${_enc(id)}');
    final data = res['data'] as Map?;
    return (
      lyric: (data?['lyric'] ?? '').toString(),
      trans: (data?['trans'] ?? '').toString(),
    );
  }

  static Future<({List<Song> list, String name, String desc, String pic})> nePlaylist(
    String id,
  ) async {
    if (id.isEmpty) throw Exception('id 不能为空');
    final res = await _request('$kApiBase/api/netease/playlist?id=${_enc(id)}');
    final data = res['data'] as Map?;
    return (
      list: parseSongsFull(data?['list']),
      name: (data?['name'] ?? '').toString(),
      desc: (data?['desc'] ?? '').toString(),
      pic: (data?['pic'] ?? '').toString(),
    );
  }

  static Future<bool> neValidateCookie(String cookie) async {
    final res = await _request(
      '$kApiBase/api/netease/validate-cookie',
      method: 'POST',
      body: jsonEncode({'cookie': sanitizeCookie(cookie)}),
    );
    return res['data']?['isValid'] == true;
  }

  static Future<Map<String, dynamic>?> neUserInfo() async {
    final res = await _request('$kApiBase/api/netease/userinfo');
    final data = res['data'];
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  // ------------------------------------------------------------ 代理地址

  static String getProxyImageUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    if (url.startsWith('$kApiBase/api/proxy/image')) return url;
    return '$kApiBase/api/proxy/image?url=${Uri.encodeComponent(url)}';
  }

  /// 推断音频扩展名。
  ///
  /// ⚠️ 这个后缀是**必需的**：`audioplayers_windows` 走 Media Foundation 的
  /// `CreateObjectFromURL`，它**靠 URL 路径后缀**挑选字节流处理器。
  /// 若代理地址形如 `/api/proxy/audio?url=...`（无后缀），会直接抛
  /// `PlatformException(WindowsAudioError, Failed to set source)`（0xC00D2EE3），
  /// 表现为「能取到流但播不出声」。
  static String _audioExt(String url) {
    const known = {'.mp3', '.m4a', '.flac', '.ogg', '.wav', '.aac', '.opus', '.wma'};
    final path = Uri.tryParse(url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    if (dot >= 0) {
      final ext = path.substring(dot).toLowerCase();
      if (known.contains(ext)) return ext;
    }
    return '.mp3';
  }

  static String getProxyAudioUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    if (url.startsWith('$kApiBase/api/proxy/audio')) return url;
    return '$kApiBase/api/proxy/audio${_audioExt(url)}'
        '?url=${Uri.encodeComponent(url)}';
  }

  // ------------------------------------------------------------ 下载 / 校验

  static Future<({String url, String filename})> downloadSong(
    Song song,
    String? filename,
  ) async {
    if (song.mid.isEmpty) throw Exception('song.mid 不能为空');
    final resp = await _http
        .post(
          Uri.parse('$kApiBase/api/song/download'),
          headers: _headers(),
          body: jsonEncode({'song': song.toApiJson(), 'filename': filename}),
        )
        .timeout(const Duration(seconds: 60));

    Map<String, dynamic> data;
    try {
      data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      data = {'error': '下载失败'};
    }
    if (resp.statusCode >= 300 || data['error'] != null) {
      throw Exception(data['error']?.toString() ?? '下载失败: ${resp.statusCode}');
    }
    final d = data['data'] as Map;
    return (
      url: (d['url'] ?? '').toString(),
      filename: (d['filename'] ?? '').toString(),
    );
  }

  /// 与原 `verifyCookie()` 一致：拿一首已知歌曲试取播放地址
  static Future<bool> verifyCookie(String cookie) async {
    final clean = sanitizeCookie(cookie);
    if (clean.isEmpty) throw Exception('Cookie 不能为空');

    final resp = await _http
        .post(
          Uri.parse('$kApiBase/api/song/url?mid=003aCYLn3L8H17&highQuality=true'),
          headers: {'Content-Type': 'application/json', 'X-QQMusic-Cookie': clean},
          body: '{}',
        )
        .timeout(const Duration(seconds: 60));

    if (resp.statusCode >= 300) {
      final s = resp.statusCode;
      if (s == 403) throw Exception('Cookie 已过期或无效');
      if (s == 401) throw Exception('Cookie 认证失败');
      if (s == 429) throw Exception('请求过于频繁');
      throw Exception('验证失败 ($s)');
    }
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final url = (data['data']?['url'] ?? '').toString();
    if (url.isNotEmpty) return true;
    throw Exception('Cookie 验证未通过');
  }

  static Future<bool> verifyNeteaseCookie(String cookie) async {
    final clean = sanitizeCookie(cookie);
    if (clean.isEmpty) throw Exception('Cookie 不能为空');
    final ok = await neValidateCookie(clean);
    if (ok) return true;
    throw Exception('Cookie 验证未通过');
  }

  static Future<void> sendErrorLog({
    required String message,
    String level = 'error',
    String stack = '',
    String url = '',
    String line = '',
    String col = '',
  }) async {
    try {
      await _http
          .post(
            Uri.parse('$kApiBase/api/log'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'level': level,
              'message': message,
              'stack': stack,
              'url': url,
              'line': line,
              'col': col,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }
}
