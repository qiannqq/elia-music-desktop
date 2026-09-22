/// 歌曲模型 —— 对应原 `normalizeSong()` 的产物。
///
/// 注意：`raw` 保存上游原始对象（QQ 音乐需要 `file.media_mid` 才能取 320kbps），
/// 持久化时**只存裁剪后的字段**（等价原 `trimSong()`），与旧行为一致。
class Song {
  final String mid;
  final String name;
  final String artist;
  final String pic;
  final String link;
  final String mediaMid;

  /// 'qq' | 'netease' | 'bilibili'
  final String source;

  /// 上游原始数据（持久化后为空 map）
  final Map<String, dynamic> raw;

  /// 网易云特有字段
  final int fee;
  final int duration;
  final String album;

  const Song({
    required this.mid,
    required this.name,
    required this.artist,
    this.pic = '',
    this.link = '',
    this.mediaMid = '',
    this.source = 'qq',
    this.raw = const {},
    this.fee = 0,
    this.duration = 0,
    this.album = '',
  });

  bool get isBilibili => source == 'bilibili';

  /// 持久化用（等价 `trimSong()`）
  Map<String, dynamic> toStoreJson() => {
        'mid': mid,
        'name': name,
        'artist': artist,
        'pic': pic,
        'link': link,
        'mediaMid': mediaMid,
        'source': source,
      };

  /// 请求体用（带上 raw，服务端据此取高品质地址）
  Map<String, dynamic> toApiJson() => {
        'mid': mid,
        'id': mid,
        'name': name,
        'artist': artist,
        'pic': pic,
        'link': link,
        'mediaMid': mediaMid,
        'source': source,
        'fee': fee,
        'duration': duration,
        'album': album,
        if (raw.isNotEmpty) 'raw': raw,
        if (raw.isNotEmpty) 'data': raw,
      };

  factory Song.fromStoreJson(Map<String, dynamic> j) => Song(
        mid: (j['mid'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        artist: (j['artist'] ?? '').toString(),
        pic: (j['pic'] ?? '').toString(),
        link: (j['link'] ?? '').toString(),
        mediaMid: (j['mediaMid'] ?? '').toString(),
        source: (j['source'] ?? 'qq').toString(),
      );

  Song copyWith({String? name, String? pic}) => Song(
        mid: mid,
        name: name ?? this.name,
        artist: artist,
        pic: pic ?? this.pic,
        link: link,
        mediaMid: mediaMid,
        source: source,
        raw: raw,
        fee: fee,
        duration: duration,
        album: album,
      );

  @override
  bool operator ==(Object other) => other is Song && other.mid == mid && other.source == source;

  @override
  int get hashCode => Object.hash(mid, source);

  @override
  String toString() => 'Song($source:$mid $name - $artist)';
}

/// 歌单（QQ / 网易云）解析结果
class PlaylistInfo {
  final List<Song> list;
  final String name;
  final String desc;
  final String pic;

  const PlaylistInfo({
    required this.list,
    this.name = '',
    this.desc = '',
    this.pic = '',
  });
}
