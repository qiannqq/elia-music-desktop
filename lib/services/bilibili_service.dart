import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../core/file_logger.dart';
import '../models/song.dart';

/// Bilibili 音源。
///
/// 全程不需要 ck —— 实测未登录（nav 返回 -101）时搜索与 playurl 依然正常，
/// 音频质量也不受影响。唯一的例外是**字幕**：游客身份下
/// `subtitle.subtitles` 恒为空（试了 12 个视频，连标题写着「中英字幕」的
/// 也是空数组），所以歌词按「有就显示、没有就不显示」处理。
class BilibiliService {
  BilibiliService._();
  static final BilibiliService instance = BilibiliService._();

  static const String _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const String _host = 'https://api.bilibili.com';

  /// wbi 签名的字符重排表 —— 官方前端的固定值。
  static const List<int> _mixinKeyEncTab = <int>[
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5,
    49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
  ];

  /// 参与 wbi 计算的参数要先把这几个字符剔除
  static final RegExp _chrFilter = RegExp(r"[!'()*]");

  /// BV 号：BV + 10 位 base58
  static final RegExp bvPattern = RegExp(r'^BV[0-9A-Za-z]{10}$');

  /// 登录后的 cookie（`SESSDATA=xxx; bili_jct=xxx; ...`）。
  ///
  /// 不配也能用：搜索、取流、字幕都按游客身份走。配上之后有三点好处 ——
  ///  * 搜索走**登录态**排序，和网页端一致（游客态 B 站给的是另一套排序）；
  ///  * 能拿到自己投稿里的**私密视频**（普通搜索搜不到）；
  ///  * 更不容易撞 gaia 风控。
  String cookie = '';

  /// 把用户填的东西整理成可用的 cookie。
  ///
  /// 三种写法都认（跟网易云那边同一套思路）：
  ///  * 完整 cookie 串（`buvid3=...; SESSDATA=xxx; ...`）—— 原样用；
  ///  * 键值（`SESSDATA=xxx`）—— 原样用；
  ///  * 纯值（只有 SESSDATA 那一串）—— 补上 `SESSDATA=`。
  ///
  /// 判据是「有没有等号」：cookie 一定是 `名字=值`，而 SESSDATA 的值是
  /// 一长串带 `%2C` 的编码，里面不会有等号。
  static String normalizeCookie(String raw) {
    final s = raw.replaceAll(RegExp(r'[\r\n\t\x00]'), '').trim();
    if (s.isEmpty) return '';
    return s.contains('=') ? s : 'SESSDATA=$s';
  }

  BilibiliService setCookie(String value) {
    cookie = normalizeCookie(value);
    return this;
  }

  String _buvid3 = '';
  String _buvid4 = '';
  bool _buvidActivated = false;
  String _mixinKey = '';
  DateTime? _mixinKeyAt;

  /// 上一次请求的时刻，用来给请求之间留最小间隔。
  /// B 站对高频请求很敏感（尤其搜索），隔开一点能明显少撞风控。
  DateTime? _lastRequestAt;
  static const Duration _minRequestGap = Duration(milliseconds: 350);

  final Random _random = Random();

  /// gaia 风控的返回码。撞上时接口不给数据、只给这个码 ——
  /// 得让用户知道「是被拦了」，而不是「没搜到」。
  static const Set<int> _riskCodes = <int>{-352, -412, -509};

  /// 视频的 aid + cid。取流时**两个都要**：
  /// playurl 只认真实的 avid，只传 bvid（或把 avid 填 0）会被风控回 412。
  final Map<String, ({int aid, int cid})> _infoCache =
      <String, ({int aid, int cid})>{};

  Map<String, String> _headers({String? referer, String? origin}) {
    final h = <String, String>{
      'User-Agent': _ua,
      'Referer': referer ?? 'https://www.bilibili.com',
      // 下面这几个是浏览器一定会带的。缺了它们，请求看起来就像脚本 ——
      // 这是 gaia 风控最容易抓的特征之一。
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Origin': origin ?? 'https://www.bilibili.com',
      'Sec-Fetch-Dest': 'empty',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Site': 'same-site',
    };
    final parts = <String>[
      if (_buvid3.isNotEmpty) 'buvid3=$_buvid3',
      if (_buvid4.isNotEmpty) 'buvid4=$_buvid4',
      // 登录 cookie 整段接在后面：它自己就是 `a=1; b=2` 的形式
      if (cookie.isNotEmpty) cookie,
    ];
    if (parts.isNotEmpty) h['Cookie'] = parts.join('; ');
    return h;
  }

  Future<Map<String, dynamic>> _getJson(
    String url, {
    Map<String, String>? headers,
    String? body,
    int attempts = 3,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final h = {..._headers(), ...?headers};
    if (body != null) h['Content-Type'] = 'application/json';
    Object? lastErr;

    for (var i = 0; i < attempts; i++) {
      await _throttle();
      final sw = Stopwatch()..start();
      try {
        // 请求和响应都完整记一份：B 站对「同一个 URL、不同请求头」会给出
        // 完全不同的结果（排序、风控、空数据），出问题时只看 URL 和条数
        // 根本查不出来 —— 得能看到当时到底带了什么头、返回了什么。
        fileLogger.debug('Bili', '→ ${body == null ? 'GET' : 'POST'} $url\n'
            '  请求头: ${_formatHeaders(h)}\n'
            '  请求体: ${body ?? '(无)'}');

        final resp = body == null
            ? await http.get(Uri.parse(url), headers: h).timeout(timeout)
            : await http
                .post(Uri.parse(url), headers: h, body: body)
                .timeout(timeout);
        final text = utf8.decode(resp.bodyBytes);
        final ms = sw.elapsedMilliseconds;

        fileLogger.debug('Bili', '← ${resp.statusCode} ($ms ms) $url\n'
            '  响应头: ${_formatHeaders(resp.headers)}\n'
            '  响应体: ${_brief(text)}');

        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw Exception('HTTP ${resp.statusCode}');
        }
        return jsonDecode(text) as Map<String, dynamic>;
      } catch (e) {
        lastErr = e;
        fileLogger.warn('Bili', '请求失败(${i + 1}/$attempts) $url → $e');
        if (i < attempts - 1) {
          await Future<void>.delayed(Duration(milliseconds: 400 * (i + 1)));
        }
      }
    }
    throw Exception('$lastErr');
  }

  /// 给两次请求之间留一个最小间隔，别把接口打得太密。
  Future<void> _throttle() async {
    final last = _lastRequestAt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < _minRequestGap) {
        await Future<void>.delayed(_minRequestGap - elapsed);
      }
    }
    _lastRequestAt = DateTime.now();
  }

  /// 日志里怎么显示请求/响应头。
  ///
  /// cookie 只留每个值的前 8 位：够认出是哪一个，又不至于把凭据整份写进日志。
  static String _formatHeaders(Map<String, String> h) {
    if (h.isEmpty) return '(无)';
    return h.entries.map((e) {
      if (e.key.toLowerCase() != 'cookie') return '${e.key}=${e.value}';
      final masked = e.value.split('; ').map((part) {
        final i = part.indexOf('=');
        if (i < 0) return part;
        final v = part.substring(i + 1);
        return '${part.substring(0, i)}=${v.length <= 8 ? v : '${v.substring(0, 8)}…'}';
      }).join('; ');
      return '${e.key}=$masked';
    }).join('; ');
  }

  /// 响应体可能几十 KB，日志里只留开头 —— 够看清 code 和结构就行。
  static String _brief(String body, [int max = 600]) => body.length <= max
      ? body
      : '${body.substring(0, max)}…(共 ${body.length} 字符)';

  /// 上报一次指纹，把游客身份「激活」。
  ///
  /// 只带 buvid 而不激活，高频请求照样会被 gaia 风控拦下来（返回 -352）。
  /// payload 的形状照 PiliPlus 抄：`3c43.bfe9` 是一段随机 base64 的尾巴。
  Future<void> _activateBuvid() async {
    if (_buvidActivated) return;
    _buvidActivated = true;
    try {
      final rand = base64.encode(<int>[
        ...List<int>.generate(32, (_) => _random.nextInt(256)),
        0, 0, 0, 0, 73, 69, 78, 68,
        ...List<int>.generate(4, (_) => _random.nextInt(256)),
      ]);
      final payload = jsonEncode({
        '3064': 1,
        '39c8': '333.1387.fp.risk',
        '3c43': {'adca': 'Linux', 'bfe9': rand.substring(rand.length - 50)},
      });
      final res = await _getJson(
        '$_host/x/internal/gaia-gateway/ExClimbWuzhi',
        body: jsonEncode({'payload': payload}),
        attempts: 2,
      );
      fileLogger.info('Bilibili', '游客身份已激活（code=${res['code']}）');
    } catch (e) {
      fileLogger.warn('Bilibili', '激活游客身份失败（继续）: $e');
    }
  }

  /// 游客标识。没有它时 B 站会把请求当成「无痕脚本」，容易触发风控。
  Future<void> _ensureBuvid() async {
    if (_buvid3.isNotEmpty) return;
    try {
      final res = await _getJson('$_host/x/frontend/finger/spi', attempts: 2);
      final data = res['data'] as Map?;
      _buvid3 = (data?['b_3'] ?? '').toString();
      _buvid4 = (data?['b_4'] ?? '').toString();
      fileLogger.debug('Bilibili', '已取到游客标识');
      // 拿到标识还不够，得再上报一次指纹把它激活
      await _activateBuvid();
    } catch (e) {
      // 拿不到也继续：实测不带它搜索与取流同样可用，只是更容易被限流
      fileLogger.warn('Bilibili', '取游客标识失败（继续）: $e');
    }
  }

  /// wbi 的 mixinKey 由 nav 接口的 img_key/sub_key 拼出来，每天变一次。
  Future<void> _ensureMixinKey() async {
    final now = DateTime.now();
    final fresh = _mixinKeyAt != null &&
        _mixinKey.isNotEmpty &&
        _mixinKeyAt!.year == now.year &&
        _mixinKeyAt!.month == now.month &&
        _mixinKeyAt!.day == now.day;
    if (fresh) return;

    await _ensureBuvid();
    final res = await _getJson('$_host/x/web-interface/nav');
    final wbi = ((res['data'] as Map?)?['wbi_img']) as Map?;
    if (wbi == null) {
      throw Exception('无法获取 wbi 签名密钥');
    }
    String keyOf(Object? url) =>
        (url ?? '').toString().split('/').last.split('.').first;
    final orig = keyOf(wbi['img_url']) + keyOf(wbi['sub_url']);
    _mixinKey = String.fromCharCodes(_mixinKeyEncTab.map(orig.codeUnitAt));
    _mixinKeyAt = now;
    fileLogger.debug('Bilibili', 'wbi 密钥已更新');
  }

  /// 给参数补上 wts 与 w_rid，返回可直接拼进 URL 的查询串。
  ///
  /// 返回**字符串**而不是 Map：调用方是直接把它接在 `?` 后面的。
  /// 早先返回 Map 再插值，URL 里会塞进 `{avid: 123, ...}` 这种字面量，
  /// 接口一律回 412。
  String _sign(Map<String, Object> params) {
    final p = Map<String, Object>.from(params);
    p['wts'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final query = (p.keys.toList()..sort())
        .map((k) => '${Uri.encodeQueryComponent(k)}='
            '${Uri.encodeQueryComponent(p[k].toString().replaceAll(_chrFilter, ''))}')
        .join('&');
    final wRid = md5.convert(utf8.encode(query + _mixinKey)).toString();
    return '$query&w_rid=$wRid';
  }

  // ---------------------------------------------------------------- 搜索

  /// 取账号信息（昵称 / 大会员）。没登录或 ck 失效时返回 null。
  ///
  /// 判据必须是 `isLogin == true`：nav 在未登录时回 `code: -101`，
  /// 只看 code 会把「没登录」当成「请求失败」。
  Future<({String nickname, bool isVip, String mid})?> fetchUserInfo({
    String? ck,
  }) async {
    final saved = cookie;
    if (ck != null) setCookie(ck);
    try {
      final res = await _getJson('$_host/x/web-interface/nav', attempts: 2);
      final data = res['data'] as Map?;
      if (data == null || data['isLogin'] != true) return null;
      final name = (data['uname'] ?? '').toString();
      if (name.isEmpty) return null;
      return (
        nickname: name,
        // vipStatus: 1 = 大会员
        isVip: (data['vipStatus'] as num?)?.toInt() == 1,
        mid: (data['mid'] ?? '').toString(),
      );
    } finally {
      if (ck != null) cookie = saved;
    }
  }

  /// 取自己投稿的视频，**含未公开（私密）的那些**。
  ///
  /// 这个接口在创作中心，必须登录 —— 私密视频在普通搜索里根本搜不到，
  /// 只能从这儿拿。没配 ck 时直接返回空。
  Future<List<Song>> fetchMyVideos() async {
    if (cookie.isEmpty) return const [];
    try {
      final res = await _getJson(
        'https://member.bilibili.com/x/web/archives'
        '?status=is_pubing,pubed,not_pubed&pn=1&ps=50',
        attempts: 2,
      );
      if (res['code'] != 0) {
        fileLogger.warn('Bilibili', '取自己投稿失败（code=${res['code']}）');
        return const [];
      }
      final raw = ((res['data'] as Map?)?['arc_audits'] as List?) ?? const [];
      final songs = <Song>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final arc = item['Archive'];
        if (arc is! Map) continue;
        final bvid = (arc['bvid'] ?? '').toString();
        if (bvid.isEmpty) continue;
        songs.add(Song(
          mid: bvid,
          name: _stripHtml((arc['title'] ?? '').toString()),
          artist: '我的投稿',
          pic: _httpsize((arc['cover'] ?? '').toString()),
          link: 'https://www.bilibili.com/video/$bvid',
          source: 'bilibili',
          duration: (arc['duration'] as num?)?.toInt() ?? 0,
        ));
      }
      fileLogger.info('Bilibili', '取到自己投稿 ${songs.length} 条');
      return songs;
    } catch (e) {
      fileLogger.warn('Bilibili', '取自己投稿出错: $e');
      return const [];
    }
  }

  /// 搜索视频。返回的 Song 里 `mid` = bvid、`mediaMid` = cid。
  Future<({List<Song> list, int total})> search(
    String keyword, [
    int page = 1,
  ]) async {
    await _ensureMixinKey();
    final query = _sign({
      'search_type': 'video',
      'keyword': keyword,
      'page': page,
      'page_size': 20,
      'platform': 'pc',
      'web_location': 1430654,
    });
    final res = await _getJson(
      '$_host/x/web-interface/wbi/search/type?$query',
      headers: {
        'Referer':
            'https://search.bilibili.com/video?keyword=${Uri.encodeQueryComponent(keyword)}',
        'Origin': 'https://search.bilibili.com',
      },
    );
    final code = (res['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      if (_riskCodes.contains(code)) {
        throw Exception('B站风控拦截（code=$code），隔一会儿再试或放慢搜索速度');
      }
      throw Exception('B站搜索失败（code=$code）');
    }
    final data = res['data'] as Map? ?? const {};
    // 风控凭证：出现它说明请求被判定为异常，需要人机验证
    if (data['v_voucher'] != null) {
      throw Exception('B站搜索触发风控，请稍后再试');
    }
    final items = (data['result'] as List?) ?? const [];
    final list = <Song>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final song = _songFromSearchItem(raw);
      if (song != null) list.add(song);
    }
    // 配了 ck 时，把自己投稿里标题命中的并到最前面 ——
    // 私密视频搜不到，只能从「我的投稿」里捞。
    if (page == 1 && cookie.isNotEmpty) {
      final mine = await fetchMyVideos();
      if (mine.isNotEmpty) {
        final kw = keyword.toLowerCase();
        final hit =
            mine.where((s) => s.name.toLowerCase().contains(kw)).toList();
        if (hit.isNotEmpty) list.insertAll(0, hit);
      }
    }

    final total = (data['numResults'] as num?)?.toInt() ??
        (data['total'] as num?)?.toInt() ??
        list.length;
    fileLogger.info('Bilibili', '搜索 "$keyword" page=$page → ${list.length} 条'
        '${cookie.isEmpty ? '' : '（含自己投稿）'}');
    return (list: list, total: total);
  }

  Song? _songFromSearchItem(Map raw) {
    final bvid = (raw['bvid'] ?? '').toString();
    if (bvid.isEmpty) return null;
    final title = _stripHtml((raw['title'] ?? '').toString());
    if (title.isEmpty) return null;
    // duration 形如 "4:36"，也有 "1:02:33" 这种
    final duration = _parseDuration((raw['duration'] ?? '').toString());
    return Song(
      mid: bvid,
      name: title,
      artist: _stripHtml((raw['author'] ?? '').toString()),
      pic: _httpsize((raw['pic'] ?? '').toString()),
      link: 'https://www.bilibili.com/video/$bvid',
      source: 'bilibili',
      duration: duration,
    );
  }

  /// 用 BV 号直接取视频信息，供「粘贴 BV 号直接搜到」用。
  Future<Song?> resolveBv(String bvid) async {
    final code = bvid.trim();
    if (!bvPattern.hasMatch(code)) return null;
    final res = await _getJson('$_host/x/web-interface/view?bvid=$code');
    if (res['code'] != 0) return null;
    final d = res['data'] as Map?;
    if (d == null) return null;
    final owner = d['owner'] as Map?;
    final cid = (d['cid'] as num?)?.toInt();
    final aid = (d['aid'] as num?)?.toInt();
    if (cid != null && aid != null) _infoCache[code] = (aid: aid, cid: cid);
    return Song(
      mid: code,
      name: (d['title'] ?? '').toString(),
      artist: (owner?['name'] ?? '').toString(),
      pic: _httpsize((d['pic'] ?? '').toString()),
      link: 'https://www.bilibili.com/video/$code',
      mediaMid: cid?.toString() ?? '',
      source: 'bilibili',
      duration: (d['duration'] as num?)?.toInt() ?? 0,
    );
  }

  // ------------------------------------------------------------ 取音频流

  /// 搜索结果里没有 aid/cid，需要单独查一次 view 接口。
  Future<({int aid, int cid})?> _infoOf(String bvid) async {
    final cached = _infoCache[bvid];
    if (cached != null) return cached;
    final res = await _getJson('$_host/x/web-interface/view?bvid=$bvid');
    if (res['code'] != 0) return null;
    final d = res['data'] as Map?;
    final aid = (d?['aid'] as num?)?.toInt();
    final cid = (d?['cid'] as num?)?.toInt();
    if (aid == null || cid == null) return null;
    final info = (aid: aid, cid: cid);
    _infoCache[bvid] = info;
    return info;
  }

  /// 取音频流地址。fnval=16 要 DASH，音频在 `dash.audio[]` 里按带宽排序。
  Future<String> getAudioUrl(Song song) async {
    await _ensureMixinKey();
    final info = await _infoOf(song.mid);
    if (info == null) throw Exception('无法获取该视频的 aid/cid');

    final query = _sign({
      'avid': info.aid,
      'cid': info.cid,
      'qn': 127,
      'fnval': 16,
      'fourk': 1,
    });
    final res = await _getJson(
      '$_host/x/player/wbi/playurl?$query',
      headers: {'Referer': 'https://www.bilibili.com/video/${song.mid}'},
    );
    if (res['code'] != 0) {
      throw Exception('B站取流失败（code=${res['code']}）');
    }
    final dash = ((res['data'] as Map?)?['dash']) as Map?;
    final audios = (dash?['audio'] as List?) ?? const [];
    if (audios.isEmpty) throw Exception('该视频没有可用的音频流');

    // 挑带宽最大的那条（实测 30280 是最高档，约 329kbps）
    Map? best;
    var bestBw = -1;
    for (final a in audios) {
      if (a is! Map) continue;
      final bw = (a['bandwidth'] as num?)?.toInt() ?? 0;
      if (bw > bestBw) {
        bestBw = bw;
        best = a;
      }
    }
    final url = (best?['baseUrl'] ?? best?['base_url'] ?? '').toString();
    if (url.isEmpty) throw Exception('音频流地址为空');
    fileLogger.info('Bilibili', '${song.mid} 音频 ${bestBw ~/ 1000}kbps');
    return url;
  }

  // ---------------------------------------------------------------- 歌词

  /// 按 bvid 取字幕。歌词缓存那边手里只有 mid，没有完整 Song。
  Future<({String lyric, String trans})> getLyricByMid(String bvid) =>
      getLyric(Song(mid: bvid, name: bvid, artist: '', source: 'bilibili'));

  /// 取字幕当歌词。游客身份下通常拿不到，此时返回空串。
  Future<({String lyric, String trans})> getLyric(Song song) async {
    try {
      await _ensureMixinKey();
      final info = await _infoOf(song.mid);
      if (info == null) return (lyric: '', trans: '');

      final query = _sign({'aid': info.aid, 'cid': info.cid});
      final res = await _getJson(
        '$_host/x/player/wbi/v2?$query',
        headers: {'Referer': 'https://www.bilibili.com/video/${song.mid}'},
      );
      final subs =
          (((res['data'] as Map?)?['subtitle'] as Map?)?['subtitles'] as List?) ??
              const [];
      if (subs.isEmpty) return (lyric: '', trans: '');

      // 优先中文，其次第一个
      Map? pick;
      for (final s in subs) {
        if (s is! Map) continue;
        final lan = (s['lan'] ?? '').toString();
        if (lan.startsWith('zh')) {
          pick = s;
          break;
        }
        pick ??= s;
      }
      if (pick == null) return (lyric: '', trans: '');

      var url = (pick['subtitle_url'] ?? '').toString();
      if (url.startsWith('//')) url = 'https:$url';
      if (url.isEmpty) return (lyric: '', trans: '');

      final body = await _getJson(url);
      final items = (body['body'] as List?) ?? const [];
      if (items.isEmpty) return (lyric: '', trans: '');

      final buf = StringBuffer();
      for (final it in items) {
        if (it is! Map) continue;
        final from = (it['from'] as num?)?.toDouble() ?? 0;
        final text = (it['content'] ?? '').toString().trim();
        if (text.isEmpty) continue;
        buf.writeln('${_lrcStamp(from)}$text');
      }
      final lyric = buf.toString();
      fileLogger.info('Bilibili',
          '${song.mid} 字幕 ${items.length} 条 → 歌词 ${lyric.length} 字符');
      return (lyric: lyric, trans: '');
    } catch (e) {
      fileLogger.warn('Bilibili', '取字幕失败: $e');
      return (lyric: '', trans: '');
    }
  }

  // ---------------------------------------------------------------- 工具

  static String _lrcStamp(double seconds) {
    final total = seconds < 0 ? 0 : (seconds * 100).round();
    final cs = total % 100;
    final totalSec = total ~/ 100;
    final s = totalSec % 60;
    final m = totalSec ~/ 60;
    return '[${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.'
        '${cs.toString().padLeft(2, '0')}]';
  }

  /// 搜索结果的标题/作者里带 `<em class="keyword">` 高亮标签
  static String _stripHtml(String text) =>
      text.replaceAll(RegExp(r'<[^>]*>'), '').trim();

  /// 把封面地址补成 https。
  ///
  /// 注意搜索结果给的是**协议相对**地址（`//i0.hdslb.com/...`，没有 scheme），
  /// 直接丢给 Uri.parse 会因 scheme 为空而报错 —— 表现为搜索页所有封面都不显示。
  static String _httpsize(String url) {
    if (url.isEmpty) return url;
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('http://')) {
      return url.replaceFirst('http://', 'https://');
    }
    return url;
  }

  /// "4:36" / "1:02:33" → 秒
  static int _parseDuration(String text) {
    final parts = text.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    if (parts.isEmpty) return 0;
    var sec = 0;
    for (final p in parts) {
      sec = sec * 60 + p;
    }
    return sec;
  }
}

final bilibiliService = BilibiliService.instance;
