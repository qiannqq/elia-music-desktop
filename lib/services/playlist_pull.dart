import '../core/file_logger.dart';
import '../models/song.dart';

/// 一页歌单结果。[total] 是音源报的总数（0 = 音源没给，按「取到短页就停」收敛）。
typedef PlaylistPage = ({List<Song> list, int total});

/// 取第 `[begin, begin+num)` 首（`num` 只是这一页要多少，与服务端的上限无关）
typedef PlaylistPageFetcher = Future<PlaylistPage> Function(int begin, int num);

/// 一页要多少首。QQ 的 `CgiGetDiss` 就是按这个粒度给的 —— 它的**默认值 500 是
/// 硬编码在请求体里的**，超过 500 首的歌单会被静默截断，所以同步这条路必须自己翻页。
const int kPlaylistPageSize = 500;

/// 翻页上限（保险丝）。一次 500 首，20 页 = 一万首，真实的歌单不会超过；
/// 触顶时只记一条 warn，不抛 —— 让调用方拿到现有的这一万首，而不是整个失败。
const int kPlaylistMaxPages = 20;

/// 分页把一个歌单拉全。
///
/// 为什么必须翻到底：截断对同步来说是**破坏性的** —— `frozen`（完全单向）机制下，
/// 「远端没有的歌」等于「音源删了」，一份只拉回前 500 首的结果会把后半张歌单
/// 从用户本地全删掉。拉不全宁可整体失败，也不能拿半份结果去合并。
///
/// 三种收尾：
///   * 音源给的这一页是空的 → 到底了；
///   * 这一页不足 [pageSize] → 到底了；
///   * 音源报了总数且已经取够 → 到底了。
///
/// 返回的 `truncated` 表示「拿到的比音源说的少」（撞上 [maxPages]、短页收尾、
/// 或者接口忽略了 `begin`）：这种情况**照样把现有的合并进去**（方案里定的
/// 「先接受」），但日志里会写明，排查时能一眼看到少了多少。
///
/// 异常（网络、超时）**原样往上抛**：调用方把它当「这次同步失败」，不动本地歌单。
Future<({List<Song> list, int total, bool truncated})> pullAllPlaylistSongs({
  required PlaylistPageFetcher fetchPage,
  int pageSize = kPlaylistPageSize,
  int maxPages = kPlaylistMaxPages,
  String label = '',
}) async {
  final all = <Song>[];
  final seen = <String>{};
  var begin = 0;
  var total = 0;
  var truncated = false;

  for (var page = 0; page < maxPages; page++) {
    final res = await fetchPage(begin, pageSize);
    if (res.total > 0) total = res.total;
    if (res.list.isEmpty) break;

    var fresh = 0;
    for (final s in res.list) {
      if (seen.add('${s.source}:${s.mid}')) {
        all.add(s);
        fresh++;
      }
    }

    begin += res.list.length;

    // 一页下来一首新的都没有：多半是接口忽略了 `begin`、把同一页又发了一遍，
    // 继续翻就是死循环（翻到上限为止白打十几次请求）。
    if (fresh == 0) {
      fileLogger.warn('PlaylistSync',
          '$label 第 ${page + 1} 页没有新的歌（begin=$begin），停止翻页');
      break;
    }

    if (res.list.length < pageSize) break;
    if (total > 0 && begin >= total) break;

    if (page == maxPages - 1) truncated = true;
  }

  // 拿到的比音源说的少（短页收尾、或接口没有下一页）：这份结果是不全的。
  // 调用方照常合并（方案里定的「先接受」），但日志里必须写明 ——
  // 不然「本地少了几首」在排查时永远对不上。
  if (total > 0 && all.length < total) truncated = true;

  if (truncated) {
    fileLogger.warn('PlaylistSync',
        '$label 只取到 ${all.length} 首'
        '${total > 0 ? '（音源共 $total 首）' : ''}，这份结果可能不全');
  }

  return (list: all, total: total > 0 ? total : all.length, truncated: truncated);
}
