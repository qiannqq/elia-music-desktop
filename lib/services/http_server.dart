import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/app_paths.dart';
import '../core/file_logger.dart';
import '../models/song.dart';
import 'bilibili_service.dart';
import 'netease_service.dart';
import 'qqmusic_service.dart';

const Map<String, String> kMime = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
};

const String kDefaultUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 本地 HTTP API 服务 —— `electron/service/httpserver.js` 的 Dart 移植。
///
/// 端口、路由、请求头、响应体结构与原实现完全一致，
/// 便于沿用既有调试手段（curl 打接口）并保证行为不变。
class HttpServerService {
  HttpServerService();

  static final HttpServerService instance = HttpServerService();

  HttpServer? _server;
  int port = 17071;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

  bool get isRunning => _server != null;

  /// 启动服务并返回**实际监听端口**。
  ///
  /// 传 0（或不传）时由系统分配一个空闲端口 —— 这是默认行为，用于避免
  /// 与原版 Electron 的固定 17071 端口冲突（两个版本可同时运行）。
  Future<int> start([int p = 0]) async {
    if (_server != null) return port;
    try {
      final server =
          await HttpServer.bind(InternetAddress.loopbackIPv4, p, shared: false);
      _server = server;
      port = server.port;
      fileLogger.info('HTTP', 'Server running at http://127.0.0.1:$port');
      server.listen(_handle, onError: (Object e) {
        fileLogger.error('HTTP', 'listen error: $e');
      });
      return port;
    } catch (e) {
      fileLogger.error('HTTP', 'bind failed on $p: $e');
      rethrow;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  // ------------------------------------------------------------ 分发

  Future<void> _handle(HttpRequest req) async {
    final pathname = req.uri.path;
    final res = req.response;
    var responded = false;

    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.headers.set(
      'Access-Control-Allow-Headers',
      'Content-Type, X-QQMusic-Cookie, X-NetEase-Cookie',
    );

    if (req.method == 'OPTIONS') {
      res.statusCode = 200;
      await res.close();
      return;
    }

    final sw = Stopwatch()..start();
    try {
      if (pathname.startsWith('/api/')) {
        await _handleApi(req, res, pathname);
      } else {
        await _serveStatic(req, res, pathname);
      }
      responded = true;
      // 请求级日志：这样「某次搜索/取歌词慢或失败」在日志里能直接看到，
      // 不用靠猜（发行版出问题时日志里什么都没有，是排查不了的）。
      // 封面图代理不记（一次搜索会打几十条，纯噪音），失败时仍会走下面的 catch。
      if (pathname.startsWith('/api/') && !pathname.startsWith('/api/proxy/image')) {
        final ms = sw.elapsedMilliseconds;
        if (ms >= 3000) {
          fileLogger.warn('HTTP', '${req.method} $pathname 慢 ${ms}ms');
        } else {
          fileLogger.debug('HTTP', '${req.method} $pathname ${ms}ms');
        }
      }
    } catch (e, st) {
      // 带上方法与路由，便于定位是哪一条接口挂了
      fileLogger.error('HTTP',
          '${req.method} $pathname → $e（${sw.elapsedMilliseconds}ms）');
      fileLogger.error('HTTP', 'Stack: $st');
      if (!responded) {
        try {
          _json(res, {'error': e.toString()}, 500);
        } catch (_) {}
      }
    }
  }

  void _json(HttpResponse res, Object? data, [int status = 200]) {
    res.statusCode = status;
    res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    res.write(jsonEncode(data));
    res.close();
  }

  // ------------------------------------------------------------ 静态资源

  Future<void> _serveStatic(HttpRequest req, HttpResponse res, String pathname) async {
    var filePath = pathname;
    if (filePath == '/') filePath = '/index.html';

    final distDir = '${AppPaths.appDir}${Platform.pathSeparator}public'
        '${Platform.pathSeparator}dist';
    final full = distDir + filePath.replaceAll('/', Platform.pathSeparator);
    final resolved = File(full).absolute.path;

    if (!resolved.startsWith(File(distDir).absolute.path)) {
      res.statusCode = 403;
      res.write('Forbidden');
      await res.close();
      return;
    }

    final f = File(resolved);
    if (!f.existsSync()) {
      res.statusCode = 404;
      res.write('Not Found');
      await res.close();
      return;
    }

    final ext = resolved.contains('.') ? resolved.substring(resolved.lastIndexOf('.')) : '';
    res.statusCode = 200;
    res.headers.set('Content-Type', kMime[ext.toLowerCase()] ?? 'application/octet-stream');
    res.headers.set('Cache-Control', 'no-cache');
    await res.addStream(f.openRead());
    await res.close();
  }

  // ------------------------------------------------------------ 请求辅助

  /// 按目标 URL 判断它属于哪个源。
  ///
  /// 代理转发时必须带上**对应源**的 Referer：三家 CDN 都会校验，
  /// 给 B 站的图/流带上 `y.qq.com` 的 Referer 会被直接拒掉。
  static String _sourceOfUrl(String url) {
    if (url.contains('music.126.net') || url.contains('music.163.com')) {
      return 'netease';
    }
    if (url.contains('hdslb.com') ||
        url.contains('bilivideo') ||
        url.contains('bilibili.com')) {
      return 'bilibili';
    }
    return 'qq';
  }

  static String _refererOf(String source) => switch (source) {
        'netease' => 'https://music.163.com/',
        'bilibili' => 'https://www.bilibili.com/',
        _ => 'https://y.qq.com/',
      };

  /// 按音源取播放地址。三个源各有一套取流方式，集中在这里分发，
  /// 免得每加一个源就要在好几处复制一遍同样的 if/else。
  Future<String> _resolvePlayUrl(Song song, {required bool hq}) {
    switch (song.source) {
      case 'netease':
        return neteaseMusicService.getMusicUrl(
          song,
          quality: hq ? 'exhigh' : 'standard',
        );
      case 'bilibili':
        // B 站音频不分档，服务端已经挑了带宽最高的那条
        return bilibiliService.getAudioUrl(song);
      default:
        return qqMusicService.getMusicUrl(song, highQuality: hq);
    }
  }

  String _qqCookie(HttpRequest req) {
    final cookie = req.headers.value('x-qqmusic-cookie') ?? '';
    if (cookie.isNotEmpty) qqMusicService.setCookie(cookie);
    return cookie;
  }

  String _neCookie(HttpRequest req) {
    final cookie = req.headers.value('x-netease-cookie') ?? '';
    if (cookie.isNotEmpty) neteaseMusicService.setCookie(cookie);
    return cookie;
  }

  Future<Map<String, dynamic>> _getBody(HttpRequest req) async {
    try {
      final text = await utf8.decoder.bind(req).join();
      if (text.trim().isEmpty) return {};
      final v = jsonDecode(text);
      return v is Map ? v.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }

  // ------------------------------------------------------------ 路由

  Future<void> _handleApi(HttpRequest req, HttpResponse res, String pathname) async {
    final key = '${req.method}:$pathname';
    final url = req.uri;
    final q = url.queryParameters;

    // 代理路由用**前缀匹配**：客户端会在路径上带音频后缀
    // （`/api/proxy/audio.mp3?url=...`），因为 audioplayers 的 Windows 后端
    // 依赖 URL 后缀来判断容器格式。同时保留无后缀的旧路径以兼容。
    if (req.method == 'GET') {
      if (pathname.startsWith('/api/proxy/audio')) {
        return _apiProxyAudio(req, res, q);
      }
      if (pathname.startsWith('/api/proxy/image')) {
        return _apiProxyImage(req, res, q);
      }
    }

    switch (key) {
      case 'GET:/api/search':
        return _apiSearch(req, res, q);
      case 'POST:/api/song/url':
        return _apiSongUrl(req, res);
      case 'POST:/api/song/batch-url':
        return _apiBatchUrl(req, res);
      case 'GET:/api/song/detail':
        return _apiSongDetail(req, res, q);
      case 'GET:/api/song/lyric':
        return _apiLyric(req, res, q);
      case 'GET:/api/playlist':
        return _apiPlaylist(req, res, q);
      case 'POST:/api/parse-url':
        return _apiParseUrl(req, res);
      case 'POST:/api/song/download':
        return _apiDownload(req, res);
      case 'GET:/api/proxy/image':
        return _apiProxyImage(req, res, q);
      case 'GET:/api/proxy/audio':
        return _apiProxyAudio(req, res, q);
      case 'GET:/api/cookie-status':
        return _apiCookieStatus(req, res);
      case 'POST:/api/set-cookie':
        return _apiSetCookie(req, res);
      case 'GET:/api/download':
        return _apiLegacyDownload(req, res, q);
      case 'POST:/api/log':
        return _apiLog(req, res);
      case 'GET:/api/netease/search':
        return _apiNeteaseSearch(req, res, q);
      case 'POST:/api/netease/song/url':
        return _apiNeteaseSongUrl(req, res);
      case 'GET:/api/netease/song/lyric':
        return _apiNeteaseLyric(req, res, q);
      case 'GET:/api/netease/playlist':
        return _apiNeteasePlaylist(req, res, q);
      case 'POST:/api/netease/validate-cookie':
        return _apiNeteaseValidateCookie(req, res);
      case 'GET:/api/netease/userinfo':
        return _apiNeteaseUserInfo(req, res);
      case 'POST:/api/netease/set-cookie':
        return _apiNeteaseSetCookie(req, res);
      default:
        return _json(res, {'error': 'Not Found'}, 404);
    }
  }

  // ------------------------------------------------------------ QQ 音乐

  Future<void> _apiSearch(HttpRequest req, HttpResponse res, Map<String, String> q) async {
    _qqCookie(req);
    final keyword = q['keyword'] ?? '';
    final page = int.tryParse(q['page'] ?? '1') ?? 1;
    final pageSize = int.tryParse(q['pageSize'] ?? '50') ?? 50;
    final sw = Stopwatch()..start();
    final result = await qqMusicService.search(keyword, page, pageSize);
    // 记下条数：这样「0 条」与「报错」在日志里能区分开
    //（点搜索转圈之后既没结果也没报错，是两种原因，必须能分辨）
    fileLogger.info('Search',
        'qq keyword="$keyword" page=$page → ${result.list.length} 首'
        '（total=${result.total}, ${sw.elapsedMilliseconds}ms）');
    _json(res, {
      'code': 0,
      'data': result.list.map((e) => _songToJson(e)).toList(),
      'total': result.total,
    });
  }

  Future<void> _apiSongUrl(HttpRequest req, HttpResponse res) async {
    _qqCookie(req);
    _neCookie(req);
    final q = req.uri.queryParameters;
    final mid = q['mid'] ?? '';
    final hq = q['highQuality'] == 'true';
    final body = await _getBody(req);

    final song = _songFromBody(body['song'], mid);
    final playUrl = await _resolvePlayUrl(song, hq: hq);
    _json(res, {
      'code': 0,
      'data': {'url': playUrl, 'mid': mid},
    });
  }

  Future<void> _apiBatchUrl(HttpRequest req, HttpResponse res) async {
    _qqCookie(req);
    _neCookie(req);
    final body = await _getBody(req);
    final songs = (body['songs'] as List?) ?? const [];
    final hq = body['highQuality'] == true;

    final results = await Future.wait(songs.map((raw) async {
      final song = _songFromBody(raw, '');
      try {
        final url = await _resolvePlayUrl(song, hq: hq);
        return {..._songToJson(song), 'url': url, 'success': true};
      } catch (e) {
        return {..._songToJson(song), 'url': '', 'success': false, 'error': e.toString()};
      }
    }));

    _json(res, {'code': 0, 'data': results});
  }

  Future<void> _apiSongDetail(HttpRequest req, HttpResponse res, Map<String, String> q) async {
    _qqCookie(req);
    final mid = q['mid'] ?? '';
    final hq = q['highQuality'] == 'true';
    final song = await qqMusicService.getFirstSong(mid, pageSize: 1);
    if (song == null) return _json(res, {'error': '歌曲不存在'}, 404);
    final playUrl = await qqMusicService.getMusicUrl(song, highQuality: hq);
    _json(res, {
      'code': 0,
      'data': {..._songToJson(song), 'url': playUrl},
    });
  }

  Future<void> _apiLyric(HttpRequest req, HttpResponse res, Map<String, String> q) async {
    _qqCookie(req);
    _neCookie(req);
    final mid = q['mid'] ?? '';
    final source = q['source'] ?? 'qq';
    final lyric = source == 'netease'
        ? await neteaseMusicService.getLyric(_songFromBody(null, mid, source: 'netease'))
        : await qqMusicService.getLyric(_songFromBody(null, mid));
    _json(res, {
      'code': 0,
      'data': {'lyric': lyric.lyric, 'trans': lyric.trans},
    });
  }

  Future<void> _apiPlaylist(HttpRequest req, HttpResponse res, Map<String, String> q) async {
    _qqCookie(req);
    final data = await qqMusicService.getPlaylist(q['id'] ?? '');
    _json(res, {
      'code': 0,
      'data': {
        'list': data.list.map((e) => _songToJson(e)).toList(),
        'name': data.name,
        'desc': data.desc,
        'pic': data.pic,
      }
    });
  }

  Future<void> _apiParseUrl(HttpRequest req, HttpResponse res) async {
    final body = await _getBody(req);
    final inputUrl = (body['url'] ?? '').toString().trim();
    if (inputUrl.isEmpty) return _json(res, {'error': 'URL 不能为空'}, 400);

    final patterns = <String, List<RegExp>>{
      'playlist': [RegExp(r'playlist/(\d+)'), RegExp(r'[?&]id=(\d+)')],
      'song': [RegExp(r'song/(\w+)\.html'), RegExp(r'song/(\w+)$')],
      'album': [RegExp(r'album/(\w+)\.html'), RegExp(r'album/(\w+)$')],
    };

    for (final entry in patterns.entries) {
      for (final re in entry.value) {
        final m = re.firstMatch(inputUrl);
        if (m != null && m.group(1) != null) {
          return _json(res, {
            'code': 0,
            'data': {'type': entry.key, 'id': m.group(1)}
          });
        }
      }
    }
    if (RegExp(r'^\d+$').hasMatch(inputUrl)) {
      return _json(res, {
        'code': 0,
        'data': {'type': 'playlist', 'id': inputUrl}
      });
    }
    _json(res, {'error': '无法识别的 URL 格式'}, 400);
  }

  Future<void> _apiDownload(HttpRequest req, HttpResponse res) async {
    _qqCookie(req);
    _neCookie(req);
    final body = await _getBody(req);
    final song = _songFromBody(body['song'], '');
    final filename = body['filename']?.toString();

    fileLogger.info('Download', 'song="${song.name}" mid=${song.mid} source=${song.source}');

    final playUrl = await _resolvePlayUrl(song, hq: true);
    if (playUrl.isEmpty) return _json(res, {'error': '无法获取播放链接'}, 500);

    _json(res, {
      'code': 0,
      'data': {
        'url': playUrl,
        'filename': (filename != null && filename.isNotEmpty)
            ? filename
            : '${song.name} - ${song.artist}.mp3',
      }
    });
  }

  // ------------------------------------------------------------ 代理

  Future<void> _apiProxyImage(HttpRequest req, HttpResponse res, Map<String, String> q) async {
    try {
      final rawUrl = q['url'];
      if (rawUrl == null || rawUrl.isEmpty) {
        res.statusCode = 400;
        await res.close();
        return;
      }
      final targetUrl = Uri.decodeComponent(rawUrl);
      final referer = _refererOf(_sourceOfUrl(targetUrl));

      final up = await _client.getUrl(Uri.parse(targetUrl));
      up.headers.set('Referer', referer);
      up.headers.set('User-Agent', kDefaultUa);
      up.headers.set('Accept', 'image/webp,image/apng,image/*,*/*;q=0.8');
      final upRes = await up.close();

      if (upRes.statusCode < 200 || upRes.statusCode >= 300) {
        res.statusCode = upRes.statusCode;
        await res.close();
        return;
      }

      res.statusCode = 200;
      res.headers.set(
        'Content-Type',
        upRes.headers.contentType?.toString() ?? 'image/jpeg',
      );
      res.headers.set('Cache-Control', 'public, max-age=86400');
      res.headers.set('Access-Control-Allow-Origin', '*');
      final len = upRes.headers.contentLength;
      if (len > 0) res.headers.set('Content-Length', '$len');
      await res.addStream(upRes);
      await res.close();
    } catch (e) {
      fileLogger.error('ImageProxy', 'Error: $e');
      try {
        res.statusCode = 500;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _apiProxyAudio(HttpRequest req, HttpResponse res, Map<String, String> q) async {
    final rawUrl = q['url'];
    if (rawUrl == null || rawUrl.isEmpty) {
      res.statusCode = 400;
      await res.close();
      return;
    }
    final targetUrl = Uri.decodeComponent(rawUrl);
    _qqCookie(req);

    final rangeHeader = req.headers.value('range');
    try {
      final src = _sourceOfUrl(targetUrl);
      final referer = _refererOf(src);
      // B 站取流不需要 ck（也不该带 QQ 的）
      final cookie = switch (src) {
        'netease' => neteaseMusicService.cookie,
        'bilibili' => '',
        _ => qqMusicService.cookie,
      };

      final up = await _client.getUrl(Uri.parse(targetUrl));
      up.headers.set('Referer', referer);
      up.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
      if (cookie.isNotEmpty) up.headers.set('Cookie', cookie);
      if (rangeHeader != null) up.headers.set('Range', rangeHeader);

      final upRes = await up.close();
      final ct = upRes.headers.contentType?.toString() ?? '';
      final cl = upRes.headers.contentLength;
      final cr = upRes.headers.value('content-range');

      if (upRes.statusCode != 200 && upRes.statusCode != 206) {
        fileLogger.error(
          'AudioProxy',
          'Failed: HTTP ${upRes.statusCode} target=${targetUrl.substring(0, targetUrl.length.clamp(0, 250))}',
        );
        res.statusCode = upRes.statusCode;
        await res.close();
        return;
      }

      // B 站的音频流是 fMP4（路径以 `.m4s` 结尾），CDN 会把它标成
      // **`video/mp4`** —— 里面确实只有音频，只是容器格式跟视频一样。
      // 不认它的话这里会回 415，播放器拿到 415 就报
      // `MediaEngine error 0xC00D2EFE`，表现成「取到流了但播不出来」。
      final isMp4 = ct.contains('mp4') || ct.contains('m4a');
      if (upRes.statusCode != 206 &&
          !ct.contains('audio') &&
          !ct.contains('octet-stream') &&
          !ct.contains('mpeg') &&
          !isMp4) {
        fileLogger.error('AudioProxy', 'Non-audio Content-Type: $ct');
        res.statusCode = 415;
        await res.close();
        return;
      }

      res.statusCode = upRes.statusCode;
      // Content-Type 按**请求路径的后缀**来定，不信上游那个值 ——
      // 同一个音频流，CDN 有时回 `video/mp4`（B站的 `.m4s` 就是这种）、
      // 有时回 `application/octet-stream`，飘得很。而路径后缀是我们自己
      // 拼的（见 `ApiClient._audioExt`），稳定。
      final ext = req.uri.path.split('.').last.toLowerCase();
      res.headers.set('Content-Type', switch (ext) {
        'm4a' || 'mp4' => 'audio/mp4',
        'mp3' => 'audio/mpeg',
        'flac' => 'audio/flac',
        'ogg' || 'opus' => 'audio/ogg',
        'wav' => 'audio/wav',
        'aac' => 'audio/aac',
        _ => (ct.isNotEmpty ? ct : 'audio/mpeg'),
      });
      res.headers.set('Accept-Ranges', 'bytes');
      res.headers.set('Access-Control-Allow-Origin', '*');
      if (cr != null) res.headers.set('Content-Range', cr);
      if (cl > 0) res.headers.set('Content-Length', '$cl');

      var total = 0;
      await for (final chunk in upRes) {
        res.add(chunk);
        total += chunk.length;
      }
      await res.close();
      fileLogger.info('AudioProxy', 'Done: $total bytes');
    } catch (e) {
      fileLogger.error('AudioProxy', 'Error: $e');
      try {
        res.statusCode = 500;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _apiLegacyDownload(
    HttpRequest req,
    HttpResponse res,
    Map<String, String> q,
  ) async {
    _qqCookie(req);
    final targetUrl = Uri.decodeComponent(q['url'] ?? '');
    final filename = q['filename'] ?? 'download.mp3';

    final up = await _client.getUrl(Uri.parse(targetUrl));
    up.headers.set('Referer', 'https://y.qq.com/');
    up.headers.set('User-Agent', 'Mozilla/5.0');
    if (qqMusicService.cookie.isNotEmpty) up.headers.set('Cookie', qqMusicService.cookie);
    final upRes = await up.close();

    if (upRes.statusCode < 200 || upRes.statusCode >= 300) {
      return _json(res, {'error': '获取音频失败: ${upRes.statusCode}'}, 500);
    }

    final ascii = filename.replaceAll(RegExp(r'[^\x20-\x7E]'), '_');
    res.headers.set(
      'Content-Disposition',
      'attachment; filename="$ascii"; filename*=UTF-8\'\'${Uri.encodeComponent(filename)}',
    );
    res.headers
        .set('Content-Type', upRes.headers.contentType?.toString() ?? 'audio/mpeg');
    await res.addStream(upRes);
    await res.close();
  }

  // ------------------------------------------------------------ Cookie

  Future<void> _apiCookieStatus(HttpRequest req, HttpResponse res) async {
    final hasCookie = qqMusicService.cookie.isNotEmpty;
    var isValid = false;
    if (hasCookie) {
      try {
        isValid = await qqMusicService.validateCookie();
      } catch (_) {}
    }
    _json(res, {
      'code': 0,
      'data': {'hasCookie': hasCookie, 'isValid': isValid, 'needClientCookie': !isValid}
    });
  }

  Future<void> _apiSetCookie(HttpRequest req, HttpResponse res) async {
    final body = await _getBody(req);
    final cookie = body['cookie']?.toString() ?? '';
    if (cookie.isEmpty) return _json(res, {'error': 'cookie 不能为空'}, 400);
    qqMusicService.setCookie(cookie);
    final isValid = await qqMusicService.validateCookie();
    _json(res, {
      'code': 0,
      'data': {'isValid': isValid}
    });
  }

  Future<void> _apiLog(HttpRequest req, HttpResponse res) async {
    final body = await _getBody(req);
    final level = (body['level'] ?? 'error').toString();
    final message = (body['message'] ?? '').toString();
    final stack = (body['stack'] ?? '').toString();
    final url = (body['url'] ?? '').toString();
    final line = (body['line'] ?? '').toString();
    final col = (body['col'] ?? '').toString();

    final prefix = '[Renderer ${level.toUpperCase()}]';
    final location = url.isNotEmpty
        ? ' ($url${line.isNotEmpty ? ':$line' : ''}${col.isNotEmpty ? ':$col' : ''})'
        : '';
    fileLogger.error('Renderer', '$prefix $message$location');
    if (stack.isNotEmpty) fileLogger.error('Renderer', 'Stack: $stack');

    _json(res, {'code': 0});
  }

  // ------------------------------------------------------------ 网易云

  Future<void> _apiNeteaseSearch(HttpRequest req, HttpResponse res, Map<String, String> q) async {
    _neCookie(req);
    final keyword = q['keyword'] ?? '';
    final page = int.tryParse(q['page'] ?? '1') ?? 1;
    final pageSize = int.tryParse(q['pageSize'] ?? '30') ?? 30;
    final sw = Stopwatch()..start();
    final result = await neteaseMusicService.search(keyword, page, pageSize);
    fileLogger.info('Search',
        'netease keyword="$keyword" page=$page → ${result.list.length} 首'
        '（total=${result.total}, ${sw.elapsedMilliseconds}ms）');
    _json(res, {
      'code': 0,
      'data': result.list.map((e) => _songToJson(e)).toList(),
      'total': result.total,
    });
  }

  Future<void> _apiNeteaseSongUrl(HttpRequest req, HttpResponse res) async {
    _neCookie(req);
    final body = await _getBody(req);
    final song = _songFromBody(body['song'], '');
    if (song.mid.isEmpty) return _json(res, {'error': 'song.id 不能为空'}, 400);
    final url = await neteaseMusicService.getMusicUrl(
      song,
      quality: (body['quality'] ?? 'exhigh').toString(),
    );
    _json(res, {
      'code': 0,
      'data': {'url': url, 'id': song.mid}
    });
  }

  Future<void> _apiNeteaseLyric(HttpRequest req, HttpResponse res, Map<String, String> q) async {
    _neCookie(req);
    final id = q['id'] ?? '';
    if (id.isEmpty) return _json(res, {'error': 'id 不能为空'}, 400);
    final lyric = await neteaseMusicService.getLyric(_songFromBody(null, id, source: 'netease'));
    _json(res, {
      'code': 0,
      'data': {'lyric': lyric.lyric, 'trans': lyric.trans}
    });
  }

  Future<void> _apiNeteasePlaylist(HttpRequest req, HttpResponse res, Map<String, String> q) async {
    _neCookie(req);
    final id = q['id'] ?? '';
    if (id.isEmpty) return _json(res, {'error': 'id 不能为空'}, 400);
    final data = await neteaseMusicService.getPlaylist(id);
    _json(res, {
      'code': 0,
      'data': {
        'list': data.list.map((e) => _songToJson(e)).toList(),
        'name': data.name,
        'desc': data.desc,
        'pic': data.pic,
      }
    });
  }

  Future<void> _apiNeteaseValidateCookie(
    HttpRequest req,
    HttpResponse res,
  ) async {
    final body = await _getBody(req);
    final cookie = body['cookie']?.toString() ?? '';
    if (cookie.isEmpty) return _json(res, {'error': 'cookie 不能为空'}, 400);
    neteaseMusicService.setCookie(cookie);
    final isValid = await neteaseMusicService.validateCookie();
    _json(res, {
      'code': 0,
      'data': {'isValid': isValid}
    });
  }

  Future<void> _apiNeteaseUserInfo(HttpRequest req, HttpResponse res) async {
    _neCookie(req);
    final info = await neteaseMusicService.getUserInfo();
    _json(res, {'code': 0, 'data': info});
  }

  Future<void> _apiNeteaseSetCookie(HttpRequest req, HttpResponse res) async {
    final body = await _getBody(req);
    final cookie = body['cookie']?.toString() ?? '';
    if (cookie.isEmpty) return _json(res, {'error': 'cookie 不能为空'}, 400);
    neteaseMusicService.setCookie(cookie);
    final isValid = await neteaseMusicService.validateCookie();
    _json(res, {
      'code': 0,
      'data': {'isValid': isValid}
    });
  }
}

final httpServerService = HttpServerService.instance;

// ---------------------------------------------------------------- 序列化辅助

/// 等价原 `normalizeSong()` 的输出结构，前端（Dart UI 层）按此解析。
Map<String, dynamic> _songToJson(Song s) => {
      'id': s.mid,
      'mid': s.mid,
      'mediaMid': s.mediaMid,
      'name': s.name,
      'artist': s.artist,
      'pic': s.pic,
      'link': s.link,
      'source': s.source,
      if (s.fee != 0) 'fee': s.fee,
      if (s.duration != 0) 'duration': s.duration,
      if (s.album.isNotEmpty) 'album': s.album,
      if (s.raw.isNotEmpty) 'raw': s.raw,
      if (s.raw.isNotEmpty) 'data': s.raw,
    };

/// 反序列化请求体中的 song 对象（raw 保留，供取 vkey 时读 media_mid）
Song _songFromBody(Object? raw, String mid, {String source = 'qq'}) {
  if (raw is Map) {
    final m = raw.cast<String, dynamic>();
    final rawData = m['raw'] ?? m['data'];
    return Song(
      mid: (m['mid'] ?? m['id'] ?? mid).toString(),
      name: (m['name'] ?? '').toString(),
      artist: (m['artist'] ?? '').toString(),
      pic: (m['pic'] ?? '').toString(),
      link: (m['link'] ?? '').toString(),
      mediaMid: (m['mediaMid'] ?? '').toString(),
      source: (m['source'] ?? source).toString(),
      fee: (m['fee'] as num?)?.toInt() ?? 0,
      duration: (m['duration'] as num?)?.toInt() ?? 0,
      album: (m['album'] ?? '').toString(),
      raw: rawData is Map ? rawData.cast<String, dynamic>() : const {},
    );
  }
  return Song(mid: mid, name: '', artist: '', source: source);
}

