/// LRC 解析 —— `app.js` / `player.js` 中同名函数的 Dart 移植。
///
/// 相比原版做了两处**必要的**增强（原版正则是 `\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)`）：
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

  /// 逐字时间戳（QRC 才有）。为 null 表示只有行级时间（普通 LRC）。
  final List<LyricWord>? words;

  const LyricLine(this.time, this.text, {this.words});

  bool get hasWords => words != null && words!.isNotEmpty;
}

/// QRC 逐字歌词里的一个「字/词」片段（时间均为**绝对秒**）
class LyricWord {
  final double time;
  final double duration;
  final String text;

  const LyricWord(this.time, this.duration, this.text);

  double get end => time + duration;
}

/// 解析 QRC（逐字歌词）。
///
/// QRC 解密后的正文长这样：
/// ```
/// [ti:ポキでも]
/// [0,2000]ポキでも(0,500)ポキ(500,300)でも(800,1200)
/// ```
/// 即 `[行起点ms,行时长ms]` 后面跟若干 `词文本(词起点ms,词时长ms)`。
///
/// 它**不是** `[mm:ss.xx]` 格式，所以绝不能走 [parseLrc] ——
/// 这正是之前「QRC 拉到了却被判定无效、回退成普通歌词」的原因。
List<LyricLine> parseQrc(String? text) {
  if (text == null || text.isEmpty) return const [];
  final result = <LyricLine>[];
  for (final raw in text.split('\n')) {
    final m = _qrcLineRe.firstMatch(raw.trim());
    if (m == null) continue; // [ti:] [ar:] 等元信息行会走到这里，跳过
    final lineStart = int.parse(m.group(1)!) / 1000.0;
    final body = m.group(3) ?? '';

    final words = <LyricWord>[];
    for (final w in _qrcWordRe.allMatches(body)) {
      final txt = w.group(1) ?? '';
      if (txt.isEmpty) continue;
      // QRC 括号里的字时间是**绝对时间**（与行起点同一时间轴），
      // **不要**再加 lineStart —— 加了会让所有字都变成「还没唱到」，
      // 表现为整行都不高亮、看起来完全没有逐字效果。
      // 实测：行起点 1931 的行，第一个字就是 (1931,56)。
      words.add(LyricWord(
        int.parse(w.group(2)!) / 1000.0,
        int.parse(w.group(3)!) / 1000.0,
        txt,
      ));
    }

    // 没有逐字片段时退化成整行文本（去掉残留的 (start,dur) 标记）
    final plain = words.isNotEmpty
        ? words.map((w) => w.text).join()
        : body.replaceAll(RegExp(r'\(\d+,\d+(?:,\d+)?\)'), '').trim();
    if (plain.isEmpty) continue;

    result.add(LyricLine(lineStart, plain, words: words.isEmpty ? null : words));
  }
  result.sort((a, b) => a.time.compareTo(b.time));
  return result;
}

/// QRC 行头：`[起点ms,时长ms]正文`
///
/// 必须开 **multiLine**：QRC 正文开头是 `[ti:...]` `[ar:...]` 等元信息行，
/// 不开多行的话 `^...$` 只匹配整串的开头/结尾，永远匹配不到真正的歌词行 ——
/// 表现就是「QRC 明明解密成功了，却被判定不是 QRC 而回退成普通歌词」。
final RegExp _qrcLineRe = RegExp(r'^\[(\d+),(\d+)\](.*)$', multiLine: true);
final RegExp _qrcWordRe = RegExp(r'([^()]*?)\((\d+),(\d+)(?:,\d+)?\)');

/// 判断一段文本像不像 QRC（有 `[数字,数字]` 行头）
bool looksLikeQrc(String? text) =>
    text != null && text.isNotEmpty && _qrcLineRe.hasMatch(text.trim());

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

/// 按时间取翻译 —— **容差匹配**，不要用精确的 `map[time]`。
///
/// QRC 的行时间是**毫秒**（1931ms），而翻译 LRC 是**厘秒**（[00:01.93] → 1930ms），
/// 两者天生差 0~9ms。用 `map[lines[i].time]` 精确查会几乎全部落空
/// （只有恰好相等的少数能命中）—— 表现为「大部分翻译对不上」。
String transAt(Map<double, String> map, double time, {double tolerance = 0.05}) {
  if (map.isEmpty) return '';
  final exact = map[time];
  if (exact != null) return exact;
  String best = '';
  var bestDiff = tolerance;
  for (final e in map.entries) {
    final d = (e.key - time).abs();
    if (d <= bestDiff) {
      bestDiff = d;
      best = e.value;
    }
  }
  return best;
}
String formatTime(double? t) {
  if (t == null || !t.isFinite || t.isNaN) return '0:00';
  final m = t ~/ 60;
  final s = (t % 60).floor();
  return '$m:${s < 10 ? '0' : ''}$s';
}
