import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/app_paths.dart';
import 'package:elia_music/services/cover_cache.dart';

/// 封面磁盘缓存。
///
/// 这份缓存要**活过重启**，所以键必须每次算得一样 —— 用 `String.hashCode`
/// 就不行（不保证跨进程稳定）。这条最容易悄悄坏掉：键一变，缓存就退化成
/// 「每次都未命中、每次都重下一遍」，而功能看着还在。
void main() {
  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('elia_cover_test');
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

  test('键是稳定的：同一个 URL 每次一样，不同 URL 不一样', () {
    const a = 'https://i2.hdslb.com/bfs/archive/abc.jpg';
    const b = 'https://i2.hdslb.com/bfs/archive/abd.jpg';
    expect(CoverCache.keyOf(a), CoverCache.keyOf(a));
    expect(CoverCache.keyOf(a), isNot(CoverCache.keyOf(b)));
    expect(CoverCache.keyOf(a).length, 8, reason: '定长十六进制，键才是稳定的');
  });

  test('存进去能按 URL 取回来，后缀跟着 Content-Type 走', () {
    const url = 'https://p1.music.126.net/xyz.jpg';
    final bytes = Uint8List.fromList(List.generate(2048, (i) => i % 251));
    CoverCache.put(url, bytes, 'image/jpeg');

    final f = CoverCache.find(url);
    expect(f, isNotNull);
    expect(f!.path.endsWith('.jpg'), isTrue);
    expect(f.readAsBytesSync(), bytes);
    expect(CoverCache.contentTypeOf(f.path), 'image/jpeg');
    expect(CoverCache.sizeOnDisk(), greaterThanOrEqualTo(2048));
  });

  test('没存过的 URL 不命中', () {
    expect(CoverCache.find('https://example.com/never.png'), isNull);
  });

  test('半成品（.part）不算命中、也不计进体积', () {
    // 别的用例也往同一个目录里写过，所以只比「加了 .part 前后有没有变」
    final before = CoverCache.sizeOnDisk();
    final part = File('${CoverCache.dir.path}/deadbeef.part')
      ..writeAsBytesSync([1, 2, 3]);
    expect(CoverCache.sizeOnDisk(), before);
    expect(CoverCache.find('https://example.com/deadbeef.jpg'), isNull);
    part.deleteSync();
  });

  test('清空会把文件删掉', () {
    const url = 'https://example.com/a.webp';
    CoverCache.put(url, Uint8List.fromList([1, 2, 3, 4]), 'image/webp');
    expect(CoverCache.find(url), isNotNull);

    CoverCache.clearAll();
    expect(CoverCache.find(url), isNull);
    expect(CoverCache.sizeOnDisk(), 0);
  });
}
