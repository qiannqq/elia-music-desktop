import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_theme.dart';
import 'package:elia_music/models/playlist.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/sidebar.dart';

/// 歌单的右键菜单里**只放入口**，不放同步机制的单选。
///
/// 机制（完全单向 / 增加单向 / 兼容单向）只在同步设置弹窗里选 —— 同一组选项
/// 在两处各摆一份，用户得在两处维持同一个心智模型，还容易以为那是两套配置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = app;

  setUp(() {
    state.playlists = [Playlist(id: 'p1', name: '默认歌单')];
    state.currentPlaylistId = 'p1';
    state.playlistsExpanded = true;
  });

  testWidgets('右键歌单：只有「同步设置」，没有「同步机制」', (tester) async {
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

    await tester.tapAt(
      tester.getCenter(find.text('默认歌单')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('同步设置'), findsOneWidget);
    expect(find.text('删除歌单'), findsOneWidget);
    expect(find.text('同步机制'), findsNothing, reason: '机制只在弹窗里选');
    expect(find.text('完全单向'), findsNothing);
  });
}
