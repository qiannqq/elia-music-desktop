import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/ui/widgets/keyboard_scroll.dart';

/// 键盘滚动的回归测试。
///
/// 起因是一个真实踩到的坑：滚动键挂在根 `Focus` 的 `onKeyEvent` 上，而这个
/// 节点在冒泡链上比 `DefaultTextEditingShortcuts` 更靠近焦点 —— 于是焦点在
/// 搜索框里按空格，输入框不但没拿到键，页面还跟着往下滚。
///
/// 判断逻辑抽成 [scrollIntentFor] / [isTextFieldFocused] 就是为了能在这里
/// 直接钉住，不必跑整个 shell。
void main() {
  group('按键映射', () {
    test('滚动键各自对应正确的意图', () {
      expect(scrollIntentFor(LogicalKeyboardKey.pageDown), KeyScrollIntent.pageDown);
      expect(scrollIntentFor(LogicalKeyboardKey.pageUp), KeyScrollIntent.pageUp);
      expect(scrollIntentFor(LogicalKeyboardKey.arrowDown), KeyScrollIntent.lineDown);
      expect(scrollIntentFor(LogicalKeyboardKey.arrowUp), KeyScrollIntent.lineUp);
      expect(scrollIntentFor(LogicalKeyboardKey.home), KeyScrollIntent.top);
      expect(scrollIntentFor(LogicalKeyboardKey.end), KeyScrollIntent.bottom);
      // 空格等同翻页（浏览器习惯）
      expect(scrollIntentFor(LogicalKeyboardKey.space), KeyScrollIntent.pageDown);
    });

    test('非滚动键一律返回 null，不许被吞掉', () {
      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.controlLeft,
      ]) {
        expect(scrollIntentFor(key), isNull, reason: '$key 不该被当成滚动键');
      }
    });
  });

  group('焦点判定', () {
    testWidgets('焦点在输入框里时为 true，在别处为 false', (tester) async {
      final plain = FocusNode();
      addTearDown(plain.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const TextField(key: Key('field')),
              Focus(focusNode: plain, child: const SizedBox(height: 10)),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      plain.requestFocus();
      await tester.pumpAndSettle();
      expect(isTextFieldFocused(), isFalse, reason: '焦点在普通节点上却被判成输入框');

      await tester.tap(find.byKey(const Key('field')));
      await tester.pumpAndSettle();
      expect(isTextFieldFocused(), isTrue, reason: '焦点在输入框里却没被认出来');
    });
  });

  group('组合行为', () {
    /// 用**与 app_shell 相同的公共函数**搭一个最小场景：
    /// 一个可滚动的列表 + 一个输入框 + 挂在根 Focus 上的滚动处理。
    Future<ScrollController> build(WidgetTester tester) async {
      final scroll = ScrollController();
      final root = FocusNode();
      addTearDown(scroll.dispose);
      addTearDown(root.dispose);

      KeyEventResult handler(FocusNode node, KeyEvent event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (isTextFieldFocused()) return KeyEventResult.ignored;
        if (scrollIntentFor(event.logicalKey) == null) {
          return KeyEventResult.ignored;
        }
        scroll.jumpTo(scroll.offset + 300);
        return KeyEventResult.handled;
      }

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Focus(
            focusNode: root,
            autofocus: true,
            onKeyEvent: handler,
            child: Column(
              children: [
                SizedBox(
                  height: 120,
                  child: ListView.builder(
                    controller: scroll,
                    itemCount: 60,
                    itemBuilder: (_, i) =>
                        SizedBox(height: 40, child: Text('行 $i')),
                  ),
                ),
                const TextField(key: Key('field')),
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return scroll;
    }

    testWidgets('焦点不在输入框时，空格/PgDn 正常滚动', (tester) async {
      final scroll = await build(tester);

      var before = scroll.offset;
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(before), reason: 'PgDn 没有滚动');

      before = scroll.offset;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(before), reason: '空格没有滚动');
    });

    testWidgets('焦点在输入框时，空格与翻页键都不许滚动', (tester) async {
      final scroll = await build(tester);

      await tester.tap(find.byKey(const Key('field')));
      await tester.pumpAndSettle();
      expect(isTextFieldFocused(), isTrue);

      final locked = scroll.offset;
      for (final key in [
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(
          scroll.offset,
          locked,
          reason: '焦点在输入框里，$key 却把页面滚动了',
        );
      }
    });
  });
}
