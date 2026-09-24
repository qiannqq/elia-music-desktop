import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/services/api_client.dart';
import 'package:elia_music/state/app_state.dart';

/// 换音源要按**输入框现在的内容**重搜。
///
/// 用户常是先改关键词、再点另一个音源。那时 `searchKeyword` 还是上一个词，
/// 拿它重搜就会搜出上一首歌的结果 —— 表现为「换了搜索框内容再点音源，
/// 弹出来的还是旧结果，得再点一次搜索才对」。
void main() {
  // 这里**故意不装** TestWidgetsFlutterBinding：它会接管 HttpClient、
  // 让所有真实网络请求返回 400，而下面的假服务端正是一个真实的本地 HTTP 服务。
  // 这条路径不需要 binding（toast 只用 ChangeNotifier）。

  late HttpServer server;
  late String savedBase;

  /// 假服务端收到的每一次搜索请求（`音源|关键词`），用来断言「到底搜没搜、搜的什么」
  late List<String> hits;

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_search_src_test');
    AppPaths.appDir = tmp.path;
    AppPaths.dataDir = tmp.path;
    AppPaths.logsDir = tmp.path;
    AppPaths.tempDir = tmp.path;
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  setUp(() async {
    // 搜索走的是本进程的本地 API（`apiBase`），这里用一个假的顶替。
    // 返回的歌名带上关键词，一眼就能看出搜的是哪个词。
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    savedBase = apiBase;
    setApiPort(server.port);
    hits = [];
    server.listen((req) {
      final kw = req.uri.queryParameters['keyword'] ?? '';
      hits.add('${req.uri.path}|$kw');
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'data': [
            {'mid': 'mid-$kw', 'name': '结果-$kw', 'artist': '歌手', 'source': 'qq'},
          ],
          'total': 1,
        }))
        ..close();
    });

    final app = AppState.instance;
    app.searchSource = 'qq';
    app.isPlaylistPage = false;
    app.searchResults = [];
    app.searchKeyword = '';
    app.searchInput = '';
  });

  tearDown(() async {
    apiBase = savedBase;
    await server.close(force: true);
  });

  /// 等这次搜索跑完（`setSearchSource` 里的重搜是「发了不等」的）
  Future<void> settle(AppState app) async {
    for (var i = 0; i < 200 && app.isSearching; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  test('改了输入框再切音源：搜的是输入框里的新词', () async {
    final app = AppState.instance;

    app.onSearchInputChanged('歌曲A');
    await app.handleSearch('歌曲A');
    expect(app.searchKeyword, '歌曲A');
    expect(app.searchResults.single.name, '结果-歌曲A');

    // 用户把输入框换成另一个词，还没点搜索
    app.onSearchInputChanged('歌曲B');
    expect(app.searchKeyword, '歌曲A', reason: '结果区这时还是 A 的，状态不该被输入框改动');

    app.setSearchSource('netease');
    await settle(app);

    expect(app.searchKeyword, '歌曲B', reason: '要按输入框现在的内容重搜');
    expect(app.searchResults.single.name, '结果-歌曲B');
    expect(hits.last, '/api/netease/search|歌曲B');
  });

  test('搜出 0 条时换音源也会重搜（空状态本来就写着「换个音源试试」）', () async {
    final app = AppState.instance;
    app.onSearchInputChanged('歌曲A');
    await app.handleSearch('歌曲A');

    // 结果被清空，模拟「这个音源下一条都没有」
    app.searchResults = [];
    hits.clear();

    app.setSearchSource('netease');
    await settle(app);

    expect(hits, isNotEmpty, reason: '没有结果也该去新音源试一次');
  });

  test('歌单页换音源不重搜：输入框里还留着那串链接', () async {
    final app = AppState.instance;
    app.isPlaylistPage = true;
    app.onSearchInputChanged('https://y.qq.com/n/ryqq/playlist/123456');

    app.setSearchSource('netease');
    await settle(app);

    expect(hits, isEmpty);
  });

  test('输入框是空的就不搜', () async {
    final app = AppState.instance;
    app.onSearchInputChanged('   ');

    app.setSearchSource('netease');
    await settle(app);

    expect(hits, isEmpty);
  });
}
