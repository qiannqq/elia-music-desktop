/// 歌词纵向滚动的弹簧参数 —— 照 AMLL 的 `getPosYSpringPolicy` 复刻。
///
/// 为什么不用 `animateTo(420ms, easeOutCubic)`：
///
///  * **速度是连续的**。目标在飞行途中变了（下一句来得快、或者用户在拖进度条），
///    弹簧会带着**当前速度**接着走；固定时长的补间每次都从「速度 0」重新开始 ——
///    连续两句间隔很短时，表现为一顿一顿的。AMLL 那种顺滑主要就来自这一条。
///  * **快慢跟着行间隔走**：间隔越短滚得越快（刚度 170~220），间隔长就慢慢飘过去。
///  * **阻尼比约 1.1（过阻尼）**：不会冲过头再弹回来，落位干净利落。
///
/// 数字都是 AMLL 的原值，别随手改 —— 改了手感就不是那个了。
library;

import 'dart:math' as math;

import 'package:flutter/physics.dart';

/// 两行间隔被夹在这个范围内参与映射（毫秒）
const double kLyricIntervalMinMs = 100;
const double kLyricIntervalMaxMs = 800;

/// 正常跟随时的刚度范围：间隔 ≤100ms → 220，间隔 ≥800ms → 170
const double kLyricStiffnessMin = 170;
const double kLyricStiffnessMax = 220;

/// 阻尼 = `sqrt(刚度) × 这个倍数` → 约 1.1 倍临界阻尼（过阻尼）
const double kLyricDampingMultiplier = 2.2;

/// 间隔映射到刚度时开五次方根 —— 让大部分区间都保持较高的刚度（偏快）
const double kLyricIntervalExponent = 0.2;

/// 弹簧的质量（AMLL 的 `posYSpringParams.mass`）
const double kLyricSpringMass = 0.9;

/// 跳转（Seek）与间奏：很慢很飘
const double kLyricSeekStiffness = 90;
const double kLyricSeekDamping = 15;

/// 鼠标滚轮手动翻歌词：比换行那套**更硬**、阻尼比 ≈ 1（不冲过头）。
///
/// 手感对齐歌单列表那条连续曲线（`SmoothScrollController` 是每帧吃掉剩余距离的
/// `1 − e^(−17·dt)`）—— 「滚一格就走一小段、很快停住」，而不是慢慢飘过去。
/// 时间上：ω = √(300/0.9) ≈ 18.3，四个时间常数约 0.22 秒到位。
///
/// ⚠️ 用它的时候**要带上当前速度**（`_RowSpring.aim(velocity: ...)`）：
/// 滚轮是一格一格来的，每次都从速度 0 重新起跑的话，连续滚动会一顿一顿。
const double kLyricWheelStiffness = 300;
const double kLyricWheelDamping = 33;

/// 滚轮滚动用的弹簧（= 上面那两个常数）
SpringDescription lyricWheelSpring() => const SpringDescription(
      mass: kLyricSpringMass,
      stiffness: kLyricWheelStiffness,
      damping: kLyricWheelDamping,
    );

/// 一曲终了：中速
const double kLyricEndStiffness = 140;
const double kLyricEndDamping = 22;

/// 给出「滚到某一句」该用的弹簧。
///
/// [intervalMs] 是这一句和**上一句**的时间差（毫秒）；第一句没有上一句就传 null，
/// 走慢速兜底。
/// [seeking] 表示这一次是跳转（拖了进度条、或一次跨过好几句），而不是跟着往后走一句。
SpringDescription lyricSpringFor({
  double? intervalMs,
  bool seeking = false,
  bool endOfSong = false,
}) {
  if (seeking) {
    return const SpringDescription(
      mass: kLyricSpringMass,
      stiffness: kLyricSeekStiffness,
      damping: kLyricSeekDamping,
    );
  }
  if (endOfSong) {
    return const SpringDescription(
      mass: kLyricSpringMass,
      stiffness: kLyricEndStiffness,
      damping: kLyricEndDamping,
    );
  }
  if (intervalMs == null) {
    // 没有间隔可比（第一句 / 只有一句）→ 慢速兜底
    return const SpringDescription(
      mass: kLyricSpringMass,
      stiffness: kLyricSeekStiffness,
      damping: kLyricSeekDamping,
    );
  }

  final clamped = intervalMs.clamp(kLyricIntervalMinMs, kLyricIntervalMaxMs);
  // 反转一下：间隔越短，比值越大（滚得越快）
  var ratio = 1 -
      (clamped - kLyricIntervalMinMs) /
          (kLyricIntervalMaxMs - kLyricIntervalMinMs);
  // 开五次方根：让大部分区间保持较高的刚度
  ratio = math.pow(ratio, kLyricIntervalExponent).toDouble();

  final stiffness =
      kLyricStiffnessMin + ratio * (kLyricStiffnessMax - kLyricStiffnessMin);
  return SpringDescription(
    mass: kLyricSpringMass,
    stiffness: stiffness,
    damping: math.sqrt(stiffness) * kLyricDampingMultiplier,
  );
}

/// 阻尼比 ζ = c / (2·√(k·m))。
///
/// **正常跟随的取值必须 ≥1**（过阻尼）：小于 1 会越过目标再弹回来，
/// 歌词「冲过去又弹一下」看着很廉价。这条有单测守着。
double lyricDampingRatio(SpringDescription spec) =>
    spec.damping / (2 * math.sqrt(spec.stiffness * spec.mass));

/// 错峰滚动的参数（照 AMLL）：
///
///  * 每行比上一行晚这么多启动；
///  * **当前句之后**的行，这个增量按 1/[kStaggerDecay] 递减 ——
///    于是越往下越挤，整片内容看起来是「被带着走」而不是各行等间隔地散开。
const double kStaggerStepSecs = 0.05;
const double kStaggerDecay = 1.05;

/// 首行往下最多累计多少秒（防止歌词很长时末尾几行等太久）
const double kStaggerMaxSecs = 0.5;

/// 计算出「第 [from]..[to] 行」各自该比首行晚多少秒启动。
///
/// 返回的列表和 `from..to` 一一对应，第一个永远是 0。
///
/// ⚠️ AMLL 只给**视口里**的行加延迟（`curPos + lineH >= 0` 才累加），
/// 所以这里也是从「视口里最上面那一行」开始数；屏幕外的行不需要错峰。
List<double> staggerDelays({
  required int first,
  required int last,
  required int active,
}) {
  final out = <double>[];
  var delay = 0.0;
  var step = kStaggerStepSecs;
  for (var i = first; i <= last; i++) {
    out.add(delay);
    delay += step;
    if (delay >= kStaggerMaxSecs) {
      // 到顶之后后面的都一样，不用再算
      step = 0;
      delay = kStaggerMaxSecs;
    }
    if (i >= active) step /= kStaggerDecay;
  }
  return out;
}
