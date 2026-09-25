import 'package:flutter_test/flutter_test.dart';

import 'package:elia_music/core/lyric_scroll.dart';

/// 歌词滚动的弹簧参数（照 AMLL 的 `getPosYSpringPolicy`）。
///
/// 这些数字决定「唱着唱着歌词往上走的那个手感」，错了从界面上很难说清哪里不对
/// （只会觉得「不顺」或者「弹了一下」），所以把规则钉在测试里。
void main() {
  group('歌词滚动弹簧', () {
    test('正常跟随：过阻尼，不会冲过头再弹回来', () {
      // 间隔从很短到很长都试一遍
      for (final interval in [80.0, 100.0, 300.0, 800.0, 2000.0]) {
        final spec = lyricSpringFor(intervalMs: interval);
        expect(lyricDampingRatio(spec), greaterThanOrEqualTo(1.0),
            reason: '间隔 ${interval}ms 时阻尼比小于 1 的话会回弹一下');
      }
    });

    test('间隔越短滚得越快（刚度落在 AMLL 的 170~220 里）', () {
      final fast = lyricSpringFor(intervalMs: 100);
      final slow = lyricSpringFor(intervalMs: 800);
      expect(fast.stiffness, closeTo(kLyricStiffnessMax, 0.01));
      expect(slow.stiffness, closeTo(kLyricStiffnessMin, 0.01));
      expect(fast.stiffness, greaterThan(slow.stiffness));

      // 超出范围的要被夹住，不是线性外推
      expect(lyricSpringFor(intervalMs: 10).stiffness,
          closeTo(kLyricStiffnessMax, 0.01));
      expect(lyricSpringFor(intervalMs: 9999).stiffness,
          closeTo(kLyricStiffnessMin, 0.01));
    });

    test('开五次方根：中间那些间隔也偏快（不是线性映射）', () {
      // 600ms 在线性映射下只拿到 (800-600)/700 = 0.29 的比例，
      // 开五次方根之后应该是 0.29^0.2 ≈ 0.78 —— 明显更接近最快那档
      final mid = lyricSpringFor(intervalMs: 600);
      final ratio = (mid.stiffness - kLyricStiffnessMin) /
          (kLyricStiffnessMax - kLyricStiffnessMin);
      expect(ratio, greaterThan(0.6), reason: '开根之后要偏向快的那档');
    });

    test('跳转用很慢很飘的参数（和 AMLL 一样）', () {
      final seek = lyricSpringFor(seeking: true);
      expect(seek.stiffness, kLyricSeekStiffness);
      expect(seek.damping, kLyricSeekDamping);
      // 拖进度条跨过好几句时，用慢参数而不是「这一段间隔很短」的快参数
      final fast = lyricSpringFor(intervalMs: 100);
      expect(seek.stiffness, lessThan(fast.stiffness));
    });

    test('最后一句用中速（比跳转快、比正常慢）', () {
      final end = lyricSpringFor(endOfSong: true);
      expect(end.stiffness, kLyricEndStiffness);
      expect(end.stiffness, greaterThan(kLyricSeekStiffness));
      expect(end.stiffness, lessThan(kLyricStiffnessMin));
    });

    test('第一句（没有上一句可比）走慢速兜底', () {
      final first = lyricSpringFor(intervalMs: null);
      expect(first.stiffness, kLyricSeekStiffness);
    });
  });

  group('错峰延迟（依次跟上）', () {
    test('第一行不延迟，往下逐行递增', () {
      final d = staggerDelays(first: 10, last: 16, active: 12);
      expect(d.first, 0);
      expect(d.length, 7);
      for (var i = 1; i < d.length; i++) {
        expect(d[i], greaterThan(d[i - 1]), reason: '越靠下的行启动得越晚');
      }
      // 第一步就是 50ms
      expect(d[1], closeTo(kStaggerStepSecs, 1e-9));
    });

    test('当前句之后的增幅按 1.05 递减（越往下越挤）', () {
      final d = staggerDelays(first: 0, last: 8, active: 2);
      final gaps = [for (var i = 1; i < d.length; i++) d[i] - d[i - 1]];

      // 当前句之前是等间隔
      expect(gaps[0], closeTo(kStaggerStepSecs, 1e-9));
      expect(gaps[1], closeTo(kStaggerStepSecs, 1e-9));

      // 间隔只能越缩越小（AMLL 是「先累加、再衰减」，所以衰减作用在**下一段**间隔上）
      for (var i = 1; i < gaps.length; i++) {
        expect(gaps[i], lessThanOrEqualTo(gaps[i - 1] + 1e-9),
            reason: '第 $i 段间隔不该比前一段大');
      }
      expect(gaps.last, lessThan(gaps.first), reason: '越往下越挤');
    });

    test('总延迟有上限（长歌词里末尾几行不会等到天荒地老）', () {
      final d = staggerDelays(first: 0, last: 200, active: 0);
      expect(d.last, lessThanOrEqualTo(kStaggerMaxSecs + 1e-9));
      // 上限之内确实有延迟，不是直接归零
      expect(d[d.length ~/ 2], greaterThan(0));
    });

    test('只有一行时不崩', () {
      expect(staggerDelays(first: 3, last: 3, active: 3), [0.0]);
    });
  });
}
