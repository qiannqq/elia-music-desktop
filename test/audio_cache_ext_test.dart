import 'dart:typed_data';

import 'package:elia_music/services/audio_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List head(List<int> magic) {
  final b = Uint8List(16);
  for (var i = 0; i < magic.length && i < b.length; i++) {
    b[i] = magic[i];
  }
  return b;
}

/// 缓存文件的后缀决定播放器拿哪个解封装器 —— 存错了，命中缓存也放不出来。
void main() {
  test('fMP4 存成 m4a（B站的音频就是这种）', () {
    // `00 00 00 24` + "ftyp" + "iso5"
    expect(
      AudioDiskCache.extensionForBytes(
        head([0x00, 0x00, 0x00, 0x24, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x35]),
      ),
      '.m4a',
    );
  });

  test('ID3 标签与 MPEG 帧同步都算 mp3', () {
    expect(
      AudioDiskCache.extensionForBytes(
        head([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01, 0x21, 0x54, 0x49]),
      ),
      '.mp3',
    );
    expect(
      AudioDiskCache.extensionForBytes(
        head([0xFF, 0xFB, 0x90, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
      ),
      '.mp3',
    );
  });

  test('fLaC 与 OggS', () {
    expect(
      AudioDiskCache.extensionForBytes(
        head([0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
      ),
      '.flac',
    );
    expect(
      AudioDiskCache.extensionForBytes(
        head([0x4F, 0x67, 0x67, 0x53, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
      ),
      '.ogg',
    );
  });

  test('空文件与认不出来的都退到 mp3', () {
    expect(AudioDiskCache.extensionForBytes(Uint8List(0)), '.mp3');
    expect(AudioDiskCache.extensionForBytes(head([0x01, 0x02, 0x03])), '.mp3');
  });
}
