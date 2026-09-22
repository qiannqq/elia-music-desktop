import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_theme.dart';
import 'package:elia_music/ui/icons.dart';
import 'package:elia_music/ui/widgets/context_menu.dart';

void main() {
  Future<void> openMenu(WidgetTester tester, {VoidCallback? onPick}) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppColors.dark, Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: GestureDetector(
              onTap: () => showAppContextMenu(
                context: ctx,
                position: const Offset(80, 80),
                items: [
                  AppMenuItem(
                    label: '播放',
                    icon: AppIcons.play,
                    onTap: onPick ?? () {},
                  ),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('左键点外面关掉菜单', (tester) async {
    await openMenu(tester);
    expect(find.text('播放'), findsOneWidget);

    await tester.tapAt(const Offset(400, 400));
    await tester.pumpAndSettle();
    expect(find.text('播放'), findsNothing);
  });

  testWidgets('右键点外面也要关掉菜单', (tester) async {
    await openMenu(tester);
    expect(find.text('播放'), findsOneWidget);

    await tester.tapAt(const Offset(400, 400), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('播放'), findsNothing);
  });

  testWidgets('菜单开着时再点右键只收起，不会再弹一个', (tester) async {
    var opens = 0;
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppColors.dark, Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (c) {
            ctx = c;
            // 和歌单页一样：右键按下就弹菜单
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onSecondaryTapDown: (d) {
                opens++;
                showAppContextMenu(
                  context: ctx,
                  position: d.globalPosition,
                  items: [
                    AppMenuItem(label: '播放', icon: AppIcons.play, onTap: () {}),
                  ],
                );
              },
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
    ));

    await tester.tapAt(const Offset(100, 100), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(find.text('播放'), findsOneWidget);

    // 菜单还开着，再点一次右键
    await tester.tapAt(const Offset(100, 100), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(opens, 1, reason: '菜单开着时按右键应该只把它收起来');
    expect(find.text('播放'), findsNothing);
  });

  testWidgets('点菜单项会执行并收起', (tester) async {
    var picked = false;
    await openMenu(tester, onPick: () => picked = true);
    expect(find.text('播放'), findsOneWidget);

    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    expect(picked, isTrue);
    expect(find.text('播放'), findsNothing);
  });
}
