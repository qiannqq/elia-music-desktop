import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_theme.dart';
import 'package:elia_music/core/lyric.dart';
import 'package:elia_music/ui/widgets/karaoke_text.dart';

/// 歌词行渲染的回归测试。
///
/// 两条都是用户实际反馈过的问题，改回去很容易（RichText 的默认行为很反直觉）：
///  1. 逐字歌词被「选中」后字反而比相邻行小一圈；
///  2. 超长的逐字歌词被省略号裁掉，滑动展示的能力消失。
void main() {
  const text = '甘い味が病みつきでしょう';

  Widget host(Widget child) => MaterialApp(
        theme: buildTheme(AppColors.light, Brightness.light),
        home: MediaQuery(
          // 系统文本缩放不是 100% 时，Text 会跟着缩放而 RichText 默认不会 ——
          // 这正是「选中后变小」的成因之一，固定成 1.2 把它钉住。
          data: const MediaQueryData(textScaler: TextScaler.linear(1.2)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: child,
            ),
          ),
        ),
      );

  testWidgets('逐字歌词与普通歌词的字号、字宽完全一致', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final line = LyricLine(0, text, words: const [
      LyricWord(0, 0.5, '甘い味が'),
      LyricWord(0.5, 0.5, '病みつきでしょう'),
    ]);

    await tester.pumpWidget(host(IntrinsicWidth(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(text,
              key: Key('plain'), style: TextStyle(fontSize: 15, height: 1.7)),
          KaraokeText(
            key: const Key('karaoke'),
            line: line,
            position: 10,
            activeColor: const Color(0xFF0078D4),
            inactiveColor: const Color(0xFF8A8A8A),
            fontSize: 15,
            height: 1.7,
          ),
        ],
      ),
    )));

    final plain = tester.renderObject<RenderParagraph>(find.byKey(const Key('plain')));
    final karaoke =
        tester.renderObject<RenderParagraph>(find.byKey(const Key('karaoke')));

    // 关键不变量：同一行歌词，逐字渲染与普通渲染的宽度必须一模一样。
    expect(karaoke.size.width, closeTo(plain.size.width, 0.01));
    // 并且都要跟随系统文本缩放（1.2 倍）
    expect(karaoke.textScaler.scale(10), closeTo(plain.textScaler.scale(10), 0.01));
    expect(karaoke.textScaler.scale(10), closeTo(12, 0.01));
    // 字族必须落到主题字族，而不是系统兜底字体
    expect(karaoke.text.style!.fontFamily, kFontFamily);
    expect(karaoke.text.style!.fontFamilyFallback, kFontFallback);
  });

  testWidgets('超长逐字歌词滑动而不是省略号', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const raw = '"可愛い"も"かっこいい"もあたし';
    final line = LyricLine(0, raw, words: const [
      LyricWord(0, 0.5, '"可愛い"も'),
      LyricWord(0.5, 0.5, '"かっこいい"も'),
      LyricWord(1.0, 0.5, 'あたし'),
    ]);

    double shiftOf(WidgetTester t) {
      final tr = t.widget<Transform>(find.descendant(
        of: find.byType(SlidingKaraokeText),
        matching: find.byType(Transform),
      ));
      return tr.transform.getTranslation().x;
    }

    // ---- 容器很窄：整行放不下 ----
    await tester.pumpWidget(host(SizedBox(
      width: 80,
      child: SlidingKaraokeText(
        line: line,
        position: 0,
        activeColor: const Color(0xFF0078D4),
        inactiveColor: const Color(0xFF8A8A8A),
      ),
    )));
    await tester.pumpAndSettle();

    final rich = tester.renderObject<RenderParagraph>(find.descendant(
      of: find.byType(SlidingKaraokeText),
      matching: find.byType(RichText),
    ));
    // 歌词按自身宽度排一行（没有被省略号裁短）
    expect(rich.size.width, greaterThan(80));
    expect(rich.text.toPlainText(), raw);

    // 唱到句尾：位移刚好把结尾推进视野（= 总宽 - 可视宽）
    await tester.pumpWidget(host(SizedBox(
      width: 80,
      child: SlidingKaraokeText(
        line: line,
        position: 99,
        activeColor: const Color(0xFF0078D4),
        inactiveColor: const Color(0xFF8A8A8A),
      ),
    )));
    await tester.pumpAndSettle();
    expect(shiftOf(tester), closeTo(-(rich.size.width - 80), 0.01));

    // ---- 容器够宽：整行放得下，不允许有任何位移 ----
    await tester.pumpWidget(host(SizedBox(
      width: 600,
      child: SlidingKaraokeText(
        line: line,
        position: 99,
        activeColor: const Color(0xFF0078D4),
        inactiveColor: const Color(0xFF8A8A8A),
      ),
    )));
    await tester.pumpAndSettle();
    expect(shiftOf(tester), 0);
  });
}
