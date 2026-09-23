import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/models/song.dart';
import 'package:elia_music/services/audio_cache.dart';
import 'package:elia_music/state/app_state.dart';

/// 上游只给试听片段（网易云会员曲目没权限时是 30 秒）。
///
/// 那份 30 秒的文件一旦进了缓存就会被一直命中 —— 用户后来配好了会员，
/// 听到的还是那 30 秒。所以：判定出来之后要**删掉**、并且本次会话里
/// 不再缓存它。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_trial_test');
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

  const song = Song(mid: 'ne1', name: '会员曲', artist: '某人', duration: 240000);

  test('drop 会把已缓存的音频删掉', () {
    // 直接往缓存目录里塞一个「已缓存」的文件（并记上当前代次，才算命中）
    final f = File('${AudioDiskCache.dir.path}/${song.mid}.mp3')
      ..writeAsBytesSync(Uint8List.fromList(List.filled(64, 7)));
    File('${AudioDiskCache.dir.path}/index.json').writeAsStringSync(
        '{"${song.mid}":{"cachedAt":1,"lastPlayedAt":1,'
        '"epoch":${AudioDiskCache.epoch}}}');
    expect(AudioDiskCache.find(song.mid), isNotNull);

    AudioDiskCache.drop(song.mid);
    expect(AudioDiskCache.find(song.mid), isNull);
    expect(f.existsSync(), isFalse);
  });

  test('标记成试听之后 warm 不会再存一遍', () async {
    AudioDiskCache.markTrial(song.mid);
    expect(AudioDiskCache.isTrial(song.mid), isTrue);

    // 真去下的话这里会打网络；提前 return 才是对的
    await AudioDiskCache.warm(song.mid, 'http://127.0.0.1:1/never.mp3');
    expect(AudioDiskCache.find(song.mid), isNull, reason: '试听片段不该入缓存');
  });

  test('收到「只给了试听片段」会删缓存并标记', () {
    final f = File('${AudioDiskCache.dir.path}/${song.mid}.mp3')
      ..writeAsBytesSync(Uint8List.fromList(List.filled(64, 7)));
    expect(f.existsSync(), isTrue);

    app.onShortAudio(song);

    expect(f.existsSync(), isFalse, reason: '那份试听文件必须删掉');
    expect(AudioDiskCache.isTrial(song.mid), isTrue);
  });

  test('凭据变过之后旧条目不再命中（这一版之前的条目也一并作废）', () {
    File('${AudioDiskCache.dir.path}/${song.mid}.mp3')
        .writeAsBytesSync(Uint8List.fromList(List.filled(64, 7)));
    final index = File('${AudioDiskCache.dir.path}/index.json');

    // 老条目：没有 epoch 字段 —— 可能正是匿名状态下缓存的试听片段
    index.writeAsStringSync('{"${song.mid}":{"cachedAt":1,"lastPlayedAt":1}}');
    expect(AudioDiskCache.find(song.mid), isNull,
        reason: '没有代次的条目一律当未命中，否则配好会员也还是听 30 秒');

    // 记上当前代次就是正常命中
    index.writeAsStringSync('{"${song.mid}":'
        '{"cachedAt":1,"lastPlayedAt":1,"epoch":${AudioDiskCache.epoch}}}');
    expect(AudioDiskCache.find(song.mid), isNotNull);

    // 用户配好会员 ck → 代次推一格 → 之前那份立刻作废
    AudioDiskCache.bumpEpoch();
    expect(AudioDiskCache.find(song.mid), isNull);
    expect(File('${AudioDiskCache.dir.path}/${song.mid}.mp3').existsSync(), isTrue,
        reason: '文件先留着：重新取的时候会就地覆盖，不用多一次删除');
  });
}
