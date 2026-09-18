/// LRC 解析 —— `app.js` / `player.js` 中同名函数的 Dart 移植。
///
/// ⚠️ 相比原版做了两处**必要的**增强（原版正则是 `\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)`）：
///
///  1. **毫秒分隔符同时接受 `.` 和 `:`**。网易云大量使用 `[00:03:17]` 这种
///     冒号写法（同一份歌词里常常与 `[00:00.00]` 混用），原版只认 `.`，
///     于是这些行被整行丢弃 —— 表现为「编辑里能看到歌词，但界面几乎不显示」，
///     翻译歌词同理整份丢失。
///  2. **支持一行多个时间戳**（`[00:01.00][00:05.00]同一句`），
///     网易云对重复句常用这种写法；原版只会取第一个并把它后面的
///     第二个时间戳当成正文。
///
/// 另外分钟/秒放宽到 1~2 位、毫秒放宽到 1~3 位并按位数补零。
class LyricLine {
  final double time;
  final String text;
  const LyricLine(this.time, this.text);
}

final RegExp _lrcTsRe = RegExp(r'\[(\d{1,2}):(\d{1,2})[.:](\d{1,3})\]');

/// 解析 LRC 文本为按时间排序的行列表
List<LyricLine> parseLrc(String? text) {
  if (text == null || text.isEmpty) return const [];
  final result = <LyricLine>[];
  for (final line in text.split('\n')) {
    final matches = _lrcTsRe.allMatches(line).toList();
    if (matches.isEmpty) continue;
    // 正文取「最后一个时间戳之后」的部分
    final content = line.substring(matches.last.end).trim();
    if (content.isEmpty) continue;
    for (final m in matches) {
      result.add(LyricLine(_toSeconds(m), content));
    }
  }
  result.sort((a, b) => a.time.compareTo(b.time));
  return result;
}

/// 解析翻译歌词为 `时间 -> 文本` 映射
Map<double, String> parseTransLrc(String? text) {
  if (text == null || text.isEmpty) return const {};
  final map = <double, String>{};
  for (final line in text.split('\n')) {
    final matches = _lrcTsRe.allMatches(line).toList();
    if (matches.isEmpty) continue;
    final content = line.substring(matches.last.end).trim();
    if (content.isEmpty) continue;
    for (final m in matches) {
      map[_toSeconds(m)] = content;
    }
  }
  return map;
}

/// `[mm:ss.xx]` / `[mm:ss:xx]` → 秒
double _toSeconds(RegExpMatch m) {
  final min = int.parse(m.group(1)!);
  final sec = int.parse(m.group(2)!);
  // 毫秒位数不定：1 位 ×100、2 位 ×10、3 位原样
  final ms = int.parse(m.group(3)!.padRight(3, '0'));
  return min * 60 + sec + ms / 1000.0;
}

/// 秒 → `m:ss`
String formatTime(double? t) {
  if (t == null || !t.isFinite || t.isNaN) return '0:00';
  final m = t ~/ 60;
  final s = (t % 60).floor();
  return '$m:${s < 10 ? '0' : ''}$s';
}
