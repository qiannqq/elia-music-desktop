import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../core/file_logger.dart';
import '../core/lyric.dart';
import 'lyric_cache.dart';
import 'qrc_decrypt.dart';
import '../models/song.dart';

/// QQ 音乐 musicu 接口入口列表（**主 u，备用 u6**）。
///
/// 主备依据来自对 QQ 音乐客户端接口的抓包结论：`u.y.qq.com` 是主入口，
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

/// ck 校验的结论。
///
/// 分三态而不是「能用 / 不能用」两态。请求**根本没到腾讯那边**时（连接被
/// 提前关掉、超时），这份 ck 是好是坏无从判断 —— 它和「服务端查无此人」
/// 是两件事。以前两者一起返回 `null`，于是每次开机都可能弹一条
/// 「Cookie 已失效」，用户点一次「验证并保存」又好了。
enum CkOutcome {
  /// 服务端认了，账号信息可信
  ok,

  /// 服务端明确不认（未登录、账号不存在）
  rejected,

  /// 请求没能完成，结论未知 —— 不要据此改任何状态
  unreachable,
}

/// 一次 ck 校验的结果。[outcome] 不是 [CkOutcome.ok] 时其余字段无意义。
typedef CkResult = ({
  CkOutcome outcome,
  String nickname,
  String uin,
  bool isWechat,
  bool isVip,
});

/// QQ 音乐服务 —— `electron/service/qqmusic.js` 的 Dart 移植。
///
/// 所有响应体都用 `utf8.decode(resp.bodyBytes)` 解码，**不要用 `resp.body`**：
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

  /// ck 刷新成功后回调 —— 由上层写回本地存储。
  /// 服务层不直接碰存储，保持单一职责。
  void Function(String cookie)? onCookieRefreshed;

  /// ck 里的 `qm_keyst` 是**会过期的**：`psrf_musickey_createtime` 记的是签发
  /// 时间，约 12 小时后失效 —— 之后接口开始返回空地址，用户看到的就是
  /// 「歌点不开了」，但 ck 本身并没有「错」，所以不会触发任何错误提示。
  static const Duration _kTokenTtl = Duration(hours: 12);
  /// 刷新检查的节流：取播放地址是高频动作，不能每次都去问一遍
  static const Duration _kRefreshThrottle = Duration(minutes: 10);
  /// 连续失败这么多次就停手（多半是 refresh_token 也失效了，再试没意义）
  static const int _kMaxRefreshFails = 3;

  /// ck 校验的尝试次数与单次超时。
  ///
  /// 超时给得比取地址那类接口紧：账号主页正常不到 1 秒，卡住就说明这一路
  /// 不通了，早点换一次重试比干等 30 秒强（实测那次挂了 19 秒才被关连接）。
  static const int _kCkAttempts = 3;
  static const Duration _kCkTimeout = Duration(seconds: 10);

  DateTime? _lastRefreshCheck;
  int _refreshFails = 0;
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
        // 搜索响应很快（正常 <1s）；卡住时尽快失败换入口，
        // 否则「切备用入口」要等 20 秒才发生。
        timeout: const Duration(seconds: 8),
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
    // 抛异常而不是返回「0 条结果」：
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
    // key 过期后接口会静默返回空地址，先确保它新鲜（通常立即返回）
    await ensureCookieFresh();
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
    // QRC 超过 10s 就放弃、直接用普通歌词 —— 否则慢的时候会长时间
    // 看不到歌词 / 拉不到翻译。
    final Future<({String lyric, String trans, dynamic raw, bool isQrc})> qrcFuture =
        _fetchQrc(mid);

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

    // QRC 的行头是 `[起点ms,时长ms]`，**不是** `[mm:ss.xx]` ——
    // 必须单独识别。之前只认 LRC 时间戳，导致 QRC 明明拉到了却被判无效、
    // 回退成普通歌词 —— 逐字歌词永远出不来。
    // 真解析一遍：能解析出逐字行才算 QRC 可用
    final qrcParsedLines = parseQrc(qrcLyric);

    // 不能只看「官方接口返回了内容」就认：
    // QRC 的解密密钥是**会换代**的，密钥过期时解出来的是乱码。
    // 实测 2026-09：旧 DES 密钥已失效（穷举密钥切片顺序 × raw/zlib/gzip
    // 解压方式全部失败），所以必须**真的能解析出行**才算有效，
    // 否则回退普通歌词 —— 否则会出现「有歌词却一行都显示不出来」的回归。
    final hasValidLyric = qrcParsedLines.isNotEmpty ||
        _hasTimestamp(qrcLyric) ||
        looksLikeQrc(qrcLyric);
    final hasValidTrans = _hasTimestamp(qrcTrans) || looksLikeQrc(qrcTrans);

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

    // 超时只是「不再等它」，那个请求还在飞。它回来时如果带着有效的 QRC，
    // 就补进缓存 —— 否则这份没有翻译的降级结果会被缓存住，
    // 之后无论怎么打开歌词都看不到逐字和翻译。
    if (qrcTimedOut) {
      unawaited(qrcFuture.then((q) {
        if (q.lyric.isEmpty || !looksLikeQrc(q.lyric)) return;
        LyricCache.putRaw(mid, q.lyric, q.trans);
      }).catchError((_) {}));
    }
    return (
      lyric: simple.lyric.isNotEmpty ? simple.lyric : qrcLyric,
      trans: hasValidTrans ? qrcTrans : simple.trans,
      raw: simple.raw,
    );
  }

  /// 取 QRC 逐字歌词（内部已吞掉异常，失败返回空串）。
  ///
  /// 优先用**文档逆向出的官方接口** `music.musichallSong.PlayLyricInfo.GetPlayLyricInfo`：
  /// 它直接吃 songMID、**不需要先查 songId**，比旧的 `lyric_download.fcg` 快很多
  /// —— 旧路径因为要先 `_getSongId`（多一次请求），实测经常撑到 10s 超时被放弃，
  /// 于是「逐字歌词永远拉不到」。
  ///
  /// 返回的 `lyric` 是 base64 编码的**加密 QRC**，解码后是
  /// `[起点ms,时长ms]字(字起点ms,字时长ms)...`；旧接口则返回 hex 编码的同类数据。
  /// 旧接口作为兜底保留。
  Future<({String lyric, String trans, dynamic raw, bool isQrc})> _fetchQrc(String mid) async {
    // ---- A) 官方接口（快，优先）----
    try {
      final res = await _requestMusicu({
        'music.musichallSong.PlayLyricInfo.GetPlayLyricInfo': {
          'module': 'music.musichallSong.PlayLyricInfo',
          'method': 'GetPlayLyricInfo',
          'param': {
            'songMID': mid,
            'songID': 0,
            'lrc_t': 0,
            'qrc_t': 0,
            'trans_t': 0,
            'roma_t': 0,
            'type': 1,
            'crypt': 0,
            'qrc': 1,
            'trans': 1,
            'roma': 1,
          },
        },
      });
      final node =
          res['music.musichallSong.PlayLyricInfo.GetPlayLyricInfo'] as Map?;
      final data = node?['data'] as Map?;
      if (data != null) {
        // 官方接口的 `lyric` 字段：`qrc=0` 时是 base64(明文LRC)，
        // 但 **`qrc=1` 时是 HEX 编码的加密 QRC**（文档里写成 base64 是错的）。
        // 同一串按 base64 解会得到乱码，按 hex 解才对 —— 且与旧接口
        // lyric_download.fcg 的 <content> 完全一致（实测逐字节相同）。
        final rawQrc = (data['lyric'] as String?) ?? '';
        if (rawQrc.isNotEmpty) {
          final lyric = _decryptQrc(rawQrc) ?? '';
          if (lyric.isNotEmpty) {
            final rawTrans = (data['trans'] as String?) ?? '';
            String trans = '';
            if (rawTrans.isNotEmpty) {
              // 翻译同样可能是 hex 加密串，也可能是 base64 明文
              final dec = _decryptQrc(rawTrans);
              if (dec != null && dec.isNotEmpty) {
                trans = dec;
              } else {
                try {
                  trans = utf8.decode(base64.decode(rawTrans), allowMalformed: true);
                } catch (_) {
                  trans = '';
                }
              }
            }
            // 诊断：确认解密后 QRC 的真实行格式
            final head = lyric.split('\n').take(3).join(' / ');
            fileLogger.info(
              'QQMusic',
              'QRC(官方接口) mid=$mid lyric=${lyric.length} trans=${trans.length} head=$head',
            );
            // 官方接口解出来的**就是 QRC**，无需再靠正则猜格式
            return (lyric: lyric, trans: trans, raw: data, isQrc: true);
          }
        }
      }
    } catch (e) {
      fileLogger.warn('QQMusic', 'QRC 官方接口失败，回退旧接口: $e');
    }


    // ---- B) 旧接口兜底 ----
    try {
      final songId = await _getSongId(mid);
      if (songId == 0) return (lyric: '', trans: '', raw: null, isQrc: false);
      final r = await _getQrcLyric(songId);
      return (
        lyric: r.lyric,
        trans: r.trans,
        raw: r.raw,
        isQrc: r.lyric.isNotEmpty && looksLikeQrc(r.lyric),
      );
    } catch (e) {
      fileLogger.warn('QQMusic', 'QRC lyric error: $e');
      return (lyric: '', trans: '', raw: null, isQrc: false);
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
  /// QRC 解密 + 取出 LyricContent。
  ///
  /// 必须用 [QrcDecrypt]（私有 S-box 的非标准 DES 变体）：
  /// 标准 DES（OpenSSL / Node crypto / pycryptodome）解出来是乱码。
  ///
  /// 取 LyricContent 必须用**正则直接抓原始字符串**，不能用 XML 解析器：
  /// XML 规范会把属性值里的换行规范化成空格，逐字歌词会被拼成一整行。
  String? _decryptQrc(String hex) {
    if (hex.isEmpty) return null;
    final xml = QrcDecrypt.decode(hex);
    if (xml == null || xml.isEmpty) return null;
    final m =
        RegExp(r'LyricContent="(.*?)"\s*/>', dotAll: true).firstMatch(xml);
    final content = _unescapeXml(m?.group(1) ?? xml);
    return content.isEmpty ? null : content;
  }

  /// XML 属性值反转义（QRC 的 LyricContent 里会有 &quot; &amp; 等）
  static String _unescapeXml(String s) => s
      .replaceAll('&#10;', '\n')
      .replaceAll('&#13;', '\r')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

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

  /// 用账号主页接口验证 ck，并取回账号信息。
  ///
  /// **不能只看 `code == 0`**：这个接口在未登录/ck 无效时同样会回 0，
  /// 真正能证明「这份 ck 对应一个真实账号」的是 `data.creator` 里的昵称。
  /// 少了这一层判断，随便填一串字符都会被判成「有效」。
  ///
  /// 这个接口偶发在**没有任何响应**的情况下被提前关掉连接
  /// （`ClientException: Connection closed before full header was received`，
  /// 实测能挂十几秒才断）。单次失败就判失效，用户每次开机都会看到一条假提示，
  /// 所以这里自己重试几次，只有服务端真的答「查无此人」才返回
  /// [CkOutcome.rejected]；连不上则返回 [CkOutcome.unreachable]，由上层决定。
  Future<CkResult> fetchUserInfo({String? ck}) async {
    final raw = (ck ?? cookie).trim();
    if (raw.isEmpty) return _ckFail(CkOutcome.rejected);

    // 结构就不合法的，不必浪费一次请求：
    // 登录态一定带着 unionid（QQ 是 psrf_qqunionid，微信是 wxunionid）
    final map = parseCookie(raw);
    final wxUnion = map['wxunionid'] ?? '';
    final qqUnion = map['psrf_qqunionid'] ?? '';
    if (wxUnion.isEmpty && qqUnion.isEmpty) return _ckFail(CkOutcome.rejected);
    if ((map['qqmusic_key'] ?? map['qm_keyst'] ?? '').isEmpty) {
      return _ckFail(CkOutcome.rejected);
    }

    Object? lastErr;
    for (var attempt = 0; attempt < _kCkAttempts; attempt++) {
      try {
        final res = await _fetchProfile(raw);
        if (!_isOkCode(res?['code'])) return _ckFail(CkOutcome.rejected);
        final creator = (res?['data'] as Map?)?['creator'] as Map?;
        final nick = (creator?['nick'] ?? '').toString().trim();
        if (nick.isEmpty) return _ckFail(CkOutcome.rejected);

        final account = (map['uin'] ?? map['wxuin'] ?? '').toString();
        return (
          outcome: CkOutcome.ok,
          nickname: nick,
          uin: account,
          // 微信登录的 ck 带 wxunionid，QQ 登录带 psrf_qqunionid
          isWechat: wxUnion.isNotEmpty,
          isVip: await _queryVip(account, ck: raw),
        );
      } catch (e) {
        lastErr = e;
        fileLogger.warn('QQMusic', 'ck 校验第 ${attempt + 1} 次没通: $e');
        if (attempt < _kCkAttempts - 1) {
          await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
        }
      }
    }
    fileLogger.warn('QQMusic', 'ck 校验未能完成，结论未知: $lastErr');
    return _ckFail(CkOutcome.unreachable);
  }

  /// 账号主页接口。单独拎出来是为了让测试能把它指到一个没人监听的端口上，
  /// 复现「连不上」那条路（正常路径下没人会改它）。
  static String profileEndpoint =
      'https://c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg';

  /// 单次账号主页请求。[fetchUserInfo] 负责重试，这里只管发一次。
  Future<Map?> _fetchProfile(String raw) async {
    final url = '$profileEndpoint'
        '?_=${DateTime.now().millisecondsSinceEpoch}&cv=4747474&ct=24&format=json'
        '&inCharset=utf-8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0'
        '&uin=0&g_tk_new_20200303=5381&g_tk=5381&cid=205360838&userid=0'
        '&reqfrom=1&reqtype=0&hostUin=0&loginUin=0';

    final resp = await http.get(Uri.parse(url), headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Cookie': raw,
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    }).timeout(_kCkTimeout);
    return jsonDecode(utf8.decode(resp.bodyBytes)) as Map?;
  }

  /// 只有 [CkOutcome.ok] 才算「这份 ck 能用」。
  Future<bool> validateCookie() async =>
      (await fetchUserInfo()).outcome == CkOutcome.ok;

  CkResult _ckFail(CkOutcome outcome) => (
        outcome: outcome,
        nickname: '',
        uin: '',
        isWechat: false,
        isVip: false,
      );

  /// 查绿钻（含豪华绿钻）。
  ///
  /// 这个接口和取播放地址用的不是同一套 comm，参数照网页版来 ——
  /// 少了 `g_tk` 那几个字段会被判成未登录，一律返回「非会员」。
  Future<bool> _queryVip(String uin, {String? ck}) async {
    if (uin.isEmpty || uin == '0') return false;
    try {
      final res = await _requestMusicu(
        {
          'comm': {
            'cv': 4747474,
            'ct': 24,
            'format': 'json',
            'inCharset': 'utf-8',
            'outCharset': 'utf-8',
            'notice': 0,
            'platform': 'yqq.json',
            'needNewCode': 1,
            'uin': 0,
            'g_tk_new_20200303': 5381,
            'g_tk': 5381,
          },
          'req_0': {
            'module': 'userInfo.VipQueryServer',
            'method': 'SRFVipQuery_V2',
            'param': {
              'uin_list': [uin],
            },
          },
        },
        headers: ck != null ? {'Cookie': ck} : const {},
      );
      final req0 = res['req_0'] as Map?;
      if (!_isOkCode(req0?['code'])) return false;
      final info = ((req0?['data'] as Map?)?['infoMap'] as Map?)?[uin] as Map?;
      if (info == null) return false;
      // iVipFlag 绿钻 / iSuperVip 豪华绿钻 / iNewVip、iNewSuperVip 新版标记
      return info['iVipFlag'] == 1 ||
          info['iSuperVip'] == 1 ||
          info['iNewVip'] == 1 ||
          info['iNewSuperVip'] == 1;
    } catch (e) {
      fileLogger.warn('QQMusic', 'VIP 查询失败: $e');
      return false;
    }
  }

  /// 这份 ck 是否需要换一张新的 musickey。
  bool get needsRefresh {
    if (cookie.isEmpty) return false;
    final key = cookieMap['qqmusic_key'] ?? cookieMap['qm_keyst'] ?? '';
    if (key.isEmpty) return true;
    final created = int.tryParse(cookieMap['psrf_musickey_createtime'] ?? '0') ?? 0;
    if (created <= 0) return true;
    final issued = DateTime.fromMillisecondsSinceEpoch(created * 1000);
    return DateTime.now().difference(issued) > _kTokenTtl;
  }

  /// 登录方式：0 = QQ，1 = 微信，-1 = 认不出来（也就没法刷新）
  int get _loginType {
    if ((cookieMap['wxunionid'] ?? '').isNotEmpty) return 1;
    if ((cookieMap['psrf_qqunionid'] ?? '').isNotEmpty) return 0;
    return -1;
  }

  /// 用 ck 里的 `refresh_token` 换一张新的 musickey。
  ///
  /// 成功时会把新 key 写回 `cookie`，并通过 [onCookieRefreshed] 通知上层落盘。
  Future<bool> refreshCookie() async {
    final type = _loginType;
    if (type < 0) return false;

    final comm = _createQQMusicComm();
    comm['guid'] = _md5('${cookieMap['uin'] ?? cookieMap['wxuin'] ?? ''}music');

    final param = <String, dynamic>{
      'expired_in': 0,
      'forceRefreshToken': 0,
      'onlyNeedAccessToken': 0,
      'musickey': cookieMap['qqmusic_key'] ?? cookieMap['qm_keyst'] ?? '',
      'access_token': '',
      'musicid': 0,
      'openid': '',
      'refresh_token': '',
      'unionid': '',
    };
    if (type == 0) {
      param.addAll({
        'appid': 100497308,
        'access_token': cookieMap['psrf_qqaccess_token'] ?? '',
        'musicid': int.tryParse(cookieMap['uin'] ?? '0') ?? 0,
        'openid': cookieMap['psrf_qqopenid'] ?? '',
        'refresh_token': cookieMap['psrf_qqrefresh_token'] ?? '',
        'unionid': cookieMap['psrf_qqunionid'] ?? '',
      });
    } else {
      param.addAll({
        'strAppid': 'wx48db31d50e334801',
        'access_token': cookieMap['wxaccess_token'] ?? '',
        'str_musicid': cookieMap['wxuin'] ?? '0',
        'openid': cookieMap['wxopenid'] ?? '',
        'refresh_token': cookieMap['wxrefresh_token'] ?? '',
        'unionid': cookieMap['wxunionid'] ?? '',
      });
    }

    try {
      final res = await _requestMusicu({
        'comm': comm,
        'req_0': {
          'method': 'Login',
          'module': 'music.login.LoginServer',
          'param': param,
        },
      });
      final req0 = res['req_0'] as Map?;
      if (!_isOkCode(req0?['code'])) {
        fileLogger.warn('QQMusic', 'ck 刷新被拒: ${req0?['code']}');
        return false;
      }
      final data = req0?['data'] as Map?;
      if (data == null || (data['musickey'] ?? '').toString().isEmpty) {
        return false;
      }

      final next = Map<String, String>.from(cookieMap);
      void put(String k, Object? v) {
        final text = (v ?? '').toString();
        if (text.isNotEmpty) next[k] = text;
      }

      if (type == 0) {
        put('psrf_qqopenid', data['openid']);
        put('psrf_qqrefresh_token', data['refresh_token']);
        put('psrf_qqaccess_token', data['access_token']);
        put('psrf_access_token_expiresAt', data['expired_at']);
        put('uin', data['str_musicid'] ?? data['musicid']);
        put('psrf_qqunionid', data['unionid']);
        put('login_type', '1');
        put('tmeLoginType', '2');
      } else {
        put('wxopenid', data['openid']);
        put('wxrefresh_token', data['refresh_token']);
        put('wxaccess_token', data['access_token']);
        put('wxuin', data['str_musicid'] ?? data['musicid']);
        put('wxunionid', data['unionid']);
        put('login_type', '2');
        put('tmeLoginType', '1');
      }
      put('qqmusic_key', data['musickey']);
      put('qm_keyst', data['musickey']);
      put('psrf_musickey_createtime', data['musickeyCreateTime']);
      put('euin', data['encryptUin']);

      setCookie(stringifyCookie(next));
      _refreshFails = 0;
      onCookieRefreshed?.call(cookie);
      fileLogger.info('QQMusic', 'ck 已刷新（新 key 有效期 12 小时）');
      return true;
    } catch (e) {
      fileLogger.warn('QQMusic', 'ck 刷新失败: $e');
      return false;
    }
  }

  /// 取播放地址前的例行检查：需要换 key 就换，并做节流与失败退避。
  Future<void> ensureCookieFresh() async {
    if (cookie.isEmpty || !needsRefresh) return;
    if (_refreshFails >= _kMaxRefreshFails) return;
    final now = DateTime.now();
    if (_lastRefreshCheck != null &&
        now.difference(_lastRefreshCheck!) < _kRefreshThrottle) {
      return;
    }
    _lastRefreshCheck = now;
    if (!await refreshCookie()) _refreshFails++;
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
  /// 关键：`u.y.qq.com` 已被限流/降级 —— 实测同一请求体、同一时间：
  ///   u.y.qq.com  → 连续 8 次全部返回空列表（item_song 为空）
  ///   u6.y.qq.com → 8 次里成功 7 次
  /// 原版 Electron 用的是 `u`（写的时候还能用）。因此这里**主用 u6、备用 u**，
  /// 并且每次重试轮换入口，避免连续撞在同一个坏入口上。
  Future<Map<String, dynamic>> _requestMusicu(
    Map<String, dynamic> body, {
    Map<String, String> headers = const {},
    int hostOffset = 0,
    // 单次尝试的超时。默认保持宽松（取播放地址那类接口本身可能慢到 20s，
    // 收紧反而会误杀）；**搜索**由调用方传 8s —— 它响应很快（正常 <1s），
    // 卡住时应尽快换入口，否则用户感受到的就是「搜索要等 20 秒」。
    Duration timeout = const Duration(seconds: 30),
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
        ).timeout(timeout);

        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw Exception('QQ音乐接口请求失败：${resp.statusCode}');
        }
        // 记下**实际生效的入口**：否则「搜索成功」时无法从日志判断
        // 走的是主入口还是备用入口（之前只能靠「没有重试日志」反推，不算证据）。
        fileLogger.debug('QQMusic',
            'musicu ${Uri.parse(host).host} 第 ${i + 1} 次成功');
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

}

final qqMusicService = QQMusicService.instance;
