/// LRC 解析 —— `app.js` / `player.js` 中同名函数的 Dart 移植。
class LyricLine {
  final double time;
  final String text;
  const LyricLine(this.time, this.text);
}

final RegExp _lrcRe = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

/// 解析 LRC 文本为按时间排序的行列表
List<LyricLine> parseLrc(String? text) {
  if (text == null || text.isEmpty) return const [];
  final result = <LyricLine>[];
  for (final line in text.split('\n')) {
    final m = _lrcRe.firstMatch(line);
    if (m == null) continue;
    final min = int.parse(m.group(1)!);
    final sec = int.parse(m.group(2)!);
    final msRaw = m.group(3)!;
    final ms = int.parse(msRaw.length == 2 ? '${msRaw}0' : msRaw);
    final time = min * 60 + sec + ms / 1000.0;
    final content = m.group(4)!.trim();
    if (content.isNotEmpty) result.add(LyricLine(time, content));
  }
  result.sort((a, b) => a.time.compareTo(b.time));
  return result;
}

/// 解析翻译歌词为 `时间 -> 文本` 映射（按 1000 倍毫秒取整作 key，等价原实现）
Map<double, String> parseTransLrc(String? text) {
  if (text == null || text.isEmpty) return const {};
  final map = <double, String>{};
  for (final line in text.split('\n')) {
    final m = _lrcRe.firstMatch(line);
    if (m == null) continue;
    final min = int.parse(m.group(1)!);
    final sec = int.parse(m.group(2)!);
    final msRaw = m.group(3)!;
    final ms = int.parse(msRaw.length == 2 ? '${msRaw}0' : msRaw);
    final time = min * 60 + sec + ms / 1000.0;
    final content = m.group(4)!.trim();
    if (content.isNotEmpty) map[time] = content;
  }
  return map;
}

/// 秒 → `m:ss`
String formatTime(double? t) {
  if (t == null || !t.isFinite || t.isNaN) return '0:00';
  final m = t ~/ 60;
  final s = (t % 60).floor();
  return '$m:${s < 10 ? '0' : ''}$s';
}
