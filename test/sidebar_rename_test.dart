import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_theme.dart';
import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/sidebar.dart';

/// 歌单名进出编辑态，字**不能动**。
///
/// 显示态是 `Text`、编辑态是 `TextField`，两边必须共用同一个 TextStyle 和
/// 同一个 strut：`Text` 会自动把 DefaultTextStyle 合进来（于是拿到主题里的
/// 字体栈），`TextField` 的 style 不会 —— 整段都是汉字、只能靠回退字体渲染
/// 时，两边算基线用的字体不同，进出编辑态字就上下跳 1px（歌名那一处踩过
/// 同一个坑）。
///
/// ⚠️ 1px 的差**只能在真实字体下**比像素，测试环境用的是等宽测试字体
/// （所有字形度量都一样，量不出差异）。所以这里盯的是前提：
/// 两边的样式完全一致、框的上下位置一致。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = app;

  setUp(() {
    state.playlists = [Playlist(id: 'p1', name: '默认歌单')];
    state.currentPlaylistId = 'p1';
    state.playlistsExpanded = true;
  });

  testWidgets('显示态与编辑态用同一个 TextStyle 与同一个 strut', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppColors.light, Brightness.light),
      home: Scaffold(
        body: AnimatedBuilder(
          animation: state,
          builder: (_, _) => AppSidebar(state: state),
        ),
      ),
    ));
    await tester.pump();

    final shown = tester.widget<Text>(find.text('默认歌单'));
    expect(shown.style?.fontFamily, kFontFamily, reason: '主题字体栈要合进 style');
    expect(shown.strutStyle?.forceStrutHeight, isTrue);
    final shownRect = tester.getRect(find.text('默认歌单'));

    // 悬停出铅笔 → 点进编辑态
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('默认歌单')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('重命名'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.strutStyle?.forceStrutHeight, isTrue);
    expect(field.style?.fontFamily, shown.style?.fontFamily);
    expect(field.style?.fontSize, shown.style?.fontSize);
    expect(field.style?.fontWeight, shown.style?.fontWeight);
    expect(field.style?.color, shown.style?.color);

    // 框的上下位置与高度也要一样 —— 布局层面的偏移同样是「跳 1px」
    final fieldRect = tester.getRect(find.byType(TextField));
    expect(
      fieldRect.top,
      closeTo(shownRect.top, 0.5),
      reason: '进编辑态字上移/下移了',
    );
    expect(
      fieldRect.height,
      closeTo(shownRect.height, 0.5),
      reason: '进编辑态行高变了（基准线会跟着动）',
    );
  });
}
