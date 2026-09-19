import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/lyric.dart';

/// 逐字歌词的**基准样式** —— 必须与普通歌词行（`Text`）解析出完全一致的样式。
///
/// 两处坑，都会让同一行歌词在「选中 / 未选中」之间换字体、换字号：
///
///  1. `RichText` **不继承** `DefaultTextStyle`。不显式给字族时字族是 `null`，
///     日文假名/汉字会掉到系统兜底字体 —— 字宽与相邻行对不上。
///  2. `RichText` 的 `textScaler` 默认是 `TextScaler.noScaling`，而 `Text` 用的是
///     `MediaQuery.textScalerOf(context)`。系统文本缩放不是 100% 时，两者字号不同。
///
/// 表现就是同一行歌词被选中后，字形比相邻行小一圈。
/// 这里改成与 `Text` 完全一样的解析方式：继承默认样式 → 合并主题字族 → 跟随文本缩放。
TextStyle karaokeBaseStyle(
  BuildContext context, {
  required double fontSize,
  double? height,
}) {
  final base = DefaultTextStyle.of(context).style;
  return base.merge(TextStyle(
    fontSize: fontSize,
    height: height,
    fontFamily: kFontFamily,
    fontFamilyFallback: kFontFallback,
  ));
}

/// 「加粗」用的描边 —— 四向零模糊阴影，等价 CSS 的 `-webkit-text-stroke`。
///
/// 为什么不用 `fontWeight: w600`：CJK 字形在请求粗体时常常要换一套字面
/// （甚至换到别的字族），字宽跟着变，于是「加粗了整行反而变窄」。
/// 阴影**不参与布局**，字形度量完全不变，宽度永远与未选中时一致。
List<Shadow> karaokeStroke(Color color, [double width = 0.5]) => [
      Shadow(color: color, blurRadius: 0, offset: Offset(-width, 0)),
      Shadow(color: color, blurRadius: 0, offset: Offset(width, 0)),
      Shadow(color: color, blurRadius: 0, offset: Offset(0, -width)),
      Shadow(color: color, blurRadius: 0, offset: Offset(0, width)),
    ];

/// 组装逐字富文本。播放栏（滑动版）与歌词弹窗共用，保证两处字形完全一致。
TextSpan buildKaraokeSpan({
  required List<LyricWord> words,
  required double position,
  required Color activeColor,
  required Color inactiveColor,
  required TextStyle base,
}) {
  final spans = <TextSpan>[];
  for (final w in words) {
    // 过渡时长：优先用字本身的时长；太短的话给个下限，
    // 否则一闪而过还是像硬切。
    final dur = w.duration < 0.12 ? 0.12 : w.duration;
    final t = ((position - w.time) / dur).clamp(0.0, 1.0);
    final col = Color.lerp(inactiveColor, activeColor, t) ?? inactiveColor;
    spans.add(TextSpan(
      text: w.text,
      style: TextStyle(color: col, shadows: karaokeStroke(col)),
    ));
  }
  return TextSpan(style: base, children: spans);
}

/// 逐字歌词行 —— 已唱过的字高亮，未唱到的用次要色。
///
/// **平滑过渡**：不是按「时间到没到」硬切颜色，而是按
/// 「这个字已经唱了多少比例」在两个颜色之间插值 ——
/// 硬切看起来非常僵硬。
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

  /// 传 null 表示不限行数（歌词弹窗用：长句换行显示，不截断）
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final words = line.words;
    final base = karaokeBaseStyle(context, fontSize: fontSize, height: height);

    if (words == null || words.isEmpty) {
      return Text(
        line.text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }

    return RichText(
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      // 必须显式跟随文本缩放，否则与相邻的 Text 行字号不一致（见 karaokeBaseStyle）
      textScaler: MediaQuery.textScalerOf(context),
      text: buildKaraokeSpan(
        words: words,
        position: position,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        base: base,
      ),
    );
  }
}

/// 播放栏专用：超长的逐字歌词**不用省略号裁掉**，而是横向滑动把后半句露出来。
///
/// 规则：
///  * 整行放得下 → 完全不动；
///  * 唱到的字逼近右边界 → 平滑左移，让当前字与它后面还没唱的部分进入视野，
///    开头则被裁掉（例：`"可愛い"も"かっこいい"もあたし` 滑到
///    `い"も"かっこいい"もあたし`）；
///  * 换到下一句 → 新行从头部重新开始，**不往回滑**
///    （每行都是一个新 State，起始位移固定为 0，不会出现回滚动画）。
class SlidingKaraokeText extends StatelessWidget {
  const SlidingKaraokeText({
    super.key,
    required this.line,
    required this.position,
    required this.activeColor,
    required this.inactiveColor,
    this.fontSize = 13,
    this.height,
    this.tailGap = 6,
  });

  final LyricLine line;
  final double position;
  final Color activeColor;
  final Color inactiveColor;
  final double fontSize;
  final double? height;

  /// 滑动后当前字右侧预留的空隙（px），让正在唱的字不贴边
  final double tailGap;

  @override
  Widget build(BuildContext context) {
    final words = line.words ?? const <LyricWord>[];
    final base = karaokeBaseStyle(context, fontSize: fontSize, height: height);

    if (words.isEmpty) {
      return Text(
        line.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }

    final scaler = MediaQuery.textScalerOf(context);
    final span = buildKaraokeSpan(
      words: words,
      position: position,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      base: base,
    );

    // 先量一遍整行：既要总宽，也要「每个字唱完时的横坐标」。
    // 用同一个 span 与同一个 textScaler，量出来的位置才和实际渲染对齐。
    final painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final totalWidth = painter.width;
    final totalChars = span.toPlainText().length;

    return SizedBox(
      width: double.infinity,
      child: LayoutBuilder(
        builder: (ctx, cons) {
          final viewport = cons.maxWidth;
          final maxShift = totalWidth - viewport;
          var target = 0.0;
          if (maxShift > 0 && totalChars > 0) {
            // 当前唱到第几个字
            var idx = 0;
            for (var i = 0; i < words.length; i++) {
              if (words[i].time <= position) {
                idx = i;
              } else {
                break;
              }
            }
            var chars = 0;
            for (var i = 0; i <= idx && i < words.length; i++) {
              chars += words[i].text.length;
            }
            if (chars > totalChars) chars = totalChars;
            final sungEnd =
                painter.getOffsetForCaret(TextPosition(offset: chars), Rect.zero).dx;
            target = (sungEnd - viewport + tailGap).clamp(0.0, maxShift);
          }

          return ClipRect(
            // OverflowBox 解除宽度约束：歌词按自身宽度排一行，
            // 超出部分由 ClipRect 裁掉（而不是变成省略号）。
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: double.infinity,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: target),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutCubic,
                builder: (ctx, shift, child) => Transform.translate(
                  offset: Offset(-shift, 0),
                  child: child,
                ),
                child: RichText(
                  maxLines: 1,
                  textScaler: scaler,
                  text: span,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
