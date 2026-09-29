import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_theme.dart';
import 'package:elia_music/ui/widgets/dialogs.dart';

/// 通用输入框里的文字必须**垂直居中**。
///
/// 坑在平台密度上：Windows 的 `visualDensity` 是 compact(-2,-2)，
/// `InputDecorator` 会把它整个算进自己的内容高度（7 + 19(行) + 7 - 8 = 25），
/// 比 `AppTextField` 自己那层 `minHeight: 32` 少 5px。这 5px 由外层容器补出来，
/// 补在文字**下面**的话一眼看上去就是「文字靠上」——下载弹窗、同步设置弹窗里
/// 都看得出来。
///
/// ⚠️ `flutter test` 的默认平台是安卓（密度 standard，内容正好 33，兜不出这个
/// 差额），所以这里直接把主题的密度钉成 compact —— 那正是 Windows 上的实际取值。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 起一个光杆输入框，量「文字那一行」与「框」的上下留白。
  Future<({double height, double top, double bottom})> layout(
    WidgetTester tester, {
    bool trailing = false,
  }) async {
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = TextEditingController(text: 'D:\\Music\\歌单链接');
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppColors.light, Brightness.light)
          .copyWith(visualDensity: VisualDensity.compact),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: AppTextField(
              controller: ctrl,
              trailing: trailing ? const Icon(Icons.clear, size: 16) : null,
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    final box = tester.getRect(find.byType(AppTextField));
    final rd = tester.allRenderObjects.whereType<RenderEditable>().first;
    final editable = rd.localToGlobal(Offset.zero) & rd.size;
    return (
      height: box.height,
      top: editable.top - box.top,
      bottom: box.bottom - editable.bottom,
    );
  }

  testWidgets('一行文字在 32 高的框里居中', (tester) async {
    final r = await layout(tester);

    expect(r.height, 32, reason: '高度按 WinUI 的 TextControlThemeMinHeight');
    expect(
      (r.top - r.bottom).abs(),
      lessThanOrEqualTo(0.5),
      reason: '上下留白不一样就是「看着靠上」：上 ${r.top} / 下 ${r.bottom}',
    );
  });

  testWidgets('带 trailing 按钮的输入框同样居中', (tester) async {
    final r = await layout(tester, trailing: true);

    expect(r.height, 32);
    expect(
      (r.top - r.bottom).abs(),
      lessThanOrEqualTo(0.5),
      reason: '右边多一个按钮不改变上下留白：上 ${r.top} / 下 ${r.bottom}',
    );
  });
}
