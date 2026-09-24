import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/ui/pages/settings_page.dart';

/// 设置页分栏的冒烟测试。
///
/// 八段内容是从一个大 `children` 列表里搬进四个分栏的 —— 搬运时很容易漏掉
/// 一段、或者把括号弄坏，而这类错 `analyze` 不一定看得出来（少一段是合法的
/// Dart，只是设置项凭空消失）。这里把每一栏都点一遍，确认该出现的段落都在、
/// 不该出现的段落不串台。
void main() {
  setUpAll(() {
    // 设置页一进来就统计缓存占用，会读 AppPaths。测试里指到临时目录，
    // 免得它去碰真实的数据目录（那里面是用户的音乐库）。
    final tmp = Directory.systemTemp.createTempSync('elia_settings_test');
    AppPaths.appDir = tmp.path;
    AppPaths.dataDir = tmp.path;
    AppPaths.logsDir = tmp.path;
    AppPaths.tempDir = tmp.path;
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  testWidgets('四个分栏各自显示自己的段落', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final qq = TextEditingController();
    final ne = TextEditingController();
    final bili = TextEditingController();
    final savePath = TextEditingController();
    addTearDown(qq.dispose);
    addTearDown(ne.dispose);
    addTearDown(bili.dispose);
    addTearDown(savePath.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsPage(
          state: app,
          scrollController: scroll,
          qqCookie: qq,
          neteaseCookie: ne,
          biliCookie: bili,
          savePath: savePath,
        ),
      ),
    ));
    await tester.pump();

    // 分栏条本身：四个标签都在
    for (final tab in SettingsTab.values) {
      expect(find.text(tab.label), findsOneWidget, reason: '分栏「${tab.label}」不见了');
    }

    Future<void> tapTab(String label) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    // 默认落在播放设置
    expect(find.text('音质设置'), findsOneWidget);
    expect(find.text('跳过首尾无声片段'), findsOneWidget);
    expect(find.text('胶囊歌词'), findsOneWidget);
    expect(find.text('QQ音乐 Cookie'), findsNothing, reason: '别的栏的内容串过来了');

    await tapTab('CK设置');
    expect(find.text('QQ音乐 Cookie'), findsOneWidget);
    expect(find.text('网易云音乐 Cookie'), findsOneWidget);
    expect(find.text('B站 Cookie'), findsOneWidget);
    expect(find.text('音质设置'), findsNothing, reason: '换栏后上一栏的内容还在');

    await tapTab('下载与缓存');
    expect(find.text('下载设置'), findsOneWidget);
    expect(find.text('缓存'), findsOneWidget);
    expect(find.text('外观'), findsNothing);

    await tapTab('外观设置');
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('主题色'), findsOneWidget);
    expect(find.text('下载设置'), findsNothing);

    // 换栏时滚动位置要归零，否则回来时停在半截
    expect(scroll.offset, 0);
  });
}
