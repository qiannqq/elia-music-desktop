/// 从用户粘进来的那一串里解出「音源 + 歌单 id」。
///
/// 搜索框那套「粘链接直接定位」的判定顺序在这里复用一遍 —— `AppState.handleSearch`
/// 里那一长串 `else if` 没有抽成函数，同步这条路只能自己来一份，正则与原处保持一致。
///
/// 返回值的 `source` 为空串表示「只认出 id、认不出音源」（用户直接粘了一串数字）：
/// 那种情况下调用方保留自己原来选的音源，别猜。
///
/// B站链接**不支持**：本项目只有单个视频的解析（`bilibiliService.resolveBv`），
/// 没有收藏夹接口，粘过来只会解析失败，由界面去解释。
library;

/// 网易云歌单：`https://music.163.com/#/playlist?id=123456` 这类
final RegExp _nePlaylistRe = RegExp(r'music\.163\.com.*playlist\?id=(\d+)');

/// 网易云单曲：`.../song?id=123` —— 单曲不是歌单，必须挡在前面
final RegExp _neSongRe = RegExp(r'music\.163\.com.*song\?id=(\d+)');

/// QQ 单曲：`https://y.qq.com/n/ryqq/songDetail/003OUlho2HcRHC`。
/// 同样要在「`[?&]id=` 兜底」之前挡掉，否则 `...?id=数字` 形态的单曲会被当成歌单。
final RegExp _qqSongRe = RegExp(r'song/(\w+)');

/// QQ 歌单：`https://y.qq.com/n/ryqq/playlist/8743216163`
final RegExp _playlistRe = RegExp(r'playlist/(\d+)');

/// 兜底：任何带 `id=数字` 的链接
final RegExp _idRe = RegExp(r'[?&]id=(\d+)');

/// 直接粘的纯数字 id
final RegExp _numRe = RegExp(r'^\d+$');

({String source, String id})? parsePlaylistLink(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;

  final ne = _nePlaylistRe.firstMatch(s)?.group(1);
  if (ne != null) return (source: 'netease', id: ne);

  if (_neSongRe.hasMatch(s)) return null;
  if (_qqSongRe.hasMatch(s)) return null;

  final qq = _playlistRe.firstMatch(s)?.group(1);
  if (qq != null) return (source: 'qq', id: qq);

  final any = _idRe.firstMatch(s)?.group(1);
  if (any != null) return (source: '', id: any);

  if (_numRe.hasMatch(s)) return (source: '', id: s);

  return null;
}
