import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_theme.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/dialogs/lyrics_dialog.dart';

/// 歌词编辑区的布局回归测试。
///
/// 这两条都是实际踩过的坑：
///  1. 两块编辑区**各占整宽**（不是各占一半）—— 少了解除宽度约束的
///     OverflowBox，Row 会被父级 maxWidth 夹住，两块各露一半；
///  2. 切换后旧的一块必须**完全**移出可视区，而不是只挤一半。
void main() {
  Future<void> openEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppColors.light, Brightness.light),
      home: LyricsDialog(state: app),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
  }

  testWidgets('切换过程中按钮背景不会闪深色', (tester) async {
    await openEditor(tester);

    Color bgOf(String key) {
      final box = tester.widget<Container>(find
          .descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(Container),
          )
          .first);
      return (box.decoration! as BoxDecoration).color!;
    }

    // 右侧按钮此刻是可用的（浅色 surfaceAlt），记下它的亮度
    final before = bgOf('switch-right').computeLuminance();

    await tester.tap(find.byTooltip('翻译歌词'));
    await tester.pump();
    // 在动画过程中采样：背景色只能往「同色零透明」走，
    // RGB 亮度不该下降 —— 下降说明是从 Colors.transparent（透明黑）
    // 插值过去的，浅色模式下就是「两个按钮同时闪一下深色」。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      final lum = bgOf('switch-right').computeLuminance();
      expect(
        lum,
        greaterThanOrEqualTo(before - 0.05),
        reason: '第 ${(i + 1) * 40}ms 时按钮背景变暗了（透明黑插值）',
      );
    }
    await tester.pumpAndSettle();
  });

  testWidgets('编辑区两块各占整宽，切换后旧的一块完全移出可视区', (tester) async {
    await openEditor(tester);

    final viewport = find.byKey(const Key('lyric-editor-viewport'));
    expect(viewport, findsOneWidget);
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));

    final viewportWidth = tester.getSize(viewport).width;
    for (var i = 0; i < 2; i++) {
      expect(
        tester.getSize(fields.at(i)).width,
        closeTo(viewportWidth, 1),
        reason: '第 $i 块编辑区宽度不等于可视宽 —— OverflowBox 没解除宽度约束',
      );
    }

    // 原歌词页上，左侧那个「切回原歌词」必须是不可用的：
    // 点它不应该有任何变化（不能只是颜色变暗、仍然可点）
    await tester.tap(find.byTooltip('原歌词'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(fields.at(0)).left,
      closeTo(tester.getRect(viewport).left, 1),
      reason: '在原歌词页上，左侧按钮居然还能点（应该置灰且点不动）',
    );

    // 切到翻译**必须是动画**：点完只推进 60ms，位置应该还在半路上。
    // （瞬间到位说明动画丢了 —— 直接 pumpAndSettle 是看不出来的，
    //   它只会检查终点，动画有没有跑根本测不到。）
    final startLeft = tester.getRect(fields.at(0)).left;
    await tester.tap(find.byTooltip('翻译歌词'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final midLeft = tester.getRect(fields.at(0)).left;
    expect(midLeft, lessThan(startLeft - 5),
        reason: '点了切换但完全没动 —— 动画没启动');
    expect(midLeft, greaterThan(startLeft - viewportWidth + 5),
        reason: '一步到位了 —— 动画丢了（应该 260ms 滑过去）');
    await tester.pumpAndSettle();

    final rawRect = tester.getRect(fields.at(0));
    final viewportRect = tester.getRect(viewport);
    expect(
      rawRect.right <= viewportRect.left + 1,
      isTrue,
      reason: '原歌词框只挤出去一半（right=${rawRect.right}, '
          'viewport.left=${viewportRect.left}）',
    );

    // 翻译页上，右侧那个「切到翻译」必须不可用
    final transLeft = tester.getRect(fields.at(1)).left;
    await tester.tap(find.byTooltip('翻译歌词'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(TextField).at(1)).left,
      closeTo(transLeft, 1),
      reason: '在翻译页上，右侧按钮居然还能点（应该置灰且点不动）',
    );

    // 切回去，内容必须原样还在
    await tester.tap(find.byTooltip('原歌词'));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(TextField).at(0)).left,
      closeTo(viewportRect.left, 1),
      reason: '切回原歌词后没有回到原位',
    );
  });
}
