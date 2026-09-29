import 'song.dart';

/// 歌单的同步机制。
///
/// 三种都是「以音源歌单为准」的单向同步，区别只在**用户能改多少**：
///  * [frozen] 完全单向 —— 用户不能增、不能删、不能排序（可以改歌曲名/歌词等元数据）；
///  * [add]    增加单向 —— 只增加；音源移出的不管；用户手动移出的记黑名单，拉取时不再加回来；
///  * [compat] 兼容单向 —— 音源的增删都响应，用户自己也能增删；
///    黑名单 = 用户手动移出的（拉取时不加回来），白名单 = 用户手动加进去的（拉取时不删）。
enum PlaylistSyncMode {
  frozen('frozen', '完全单向同步'),
  add('add', '增加单向同步'),
  compat('compat', '兼容单向同步');

  const PlaylistSyncMode(this.id, this.label);

  /// 落盘用的字符串（改它等于改数据格式，要配套改 fromStoreJson 的容错）
  final String id;

  /// 界面上显示的名字
  final String label;

  static PlaylistSyncMode? byId(String? id) {
    for (final m in values) {
      if (m.id == id) return m;
    }
    return null;
  }
}

/// 一个歌单。
///
/// 多歌单之前整个应用只有一份歌单（存在 `qqmusic_songs` 里）。升级时那份
/// 数据会被搬进「默认歌单」，所以老用户看到的还是原来那些歌 ——
/// 见 `AppState._loadPlaylists`。
class Playlist {
  Playlist({required this.id, required this.name, List<Song>? songs})
      : songs = songs ?? [];

  /// 稳定标识。歌单名可以随便改，认歌单靠它。
  final String id;

  String name;

  List<Song> songs;

  // ------------------------------------------------------------ 同步配置
  //
  // ⚠️ 这些字段是**后来加的**，读存档时一律「缺了就取默认值」——
  // `AppState._loadPlaylists` 的兜底是 `catch (_) { playlists = [] }`，
  // 模型层只要抛一次异常，用户**所有歌单会当场消失**。所以：
  //  * 不要 `as` 硬转、不要假设键存在；
  //  * 读可疑类型时能容错就容错（比如用 `toString()`、`is List` 判断）。

  /// 有没有开同步
  bool syncEnabled = false;

  /// 音源（'qq' / 'netease'）
  String syncSource = '';

  /// 音源那边的歌单 id（从链接里解出来的）
  String syncPlaylistId = '';

  /// 原始链接（留给界面回显，也让用户能改）
  String syncLink = '';

  /// 同步机制
  PlaylistSyncMode syncMode = PlaylistSyncMode.compat;

  /// 用户手动移出的歌（`'<source>:<mid>'`）—— 拉取时不再自动加回来。
  ///
  /// ⚠️ 这份名单**属于这个歌单自己**，不是全局的：同一首歌在别的歌单里
  /// 该不该同步，跟这里无关。
  Set<String> syncBlacklist = {};

  /// 用户手动加进去的歌（`'<source>:<mid>'`）—— 拉取时不会被删掉
  Set<String> syncWhitelist = {};

  /// 用户手动动过的歌（同上键），用来区分「音源删的」和「用户删的」
  Set<String> syncUserTouched = {};

  /// 上次同步时间（毫秒时间戳，0 = 从没同步过）
  int syncLastAt = 0;

  /// 上次同步结果（给界面看的短状态：'ok' / 'empty' / 'fail' / …）
  String syncLastResult = '';

  Map<String, dynamic> toStoreJson() => {
        'id': id,
        'name': name,
        'songs': songs.map((s) => s.toStoreJson()).toList(),
        // 同步配置：没开过的歌单不写这些键，存档不至于平白变大
        if (syncEnabled || syncSource.isNotEmpty) ...{
          'syncEnabled': syncEnabled,
          'syncSource': syncSource,
          'syncPlaylistId': syncPlaylistId,
          'syncLink': syncLink,
          'syncMode': syncMode.id,
          'syncBlacklist': syncBlacklist.toList(),
          'syncWhitelist': syncWhitelist.toList(),
          'syncUserTouched': syncUserTouched.toList(),
          'syncLastAt': syncLastAt,
          'syncLastResult': syncLastResult,
        },
      };

  /// 读坏了就返回 null，由调用方决定怎么兜 —— 不要在这里造一个半残的歌单。
  static Playlist? fromStoreJson(Object? v) {
    if (v is! Map) return null;
    final m = v.cast<String, dynamic>();
    final id = (m['id'] ?? '').toString();
    if (id.isEmpty) return null;
    final raw = m['songs'];
    final p = Playlist(
      id: id,
      name: (m['name'] ?? '').toString().isEmpty
          ? '未命名歌单'
          : m['name'].toString(),
      songs: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => Song.fromStoreJson(e.cast<String, dynamic>()))
              // 存档里混进来的空 mid 条目（上游那些用户自传的作品）读出来就丢
              .where((s) => s.hasMid)
              .toList()
          : null,
    );
    p.syncEnabled = m['syncEnabled'] == true;
    p.syncSource = (m['syncSource'] ?? '').toString();
    p.syncPlaylistId = (m['syncPlaylistId'] ?? '').toString();
    p.syncLink = (m['syncLink'] ?? '').toString();
    p.syncMode = PlaylistSyncMode.byId((m['syncMode'] ?? '').toString()) ??
        PlaylistSyncMode.compat;
    p.syncBlacklist = _stringSet(m['syncBlacklist']);
    p.syncWhitelist = _stringSet(m['syncWhitelist']);
    p.syncUserTouched = _stringSet(m['syncUserTouched']);
    p.syncLastAt = switch (m['syncLastAt']) {
      final int v => v,
      final String v => int.tryParse(v) ?? 0,
      _ => 0,
    };
    p.syncLastResult = (m['syncLastResult'] ?? '').toString();
    return p;
  }

  /// 名单读法：缺、类型怪、混进非字符串 —— 一律只收能用的，绝不抛
  static Set<String> _stringSet(Object? v) {
    if (v is! List) return {};
    return v.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toSet();
  }
}
