import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/services/audio_cache.dart';
import 'package:elia_music/services/silence_probe.dart';

/// 「跳过首尾无声」的两块纯逻辑：
///
///   * [SilenceSkip] —— 什么时候跳、跳完还跳不跳、用户拖过之后怎么办。
///     这些判定错了很难从界面上看出来（最多是「开头还是静了几秒」或者
///     「拖回开头又被顶走」），所以单独盯着。
///   * [SilenceProbe] —— 等本地音频文件、轮询原生的结果、落盘、命中缓存。
///
/// 真正解音频的是原生侧（Media Foundation），这里把通道挡掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const trimWithBoth =
      SilenceTrim(durationMs: 200000, startMs: 3000, endMs: 195000);
  const noTrim = SilenceTrim(durationMs: 200000, startMs: 0, endMs: 200000);

  late List<String> calls;
  late String lastSource;
  late int pollsBeforeResult;

  /// 造一份「已缓存」的音频。
  ///
  /// `AudioDiskCache.find()` 的三个条件都要满足：文件非空、索引里有当前凭据代次、
  /// 后缀与内容相符（随便写点字节 → 认不出来 → 按 `.mp3` 算）。
  File seedAudio(String mid) {
    final f = File('${AudioDiskCache.dir.path}/$mid.mp3')
      ..writeAsBytesSync(Uint8List.fromList(List.filled(64, 7)));
    File('${AudioDiskCache.dir.path}/index.json').writeAsStringSync(
        '{"$mid":{"cachedAt":1,"lastPlayedAt":1,"epoch":${AudioDiskCache.epoch}}}');
    return f;
  }

  void clearAudioCache() {
    try {
      for (final f in AudioDiskCache.dir.listSync()) {
        if (f is File) f.deleteSync();
      }
    } catch (_) {}
  }

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_silence_test');
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

  setUp(() {
    SilenceProbe.clearCache();
    clearAudioCache();
    // 默认 20s 是给真机留的余量，测试里不用等那么久
    SilenceProbe.fileWait = const Duration(milliseconds: 900);
    calls = [];
    lastSource = '';
    pollsBeforeResult = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('elia/audio_probe'),
            (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'start':
          lastSource = ((call.arguments as Map)['source'] ?? '').toString();
          return true;
        case 'poll':
          if (pollsBeforeResult > 0) {
            pollsBeforeResult--;
            return null;
          }
          return <Object?, Object?>{
            'source': lastSource,
            'ok': true,
            'durationMs': 200000,
            'startMs': 3000,
            'endMs': 195000,
          };
      }
      return null;
    });
  });

  tearDown(() {
    SilenceProbe.fileWait = const Duration(seconds: 20);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('elia/audio_probe'), null);
  });

  group('SilenceSkip 的判定', () {
    test('没有结果：什么都不跳', () {
      final skip = SilenceSkip();
      expect(skip.leadingTarget(Duration.zero), isNull);
      expect(skip.reachedEnd(const Duration(minutes: 5)), isFalse);
    });

    test('首尾都没有空白：什么都不跳', () {
      final skip = SilenceSkip()..apply(noTrim);
      expect(skip.leadingTarget(Duration.zero), isNull);
      expect(skip.reachedEnd(const Duration(seconds: 199)), isFalse);
    });

    test('开头：跳一次，之后不再跳', () {
      final skip = SilenceSkip()..apply(trimWithBoth);
      expect(skip.leadingTarget(Duration.zero), const Duration(seconds: 3));
      expect(skip.leadingTarget(Duration.zero), isNull,
          reason: '只跳一次 —— 否则用户拖回开头会被立刻顶走');
    });

    test('位置已经在第一声之后：不跳，但也不该再跳', () {
      final skip = SilenceSkip()..apply(trimWithBoth);
      expect(skip.leadingTarget(const Duration(seconds: 10)), isNull);
      expect(skip.leadingTarget(Duration.zero), isNull,
          reason: '判定过一次就消费掉了，不会再回头跳');
    });

    test('用户自己拖过进度条：开头那段让他听', () {
      final skip = SilenceSkip()..apply(trimWithBoth);
      skip.userSeeked();
      expect(skip.leadingTarget(Duration.zero), isNull);
    });

    test('单曲循环重头放：开头那段要重新跳', () {
      final skip = SilenceSkip()..apply(trimWithBoth);
      expect(skip.leadingTarget(Duration.zero), isNotNull);
      skip.rewind();
      expect(skip.leadingTarget(Duration.zero), const Duration(seconds: 3));
    });

    test('结尾：到点算唱完，只算一次', () {
      final skip = SilenceSkip()..apply(trimWithBoth);
      expect(skip.reachedEnd(const Duration(milliseconds: 194999)), isFalse);
      expect(skip.reachedEnd(const Duration(milliseconds: 195000)), isTrue);
      expect(skip.reachedEnd(const Duration(milliseconds: 196000)), isFalse,
          reason: '位置事件每秒来好几次，只认第一次');
    });
  });

  group('SilenceProbe', () {
    test('轮询到结果就返回，并落盘', () async {
      final file = seedAudio('mid1');
      pollsBeforeResult = 2; // 前两次还没好

      final trim = await SilenceProbe.probe('mid1');

      expect(trim, isNotNull);
      expect(trim!.startMs, 3000);
      expect(trim.endMs, 195000);
      expect(calls, ['start', 'poll', 'poll', 'poll']);
      // 目录列表给出来的路径用的是平台分隔符，跟拼出来的不完全一样，只比文件名
      expect(lastSource.endsWith('mid1.mp3'), isTrue);
      expect(lastSource.contains('http'), isFalse, reason: '探测只在本地文件上做，不能喂 http 地址');
      expect(File(lastSource).existsSync(), isTrue);
      expect(file.existsSync(), isTrue);

      // 存下来了：第二次直接命中，不再碰通道
      calls.clear();
      final again = await SilenceProbe.probe('mid1');
      expect(again!.startMs, 3000);
      expect(calls, isEmpty, reason: '探测结果存过就不该再解一遍音频');
    });

    test('本地文件是边播边缓存出来的：等它落地再探', () async {
      // 模拟 `AudioDiskCache.warm`：探测开始时文件还没写完，过一会儿才出现
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        seedAudio('midLate');
      });

      final trim = await SilenceProbe.probe('midLate');
      expect(trim, isNotNull);
      expect(calls.first, 'start');
    });

    test('等不到本地文件、又没有地址：不探测', () async {
      expect(await SilenceProbe.probe('mid4'), isNull);
      expect(calls, isEmpty);
    });

    test('源对不上（被别的歌顶掉了）：放弃', () async {
      seedAudio('mid2');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('elia/audio_probe'),
              (call) async {
        calls.add(call.method);
        if (call.method == 'start') return true;
        return <Object?, Object?>{
          'source': '别人的源',
          'ok': true,
          'durationMs': 200000,
          'startMs': 3000,
          'endMs': 195000,
        };
      });

      expect(await SilenceProbe.probe('mid2'), isNull);
      expect(SilenceProbe.cached('mid2'), isNull);
    });

    test('原生说探不出来：不缓存', () async {
      seedAudio('mid3');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('elia/audio_probe'),
              (call) async {
        calls.add(call.method);
        if (call.method == 'start') return true;
        return <Object?, Object?>{'source': lastSource, 'ok': false};
      });

      expect(await SilenceProbe.probe('mid3'), isNull);
      expect(SilenceProbe.cached('mid3'), isNull);
    });

    test('凭据代次变了：旧结果作废', () async {
      seedAudio('mid5');
      await SilenceProbe.probe('mid5');
      expect(SilenceProbe.cached('mid5'), isNotNull);

      // 匿名状态下探的可能是试听片段，配上会员 ck 之后音频就不是那份了
      AudioDiskCache.bumpEpoch();
      expect(SilenceProbe.cached('mid5'), isNull);
    });

    test('清缓存会把探测结果一起清掉', () async {
      seedAudio('mid6');
      await SilenceProbe.probe('mid6');
      expect(SilenceProbe.cached('mid6'), isNotNull);
      SilenceProbe.clearCache();
      expect(SilenceProbe.cached('mid6'), isNull);
    });
  });
}
