import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../core/file_logger.dart';
import '../core/local_store.dart';
import '../core/lyric.dart';
import '../models/song.dart';
import '../services/api_client.dart';
import '../services/lyric_cache.dart';
import '../services/player_controller.dart';
import 'toast.dart';

enum DownloadStatus { idle, running, done, fail }

/// 全局应用状态 —— `public/dist/js/app.js` 中 `state` + `App` 对象的 Dart 移植。
class AppState extends ChangeNotifier {
  AppState._();

  static final AppState instance = AppState._();

  // ------------------------------------------------------------ 页面

  String page = 'search';
  final Map<String, double> pageScrolls = {};

  // ------------------------------------------------------------ 搜索

  List<Song> searchResults = [];
  String searchKeyword = '';
  int currentPage = 1;
  int searchTotal = 0;
  bool isSearching = false;
  bool isPlaylistPage = false;
  String searchSource = 'qq';

  /// 是否已经完成过一次搜索。
  /// 用来区分「还没搜过」与「搜过了但 0 条」—— 后者以前界面完全没提示，
  /// 看起来就像「点了搜索没反应」（用户反馈）。
  bool hasSearched = false;

  /// 搜索框里的链接样式（等价原 `link-style` 类）
  bool searchLinkStyle = false;

  // ------------------------------------------------------------ 歌单

  List<Song> songs = [];
  final Set<String> selectedMids = {};

  // ------------------------------------------------------------ 设置

  bool highQuality = true;
  String savePath = '';
  List<String> recentDirs = [];
  double zoom = 100;

  String qqCookie = '';
  String neteaseCookie = '';
  String qqCookieStatus = 'pending';
  String neteaseCookieStatus = 'pending';

  // ------------------------------------------------------------ 下载

  final Map<String, String> downloadedPaths = {};
  final Map<String, double> downloadProgress = {};
  final Map<String, DownloadStatus> downloadStatuses = {};

  // ------------------------------------------------------------ 随机 / 历史

  List<String> shufflePlaylist = [];
  int shuffleIndex = -1;
  List<String> playHistory = [];
  int historyIndex = -1;

  // ------------------------------------------------------------ 歌词弹窗

  String? currentLyricMid;
  String currentLyricRaw = '';
  String currentLyricTrans = '';

  bool _inited = false;

  // ------------------------------------------------------------ Toast 便捷方法

  void showSuccess(String msg) => toast.show(msg, type: ToastType.success);
  void showError(String msg) => toast.show(msg, type: ToastType.error);
  void showInfo(String msg) => toast.show(msg, type: ToastType.info);

  // ============================================================ 初始化

  Future<void> init() async {
    if (_inited) return;
    _inited = true;

    _loadSongs();
    _loadShuffleState();
    _loadPlayHistory();

    searchSource = LocalStore.getOr('search_source', 'qq');
    highQuality = LocalStore.get('qqmusic_high_quality') != 'false';
    savePath = LocalStore.getOr('qqmusic_save_path', '');
    zoom = (double.tryParse(LocalStore.getOr('qqmusic_zoom', '100')) ?? 100).clamp(75, 150);
    recentDirs = LocalStore.readJson<List<dynamic>>('qqmusic_recent_dirs', const [])
        .map((e) => e.toString())
        .toList();
    downloadedPaths
      ..clear()
      ..addAll(LocalStore.readMap('qqmusic_downloaded_paths').map(
        (k, v) => MapEntry(k, v.toString()),
      ));

    qqCookie = LocalStore.getOr('qqmusic_cookie', '');
    neteaseCookie = LocalStore.getOr('netease_cookie', '');
    qqCookieStatus = LocalStore.getOr('qqmusic_cookie_status', 'pending');
    neteaseCookieStatus = LocalStore.getOr('netease_cookie_status', 'pending');

    notifyListeners();
    _verifyCookiesInBackground();
  }

  Future<void> _verifyCookiesInBackground() async {
    if (qqCookie.isNotEmpty) {
      try {
        await ApiClient.verifyCookie(qqCookie);
        qqCookieStatus = 'valid';
        LocalStore.set('qqmusic_cookie_status', 'valid');
      } catch (_) {
        qqCookieStatus = 'invalid';
        LocalStore.set('qqmusic_cookie_status', 'invalid');
        toast.show('Cookie 已失效，请在设置中重新配置', type: ToastType.error);
      }
      notifyListeners();
    }
    if (neteaseCookie.isNotEmpty) {
      try {
        await ApiClient.verifyNeteaseCookie(neteaseCookie);
        neteaseCookieStatus = 'valid';
        LocalStore.set('netease_cookie_status', 'valid');
      } catch (_) {
        neteaseCookieStatus = 'invalid';
        LocalStore.set('netease_cookie_status', 'invalid');
      }
      notifyListeners();
    }
  }

  // ============================================================ 持久化

  void _loadSongs() {
    try {
      final raw = LocalStore.get('qqmusic_songs');
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is List) {
        songs = list
            .whereType<Map>()
            .map((e) => Song.fromStoreJson(e.cast<String, dynamic>()))
            .toList();
      }
    } catch (_) {
      songs = [];
    }
  }

  void _saveSongs() {
    LocalStore.writeJson('qqmusic_songs', songs.map((e) => e.toStoreJson()).toList());
  }

  void _saveShuffleState() {
    LocalStore.writeJson('shuffle_playlist', shufflePlaylist);
    LocalStore.set('shuffle_index', '$shuffleIndex');
  }

  void _loadShuffleState() {
    try {
      final pl = LocalStore.readJson<List<dynamic>>('shuffle_playlist', const [])
          .map((e) => e.toString())
          .toList();
      final idx = int.tryParse(LocalStore.getOr('shuffle_index', '-1')) ?? -1;
      if (pl.isNotEmpty && idx >= 0 && idx < pl.length) {
        shufflePlaylist = pl;
        shuffleIndex = idx;
      }
    } catch (_) {}
  }

  void _savePlayHistory() {
    LocalStore.writeJson('play_history', playHistory);
    LocalStore.set('history_index', '$historyIndex');
  }

  void _loadPlayHistory() {
    try {
      playHistory = LocalStore.readJson<List<dynamic>>('play_history', const [])
          .map((e) => e.toString())
          .toList();
      historyIndex = int.tryParse(LocalStore.getOr('history_index', '-1')) ?? -1;
    } catch (_) {
      playHistory = [];
      historyIndex = -1;
    }
  }

  void _saveDownloadedPaths() {
    LocalStore.writeJson('qqmusic_downloaded_paths', downloadedPaths);
  }

  // ============================================================ 导航

  static const List<String> _pageOrder = ['search', 'playlist', 'settings', 'about'];

  /// 页面切换方向：1 = 向右进入，-1 = 向左进入
  int pageDirection = 1;

  void navigate(String target) {
    if (page == target && target != 'playlist' && target != 'settings') return;
    final from = _pageOrder.indexOf(page);
    final to = _pageOrder.indexOf(target);
    pageDirection = to >= from ? 1 : -1;
    page = target;
    notifyListeners();

    if (target == 'playlist') {
      verifyDownloadedPaths().then((_) => notifyListeners());
    }
  }

  // ============================================================ 歌单操作

  bool isAdded(String mid) => songs.any((s) => s.mid == mid);

  bool addToList(Song song) {
    if (isAdded(song.mid)) return false;
    songs.add(song);
    _saveSongs();
    notifyListeners();
    return true;
  }

  void addToTop(Song song) {
    if (isAdded(song.mid)) return;
    songs.insert(0, song);
    _saveSongs();
    notifyListeners();
  }

  void removeFromList(String mid) {
    songs.removeWhere((s) => s.mid == mid);
    selectedMids.remove(mid);
    _saveSongs();
    notifyListeners();
  }

  void clearList() {
    songs = [];
    selectedMids.clear();
    _saveSongs();
    notifyListeners();
  }

  void addAllResults() {
    final toAdd = searchResults.where((s) => !isAdded(s.mid)).toList();
    if (toAdd.isEmpty) return;
    songs.insertAll(0, toAdd);
    _saveSongs();
    notifyListeners();
    toast.show('已置顶 ${toAdd.length} 首', type: ToastType.success);
  }

  Song? findSong(String mid) {
    for (final s in searchResults) {
      if (s.mid == mid) return s;
    }
    for (final s in songs) {
      if (s.mid == mid) return s;
    }
    return null;
  }

  // ============================================================ 选择

  void toggleSelect(String mid) {
    if (selectedMids.contains(mid)) {
      selectedMids.remove(mid);
    } else {
      selectedMids.add(mid);
    }
    notifyListeners();
  }

  bool get allSelected => songs.isNotEmpty && selectedMids.length == songs.length;

  void selectAll() {
    if (allSelected) {
      selectedMids.clear();
    } else {
      selectedMids
        ..clear()
        ..addAll(songs.map((s) => s.mid));
    }
    notifyListeners();
  }

  void invertSelect() {
    final inverted = songs.where((s) => !selectedMids.contains(s.mid)).map((s) => s.mid);
    selectedMids
      ..clear()
      ..addAll(inverted);
    notifyListeners();
  }

  void deleteSelected() {
    if (selectedMids.isEmpty) return;
    songs.removeWhere((s) => selectedMids.contains(s.mid));
    selectedMids.clear();
    _saveSongs();
    notifyListeners();
  }

  // ============================================================ 随机 / 历史

  void _pushHistory(String mid) {
    if (historyIndex >= 0) {
      playHistory = playHistory.sublist(0, math.min(historyIndex + 1, playHistory.length));
    }
    playHistory.remove(mid);
    playHistory.add(mid);
    if (playHistory.length > 200) playHistory.removeAt(0);
    historyIndex = -1;
    _savePlayHistory();
  }

  void _buildShufflePlaylist([String? startMid]) {
    final mids = songs.map((s) => s.mid).toList();
    for (var i = mids.length - 1; i > 0; i--) {
      final j = math.Random().nextInt(i + 1);
      final tmp = mids[i];
      mids[i] = mids[j];
      mids[j] = tmp;
    }
    if (startMid != null && mids.length > 1 && mids[0] == startMid) {
      final tmp = mids[0];
      mids[0] = mids[1];
      mids[1] = tmp;
    }
    shufflePlaylist = mids;
    shuffleIndex = 0;
    playHistory = [];
    historyIndex = -1;
    _saveShuffleState();
    _savePlayHistory();
  }

  Song? _getNextShuffleSong() {
    if (songs.isEmpty) return null;
    if (historyIndex >= 0 && historyIndex < playHistory.length - 1) {
      historyIndex++;
      _savePlayHistory();
      final mid = playHistory[historyIndex];
      return songs.where((s) => s.mid == mid).firstOrNull;
    }
    if (shufflePlaylist.isEmpty || shufflePlaylist.length != songs.length) {
      _buildShufflePlaylist(player.currentSong?.mid);
    }
    shuffleIndex++;
    if (shuffleIndex >= shufflePlaylist.length) {
      _buildShufflePlaylist(player.currentSong?.mid);
    }
    _saveShuffleState();
    final mid = shufflePlaylist[shuffleIndex];
    final song = songs.where((s) => s.mid == mid).firstOrNull;
    if (song == null) {
      _buildShufflePlaylist(player.currentSong?.mid);
      return songs.where((s) => s.mid == shufflePlaylist[0]).firstOrNull;
    }
    return song;
  }

  Song? _reshuffleAndPlayFromEnd() {
    _buildShufflePlaylist(player.currentSong?.mid);
    if (shufflePlaylist.isEmpty) return null;
    shuffleIndex = shufflePlaylist.length - 1;
    playHistory = [...shufflePlaylist];
    historyIndex = shufflePlaylist.length - 1;
    _saveShuffleState();
    _savePlayHistory();
    return songs.where((s) => s.mid == shufflePlaylist[shuffleIndex]).firstOrNull;
  }

  Song? _getPrevShuffleSong() {
    if (songs.isEmpty) return null;
    if (playHistory.isEmpty) return _reshuffleAndPlayFromEnd();
    if (historyIndex == -1) {
      if (playHistory.length < 2) return _reshufflePlayFromEndSafe();
      historyIndex = playHistory.length - 2;
    } else if (historyIndex > 0) {
      historyIndex--;
    } else {
      return _reshufflePlayFromEndSafe();
    }
    _savePlayHistory();
    final mid = playHistory[historyIndex];
    return songs.where((s) => s.mid == mid).firstOrNull;
  }

  Song? _reshufflePlayFromEndSafe() => _reshuffleAndPlayFromEnd();

  /// 播放结束 / 上一首 / 下一首 的统一调度（等价原 `Player.setOnEnded`）
  void handleEndedAction(String action) {
    final current = player.currentSong;
    if (current == null) return;

    Song? next;
    if (player.playMode == PlayMode.shuffle) {
      if (action == 'next' || action == 'random') {
        next = _getNextShuffleSong();
      } else if (action == 'prev') {
        next = _getPrevShuffleSong();
      }
    } else {
      final idx = songs.indexWhere((s) => s.mid == current.mid);
      if (idx < 0) return;
      if (action == 'next') {
        if (idx + 1 < songs.length) {
          next = songs[idx + 1];
        } else if (player.playMode == PlayMode.repeatAll) {
          next = songs.first;
        }
      } else if (action == 'prev') {
        if (idx - 1 >= 0) {
          next = songs[idx - 1];
        } else if (player.playMode == PlayMode.repeatAll) {
          next = songs.last;
        }
      }
    }
    if (next != null) playSong(next.mid, manual: false);
  }

  void onModeChanged(PlayMode mode) {
    if (mode == PlayMode.shuffle) {
      _buildShufflePlaylist(player.currentSong?.mid);
    }
  }

  // ============================================================ 播放

  Future<void> playSong(String mid, {bool manual = true}) async {
    final song = findSong(mid);
    if (song == null) {
      toast.show('歌曲不存在', type: ToastType.error);
      return;
    }
    if (player.playMode == PlayMode.shuffle) {
      if (manual) _buildShufflePlaylist(mid);
      _pushHistory(mid);
    }
    // 先展开播放栏并进入加载态，再去取播放地址（对齐 Electron 的交互）
    player.prepare(song);
    notifyListeners();
    try {
      final url = await ApiClient.getSongUrl(mid, true, song);
      if (url.isNotEmpty) {
        await player.play(song, url);
        notifyListeners();
      } else {
        player.cancelLoading();
        toast.show('无法获取播放链接', type: ToastType.error);
      }
    } catch (e) {
      player.cancelLoading();
      toast.show('播放失败: $e', type: ToastType.error);
    }
  }

  // ============================================================ 搜索

  static final RegExp _qqSongRe = RegExp(r'song/(\w+)');
  static final RegExp _nePlaylistRe = RegExp(r'music\.163\.com.*playlist\?id=(\d+)');
  static final RegExp _neSongRe = RegExp(r'music\.163\.com.*song\?id=(\d+)');
  static final RegExp _playlistRe = RegExp(r'playlist/(\d+)');
  static final RegExp _idRe = RegExp(r'[?&]id=(\d+)');
  static final RegExp _numRe = RegExp(r'^\d+$');

  /// 输入框内容变化时判断搜索按钮是否切换为「链接样式」
  void onSearchInputChanged(String value) {
    final v = value.trim();
    final isLink = RegExp(r'playlist/(\d+)|song/(\w+)|[?&]id=\d+|^\d+$').hasMatch(v);
    final isNeteaseLink = v.contains('music.163.com');
    final next = isLink || isNeteaseLink;
    if (next != searchLinkStyle) {
      searchLinkStyle = next;
      notifyListeners();
    }
  }

  Future<void> handleSearch(String rawKeyword) async {
    if (isSearching) return;
    final keyword = rawKeyword.trim();
    if (keyword.isEmpty) return;

    isSearching = true;
    notifyListeners();

    try {
      String? m;
      if ((m = _nePlaylistRe.firstMatch(keyword)?.group(1)) != null) {
        final toastId = toast.show('网易云音乐 歌单加载中...歌曲过多可能需要十几秒种加载~',
            type: ToastType.progress, duration: 0);
        try {
          final res = await ApiClient.nePlaylist(m!);
          toast.dismiss(toastId);
          if (res.list.isNotEmpty) {
            searchResults = res.list;
            searchKeyword = res.name.isNotEmpty ? res.name : '网易云歌单';
            currentPage = 1;
            isPlaylistPage = true;
            toast.show('歌曲加载完成~', type: ToastType.success);
            notifyListeners();
          } else {
            toast.show('歌单为空或获取失败', type: ToastType.error);
          }
        } catch (e) {
          toast.dismiss(toastId);
          toast.show('歌单加载失败 $e', type: ToastType.error);
        }
      } else if ((m = _neSongRe.firstMatch(keyword)?.group(1)) != null) {
        final res = await ApiClient.neSearch(keyword, 1, 1);
        if (res.list.isNotEmpty) {
          final song = res.list.first;
          addToList(song);
          searchResults = [];
          searchKeyword = '';
          toast.show('已导入: ${song.name}', type: ToastType.success);
          notifyListeners();
        } else {
          toast.show('歌曲不存在', type: ToastType.error);
        }
      } else if (searchSource == 'netease' && !keyword.contains('y.qq.com')) {
        final res = await ApiClient.neSearch(keyword);
        searchResults = res.list;
        searchTotal = res.total;
        searchKeyword = keyword;
        currentPage = 1;
        isPlaylistPage = false;
        hasSearched = true;
        notifyListeners();
      } else if ((m = _playlistRe.firstMatch(keyword)?.group(1) ??
              _idRe.firstMatch(keyword)?.group(1) ??
              (_numRe.hasMatch(keyword) ? keyword : null)) !=
          null) {
        final toastId = toast.show('QQ音乐 歌单加载中...歌曲过多可能需要十几秒种加载~',
            type: ToastType.progress, duration: 0);
        try {
          final res = await ApiClient.getPlaylist(m!);
          toast.dismiss(toastId);
          if (res.list.isNotEmpty) {
            searchResults = res.list;
            searchKeyword = res.name.isNotEmpty ? res.name : 'QQ歌单';
            currentPage = 1;
            isPlaylistPage = true;
            toast.show('歌曲加载完成~', type: ToastType.success);
            notifyListeners();
          } else {
            toast.show('歌单为空或获取失败', type: ToastType.error);
          }
        } catch (e) {
          toast.dismiss(toastId);
          toast.show('歌单加载失败 $e', type: ToastType.error);
        }
      } else if ((m = _qqSongRe.firstMatch(keyword)?.group(1)) != null) {
        final song = await ApiClient.getSongDetail(m!);
        if (song != null) {
          addToList(song);
          searchResults = [];
          searchKeyword = '';
          toast.show('已导入: ${song.name}', type: ToastType.success);
          notifyListeners();
        } else {
          toast.show('歌曲不存在', type: ToastType.error);
        }
      } else {
        final res = await ApiClient.search(keyword);
        searchResults = res.list;
        searchTotal = res.total;
        searchKeyword = keyword;
        currentPage = 1;
        isPlaylistPage = false;
        hasSearched = true;
        notifyListeners();
      }
    } catch (e) {
      hasSearched = true;
      toast.show('搜索失败: $e', type: ToastType.error);
    } finally {
      isSearching = false;
      notifyListeners();
    }
  }

  Future<void> changePage(int target) async {
    if (searchKeyword.isEmpty || target < 1) return;
    try {
      final res = searchSource == 'netease'
          ? await ApiClient.neSearch(searchKeyword, target)
          : await ApiClient.search(searchKeyword, target);
      searchResults = res.list;
      searchTotal = res.total;
      currentPage = target;
      notifyListeners();
    } catch (e) {
      toast.show('加载失败: $e', type: ToastType.error);
    }
  }

  void setSearchSource(String source) {
    if (isSearching) return;
    searchSource = source;
    LocalStore.set('search_source', source);
    notifyListeners();
    if (searchKeyword.isNotEmpty && searchResults.isNotEmpty && !isPlaylistPage) {
      handleSearch(searchKeyword);
    }
  }

  // ============================================================ 设置

  void setHighQuality(bool v) {
    highQuality = v;
    LocalStore.set('qqmusic_high_quality', v.toString());
    notifyListeners();
  }

  void setZoom(double v) {
    zoom = v.clamp(75, 150);
    LocalStore.set('qqmusic_zoom', '${zoom.round()}');
    notifyListeners();
  }

  void setQqCookie(String cookie) {
    qqCookie = cookie;
    LocalStore.set('qqmusic_cookie', cookie);
    if (qqCookieStatus != 'valid') {
      qqCookieStatus = 'pending';
      LocalStore.set('qqmusic_cookie_status', 'pending');
    }
    notifyListeners();
  }

  void clearQqCookie() {
    qqCookie = '';
    qqCookieStatus = 'pending';
    LocalStore.remove('qqmusic_cookie');
    LocalStore.remove('qqmusic_cookie_status');
    notifyListeners();
  }

  void setNeteaseCookie(String cookie) {
    neteaseCookie = cookie;
    LocalStore.set('netease_cookie', cookie);
    if (neteaseCookieStatus != 'valid') {
      neteaseCookieStatus = 'pending';
      LocalStore.set('netease_cookie_status', 'pending');
    }
    notifyListeners();
  }

  void clearNeteaseCookie() {
    neteaseCookie = '';
    neteaseCookieStatus = 'pending';
    LocalStore.remove('netease_cookie');
    LocalStore.remove('netease_cookie_status');
    notifyListeners();
  }

  void setSavePath(String dir) {
    savePath = dir;
    LocalStore.set('qqmusic_save_path', dir);
    notifyListeners();
  }

  void clearSavePath() {
    savePath = '';
    LocalStore.remove('qqmusic_save_path');
    notifyListeners();
  }

  void addRecentDir(String dir) {
    recentDirs = recentDirs.where((d) => d != dir).toList();
    recentDirs.insert(0, dir);
    if (recentDirs.length > 5) recentDirs = recentDirs.sublist(0, 5);
    LocalStore.writeJson('qqmusic_recent_dirs', recentDirs);
    LocalStore.set('qqmusic_save_path', dir);
    savePath = dir;
    notifyListeners();
  }

  void removeRecentDir(String dir) {
    recentDirs = recentDirs.where((d) => d != dir).toList();
    LocalStore.writeJson('qqmusic_recent_dirs', recentDirs);
    notifyListeners();
  }

  // ============================================================ 文件名 / 目录

  static String sanitizeFilename(String name) =>
      name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();

  static Future<String?> pickDirectory() async {
    try {
      final dir = await getDirectoryPath();
      return dir;
    } catch (e) {
      fileLogger.error('Dialog', 'pickDirectory failed: $e');
      return null;
    }
  }

  /// 等价 `shell.showItemInFolder`
  Future<void> showItemInFolder(String filePath) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', ['/select,', filePath.replaceAll('/', '\\')]);
      }
    } catch (e) {
      fileLogger.error('Shell', 'showItemInFolder failed: $e');
    }
  }

  // ============================================================ 下载

  void _setProgress(String mid, double pct, DownloadStatus status) {
    downloadProgress[mid] = pct;
    downloadStatuses[mid] = status;
    notifyListeners();
  }

  Future<bool> _downloadToFile(
    String url,
    String filePath,
    void Function(double pct) onProgress,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        fileLogger.error('Download', 'HTTP ${resp.statusCode} for $url');
        return false;
      }
      final total = resp.contentLength;
      final file = File(filePath);
      await file.parent.create(recursive: true);
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total * 100);
      }
      await sink.flush();
      await sink.close();
      onProgress(100);
      return true;
    } catch (e) {
      fileLogger.error('Download', 'failed: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 单曲下载（对应 `doDownload`），返回是否成功
  Future<bool> downloadSong(
    String mid, {
    required Future<({String path, String filename})?> Function(String filename) askSaveLocation,
  }) async {
    final song = findSong(mid);
    if (song == null) {
      toast.show('歌曲不存在', type: ToastType.error);
      return false;
    }

    final defaultName =
        '${sanitizeFilename(song.name)} - ${sanitizeFilename(song.artist)}.mp3';
    final target = await askSaveLocation(defaultName);
    if (target == null || target.path.isEmpty) {
      _setProgress(mid, 0, DownloadStatus.idle);
      return false;
    }

    _setProgress(mid, 0, DownloadStatus.running);
    try {
      final data = await ApiClient.downloadSong(song, target.filename);
      final audioUrl = ApiClient.getProxyAudioUrl(data.url);
      if (audioUrl.isEmpty) {
        _setProgress(mid, 0, DownloadStatus.fail);
        return false;
      }
      final fullPath = '${target.path}${Platform.pathSeparator}${target.filename}';
      final ok = await _downloadToFile(audioUrl, fullPath, (pct) {
        _setProgress(mid, pct, DownloadStatus.running);
      });
      if (ok) {
        addRecentDir(target.path);
        downloadedPaths[mid] = fullPath;
        _saveDownloadedPaths();
        _setProgress(mid, 100, DownloadStatus.done);
        toast.show('下载完成: ${target.filename}', type: ToastType.success);
        return true;
      }
      _setProgress(mid, 0, DownloadStatus.fail);
      toast.show('下载失败', type: ToastType.error);
      return false;
    } catch (e) {
      _setProgress(mid, 0, DownloadStatus.fail);
      toast.show('下载失败: $e', type: ToastType.error);
      return false;
    }
  }

  /// 批量下载（对应 `doBatchDownload`）
  Future<void> batchDownload(List<Song> targetSongs) async {
    if (targetSongs.isEmpty) return;

    var saveDir = savePath;
    if (saveDir.isEmpty) {
      final dir = await pickDirectory();
      if (dir == null || dir.isEmpty) return;
      saveDir = dir;
      setSavePath(dir);
    }

    final toastId = toast.show('批量下载 ${targetSongs.length} 首...',
        type: ToastType.progress, duration: 0);

    try {
      final urls = await ApiClient.getBatchUrls(targetSongs, highQuality);
      var ok = 0;
      var fail = 0;

      for (final item in urls) {
        final mid = (item['mid'] ?? item['id'] ?? '').toString();
        final url = (item['url'] ?? '').toString();
        if (url.isEmpty) {
          if (mid.isNotEmpty) _setProgress(mid, 0, DownloadStatus.fail);
          fail++;
          continue;
        }
        final name = sanitizeFilename((item['name'] ?? '未知').toString());
        final artist = sanitizeFilename((item['artist'] ?? '未知').toString());
        final filename = '$name - $artist.mp3';

        try {
          if (mid.isNotEmpty) _setProgress(mid, 0, DownloadStatus.running);
          final audioUrl = ApiClient.getProxyAudioUrl(url);
          final fullPath = '$saveDir${Platform.pathSeparator}$filename';
          final done = await _downloadToFile(audioUrl, fullPath, (pct) {
            if (mid.isNotEmpty) _setProgress(mid, pct, DownloadStatus.running);
          });
          if (done) {
            if (mid.isNotEmpty) {
              downloadedPaths[mid] = fullPath;
              _setProgress(mid, 100, DownloadStatus.done);
            }
            ok++;
          } else {
            if (mid.isNotEmpty) _setProgress(mid, 0, DownloadStatus.fail);
            fail++;
          }
        } catch (e) {
          if (mid.isNotEmpty) _setProgress(mid, 0, DownloadStatus.fail);
          fail++;
        }
      }

      _saveDownloadedPaths();
      if (ok > 0) {
        toast.update(toastId, '成功下载 $ok 首${fail > 0 ? '，$fail 首失败' : ''}',
            type: ToastType.success);
      } else {
        toast.update(toastId, '下载失败', type: ToastType.error);
      }
      Timer(const Duration(seconds: 3), () => toast.dismiss(toastId));
    } catch (e) {
      toast.update(toastId, '批量下载失败: $e', type: ToastType.error);
      Timer(const Duration(seconds: 3), () => toast.dismiss(toastId));
    }
  }

  List<Song> get songsForBatchDownload => selectedMids.isEmpty
      ? songs
      : songs.where((s) => selectedMids.contains(s.mid)).toList();

  /// 校验已下载文件是否仍存在（对应 `verifyDownloadedPaths`）
  Future<void> verifyDownloadedPaths() async {
    var changed = false;
    final keys = downloadedPaths.keys.toList();
    for (final mid in keys) {
      final exists = await File(downloadedPaths[mid]!).exists();
      if (!exists) {
        downloadedPaths.remove(mid);
        changed = true;
      }
    }
    if (changed) _saveDownloadedPaths();
  }

  Future<void> openFileFolder(String mid) async {
    final p = downloadedPaths[mid];
    if (p == null || p.isEmpty) {
      toast.show('文件路径不存在', type: ToastType.error);
      return;
    }
    await showItemInFolder(p);
  }

  // ============================================================ 导出歌单

  Future<void> exportPlaylist() async {
    if (songs.isEmpty) {
      toast.show('歌单为空', type: ToastType.error);
      return;
    }
    var md = '# 我的歌单\n\n| # | 歌曲名 | 歌手 |\n|---|--------|------|\n';
    for (var i = 0; i < songs.length; i++) {
      md += '| ${i + 1} | ${songs[i].name} | ${songs[i].artist} |\n';
    }
    final now = DateTime.now();
    md += '\n导出时间: $now\n共 ${songs.length} 首\n';

    final date = now.toIso8601String().substring(0, 10);
    final filename = '歌单_$date.md';

    String? dir = savePath;
    if (dir.isEmpty) dir = await pickDirectory();
    if (dir == null || dir.isEmpty) return;

    try {
      final file = File('$dir${Platform.pathSeparator}$filename');
      await file.writeAsString(md, flush: true);
      toast.show('已导出歌单', type: ToastType.success);
    } catch (e) {
      toast.show('导出失败: $e', type: ToastType.error);
    }
  }

  // ============================================================ 歌词弹窗

  String? lyricErrorToast;
  List<LyricLineBox> currentLyricParsed = [];
  Map<double, String> currentLyricTransMap = {};

  /// 正在拉取歌词（弹窗用来显示加载态，避免「点了没反应」）
  bool lyricLoading = false;

  /// 歌词弹窗打开请求计数器（UI 层监听该值变化来弹出对话框）
  int lyricDialogRequest = 0;

  /// 请求打开歌词弹窗。
  ///
  /// ⚠️ 顺序很重要：**先递增请求计数器把弹窗弹出来**，再取歌词。
  /// 早期实现是「await 取完歌词再弹窗」，于是弹窗出现时间完全取决于网络，
  /// 表现为「点歌词按钮时快时慢」。现在命中缓存瞬间显示，未命中则先显示加载态。
  Future<void> requestLyricDialog(String mid) async {
    currentLyricMid = mid;
    final song = findSong(mid);
    final cached = LyricCache.peek(mid);

    if (cached != null) {
      _applyLyricBundle(cached);
      lyricLoading = false;
    } else {
      currentLyricRaw = '';
      currentLyricTrans = '';
      currentLyricParsed = [];
      currentLyricTransMap = {};
      lyricLoading = true;
    }
    lyricDialogRequest++; // 先弹窗
    notifyListeners();

    if (cached != null) return;

    final bundle = await LyricCache.load(mid, isNetease: song?.isNetease ?? false);
    if (currentLyricMid != mid) return; // 期间用户又切了别的歌
    if (bundle != null) _applyLyricBundle(bundle);
    lyricLoading = false;
    notifyListeners();
  }

  void _applyLyricBundle(LyricBundle b) {
    currentLyricRaw = b.raw;
    currentLyricTrans = b.trans;
    currentLyricParsed =
        b.lines.map((e) => LyricLineBox(e.time, e.text)).toList();
    currentLyricTransMap = b.transMap;
  }

  /// 只加载歌词、不弹窗（供编辑态重载等场景使用）
  Future<void> loadLyricForModal(String mid) async {
    final song = findSong(mid);
    currentLyricMid = mid;
    lyricLoading = true;
    notifyListeners();
    final bundle = await LyricCache.load(mid, isNetease: song?.isNetease ?? false);
    if (currentLyricMid != mid) return;
    if (bundle != null) _applyLyricBundle(bundle);
    lyricLoading = false;
    notifyListeners();
  }

  void saveLyric(String raw, String trans) {
    final mid = currentLyricMid;
    if (mid == null) {
      toast.show('无法保存：歌曲信息丢失', type: ToastType.error);
      return;
    }
    if (raw.trim().isEmpty) {
      LocalStore.remove('custom_lyric_$mid');
    } else {
      LocalStore.set('custom_lyric_$mid', raw);
    }
    if (trans.trim().isEmpty) {
      LocalStore.remove('custom_lyric_trans_$mid');
    } else {
      LocalStore.set('custom_lyric_trans_$mid', trans);
    }
    LyricCache.invalidate(mid); // 自定义歌词已变，缓存作废
    currentLyricRaw = raw;
    currentLyricTrans = trans;
    notifyListeners();
    toast.show('歌词已保存', type: ToastType.success);
  }

  /// 供 UI 使用的歌词标题
  String get lyricTitle {
    final mid = currentLyricMid;
    if (mid == null) return '歌词';
    if (player.currentSong?.mid == mid) {
      return '${player.currentSong!.name} - ${player.currentSong!.artist}';
    }
    final s = findSong(mid);
    return s != null ? '${s.name} - ${s.artist}' : '歌词';
  }

  void reloadLyricFromStore() {
    final mid = currentLyricMid;
    if (mid == null) return;
    currentLyricParsed =
        parseLrc(currentLyricRaw).map((e) => LyricLineBox(e.time, e.text)).toList();
    currentLyricTransMap = parseTransLrc(currentLyricTrans);
    notifyListeners();
  }
}

/// 歌词弹窗内部使用的行结构（避免与 core/lyric 的只读模型混淆）
class LyricLineBox {
  final double time;
  final String text;
  const LyricLineBox(this.time, this.text);
}

final app = AppState.instance;
