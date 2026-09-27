import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/core/window_fx.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/bilibili_service.dart';
import 'package:elia_music/services/player_controller.dart';
import 'package:elia_music/services/video_bg.dart';
import 'package:elia_music/state/app_state.dart';
import 'package:elia_music/state/toast.dart';
import 'package:elia_music/ui/now_playing.dart';

/// B站视频背景：能单测的部分（挑选、尺寸、参数、取帧）+ 页面接线。
///
/// 真机上看的东西（画面跟不跟得上、卡不卡）留给千奈；这里盯的是
/// 「帧号↔时间」这条换算和「什么时候才该切背景」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_video_bg_test');
    AppPaths.appDir = tmp.path;
    AppPaths.dataDir = tmp.path;
    AppPaths.logsDir = tmp.path;
    AppPaths.tempDir = tmp.path;
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async => null);
    }
    messenger.setMockStreamHandler(
      const EventChannel('xyz.luan/audioplayers.global/events'),
      MockStreamHandler.inline(onListen: (args, sink) {}),
    );
  });

  group('挑视频流', () {
    Map<String, dynamic> v({
      required int id,
      required int w,
      required int h,
      required String codecs,
      int bw = 1000000,
      String url = 'https://example.com/v.m4s',
    }) =>
        {
          'id': id,
          'baseUrl': url,
          'width': w,
          'height': h,
          'codecs': codecs,
          'bandwidth': bw,
        };

    test('编码优先 AVC：HEVC 再小也不用（不是每台机器都硬解得了）', () {
      final picked = pickBilibiliVideo([
        v(id: 32, w: 480, h: 360, codecs: 'hev1.1.6.L120.90'),
        v(id: 64, w: 1280, h: 720, codecs: 'avc1.640028'),
      ]);
      expect(picked!.codecs, startsWith('avc1'));
      expect(picked.qn, 64, reason: '没有 AVC 的低档时，退到有 AVC 的那档');
    });

    test('直接取最低那一档（糊开的背景不需要高清）', () {
      final picked = pickBilibiliVideo([
        v(id: 80, w: 1920, h: 1080, codecs: 'avc1.640032'),
        v(id: 32, w: 852, h: 480, codecs: 'avc1.64001f'),
        v(id: 64, w: 1280, h: 720, codecs: 'avc1.640028'),
      ]);
      expect(picked!.qn, 32, reason: '480P 是最低那档 → 起流最快，糊开当背景够用');
    });

    test('再低也照取：240P 也要（背景本来就要糊掉）', () {
      final picked = pickBilibiliVideo([
        v(id: 32, w: 852, h: 480, codecs: 'avc1.64001f'),
        v(id: 16, w: 320, h: 240, codecs: 'avc1.64000c'),
      ]);
      expect(picked!.height, 240);
    });

    test('同档里挑带宽最小的', () {
      final picked = pickBilibiliVideo([
        v(id: 32, w: 852, h: 480, codecs: 'avc1.64001f', bw: 3_000_000),
        v(id: 32, w: 852, h: 480, codecs: 'avc1.64001f', bw: 900_000),
      ]);
      expect(picked!.url, 'https://example.com/v.m4s');
      expect(picked.qn, 32);
    });

    test('缺字段的条目跳过；一条能用的都没有 → null', () {
      expect(
        pickBilibiliVideo([
          {'id': 32, 'width': 852, 'height': 480}, // 没地址
          v(id: 32, w: 0, h: 0, codecs: 'avc1'),
          'not a map',
        ]),
        isNull,
      );
      expect(pickBilibiliVideo(const []), isNull);
    });

    test('候选节点：baseUrl + 备份，mcdn 排最后', () {
      final urls = bilibiliStreamUrls({
        'baseUrl': 'https://xy.mcdn.bilivideo.cn/v.m4s',
        'backupUrl': ['https://upos-sz.bilivideo.com/v.m4s'],
      });
      expect(urls.length, 2);
      expect(urls.first, contains('upos-sz'),
          reason: 'mcdn 是 P2P 边缘节点，实测会把连接掐掉 —— 别让它排第一');
      expect(urls.last, contains('mcdn'));
    });

    test('挑出来的那条带着全部候选', () {
      final picked = pickBilibiliVideo([
        {
          'id': 32,
          'baseUrl': 'https://xy.mcdn.bilivideo.cn/a.m4s',
          'backupUrl': ['https://upos-sz.bilivideo.com/a.m4s'],
          'width': 852,
          'height': 480,
          'codecs': 'avc1.64001f',
        },
      ]);
      expect(picked!.urls.length, 2);
      expect(picked.url, picked.urls.first);
    });
  });

  group('ffmpeg 参数', () {
    test('硬解优先：带上 d3d11va；软解不带', () {
      final hw = ffmpegArgs(
        input: 'a.m4s',
        width: 320,
        height: 180,
        startSecs: 0,
        hardware: true,
      );
      final sw = ffmpegArgs(
        input: 'a.m4s',
        width: 320,
        height: 180,
        startSecs: 0,
        hardware: false,
      );
      expect(hw, contains('-hwaccel'));
      expect(hw[hw.indexOf('-hwaccel') + 1], 'd3d11va');
      expect(sw, isNot(contains('-hwaccel')));
    });

    test('从中间解：`-ss` 落在 `-i` 前面（快跳关键帧）', () {
      final a = ffmpegArgs(
        input: 'a.m4s',
        width: 320,
        height: 180,
        startSecs: 12.5,
        hardware: true,
      );
      expect(a.indexOf('-ss'), lessThan(a.indexOf('-i')));
      expect(a[a.indexOf('-ss') + 1], '12.500');
      // 从 0 开始就别带 -ss 了（免得 ffmpeg 多走一次 seek 逻辑）
      final b = ffmpegArgs(
        input: 'a.m4s',
        width: 320,
        height: 180,
        startSecs: 0,
        hardware: true,
      );
      expect(b, isNot(contains('-ss')));
    });

    test('模糊与照片滤镜在 ffmpeg 里做（Flutter 侧只贴图）', () {
      final a = ffmpegArgs(
        input: 'a.m4s',
        width: 320,
        height: 180,
        startSecs: 0,
        hardware: false,
      );
      final vf = a[a.indexOf('-vf') + 1];
      expect(vf, contains('scale=320:180'));
      expect(vf, contains('gblur=sigma=${kVideoBlurSigma.toString()}'));
      expect(vf, contains('eq=contrast=0.68:saturation=3.0'),
          reason: '和封面背景的 bgPhotoFilter 算出来是同一条仿射');
    });

    test('输出是 rawvideo(BGRA)、帧率钉死', () {
      final a = ffmpegArgs(
        input: 'a.m4s',
        width: 320,
        height: 180,
        startSecs: 0,
        hardware: false,
      );
      expect(a[a.indexOf('-pix_fmt') + 1], 'bgra');
      expect(a[a.indexOf('-f') + 1], 'rawvideo');
      expect(a[a.indexOf('-r') + 1], '30');
      expect(a[a.indexOf('-fps_mode') + 1], 'cfr');
      expect(a.last, '-', reason: '最后一帧必须往 stdout 吐');
    });
  });

  group('按时间轴取帧', () {
    test('队列里挑最后一个不晚于目标的', () {
      final q = [10, 11, 12, 13];
      expect(frameIndexAt(q, 12), 2, reason: '正好命中');
      expect(frameIndexAt(q, 12.9.toInt()), 2, reason: '落在两帧之间 → 用早的那帧');
      expect(frameIndexAt(q, 13), 3);
      expect(frameIndexAt(q, 100), 3);
    });

    test('都还没到（解码跟不上）→ -1，画面先别动', () {
      expect(frameIndexAt([10, 11], 9), -1);
      expect(frameIndexAt(const [], 5), -1);
    });

    test('正常推进不算跳转（哪怕中间隔了两秒没收到位置事件）', () {
      expect(isSeekJump(0.2, 0.2), isFalse, reason: '每 200ms 一档的常规推进');
      // ⚠️ 这条就是那个死循环的判据：起 ffmpeg 期间帧循环停着，位置照样往前走了 2 秒
      expect(isSeekJump(2.0, 2.0), isFalse,
          reason: '位置走了多少和真实过了多久一致，就不是跳转');
      expect(isSeekJump(1.4, 0.2), isFalse, reason: '一档里的抖动不认');
    });

    test('拖了进度条才算跳转（往前、往后都认）', () {
      expect(isSeekJump(-30, 0.2), isTrue, reason: '往回拖');
      expect(isSeekJump(45, 0.2), isTrue, reason: '往前拖');
    });
  });

  group('现在播放页的接线', () {
    tearDown(() {
      videoBackground.debugDisabled = false;
      videoBackground.sync(want: false);
      app.setBgVideo(false);
      player.currentSong = null;
    });

    testWidgets('设置开着 + B站音源 + 页面打开 → 才会去拉流', (tester) async {
      videoBackground.debugDisabled = true; // 单测里不真去拉
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      appFullscreen.value = false;

      const bili = Song(
        mid: 'BV1xx411c7mD',
        name: '某首B站歌',
        artist: 'up',
        source: 'bilibili',
      );

      // 设置关着：不动
      app.setBgVideo(false);
      player.currentSong = bili;
      player.isPlaying = false;
      player.lyricLines = const [];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NowPlayingPage(state: app, open: true, onClose: () {})),
      ));
      await tester.pump();
      expect(videoBackground.wantedMid, isNull, reason: '默认关闭时不该去拉流');

      // 开了设置 → 目标就位
      app.setBgVideo(true);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NowPlayingPage(state: app, open: true, onClose: () {})),
      ));
      await tester.pump();
      expect(videoBackground.wantedMid, 'BV1xx411c7mD');

      // 收起页面 → 不再需要
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NowPlayingPage(state: app, open: false, onClose: () {})),
      ));
      await tester.pump();
      expect(videoBackground.wantedMid, isNull, reason: '页面收起就该停掉');

      toast.clear();
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('不是 B站音源就不会去拉流', (tester) async {
      videoBackground.debugDisabled = true;
      app.setBgVideo(true);
      player.currentSong =
          const Song(mid: 'qq1', name: 'QQ的歌', artist: 'a', source: 'qq');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NowPlayingPage(state: app, open: true, onClose: () {})),
      ));
      await tester.pump();
      expect(videoBackground.wantedMid, isNull);

      // LocalStore 的落盘是 120ms 防抖 —— 不等它，测试框架会判「有未完成的定时器」
      await tester.pump(const Duration(milliseconds: 200));
    });
  });

  group('有帧之后背景换成视频', () {
    /// 造一张真图（`ui.Image` 只能由引擎产出，测试里用这个 API 造）
    Future<ui.Image> solid(int w, int h) {
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List(w * h * 4),
        w,
        h,
        ui.PixelFormat.bgra8888,
        c.complete,
      );
      return c.future;
    }

    testWidgets('拿到帧才切，清掉帧就退回封面', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      player.currentSong = const Song(mid: 'm1', name: '铁花飞', artist: 'x');
      player.lyricLines = const [];
      videoBackground.frame.value = null;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NowPlayingPage(state: app, open: true, onClose: () {})),
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('bili-video')), findsNothing,
          reason: '没有帧的时候背景是封面');

      final img = await tester.runAsync(() => solid(64, 36));
      videoBackground.frame.value = img;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('bili-video')), findsOneWidget,
          reason: '有帧了才把背景换成视频');

      videoBackground.frame.value = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('bili-video')), findsNothing,
          reason: '帧没了（关掉设置/换歌/收起页面）要退回封面');
    });
  });
}
