import 'package:flutter/animation.dart';

/// Fluent 2 的动效常量 —— 时长与曲线。
///
/// 为什么要单独立一份、而不是到处写 `Duration(milliseconds: 150)`：
/// Win11 的手感**一半来自曲线**。同一个 150ms，用 `easeOut` 和用官方的
/// `decelerate`（`cubic-bezier(0,0,0,1)`）观感完全不同 —— 后者起步极快、
/// 尾巴拖得长，就是那种「跟手但收得住」的 Windows 味。
///
/// 只放**已经在用**的那几档。Fluent 的时长表是 ultraFast(50) ~ ultraSlow(500)
/// 八档，这里没有全抄：没被用到的常量就是噪音，需要时再补。
abstract final class Motion {
  /// 300ms —— 通知退场（进得快、退得从容）
  static const Duration slow = Duration(milliseconds: 300);

  /// 250ms —— WinUI 的 `ControlNormalAnimationDuration`：对话框出现、面板开合
  static const Duration controlNormal = Duration(milliseconds: 250);

  /// 167ms —— WinUI 的 `ControlFastAnimationDuration`：控件状态切换
  static const Duration controlFast = Duration(milliseconds: 167);

  /// 83ms —— WinUI 的 `ControlFasterAnimationDuration`：悬停底色这类
  static const Duration controlFaster = Duration(milliseconds: 83);

  /// 进入：起步快、末端极缓（Fluent 的 `curveDecelerateMid`）
  static const Curve decelerate = Cubic(0, 0, 0, 1);

  /// 退出：起步慢、突然加速走掉（Fluent 的 `curveAccelerateMid`）
  static const Curve accelerate = Cubic(1, 0, 1, 1);

  /// 两端都平缓（Fluent 的 `curveEasyEase`）—— 位置/颜色的连续变化用它
  static const Curve easyEase = Cubic(0.33, 0, 0.67, 1);
}
