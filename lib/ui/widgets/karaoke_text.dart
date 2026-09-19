import 'package:flutter/material.dart';

import '../../core/lyric.dart';

/// 逐字歌词行 —— 已唱过的字高亮，未唱到的用次要色。
///
/// ⚠️ **平滑过渡**：不是按「时间到没到」硬切颜色，而是按
/// 「这个字已经唱了多少比例」在两个颜色之间插值 ——
/// 硬切看起来非常僵硬（用户反馈「点亮太僵硬」）。
///
/// 播放栏与歌词弹窗共用本组件，避免两处效果不一致。
class KaraokeText extends StatelessWidget {
  const KaraokeText({
    super.key,
    required this.line,
    required this.position,
    required this.activeColor,
    required this.inactiveColor,
    this.fontSize = 13,
    this.height,
    this.maxLines = 1,
  });

  final LyricLine line;

  /// 当前播放位置（秒）
  final double position;
  final Color activeColor;
  final Color inactiveColor;
  final double fontSize;
  final double? height;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final words = line.words;
    if (words == null || words.isEmpty) {
      return Text(
        line.text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: fontSize, height: height),
      );
    }

    final spans = <TextSpan>[];
    for (final w in words) {
      // 过渡时长：优先用字本身的时长；太短的话给个下限，
      // 否则一闪而过还是像硬切。
      final dur = w.duration < 0.12 ? 0.12 : w.duration;
      final t = ((position - w.time) / dur).clamp(0.0, 1.0);
      spans.add(TextSpan(
        text: w.text,
        style: TextStyle(
          color: Color.lerp(inactiveColor, activeColor, t),
          // 字重保持不变：字重没法插值，硬跳会盖过颜色过渡的平滑感
          fontWeight: FontWeight.w600,
        ),
      ));
    }

    return RichText(
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(fontSize: fontSize, height: height),
        children: spans,
      ),
    );
  }
}
