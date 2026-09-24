import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../core/file_logger.dart';
import '../core/local_store.dart';
import '../core/lyric.dart';
import '../core/perf_probe.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/api_client.dart';
import '../services/audio_cache.dart';
import '../services/bilibili_service.dart';
import '../services/lyric_cache.dart';
import '../services/netease_service.dart';
import '../services/player_controller.dart';
import '../services/qqmusic_service.dart';
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

  /// 上游搜出来的歌。**mid 为空的直接丢掉**（见 [Song.hasMid]）。
  ///
  /// 搜索页是这些歌唯一的入口（右键加歌单、全部添加都从这里取），
  /// 在这一层滤掉，等于「不显示也不添加」。
  List<Song> get searchResults => _searchResults;
  set searchResults(List<Song> v) =>
      _searchResults = v.where((s) => s.hasMid).toList();

  List<Song> _searchResults = [];

  /// 上一次**搜过**的关键词（结果区标题、翻页缓存都用它）
  String searchKeyword = '';

  /// 输入框里**当前**的内容。
  ///
  /// 输入框由 shell 持有，状态层拿不到那个控制器，所以在这里同步一份。
  /// 换音源时要按它重搜，不能按 [searchKeyword] —— 后者是上一次搜过的词，
  /// 用户改了输入框还没搜，两者就不一样了。
  String searchInput = '';
  int currentPage = 1;
  int searchTotal = 0;
  bool isSearching = false;

  /// 正在换页（翻页按钮据此禁用并显示加载态）。
  ///
  /// 换页请求慢的时候，界面上必须**先有反馈**再换内容 ——
  /// 否则表现为「点了下一页，页面瞬间回到顶部、内容还是旧的」。
  bool pageLoading = false;
  bool isPlaylistPage = false;
  /// 当前音源：'qq' | 'netease' | 'bilibili'
  String searchSource = 'qq';

  /// 是否已经完成过一次搜索。
  /// 用来区分「还没搜过」与「搜过了但 0 条」—— 后者以前界面完全没提示，
  /// 看起来就像「点了搜索没反应」。
  bool hasSearched = false;

  /// 搜索框里的链接样式（等价原 `link-style` 类）
  bool searchLinkStyle = false;

  // ------------------------------------------------------------ 歌单

  // ------------------------------------------------------------ 歌单

  /// 所有歌单。永远至少有一个 —— 删到最后一个会被拦住。
  List<Playlist> playlists = [];

  /// 当前歌单的 id
  String currentPlaylistId = '';

  static const String kDefaultPlaylistName = '默认歌单';

  Playlist get currentPlaylist {
    for (final p in playlists) {
      if (p.id == currentPlaylistId) return p;
    }
    // id 对不上（歌单被删了、存档读坏了）：兜回第一个，必要时现造一个
    if (playlists.isEmpty) {
      playlists.add(Playlist(id: _newPlaylistId(), name: kDefaultPlaylistName));
    }
    currentPlaylistId = playlists.first.id;
    return playlists.first;
  }

  /// 当前歌单的歌。
  ///
  /// **整个应用都通过它读写当前歌单** —— 多歌单之后这里仍然是一个
  /// `List<Song>`，所以原来那些 `songs.add / removeWhere / ...` 一处都不用改。
  List<Song> get songs => currentPlaylist.songs;
  set songs(List<Song> v) => currentPlaylist.songs = v;

  /// 所有歌单里的 mid。缓存淘汰要用它 —— 只看当前歌单的话，
  /// 切到另一个歌单时前一个歌单的歌会被判成「已经不在歌单里」而清掉缓存。
  Set<String> get allPlaylistMids =>
      {for (final p in playlists) ...p.songs.map((s) => s.mid)};

  String _newPlaylistId() {
    var id = 'pl-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    while (playlists.any((p) => p.id == id)) {
      id = '${id}x';
    }
    return id;
  }

  Playlist createPlaylist([String name = '新歌单']) {
    final p = Playlist(id: _newPlaylistId(), name: name);
    playlists.add(p);
    _savePlaylists();
    notifyListeners();
    return p;
  }

  /// 切歌单。选中态要跟着清 —— 选中的是「这个歌单里的哪几首」，
  /// 留着上一份会张冠李戴。
  void switchPlaylist(String id) {
    if (currentPlaylistId == id) return;
    if (!playlists.any((p) => p.id == id)) return;
    currentPlaylistId = id;
    selectedMids.clear();
    LocalStore.set('qqmusic_current_playlist', id);
    notifyListeners();
  }

  void renamePlaylist(String id, String name) {
    final next = name.trim();
    if (next.isEmpty) return;
    final i = playlists.indexWhere((p) => p.id == id);
    if (i < 0 || playlists[i].name == next) return;
    playlists[i].name = next;
    _savePlaylists();
    notifyListeners();
  }

  /// 删歌单。**最后一个不给删** —— 应用总得有一个能放歌的地方。
  bool deletePlaylist(String id) {
    if (playlists.length <= 1) return false;
    final i = playlists.indexWhere((p) => p.id == id);
    if (i < 0) return false;
    playlists.removeAt(i);
    if (currentPlaylistId == id) {
      currentPlaylistId = playlists.first.id;
      selectedMids.clear();
      LocalStore.set('qqmusic_current_playlist', currentPlaylistId);
    }
    _savePlaylists();
    notifyListeners();
    return true;
  }

  /// 侧边栏的歌单子列表是否展开。切到歌单页会自动展开 ——
  /// 进了歌单页却看不到有哪些歌单，会以为只有一个。
  bool playlistsExpanded = false;

  void togglePlaylistsExpanded() {
    playlistsExpanded = !playlistsExpanded;
    notifyListeners();
  }
  final Set<String> selectedMids = {};

  // ------------------------------------------------------------ 设置

  bool highQuality = true;
  String savePath = '';
  List<String> recentDirs = [];
  double zoom = 110;

  /// 当前打开着「+」二级菜单的歌曲 mid（没有则为 null）。
  /// 搜索卡片靠它决定「弹出层打开期间也显示操作按钮」，
  /// 否则遮罩会让卡片失去 hover、按钮闪一下。
  String? openAddMenuMid;

  void setOpenAddMenu(String? mid) {
    if (openAddMenuMid == mid) return;
    openAddMenuMid = mid;
    notifyListeners();
  }

  String qqCookie = '';
  String neteaseCookie = '';
  String qqCookieStatus = 'pending';
  String neteaseCookieStatus = 'pending';

  /// B站 cookie。不填也能用（游客态），填了才能拿私密投稿、搜索排序也才与网页一致。
  String biliCookie = '';
  String biliCookieStatus = 'pending';

  // 校验通过后填充，供设置页显示（昵称 / 登录方式 / 是否绿钻）
  String qqNickname = '';
  bool qqIsWechat = false;
  bool qqIsVip = false;

  // 网易云同理（昵称 / 是否黑胶）——网易云 cookie 看不出登录方式，就没这一项
  String neNickname = '';
  bool neIsVip = false;

  // B站（昵称 / 是否大会员）
  String biliNickname = '';
  bool biliIsVip = false;

  // ------------------------------------------------------------ 下载

  final Map<String, String> downloadedPaths = {};
  final Map<String, double> downloadProgress = {};
  final Map<String, DownloadStatus> downloadStatuses = {};

  // ------------------------------------------------------------ 播放队列

  /// 播放队列 —— 播放栏**只**按它走，没有第二个隐藏池。
  ///
  /// 顺序类模式下它就是歌单的顺序；随机模式下是洗好的顺序（以前是藏着的，
  /// 现在由播放栏的「播放列表」面板摊开给用户看）。
  ///
  /// 存 [Song] 而不是 mid：队列里可能有**不在歌单里**的歌 —— 右键
  /// 「插入到下一首」从搜索页插进来的那种，按 mid 在歌单里查不到。
  List<Song> playQueue = [];

  /// [playQueue] 里正在播放那首的下标。-1 = 还没开始播。
  int queueIndex = -1;

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

    _loadPlaylists();

    searchSource = LocalStore.getOr('search_source', 'qq');
    highQuality = LocalStore.get('qqmusic_high_quality') != 'false';
    savePath = LocalStore.getOr('qqmusic_save_path', '');
    // 默认 110%：未设置过时用它；已设置过的仍读存下来的值
    zoom = (double.tryParse(LocalStore.getOr('qqmusic_zoom', '110')) ?? 110)
        .clamp(75, 150);
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
    qqNickname = LocalStore.getOr('qqmusic_nickname', '');
    qqIsWechat = LocalStore.getOr('qqmusic_is_wechat', 'false') == 'true';
    qqIsVip = LocalStore.getOr('qqmusic_is_vip', 'false') == 'true';
    neNickname = LocalStore.getOr('netease_nickname', '');
    neIsVip = LocalStore.getOr('netease_is_vip', 'false') == 'true';
    biliCookie = LocalStore.getOr('bilibili_cookie', '');
    biliCookieStatus = LocalStore.getOr('bilibili_cookie_status', 'pending');
    biliNickname = LocalStore.getOr('bilibili_nickname', '');
    biliIsVip = LocalStore.getOr('bilibili_is_vip', 'false') == 'true';

    // ck 被刷新后要落盘：服务层只负责换 key，存储归这里管
    qqMusicService.onCookieRefreshed = (fresh) {
      qqCookie = fresh;
      LocalStore.set('qqmusic_cookie', fresh);
      notifyListeners();
    };

    notifyListeners();
    _verifyCookiesInBackground();
  }

  Future<void> _verifyCookiesInBackground() async {
    if (qqCookie.isNotEmpty) {
      // 先看 musickey 是不是该换了（约 12 小时过期）。它过期后接口只是
      // 静默返回空地址、不会报错，所以这里主动换一次，别等用户点不开歌。
      qqMusicService.setCookie(qqCookie);
      await qqMusicService.ensureCookieFresh();

      final info = await qqMusicService.fetchUserInfo();
      switch (info.outcome) {
        case CkOutcome.ok:
          applyQqUserInfo(
            nickname: info.nickname,
            isWechat: info.isWechat,
            isVip: info.isVip,
          );
        case CkOutcome.rejected:
          qqCookieStatus = 'invalid';
          LocalStore.set('qqmusic_cookie_status', 'invalid');
          toast.show('QQ 音乐 Cookie 已失效，请在设置中重新配置', type: ToastType.error);
          notifyListeners();
        case CkOutcome.unreachable:
          // 账号接口没连上，这份 ck 是好是坏无从判断 ——
          // 拿一次网络抖动去改用户看到的状态，只会让他白填一遍。
          fileLogger.warn('App', 'QQ ck 校验未能完成，保留原状态（$qqCookieStatus）');
      }
    }
    if (neteaseCookie.isNotEmpty) {
      try {
        await ApiClient.verifyNeteaseCookie(neteaseCookie);
        // 顺手把昵称和会员状态取回来 —— 设置页的账号信息就靠它，
        // 不然每次启动都得手动点一次验证才看得到。
        final info = await neteaseMusicService.getUserInfo();
        if (info != null) {
          applyNeUserInfo(
            nickname: (info['nickname'] ?? '').toString(),
            isVip: info['isVip'] == true,
          );
        } else {
          neteaseCookieStatus = 'valid';
          LocalStore.set('netease_cookie_status', 'valid');
        }
      } catch (_) {
        neteaseCookieStatus = 'invalid';
        LocalStore.set('netease_cookie_status', 'invalid');
      }
      notifyListeners();
    }

    if (biliCookie.isNotEmpty) {
      bilibiliService.setCookie(biliCookie);
      try {
        final info = await bilibiliService.fetchUserInfo();
        if (info != null) {
          applyBiliUserInfo(nickname: info.nickname, isVip: info.isVip);
        } else {
          biliCookieStatus = 'invalid';
          LocalStore.set('bilibili_cookie_status', 'invalid');
        }
      } catch (e) {
        // 请求本身失败（超时、断网、服务端抽风）就**保留上一次的状态**：
        // 把这些当成「ck 失效」会让用户白填一遍，而实际上什么都没变。
        fileLogger.warn('Bilibili', '启动校验 ck 失败，保留原状态: $e');
      }
      notifyListeners();
    }
  }

  // ============================================================ 持久化

  /// 读歌单。
  ///
  /// 老版本只有一份歌单（`qqmusic_songs`）—— 读不到新结构时把它搬进
  /// 「默认歌单」，升级之后看到的还是原来那些歌，不会因为改结构丢东西。
  void _loadPlaylists() {
    try {
      final raw = LocalStore.get('qqmusic_playlists');
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          playlists =
              list.map(Playlist.fromStoreJson).whereType<Playlist>().toList();
        }
      }
    } catch (_) {
      playlists = [];
    }
    if (playlists.isEmpty) {
      playlists = [
        Playlist(
          id: _newPlaylistId(),
          name: kDefaultPlaylistName,
          songs: _legacySongs(),
        ),
      ];
    }
    final saved = LocalStore.get('qqmusic_current_playlist') ?? '';
    currentPlaylistId =
        playlists.any((p) => p.id == saved) ? saved : playlists.first.id;
  }

  /// 老结构里的那一份歌单
  List<Song> _legacySongs() {
    try {
      final raw = LocalStore.get('qqmusic_songs');
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((e) => Song.fromStoreJson(e.cast<String, dynamic>()))
          .where((s) => s.hasMid)
          .toList();
    } catch (_) {
      return [];
    }
  }

  void _savePlaylists() {
    LocalStore.writeJson(
      'qqmusic_playlists',
      playlists.map((p) => p.toStoreJson()).toList(),
    );
  }

  /// 歌单内容变了。现在整份歌单结构一起落盘，调用方不用关心。
  void _saveSongs() => _savePlaylists();

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
    // 切页时歌单子列表跟着收/展：进了别的页面还挂着那一排歌单，
    // 侧边栏会一直占着高度；回到歌单页则自动展开（不然看不到有哪些歌单）。
    playlistsExpanded = target == 'playlist';
    // 探针开着时给这一段起个名，方便把帧耗时对上具体操作
    PerfProbe.mark('切页→$target');
    notifyListeners();

    if (target == 'playlist') {
      verifyDownloadedPaths().then((_) => notifyListeners());
    }
  }

  // ============================================================ 歌单操作

  bool isAdded(String mid) => songs.any((s) => s.mid == mid);

  bool addToList(Song song) {
    if (!song.hasMid) return false;
    if (isAdded(song.mid)) return false;
    songs.add(song);
    _saveSongs();
    notifyListeners();
    return true;
  }

  void addToTop(Song song) {
    if (!song.hasMid) return;
    if (isAdded(song.mid)) return;
    songs.insert(0, song);
    _saveSongs();
    notifyListeners();
  }

  /// 某个歌单里有没有这首歌。菜单里要据此把对应项置灰。
  bool playlistHasSong(String playlistId, String mid) {
    final i = playlists.indexWhere((p) => p.id == playlistId);
    if (i < 0) return false;
    return playlists[i].songs.any((s) => s.mid == mid);
  }

  /// 加进**指定歌单**的顶部。搜索页让用户选歌单之后走这里。
  void addToPlaylist(String playlistId, Song song) {
    if (!song.hasMid) return;
    final i = playlists.indexWhere((p) => p.id == playlistId);
    if (i < 0) return;
    if (playlists[i].songs.any((s) => s.mid == song.mid)) return;
    playlists[i].songs.insert(0, song);
    _savePlaylists();
    notifyListeners();
    toast.show('已加入「${playlists[i].name}」', type: ToastType.success);
  }

  /// 把当前搜索结果里**还没有的**加进指定歌单。
  /// 已经在里面的不动 —— 重复添加会把顺序搞乱，也会出现两首一样的。
  void addAllToPlaylist(String playlistId) {
    final i = playlists.indexWhere((p) => p.id == playlistId);
    if (i < 0) return;
    final p = playlists[i];
    final have = {for (final s in p.songs) s.mid};
    final toAdd =
        searchResults.where((s) => !have.contains(s.mid)).toList(growable: false);
    if (toAdd.isEmpty) {
      showInfo('「${p.name}」里已经有这些歌了');
      return;
    }
    p.songs.insertAll(0, toAdd);
    _savePlaylists();
    notifyListeners();
    showSuccess('已加入 ${toAdd.length} 首到「${p.name}」');
  }

  /// 整个歌单倒序。顺序变了要落盘，不然重启就复原。
  void reversePlaylist() {
    if (songs.length < 2) return;
    songs = songs.reversed.toList();
    _saveSongs();
    notifyListeners();
    showSuccess('已倒序「${currentPlaylist.name}」');
  }

  /// 拖动排序：把第 [from] 首插到第 [to] 首的位置上。
  ///
  /// 两个下标都是**当前歌单**的下标 —— 歌单页只在没过滤时开放拖动
  /// （搜索过滤后的下标跟歌单下标不是一回事，直接搬会挪错位置）。
  /// 落点由框架算好：`ReorderableListView` 传过来的 to 已经扣掉了
  /// 「被拖走的那一格」，这里不用再 `if (to > from) to--`。
  void moveSong(int from, int to) {
    if (from == to) return;
    if (from < 0 || from >= songs.length) return;
    if (to < 0 || to >= songs.length) return;
    final song = songs.removeAt(from);
    songs.insert(to, song);
    _saveSongs();
    notifyListeners();
  }

  /// 把**已经在歌单里**的一首挪到最前。
  ///
  /// 与 [addToTop] 不同：那个是「加进来」，已经在歌单里就直接返回、挪不动。
  void moveToTop(String mid) {
    final i = songs.indexWhere((s) => s.mid == mid);
    if (i <= 0) return;
    final song = songs.removeAt(i);
    songs.insert(0, song);
    _saveSongs();
    notifyListeners();
    toast.show('已置顶: ${song.name}', type: ToastType.success);
  }

  /// 把已经在歌单里的一首挪到最后
  void moveToBottom(String mid) {
    final i = songs.indexWhere((s) => s.mid == mid);
    if (i < 0 || i == songs.length - 1) return;
    final song = songs.removeAt(i);
    songs.add(song);
    _saveSongs();
    notifyListeners();
    toast.show('已置底: ${song.name}', type: ToastType.success);
  }

  /// 改歌名。只动本地记录 —— 上游没有「改标题」这回事，改名也不影响
  /// 取流和歌词（两者都按 mid 走）。
  void renameSong(String mid, String newName) {
    final i = songs.indexWhere((s) => s.mid == mid);
    if (i < 0) return;
    songs[i] = songs[i].copyWith(name: newName);
    player.renameCurrentSong(mid, newName);
    _saveSongs();
    notifyListeners();
  }

  void removeFromList(String mid) {
    songs.removeWhere((s) => s.mid == mid);
    selectedMids.remove(mid);
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

  /// 按 mid 找歌。**歌单优先**。
  ///
  /// 歌名是可以就地改的，改的是歌单里那一份，搜索结果里还是旧的。
  /// 先命中搜索结果的话，改名后去播放这首歌，播放栏拿到的就是改名前的名字
  ///（要等播放中再改一次才显示新的）。
  /// 按 mid 找歌：**先搜所有歌单**（当前歌单优先），再搜搜索结果。
  ///
  /// 不能只搜当前歌单：恢复上次播放态、以及队列里那些歌都可能来自别的歌单，
  /// 只认当前歌单会「找不到」，被当成已经删除。
  Song? findSong(String mid) {
    for (final s in songs) {
      if (s.mid == mid) return s;
    }
    for (final p in playlists) {
      if (p.id == currentPlaylistId) continue;
      for (final s in p.songs) {
        if (s.mid == mid) return s;
      }
    }
    for (final s in searchResults) {
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
    // **必须先 toList()**：`where` 是惰性的，直接 addAll 会在 clear() 之后才
    // 求值 —— 那时集合已经空了，每首都判成「没选中」，反选变成全选。
    final inverted = songs
        .where((s) => !selectedMids.contains(s.mid))
        .map((s) => s.mid)
        .toList();
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

  // ============================================================ 播放队列

  /// 队列空的时候按当前模式建一次。
  ///
  /// 「播放列表」面板打开时也调它 —— 启动后还没播过东西时队列是空的，
  /// 直接摊开一个空列表很奇怪。
  void ensureQueue() {
    if (playQueue.isNotEmpty || songs.isEmpty) return;
    _rebuildQueue();
  }

  /// 按当前模式重建队列，[keep] 是重建后要当作「当前这首」的歌
  /// （不传就沿用播放器里正在播的那首）。
  ///
  /// * 随机：重洗一遍；
  /// * **倒序：把歌单整个反过来** —— 播放栏严格按队列内容走，所以「倒序」必须
  ///   落在队列本身，而不是只体现在游标方向上；
  /// * 其余：就是歌单顺序。
  void _rebuildQueue({Song? keep}) {
    final cur = keep ?? player.currentSong;
    final list = player.playMode == PlayMode.reverse
        ? songs.reversed.toList()
        : [...songs];
    if (player.playMode == PlayMode.shuffle) _shuffle(list);
    // 正在播的那首如果不在歌单里（从搜索页插进来的），得把它留在队列里 ——
    // 重建时丢掉的话，面板上会出现「正在播的歌不在列表里」。
    var idx = cur == null ? -1 : list.indexWhere((s) => s.mid == cur.mid);
    if (cur != null && idx < 0) {
      list.insert(0, cur);
      idx = 0;
    }
    playQueue = list;
    queueIndex = idx;
  }

  /// 原地洗牌
  static void _shuffle(List<Song> list) {
    for (var i = list.length - 1; i > 0; i--) {
      final j = math.Random().nextInt(i + 1);
      final tmp = list[i];
      list[i] = list[j];
      list[j] = tmp;
    }
  }

  /// 把 [song] 插到「正在播的那首」后面。
  ///
  /// 已经在队列里的话先把它从原位置摘掉 —— 不摘会出现同一首歌占两处，
  /// 而「插入到下一首」要的就是它紧接着播。
  void insertNext(Song song) {
    if (!song.hasMid) return;
    var at = queueIndex;
    if (at < 0 || at >= playQueue.length) {
      // 还没开始播：插到队首，下一次播放就是它
      playQueue.insert(0, song);
      notifyListeners();
      return;
    }
    final existing = playQueue.indexWhere((s) => s.mid == song.mid);
    if (existing >= 0) {
      playQueue.removeAt(existing);
      // 摘掉的位置在当前位置之前，当前位置要跟着左移一格
      if (existing < at) at--;
    }
    playQueue.insert(at + 1, song);
    queueIndex = at;
    notifyListeners();
  }

  /// 队列里的「下一首」（并把游标推进一格）。走到队尾时的行为由播放模式决定。
  ///
  /// 倒序模式走的是**队列本身**（队列已经是反过来的），所以这里不需要分方向。
  ///
  /// 是纯逻辑：不碰播放器、不发网络请求。所以测试可以直接调它 ——
  /// 走 [handleEndedAction] 会真的去取播放地址。
  Song? nextInQueue() {
    if (playQueue.isEmpty) return null;
    if (queueIndex + 1 < playQueue.length) {
      queueIndex++;
      return playQueue[queueIndex];
    }
    switch (player.playMode) {
      case PlayMode.sequential:
      case PlayMode.reverse:
        // 顺序 / 倒序：播完就停，不绕回去 —— 这正是它们与循环的区别
        return null;
      case PlayMode.shuffle:
        // 随机：整池放完重洗一遍接着放
        _rebuildQueue();
        if (playQueue.isEmpty) return null;
        queueIndex = 0;
        return playQueue[0];
      case PlayMode.repeatAll:
      case PlayMode.repeatOne:
        queueIndex = 0;
        return playQueue[0];
    }
  }

  /// 队列里的「上一首」（游标退一格）。队首时顺序/倒序不动，其余模式绕到队尾。
  ///
  /// 随机模式下顺带把「当前这首**之后**」的那一段重洗 —— 上一首的语义是
  /// 「这首不对，换一批」，不重洗的话紧接着点下一首又会回到刚才那首。
  /// 当前之前那一段（已经听过的）保留，否则往回翻就没有意义了。
  ///
  /// 例：队列 `[A,B,C,D,E]` 正在放 C，点上一首 → 放 B，队列变成 `[A,B,E,C,D]`。
  Song? prevInQueue() {
    if (playQueue.isEmpty) return null;
    if (queueIndex > 0) {
      queueIndex--;
    } else if (!player.playMode.stopsAtEnd) {
      queueIndex = playQueue.length - 1;
    } else {
      return null;
    }
    if (player.playMode == PlayMode.shuffle) {
      final tail = playQueue.sublist(queueIndex + 1);
      _shuffle(tail);
      playQueue = [...playQueue.sublist(0, queueIndex + 1), ...tail];
    }
    return playQueue[queueIndex];
  }

  /// 把这首歌从播放队列里摘掉（面板右键菜单用）。
  ///
  /// 摘的是**正在播**的那首时游标跟着挪一格，否则下一首会跳过一首。
  void removeFromQueue(Song song) {
    final at = playQueue.indexWhere((s) => s.mid == song.mid);
    if (at < 0) return;
    playQueue.removeAt(at);
    if (at < queueIndex) {
      queueIndex--;
    } else if (at == queueIndex) {
      queueIndex = queueIndex < playQueue.length ? queueIndex : playQueue.length - 1;
    }
    notifyListeners();
  }

  /// 播放结束 / 上一首 / 下一首 的统一调度（等价原 `Player.setOnEnded`）
  void handleEndedAction(String action) {
    ensureQueue();
    final next = action == 'prev' ? prevInQueue() : nextInQueue();
    if (next != null) playResolved(next, manual: false);
  }

  /// 上游只给了试听片段（会员曲目没权限时是 30 秒）。
  ///
  /// 必须把那份缓存删掉：不删的话它会一直被命中，用户后来配好了会员
  /// 也还是听到那 30 秒 —— 表现成「有黑胶也只能听 30 秒」。
  void onShortAudio(Song song) {
    AudioDiskCache.drop(song.mid);
    AudioDiskCache.markTrial(song.mid);
    showInfo('《${song.name}》只能试听一小段，可能需要会员');
  }

  /// 播放模式变了 —— 队列立刻按新模式重建，面板跟着刷新。
  void onModeChanged(PlayMode mode) {
    _rebuildQueue();
    notifyListeners();
  }
  // ============================================================ 播放

  /// 播放请求代次：切歌之后，旧请求的结果必须丢弃。
  ///
  /// 没有它就会出现：A 还在加载时切到 B（B 秒开），几秒后 A 的地址才回来，
  /// 直接把 B 顶掉 —— 表现为「刚放两秒又跳回上一首」。
  int _playGeneration = 0;

  Future<void> playSong(String mid, {bool manual = true}) async {
    final song = findSong(mid);
    if (song == null) {
      toast.show('歌曲不存在', type: ToastType.error);
      return;
    }
    await playResolved(song, manual: manual);
  }

  /// 播放一首已经拿到手的歌。
  ///
  /// 队列里的歌**不一定在歌单里**（右键「插入到下一首」从搜索页插进来的那种），
  /// 那种按 mid 查不到 —— 所以队列直接拿着 [Song] 调这里，而不是绕回去调
  /// [playSong]。
  ///
  /// [manual] = 用户主动点的（点歌、双击）。只有手动点歌才动队列位置：
  /// 自动续播时位置已经由 [nextInQueue] / [prevInQueue] 挪好了。
  Future<void> playResolved(Song song, {bool manual = true}) async {
    if (manual) {
      final idx = playQueue.indexWhere((s) => s.mid == song.mid);
      if (idx >= 0) {
        // 队列里已经有它：跳过去就行，不要重建 ——
        // 重建会把「插入到下一首」插进来的东西冲掉。
        queueIndex = idx;
      } else {
        // 不在队列里：先按模式把歌单的最新顺序带进来，再把这首放进去。
        final at = queueIndex;
        _rebuildQueue();
        final inList = playQueue.indexWhere((s) => s.mid == song.mid);
        if (inList >= 0) {
          queueIndex = inList;
        } else {
          // 歌单里也没有（搜索页直接播的）：插到原当前位置后面再跳过去，
          // 这样它播完能顺着往下走，而不是从歌单头重来。
          final pos = (at < 0 || at >= playQueue.length) ? 0 : at + 1;
          playQueue.insert(pos, song);
          queueIndex = pos;
        }
      }
    }
    // 先展开播放栏并进入加载态，再去取播放地址（对齐 Electron 的交互）
    final gen = ++_playGeneration;
    player.prepare(song);
    notifyListeners();
    try {
      // 本地已经有这首歌的音频文件：直接播，**不去取播放地址**。
      //
      // 取地址是一串网络请求（B站要 4 次：游客标识 → ExClimbWuzhi → nav → view，
      // 然后才是 playurl），请求之间还夹着 350ms 的最小间隔。冷启动时这一串就是
      // 1.5 秒左右，而且它**挡在缓存前面** —— 上游一频控、一超时，本地明明躺着
      // 文件也放不出来，表现就是「缓存没生效」。
      //
      // `play()` 本来就会先查缓存，这里只是把那一次查询提前，好把这段白等省掉。
      final cached = AudioDiskCache.find(song.mid) != null;
      final url = cached ? '' : await ApiClient.getSongUrl(song.mid, true, song);
      // 取地址期间用户已经切到别的歌了 —— 这个结果作废，
      // 既不能拿去播放（会把新歌顶掉），也不该弹错误提示
      if (gen != _playGeneration) return;
      if (cached || url.isNotEmpty) {
        await player.play(song, url);
        if (gen != _playGeneration) return;
        notifyListeners();
      } else {
        player.cancelLoading();
        toast.show('无法获取播放链接', type: ToastType.error);
      }
    } catch (e) {
      if (gen != _playGeneration) return;
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
    searchInput = value;
    final v = value.trim();
    final isLink = RegExp(r'playlist/(\d+)|song/(\w+)|[?&]id=\d+|^\d+$').hasMatch(v);
    final isNeteaseLink = v.contains('music.163.com');
    // BV 号也是「直接定位」，跟粘贴链接一样把按钮切成链接样式
    final isBv = BilibiliService.bvPattern.hasMatch(v);
    final next = isLink || isNeteaseLink || isBv;
    if (next != searchLinkStyle) {
      searchLinkStyle = next;
      notifyListeners();
    }
  }

  /// 按当前音源搜索。三个源的入口集中在这里，加音源时只改这一处。
  Future<({List<Song> list, int total})> _searchCurrentSource(
    String keyword, [
    int page = 1,
  ]) {
    switch (searchSource) {
      case 'netease':
        return ApiClient.neSearch(keyword, page);
      case 'bilibili':
        return bilibiliService.search(keyword, page);
      default:
        return ApiClient.search(keyword, page);
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
      // 粘贴 BV 号 → 直接定位到那一个视频，不当作关键词去搜
      if (BilibiliService.bvPattern.hasMatch(keyword)) {
        final song = await bilibiliService.resolveBv(keyword);
        if (song == null) {
          toast.show('没有找到该 BV 号对应的视频', type: ToastType.error);
        } else {
          searchResults = [song];
          searchTotal = 1;
          searchKeyword = song.name;
          currentPage = 1;
          isPlaylistPage = false;
          hasSearched = true;
          notifyListeners();
        }
      } else if ((m = _nePlaylistRe.firstMatch(keyword)?.group(1)) != null) {
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
      } else if ((searchSource == 'netease' || searchSource == 'bilibili') &&
          !keyword.contains('y.qq.com')) {
        final res = await _searchCurrentSource(keyword);
        searchResults = res.list;
        searchTotal = res.total;
        searchKeyword = keyword;
        currentPage = 1;
        isPlaylistPage = false;
        hasSearched = true;
        _cacheCurrentPage();   // 首屏也进缓存，翻回第 1 页就不再请求
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
        _cacheCurrentPage();   // 首屏也进缓存，翻回第 1 页就不再请求
        notifyListeners();
      }
    } catch (e) {
      // 不置 hasSearched：失败只弹错误提示，不要再显示「没有找到 xxx」空状态
      toast.show('搜索失败: $e', type: ToastType.error);
    } finally {
      isSearching = false;
      notifyListeners();
    }
  }

  Future<void> changePage(int target) async {
    if (searchKeyword.isEmpty || target < 1) return;

    // 命中缓存就直接显示：翻回上一页、来回翻同一页都不该重新发请求
    // （QQ 音乐有频控，翻页本来就慢，能省一次是一次）。
    final cached = _pageCache[_pageCacheKey(target)];
    if (cached != null) {
      searchResults = cached.list;
      searchTotal = cached.total;
      currentPage = target;
      pageLoading = false;
      notifyListeners();
      return;
    }

    pageLoading = true;
    notifyListeners();
    try {
      final res = await _searchCurrentSource(searchKeyword, target);
      _pageCache[_pageCacheKey(target)] = (list: res.list, total: res.total);
      searchResults = res.list;
      searchTotal = res.total;
      currentPage = target;
    } catch (e) {
      toast.show('加载失败: $e', type: ToastType.error);
    } finally {
      // 必须在 finally 里收掉加载态：失败时也要让按钮恢复可用
      pageLoading = false;
      notifyListeners();
    }
  }

  /// 已加载过的分页缓存，key = 来源|关键词|页码
  final Map<String, ({List<Song> list, int total})> _pageCache = {};

  String _pageCacheKey(int page) => '$searchSource|$searchKeyword|$page';

  /// 把当前这一页记进缓存。
  ///
  /// 搜索的首屏不走 changePage，所以这里也要记一次 ——
  /// 否则从第 2 页翻回第 1 页时又会重新请求一次（QQ 音乐那边很慢）。
  void _cacheCurrentPage() {
    if (searchKeyword.isEmpty || isPlaylistPage) return;
    _pageCache[_pageCacheKey(currentPage)] =
        (list: searchResults, total: searchTotal);
    // 简单的上限：翻得再多也不至于无限涨（key 里带关键词，不会串页）
    if (_pageCache.length > 40) _pageCache.clear();
  }

  /// 换音源。当前有搜索内容就按**它**在新音源上重搜一遍。
  ///
  /// 重搜的关键词取 [searchInput]（输入框里现在的内容），不是 [searchKeyword]：
  /// 用户常是先改关键词、再点另一个音源，用上一次搜过的词会搜出上一首歌的结果。
  ///
  /// 歌单页（粘贴链接进来的）不重搜 —— 输入框里还留着那串链接，重搜没有意义。
  void setSearchSource(String source) {
    if (isSearching) return;
    searchSource = source;
    LocalStore.set('search_source', source);
    notifyListeners();
    final keyword = searchInput.trim();
    if (keyword.isEmpty || isPlaylistPage) return;
    handleSearch(keyword);
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

  /// 标记 ck 无效并落盘（校验失败时用）。
  void markQqCookieInvalid() {
    qqCookieStatus = 'invalid';
    LocalStore.set('qqmusic_cookie_status', 'invalid');
    notifyListeners();
  }

  /// 记录校验结果（昵称 / 登录方式 / 绿钻），并落盘。
  void applyQqUserInfo({
    required String nickname,
    required bool isWechat,
    required bool isVip,
  }) {
    qqNickname = nickname;
    qqIsWechat = isWechat;
    qqIsVip = isVip;
    qqCookieStatus = 'valid';
    LocalStore.set('qqmusic_nickname', nickname);
    LocalStore.set('qqmusic_is_wechat', isWechat ? 'true' : 'false');
    LocalStore.set('qqmusic_is_vip', isVip ? 'true' : 'false');
    LocalStore.set('qqmusic_cookie_status', 'valid');
    notifyListeners();
  }

  /// 记录 B站的校验结果（昵称 / 大会员），并落盘。
  void applyBiliUserInfo({required String nickname, required bool isVip}) {
    biliNickname = nickname;
    biliIsVip = isVip;
    biliCookieStatus = 'valid';
    LocalStore.set('bilibili_nickname', nickname);
    LocalStore.set('bilibili_is_vip', isVip ? 'true' : 'false');
    LocalStore.set('bilibili_cookie_status', 'valid');
    notifyListeners();
  }

  void setBiliCookie(String cookie) {
    biliCookie = cookie;
    bilibiliService.setCookie(cookie);
    LocalStore.set('bilibili_cookie', cookie);
    if (biliCookieStatus != 'valid') {
      biliCookieStatus = 'pending';
      LocalStore.set('bilibili_cookie_status', 'pending');
    }
    notifyListeners();
  }

  void clearBiliCookie() {
    biliCookie = '';
    biliCookieStatus = 'pending';
    biliNickname = '';
    biliIsVip = false;
    bilibiliService.setCookie('');
    LocalStore.remove('bilibili_cookie');
    LocalStore.remove('bilibili_cookie_status');
    LocalStore.remove('bilibili_nickname');
    LocalStore.remove('bilibili_is_vip');
    notifyListeners();
  }

  /// 记录网易云的校验结果（昵称 / 黑胶），并落盘。
  void applyNeUserInfo({required String nickname, required bool isVip}) {
    neNickname = nickname;
    neIsVip = isVip;
    neteaseCookieStatus = 'valid';
    LocalStore.set('netease_nickname', nickname);
    LocalStore.set('netease_is_vip', isVip ? 'true' : 'false');
    LocalStore.set('netease_cookie_status', 'valid');
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
    qqNickname = '';
    qqIsWechat = false;
    qqIsVip = false;
    LocalStore.remove('qqmusic_cookie');
    LocalStore.remove('qqmusic_cookie_status');
    LocalStore.remove('qqmusic_nickname');
    LocalStore.remove('qqmusic_is_wechat');
    LocalStore.remove('qqmusic_is_vip');
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
    neNickname = '';
    neIsVip = false;
    LocalStore.remove('netease_cookie');
    LocalStore.remove('netease_cookie_status');
    LocalStore.remove('netease_nickname');
    LocalStore.remove('netease_is_vip');
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
  /// 顺序很重要：**先递增请求计数器把弹窗弹出来**，再取歌词。
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

    final bundle = await LyricCache.load(mid, source: song?.source ?? 'qq');
    if (currentLyricMid != mid) return; // 期间用户又切了别的歌
    if (bundle != null) _applyLyricBundle(bundle);
    lyricLoading = false;
    notifyListeners();
  }

  void _applyLyricBundle(LyricBundle b) {
    currentLyricRaw = b.raw;
    currentLyricTrans = b.trans;
    currentLyricParsed =
        b.lines.map((e) => LyricLineBox(e.time, e.text, words: e.words)).toList();
    currentLyricTransMap = b.transMap;
  }

  /// 只加载歌词、不弹窗（供编辑态重载等场景使用）
  Future<void> loadLyricForModal(String mid) async {
    final song = findSong(mid);
    currentLyricMid = mid;
    lyricLoading = true;
    notifyListeners();
    final bundle = await LyricCache.load(mid, source: song?.source ?? 'qq');
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
      // **不能只是删掉这个键**：删掉之后取词会继续往下走
      //（磁盘缓存 → 网络），旧歌词又被拉回来 —— 表现就是「清空不了」。
      // 存一个空串当标记，意思是「这首歌就是没有歌词」。
      LocalStore.set('custom_lyric_$mid', '');
      LyricCache.dropDisk(mid);
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
    reloadLyricFromStore();
    // 播放栏那份歌词归播放器管（player.lyricLines），和弹窗不是同一份数据。
    // 这里必须让播放器也重新读一次，否则「保存后弹窗是新的、播放栏还是旧的」。
    if (player.currentSong?.mid == mid) player.reloadLyrics();
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
    // 必须和 _applyLyricBundle 一样区分 QRC / LRC，并且**保留 words**：
    // 这里原来写死 parseLrc，而 QRC 的行头是 `[起点ms,时长ms]` 不是 `[mm:ss.xx]`
    // → 解析出 0 行 → 用户「点编辑再取消」回来就变成「暂无歌词」。
    final isQrc = looksLikeQrc(currentLyricRaw);
    currentLyricParsed = (isQrc ? parseQrc(currentLyricRaw) : parseLrc(currentLyricRaw))
        .map((e) => LyricLineBox(e.time, e.text, words: e.words))
        .toList();
    currentLyricTransMap = parseTransLrc(currentLyricTrans);
    notifyListeners();
  }
}

/// 歌词弹窗内部使用的行结构（避免与 core/lyric 的只读模型混淆）
class LyricLineBox {
  final double time;
  final String text;

  /// 逐字时间（QRC 才有）。必须保留 —— 早先这里只传了 time/text，
  /// 把 words 丢掉，导致歌词弹窗永远显示不出逐字效果。
  final List<LyricWord>? words;

  const LyricLineBox(this.time, this.text, {this.words});

  bool get hasWords => words != null && words!.isNotEmpty;
}

final app = AppState.instance;
