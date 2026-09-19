import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'qrc_sbox.dart';

/// QQ 音乐 QRC 歌词解密。
///
/// **关键**：QRC 用的是**非标准 DES 变体** —— S-box 与标准 DES 差两项
/// （S2[23]=15、S4[53]=10）。所以 OpenSSL / Node `crypto` / pycryptodome
/// 的 `des-ede3` **全都解不开**（会得到乱码、zlib 报 header check 失败）。
/// 必须用 [kQrcSbox] 这张私有表。
///
/// 流程：hex → 3DES-EDE-ECB 解密（无填充）→ zlib inflate → UTF-8。
/// 这是 `qrc_decode.py`（lx-music-desktop 的 qrcDecode.js 移植版）的 Dart 移植，
/// 已用文档附录 C 的离线测试向量校验：
///   密文 12416 hex → SHA-256 ad86eb91…；解密结果 10965 字符 → SHA-256 b5ce5018…
class QrcDecrypt {
  QrcDecrypt._();

  static const String _keyStr = r'!@#)(*$%123ZXC!@!@#)(NHL';

  static const List<int> _keyRndShift = [
    1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1,
  ];

  static const List<int> _keyPermC = [
    56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1,
    58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35,
  ];

  static const List<int> _keyPermD = [
    62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5,
    60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3,
  ];

  static const List<int> _keyCompression = [
    13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3,
    25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39,
    50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31,
  ];

  static const int _desEncrypt = 1;
  static const int _desDecrypt = 0;

  static const int _mask32 = 0xFFFFFFFF;

  static int _bitnum(List<int> a, int b, int c) =>
      (((a[((b ~/ 32) * 4 + 3 - ((b % 32) ~/ 8))] >> (7 - (b % 8))) & 1) << c) &
      _mask32;

  static int _bitnumIntr(int a, int b, int c) => ((a >> (31 - b)) & 1) << c;

  static int _bitnumIntl(int a, int b, int c) =>
      ((((a << b) & _mask32) & 0x80000000) >> c);

  static int _sboxBit(int a) => (a & 32) | ((a & 31) >> 1) | ((a & 1) << 4);

  static List<int> _initialPermutation(List<int> inp) {
    var s0 = (_bitnum(inp, 57, 31) |
            _bitnum(inp, 49, 30) |
            _bitnum(inp, 41, 29) |
            _bitnum(inp, 33, 28) |
            _bitnum(inp, 25, 27) |
            _bitnum(inp, 17, 26) |
            _bitnum(inp, 9, 25) |
            _bitnum(inp, 1, 24) |
            _bitnum(inp, 59, 23) |
            _bitnum(inp, 51, 22) |
            _bitnum(inp, 43, 21) |
            _bitnum(inp, 35, 20) |
            _bitnum(inp, 27, 19) |
            _bitnum(inp, 19, 18) |
            _bitnum(inp, 11, 17) |
            _bitnum(inp, 3, 16) |
            _bitnum(inp, 61, 15) |
            _bitnum(inp, 53, 14) |
            _bitnum(inp, 45, 13) |
            _bitnum(inp, 37, 12) |
            _bitnum(inp, 29, 11) |
            _bitnum(inp, 21, 10) |
            _bitnum(inp, 13, 9) |
            _bitnum(inp, 5, 8) |
            _bitnum(inp, 63, 7) |
            _bitnum(inp, 55, 6) |
            _bitnum(inp, 47, 5) |
            _bitnum(inp, 39, 4) |
            _bitnum(inp, 31, 3) |
            _bitnum(inp, 23, 2) |
            _bitnum(inp, 15, 1) |
            _bitnum(inp, 7, 0)) &
        _mask32;
    var s1 = (_bitnum(inp, 56, 31) |
            _bitnum(inp, 48, 30) |
            _bitnum(inp, 40, 29) |
            _bitnum(inp, 32, 28) |
            _bitnum(inp, 24, 27) |
            _bitnum(inp, 16, 26) |
            _bitnum(inp, 8, 25) |
            _bitnum(inp, 0, 24) |
            _bitnum(inp, 58, 23) |
            _bitnum(inp, 50, 22) |
            _bitnum(inp, 42, 21) |
            _bitnum(inp, 34, 20) |
            _bitnum(inp, 26, 19) |
            _bitnum(inp, 18, 18) |
            _bitnum(inp, 10, 17) |
            _bitnum(inp, 2, 16) |
            _bitnum(inp, 60, 15) |
            _bitnum(inp, 52, 14) |
            _bitnum(inp, 44, 13) |
            _bitnum(inp, 36, 12) |
            _bitnum(inp, 28, 11) |
            _bitnum(inp, 20, 10) |
            _bitnum(inp, 12, 9) |
            _bitnum(inp, 4, 8) |
            _bitnum(inp, 62, 7) |
            _bitnum(inp, 54, 6) |
            _bitnum(inp, 46, 5) |
            _bitnum(inp, 38, 4) |
            _bitnum(inp, 30, 3) |
            _bitnum(inp, 22, 2) |
            _bitnum(inp, 14, 1) |
            _bitnum(inp, 6, 0)) &
        _mask32;
    return [s0, s1];
  }

  static void _inversePermutation(int s0, int s1, Uint8List out) {
    out[3] = (_bitnumIntr(s1, 7, 7) |
            _bitnumIntr(s0, 7, 6) |
            _bitnumIntr(s1, 15, 5) |
            _bitnumIntr(s0, 15, 4) |
            _bitnumIntr(s1, 23, 3) |
            _bitnumIntr(s0, 23, 2) |
            _bitnumIntr(s1, 31, 1) |
            _bitnumIntr(s0, 31, 0)) &
        0xff;
    out[2] = (_bitnumIntr(s1, 6, 7) |
            _bitnumIntr(s0, 6, 6) |
            _bitnumIntr(s1, 14, 5) |
            _bitnumIntr(s0, 14, 4) |
            _bitnumIntr(s1, 22, 3) |
            _bitnumIntr(s0, 22, 2) |
            _bitnumIntr(s1, 30, 1) |
            _bitnumIntr(s0, 30, 0)) &
        0xff;
    out[1] = (_bitnumIntr(s1, 5, 7) |
            _bitnumIntr(s0, 5, 6) |
            _bitnumIntr(s1, 13, 5) |
            _bitnumIntr(s0, 13, 4) |
            _bitnumIntr(s1, 21, 3) |
            _bitnumIntr(s0, 21, 2) |
            _bitnumIntr(s1, 29, 1) |
            _bitnumIntr(s0, 29, 0)) &
        0xff;
    out[0] = (_bitnumIntr(s1, 4, 7) |
            _bitnumIntr(s0, 4, 6) |
            _bitnumIntr(s1, 12, 5) |
            _bitnumIntr(s0, 12, 4) |
            _bitnumIntr(s1, 20, 3) |
            _bitnumIntr(s0, 20, 2) |
            _bitnumIntr(s1, 28, 1) |
            _bitnumIntr(s0, 28, 0)) &
        0xff;
    out[7] = (_bitnumIntr(s1, 3, 7) |
            _bitnumIntr(s0, 3, 6) |
            _bitnumIntr(s1, 11, 5) |
            _bitnumIntr(s0, 11, 4) |
            _bitnumIntr(s1, 19, 3) |
            _bitnumIntr(s0, 19, 2) |
            _bitnumIntr(s1, 27, 1) |
            _bitnumIntr(s0, 27, 0)) &
        0xff;
    out[6] = (_bitnumIntr(s1, 2, 7) |
            _bitnumIntr(s0, 2, 6) |
            _bitnumIntr(s1, 10, 5) |
            _bitnumIntr(s0, 10, 4) |
            _bitnumIntr(s1, 18, 3) |
            _bitnumIntr(s0, 18, 2) |
            _bitnumIntr(s1, 26, 1) |
            _bitnumIntr(s0, 26, 0)) &
        0xff;
    out[5] = (_bitnumIntr(s1, 1, 7) |
            _bitnumIntr(s0, 1, 6) |
            _bitnumIntr(s1, 9, 5) |
            _bitnumIntr(s0, 9, 4) |
            _bitnumIntr(s1, 17, 3) |
            _bitnumIntr(s0, 17, 2) |
            _bitnumIntr(s1, 25, 1) |
            _bitnumIntr(s0, 25, 0)) &
        0xff;
    out[4] = (_bitnumIntr(s1, 0, 7) |
            _bitnumIntr(s0, 0, 6) |
            _bitnumIntr(s1, 8, 5) |
            _bitnumIntr(s0, 8, 4) |
            _bitnumIntr(s1, 16, 3) |
            _bitnumIntr(s0, 16, 2) |
            _bitnumIntr(s1, 24, 1) |
            _bitnumIntr(s0, 24, 0)) &
        0xff;
  }

  static int _desF(int state, List<int> key) {
    final t1 = (_bitnumIntl(state, 31, 0) |
            ((state & 0xf0000000) & _mask32) >> 1 |
            _bitnumIntl(state, 4, 5) |
            _bitnumIntl(state, 3, 6) |
            ((state & 0x0f000000) & _mask32) >> 3 |
            _bitnumIntl(state, 8, 11) |
            _bitnumIntl(state, 7, 12) |
            ((state & 0x00f00000) & _mask32) >> 5 |
            _bitnumIntl(state, 12, 17) |
            _bitnumIntl(state, 11, 18) |
            ((state & 0x000f0000) & _mask32) >> 7 |
            _bitnumIntl(state, 16, 23)) &
        _mask32;
    final t2 = (_bitnumIntl(state, 15, 0) |
            (((state & 0x0000f000) << 15) & _mask32) |
            _bitnumIntl(state, 20, 5) |
            _bitnumIntl(state, 19, 6) |
            (((state & 0x00000f00) << 13) & _mask32) |
            _bitnumIntl(state, 24, 11) |
            _bitnumIntl(state, 23, 12) |
            (((state & 0x000000f0) << 11) & _mask32) |
            _bitnumIntl(state, 28, 17) |
            _bitnumIntl(state, 27, 18) |
            (((state & 0x0000000f) << 9) & _mask32) |
            _bitnumIntl(state, 0, 23)) &
        _mask32;

    final lrg = <int>[
      (t1 >> 24) & 0xff,
      (t1 >> 16) & 0xff,
      (t1 >> 8) & 0xff,
      (t2 >> 24) & 0xff,
      (t2 >> 16) & 0xff,
      (t2 >> 8) & 0xff,
    ];
    for (var i = 0; i < 6; i++) {
      lrg[i] ^= key[i];
    }

    final s = ((kQrcSbox[0][_sboxBit(lrg[0] >> 2)] << 28) |
            (kQrcSbox[1][_sboxBit(((lrg[0] & 0x03) << 4) | (lrg[1] >> 4))] << 24) |
            (kQrcSbox[2][_sboxBit(((lrg[1] & 0x0f) << 2) | (lrg[2] >> 6))] << 20) |
            (kQrcSbox[3][_sboxBit(lrg[2] & 0x3f)] << 16) |
            (kQrcSbox[4][_sboxBit(lrg[3] >> 2)] << 12) |
            (kQrcSbox[5][_sboxBit(((lrg[3] & 0x03) << 4) | (lrg[4] >> 4))] << 8) |
            (kQrcSbox[6][_sboxBit(((lrg[4] & 0x0f) << 2) | (lrg[5] >> 6))] << 4) |
            kQrcSbox[7][_sboxBit(lrg[5] & 0x3f)]) &
        _mask32;

    return (_bitnumIntl(s, 15, 0) |
            _bitnumIntl(s, 6, 1) |
            _bitnumIntl(s, 19, 2) |
            _bitnumIntl(s, 20, 3) |
            _bitnumIntl(s, 28, 4) |
            _bitnumIntl(s, 11, 5) |
            _bitnumIntl(s, 27, 6) |
            _bitnumIntl(s, 16, 7) |
            _bitnumIntl(s, 0, 8) |
            _bitnumIntl(s, 14, 9) |
            _bitnumIntl(s, 22, 10) |
            _bitnumIntl(s, 25, 11) |
            _bitnumIntl(s, 4, 12) |
            _bitnumIntl(s, 17, 13) |
            _bitnumIntl(s, 30, 14) |
            _bitnumIntl(s, 9, 15) |
            _bitnumIntl(s, 1, 16) |
            _bitnumIntl(s, 7, 17) |
            _bitnumIntl(s, 23, 18) |
            _bitnumIntl(s, 13, 19) |
            _bitnumIntl(s, 31, 20) |
            _bitnumIntl(s, 26, 21) |
            _bitnumIntl(s, 2, 22) |
            _bitnumIntl(s, 8, 23) |
            _bitnumIntl(s, 18, 24) |
            _bitnumIntl(s, 12, 25) |
            _bitnumIntl(s, 29, 26) |
            _bitnumIntl(s, 5, 27) |
            _bitnumIntl(s, 21, 28) |
            _bitnumIntl(s, 10, 29) |
            _bitnumIntl(s, 3, 30) |
            _bitnumIntl(s, 24, 31)) &
        _mask32;
  }

  static void _desCrypt(List<int> inp, List<Uint8List> schedule, Uint8List out) {
    final ip = _initialPermutation(inp);
    var s0 = ip[0];
    var s1 = ip[1];
    for (var i = 0; i < 15; i++) {
      final prev = s1;
      s1 = (_desF(s1, schedule[i]) ^ s0) & _mask32;
      s0 = prev;
    }
    s0 = (_desF(s1, schedule[15]) ^ s0) & _mask32;
    _inversePermutation(s0, s1, out);
  }

  static List<Uint8List> _keySchedule(List<int> key, int mode) {
    final schedule = List.generate(16, (_) => Uint8List(6));
    var c = 0;
    var d = 0;
    for (var i = 0; i < 28; i++) {
      c = (c | _bitnum(key, _keyPermC[i], 31 - i)) & _mask32;
      d = (d | _bitnum(key, _keyPermD[i], 31 - i)) & _mask32;
    }
    for (var i = 0; i < 16; i++) {
      final sh = _keyRndShift[i];
      c = ((((c << sh) & _mask32) | (c >> (28 - sh))) & 0xfffffff0) & _mask32;
      d = ((((d << sh) & _mask32) | (d >> (28 - sh))) & 0xfffffff0) & _mask32;
      final togen = mode == _desDecrypt ? 15 - i : i;
      for (var j = 0; j < 24; j++) {
        schedule[togen][j ~/ 8] |= _bitnumIntr(c, _keyCompression[j], 7 - (j % 8));
      }
      for (var j = 24; j < 48; j++) {
        schedule[togen][j ~/ 8] |=
            _bitnumIntr(d, _keyCompression[j] - 27, 7 - (j % 8));
      }
    }
    return schedule;
  }

  static List<List<Uint8List>> _tripledesKeySetup(List<int> key, int mode) {
    if (mode == _desEncrypt) {
      return [
        _keySchedule(key.sublist(0, 8), _desEncrypt),
        _keySchedule(key.sublist(8, 16), _desDecrypt),
        _keySchedule(key.sublist(16, 24), _desEncrypt),
      ];
    }
    // 解密：D(K3) -> E(K2) -> D(K1)
    return [
      _keySchedule(key.sublist(16, 24), _desDecrypt),
      _keySchedule(key.sublist(8, 16), _desEncrypt),
      _keySchedule(key.sublist(0, 8), _desDecrypt),
    ];
  }

  static Uint8List _tripledesCrypt(List<int> inp, List<List<Uint8List>> schedule) {
    final out = Uint8List(8);
    final buf = Uint8List(8);
    _desCrypt(inp, schedule[0], buf);
    _desCrypt(buf, schedule[1], out);
    _desCrypt(out, schedule[2], buf);
    return buf;
  }

  /// 把接口返回的十六进制密文解密、解压为 UTF-8 文本；失败返回 null。
  static String? decode(String hexData) {
    if (hexData.isEmpty || hexData.length.isOdd) return null;
    final Uint8List encrypted;
    try {
      encrypted = _hexToBytes(hexData);
    } catch (_) {
      return null;
    }
    if (encrypted.isEmpty) return null;

    final schedule =
        _tripledesKeySetup(utf8.encode(_keyStr), _desDecrypt);
    final plain = Uint8List.fromList(encrypted);
    for (var i = 0; i + 8 <= plain.length; i += 8) {
      plain.setRange(i, i + 8,
          _tripledesCrypt(plain.sublist(i, i + 8), schedule));
    }

    try {
      final decompressed = zlib.decode(plain);
      return utf8.decode(decompressed, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
