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

  Future<void> openSubmenuMenu(
    WidgetTester tester, {
    VoidCallback? onPick,
  }) async {
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
                    children: [
                      AppMenuItem(
                        label: '歌单甲',
                        icon: AppIcons.plus,
                        onTap: onPick ?? () {},
                      ),
                      AppMenuItem(
                        label: '歌单乙',
                        icon: AppIcons.check,
                        enabled: false,
                        onTap: () {},
                      ),
                    ],
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

  testWidgets('有子项的项：刚开始不展开子菜单', (tester) async {
    await openSubmenuMenu(tester);
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('歌单甲'), findsNothing, reason: '没悬停之前不该冒出来');
  });

  testWidgets('悬停父项 → 展开子菜单（稍等一下才出，避免划过去就闪）', (tester) async {
    await openSubmenuMenu(tester);
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer(location: Offset.zero);
    addTearDown(() => hover.removePointer());
    await hover.moveTo(tester.getCenter(find.text('播放')));
    await tester.pump();

    // 刚进去还不展开
    expect(find.text('歌单甲'), findsNothing);
    // 过了悬停延时才展开
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.text('歌单甲'), findsOneWidget);
  });

  testWidgets('点父项也能展开（不用非等悬停）', (tester) async {
    var picked = '';
    await openSubmenuMenu(tester, onPick: () => picked = '甲');
    await tester.tap(find.text('播放'));
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.text('歌单甲'), findsOneWidget);
    expect(find.text('播放'), findsOneWidget, reason: '点父项不该把整个菜单关掉');

    // 点子项：干活 + 整个菜单收起
    await tester.tap(find.text('歌单甲'));
    await tester.pumpAndSettle();
    expect(picked, '甲');
    expect(find.text('播放'), findsNothing, reason: '点完子项整张菜单都要收');
    expect(find.text('歌单甲'), findsNothing);
  });

  testWidgets('子菜单里已有的那份是置灰的', (tester) async {
    await openSubmenuMenu(tester);
    await tester.tap(find.text('播放'));
    await tester.pump(const Duration(milliseconds: 180));

    final disabled = tester.widget<GestureDetector>(find.ancestor(
      of: find.text('歌单乙'),
      matching: find.byType(GestureDetector),
    ).first);
    expect(disabled.onTap, isNull, reason: '已有该曲的歌单不该还能点');
  });

  testWidgets('父项的行尾是箭头（告诉用户这里还能展开）', (tester) async {
    await openSubmenuMenu(tester);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
  });

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
