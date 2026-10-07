import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_theme.dart';
import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/pages/search_page.dart';
import 'package:elia_music/ui/widgets/common.dart';

/// 切换音源时搜索框不能失焦。
///
/// 音源按钮在 TextField 的**框外**，而 TextField 的默认行为就是「点到框外就
/// unfocus」。于是点音源的一瞬间光标先被收走，等菜单收起再抢回来 —— 表现是
/// 「先失焦、再聚焦」的跳变（千奈真机报的）。所以判据要卡在**菜单开着的那一帧**
/// 上：那时焦点本来就该一直在输入框里，菜单一关还抢一次才是多余的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = app;

  setUp(() {
    state.playlists = [Playlist(id: 'p1', name: '默认歌单')];
    state.currentPlaylistId = 'p1';
    state.isSearching = false;
    state.searchResults = const [];
  });

  bool focusHeld(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

  testWidgets('聚焦后点音源：菜单开着的那一帧焦点仍在输入框', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final input = TextEditingController(text: '周杰伦');
    addTearDown(input.dispose);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppColors.light, Brightness.light),
      home: Scaffold(
        body: SearchPage(
          state: state,
          scrollController: scroll,
          inputController: input,
          onOpenLyric: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // ⚠️ 必须用**鼠标**点击：Flutter 的默认 onTapOutside 只对 mouse/trackpad
    // 触发 unfocus，触摸事件不走那条分支（tester.tap 默认就是触摸）。用触摸
    // 测会得到一个「怎么都过」的假阳性。
    await tester.tap(find.byType(TextField), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(focusHeld(tester), isTrue, reason: '点一下搜索框应当聚焦');

    // 点左侧音源按钮 → 菜单弹出。焦点不许在这一步被收走。
    await tester.tap(find.byType(SourceIcon), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('网易云音乐'), findsOneWidget, reason: '音源菜单应当展开');
    expect(
      focusHeld(tester),
      isTrue,
      reason: '菜单展开期间搜索框仍在聚焦（不该被 TextField 的 onTapOutside 收走）',
    );

    // 选一个音源。判据卡在「按下」与「抬手激活」**之间**那一帧：菜单项的
    // 按下也是一次框外点击，如果那一下 unfocus 了，用户就会看到「选中音源的
    // 一瞬间失焦又重新聚焦」。只看抬手之后的稳定状态是抓不到它的。
    final item = find.text('网易云音乐');
    final gesture = await tester.startGesture(
      tester.getCenter(item),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(
      focusHeld(tester),
      isTrue,
      reason: '按下菜单项的那一帧焦点也不能丢（不该出现瞬间失焦再抢回）',
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(focusHeld(tester), isTrue, reason: '切换音源后搜索框应保持聚焦');
    expect(state.searchSource, 'netease');
  });

  testWidgets('点搜索条以外的地方：正常退出聚焦', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final input = TextEditingController(text: '周杰伦');
    addTearDown(input.dispose);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppColors.light, Brightness.light),
      home: Scaffold(
        body: SearchPage(
          state: state,
          scrollController: scroll,
          inputController: input,
          onOpenLyric: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(focusHeld(tester), isTrue);

    // 点页面下方空白处（搜索条自己身上之外）→ 焦点必须真的走掉。
    await tester.tapAt(const Offset(600, 760));
    await tester.pumpAndSettle();
    expect(
      focusHeld(tester),
      isFalse,
      reason: '点搜索条以外的地方应当退出聚焦（不能被无条件 requestFocus 锁死）',
    );
  });
}