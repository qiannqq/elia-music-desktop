import '../models/playlist.dart';
import '../models/song.dart';

/// 歌单同步的**纯逻辑**。
///
/// 这里不碰网络、不碰 `LocalStore`、不发通知 —— 输入输出都是值，方便单测。
/// 真正的拉取与接线在状态层（`AppState` / `app_shell`）。
///
/// 一条贯穿全篇的硬约束：**远端拿到空列表绝不能当作「音源把歌单清空了」**。
/// 接口上「拉取失败」和「音源歌单确实是空的」几乎分不出来（都是空数组），
/// 一次抽风就能把用户本地的歌全删掉 —— 所以空远端一律「什么都不做」。

/// 名单里的键。用 `source:mid` 而不是裸 mid：两个音源的 mid 空间可能撞形
/// （网易云的 mid 就是纯数字 id），只存 mid 会跨源误判。
String syncKey(Song s) => '${s.source}:${s.mid}';

/// 一次同步的输入
class SyncInput {
  const SyncInput({
    required this.local,
    required this.remote,
    required this.mode,
    required this.source,
    required this.blacklist,
    required this.whitelist,
    required this.userTouched,
  });

  /// 本地歌单当前的歌（顺序就是界面上的顺序）
  final List<Song> local;

  /// 音源拉回来的歌（顺序就是音源那边的顺序）
  final List<Song> remote;

  final PlaylistSyncMode mode;
  final String source;
  final Set<String> blacklist;
  final Set<String> whitelist;

  /// 用户手动动过的歌（加了或删了都算）
  final Set<String> userTouched;
}

/// 一次同步的结果
class SyncResult {
  const SyncResult({
    required this.songs,
    required this.blacklist,
    required this.whitelist,
    required this.userTouched,
    required this.added,
    required this.removed,
    required this.changed,
    this.skipReason = '',
  });

  final List<Song> songs;
  final Set<String> blacklist;
  final Set<String> whitelist;
  final Set<String> userTouched;

  /// 这次加了几首 / 删了几首（给日志和界面用）
  final int added;
  final int removed;

  /// 有没有真的变（变了才写盘、才通知界面）
  final bool changed;

  /// 非空表示「什么都没做」，值是原因（'empty' = 音源返回空）
  final String skipReason;
}

/// 按机制把音源的歌单合并进本地歌单。
///
/// 三种机制的区别只在「用户能改多少」，共同点是**新加进来的歌一律置顶**，
/// 且新歌之间保持**音源那边的顺序**。
SyncResult mergeSyncedPlaylist(SyncInput input) {
  final local = input.local;
  final remote = input.remote;
  final blacklist = Set<String>.from(input.blacklist);
  final whitelist = Set<String>.from(input.whitelist);
  final touched = Set<String>.from(input.userTouched);

  SyncResult skip(String reason) => SyncResult(
        songs: local,
        blacklist: blacklist,
        whitelist: whitelist,
        userTouched: touched,
        added: 0,
        removed: 0,
        changed: false,
        skipReason: reason,
      );

  // ⚠️ 空远端：见文件头。宁可什么都不做，也不能清空用户的歌单。
  if (remote.isEmpty) return skip('empty');

  final localByKey = <String, Song>{for (final s in local) syncKey(s): s};

  // 音源里还在的歌，按音源顺序（这就是「置顶 + 保持音源内部顺序」的下半句）
  final remoteKeys = <String>[];
  final remoteSongs = <String, Song>{};
  for (final s in remote) {
    final k = syncKey(s);
    if (remoteSongs.containsKey(k)) continue; // 音源自己重了就去重
    remoteSongs[k] = s;
    remoteKeys.add(k);
  }

  switch (input.mode) {
    // 完全单向：整个歌单由音源决定（顺序也跟随音源）
    case PlaylistSyncMode.frozen:
      // 顺序完全跟随音源，但**本地已有的那首用本地那份** ——
      // 用户改过歌名/歌词/封面（机制允许改元数据），不能被音源的覆盖回去。
      final next = [
        for (final k in remoteKeys) localByKey[k] ?? remoteSongs[k]!,
      ];
      final changed = !_sameOrder(next, local);
      return SyncResult(
        songs: next,
        blacklist: blacklist,
        whitelist: whitelist,
        userTouched: touched,
        added: remoteKeys.where((k) => !localByKey.containsKey(k)).length,
        removed: local.where((s) => !remoteSongs.containsKey(syncKey(s))).length,
        changed: changed,
      );

    // 增加单向：只把音源里**新的**歌加到最上方；本地已有的顺序一律不动，
    // 音源移出的也不管（只有用户自己移出的会进黑名单，不再加回来）
    case PlaylistSyncMode.add:
      final fresh = [
        for (final k in remoteKeys)
          if (!localByKey.containsKey(k) && !blacklist.contains(k)) remoteSongs[k]!
      ];
      if (fresh.isEmpty) {
        return SyncResult(
          songs: local,
          blacklist: blacklist,
          whitelist: whitelist,
          userTouched: touched,
          added: 0,
          removed: 0,
          changed: false,
        );
      }
      return SyncResult(
        songs: [...fresh, ...local],
        blacklist: blacklist,
        whitelist: whitelist,
        userTouched: touched,
        added: fresh.length,
        removed: 0,
        changed: true,
      );

    // 兼容单向：音源的增删都响应，但用户在本地加进来的（白名单）不删
    case PlaylistSyncMode.compat:
      final next = <Song>[];
      final kept = <String>{};

      // ① 音源里还在的：先放（保持音源顺序），本地有就用本地那份
      //    （本地可能改过歌名/歌词，不能拿音源的覆盖掉）
      for (final k in remoteKeys) {
        if (blacklist.contains(k) && !whitelist.contains(k)) continue;
        final s = localByKey[k] ?? remoteSongs[k]!;
        if (kept.add(k)) next.add(s);
      }

      // ② 本地留下的「音源已经没有了」的歌：用户自己加的（白名单/动过）留着，
      //    其余的当作被音源删掉 —— 从歌单里移除，并**补记进黑名单**，
      //    这样下次拉取不会又冒出来。
      for (final s in local) {
        final k = syncKey(s);
        if (kept.contains(k)) continue;
        if (whitelist.contains(k) || touched.contains(k)) {
          if (kept.add(k)) next.add(s);
        } else {
          blacklist.add(k);
        }
      }

      final changed = !_sameOrder(next, local);
      return SyncResult(
        songs: next,
        blacklist: blacklist,
        whitelist: whitelist,
        userTouched: touched,
        added: next.length - local.length > 0 ? next.length - local.length : 0,
        removed: local.where((s) => !next.any((n) => syncKey(n) == syncKey(s))).length,
        changed: changed,
      );
  }
}

/// 顺序与内容都一致？（[Song] 的相等性是 mid+source，见 song.dart）
bool _sameOrder(List<Song> a, List<Song> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (syncKey(a[i]) != syncKey(b[i])) return false;
  }
  return true;
}
