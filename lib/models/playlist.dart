import 'song.dart';

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

  Map<String, dynamic> toStoreJson() => {
        'id': id,
        'name': name,
        'songs': songs.map((s) => s.toStoreJson()).toList(),
      };

  /// 读坏了就返回 null，由调用方决定怎么兜 —— 不要在这里造一个半残的歌单。
  static Playlist? fromStoreJson(Object? v) {
    if (v is! Map) return null;
    final m = v.cast<String, dynamic>();
    final id = (m['id'] ?? '').toString();
    if (id.isEmpty) return null;
    final raw = m['songs'];
    return Playlist(
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
  }
}
