import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/file_logger.dart';
import '../core/local_store.dart';
import '../models/song.dart';
import 'netease_service.dart';

/// 本地 API 基地址。
///
/// 端口**不固定**：启动时由系统分配一个空闲端口（绑定端口 0），
/// 避免与原版 Electron 的固定 17071 冲突 —— 两个版本可同时运行。
/// 因此这里是变量而非常量，由 main() 调用 [setApiPort] 写入。
String apiBase = 'http://127.0.0.1:17071';

/// 由 main() 在 HTTP 服务启动后写入实际端口
void setApiPort(int port) => apiBase = 'http://127.0.0.1:$port';

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

  /// 只保留路径用于日志（避免把超长 query 写进日志）
  static String _label(String url) => Uri.tryParse(url)?.path ?? url;

  static String _clip(String s, [int n = 200]) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

  static Future<Map<String, dynamic>> _request(
    String url, {
    String method = 'GET',
    Object? body,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final h = _headers(headers);
    final sw = Stopwatch()..start();
    final label = _label(url);
    late http.Response resp;
    try {
      if (method == 'POST') {
        resp = await _http
            .post(Uri.parse(url), headers: h, body: body ?? '{}')
            .timeout(timeout);
      } else {
        resp = await _http.get(Uri.parse(url), headers: h).timeout(timeout);
      }
    } on TimeoutException {
      fileLogger.error('API',
          '$method $label 超时（上限 ${timeout.inSeconds}s，已等待 ${sw.elapsedMilliseconds}ms）');
      rethrow;
    } catch (e) {
      fileLogger.error('API',
          '$method $label 请求失败: $e（已用 ${sw.elapsedMilliseconds}ms）');
      rethrow;
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
      fileLogger.error('API',
          '$method $label HTTP ${resp.statusCode}（${sw.elapsedMilliseconds}ms）: ${_clip(text)}');
      Map<String, dynamic> err = {};
      try {
        err = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {}
      throw Exception(err['error']?.toString() ?? '请求失败: ${resp.statusCode}');
    }
    fileLogger.debug('API', '$method $label OK ${resp.statusCode} ${sw.elapsedMilliseconds}ms');
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
      '$apiBase/api/search?keyword=${_enc(keyword)}&page=$page&pageSize=$pageSize',
    );
    return (
      list: parseSongsFull(res['data']),
      total: (res['total'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<String> getSongUrl(String mid, bool highQuality, Song? songData) async {
    if (mid.isEmpty) throw Exception('mid 不能为空');
    final url = '$apiBase/api/song/url?mid=${_enc(mid)}&highQuality=$highQuality';
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
      '$apiBase/api/song/batch-url',
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
      '$apiBase/api/song/detail?mid=${_enc(mid)}&highQuality=$highQuality',
    );
    final data = res['data'];
    if (data is! Map) return null;
    return parseSongsFull([data]).firstOrNull;
  }

  static Future<({String lyric, String trans})> getLyric(String mid, [String? source]) async {
    if (mid.isEmpty) throw Exception('mid 不能为空');
    var url = '$apiBase/api/song/lyric?mid=${_enc(mid)}';
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
    final res = await _request('$apiBase/api/playlist?id=${_enc(id)}');
    final data = res['data'] as Map?;
    return (
      list: parseSongsFull(data?['list']),
      name: (data?['name'] ?? '').toString(),
      desc: (data?['desc'] ?? '').toString(),
      pic: (data?['pic'] ?? '').toString(),
    );
  }

  static Future<Map<String, dynamic>> parseUrl(String url) =>
      _request('$apiBase/api/parse-url', method: 'POST', body: jsonEncode({'url': url}));

  static Future<bool> setCookie(String cookie) async {
    final res = await _request(
      '$apiBase/api/set-cookie',
      method: 'POST',
      body: jsonEncode({'cookie': sanitizeCookie(cookie)}),
    );
    return res['data']?['isValid'] == true;
  }

  static Future<Map<String, dynamic>> getCookieStatus() =>
      _request('$apiBase/api/cookie-status');

  // ------------------------------------------------------------ 网易云

  static Future<({List<Song> list, int total})> neSearch(
    String keyword, [
    int page = 1,
    int pageSize = 30,
  ]) async {
    if (keyword.isEmpty) throw Exception('keyword 不能为空');
    final res = await _request(
      '$apiBase/api/netease/search?keyword=${_enc(keyword)}&page=$page&pageSize=$pageSize',
    );
    return (
      list: parseSongsFull(res['data']),
      total: (res['total'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<String> neSongUrl(Song song, [String quality = 'exhigh']) async {
    if (song.mid.isEmpty) throw Exception('song.id 不能为空');
    final res = await _request(
      '$apiBase/api/netease/song/url',
      method: 'POST',
      body: jsonEncode({'song': song.toApiJson(), 'quality': quality}),
    );
    return (res['data']?['url'] ?? '').toString();
  }

  static Future<({String lyric, String trans})> neLyric(String id) async {
    if (id.isEmpty) throw Exception('id 不能为空');
    final res = await _request('$apiBase/api/netease/song/lyric?id=${_enc(id)}');
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
    final res = await _request('$apiBase/api/netease/playlist?id=${_enc(id)}');
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
      '$apiBase/api/netease/validate-cookie',
      method: 'POST',
      body: jsonEncode({'cookie': sanitizeCookie(cookie)}),
    );
    return res['data']?['isValid'] == true;
  }

  static Future<Map<String, dynamic>?> neUserInfo() async {
    final res = await _request('$apiBase/api/netease/userinfo');
    final data = res['data'];
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  // ------------------------------------------------------------ 代理地址

  static String getProxyImageUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    if (url.startsWith('$apiBase/api/proxy/image')) return url;
    return '$apiBase/api/proxy/image?url=${Uri.encodeComponent(url)}';
  }

  /// 推断音频扩展名。
  ///
  /// 这个后缀是**必需的**：`audioplayers_windows` 走 Media Foundation 的
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
      // B 站的音频流路径以 .m4s 结尾（fMP4 封装的 AAC）。
      // 直接把 .m4s 交给 Media Foundation 它不认，用 .m4a 才行。
      if (ext == '.m4s') return '.m4a';
    }
    return '.mp3';
  }

  static String getProxyAudioUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    if (url.startsWith('$apiBase/api/proxy/audio')) return url;
    return '$apiBase/api/proxy/audio${_audioExt(url)}'
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
          Uri.parse('$apiBase/api/song/download'),
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

  static Future<bool> verifyNeteaseCookie(String cookie) async {
    // 纯值也认（会自动补上 `MUSIC_U=`）。这里和保存走同一套整理规则，
    // 免得出现「校验时按纯值、保存时按整串」两边不一致。
    final clean = NeteaseMusicService.normalizeCookie(cookie);
    if (clean.isEmpty) throw Exception('Cookie 不能为空');
    if (!clean.contains('MUSIC_U=')) {
      throw Exception('这段内容里没有 MUSIC_U，请粘贴完整 cookie 或 MUSIC_U 的值');
    }
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
            Uri.parse('$apiBase/api/log'),
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
