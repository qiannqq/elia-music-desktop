import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 平滑滚动控制器 —— 滚轮与键盘翻页**共用**的一条连续动画。
///
/// 关键点：**不要用 `animateTo` 逐次做动画**。
/// `animateTo` 每次调用都会新建一个动画、速度从 0 重新开始；
/// 滚轮一格接一格、按键 30 次/秒时，就变成「加速→减速→加速→减速」，
/// 看起来一顿一顿 —— 这是滚动手感不如浏览器（原版 Electron）的直接原因。
///
/// 浏览器那套顺滑靠的是**一条连续曲线**：输入事件只负责**累加目标值**，
/// 动画由一个持续运行的 ticker 把当前位置推向目标，速度连续、从不重置。
/// 这里就是照这个模型做的：指数逼近（每帧吃掉剩余距离的固定比例），
/// 所以事件来得越密，只是目标越远，曲线本身不被打断。
class SmoothScrollController extends ScrollController {
  SmoothScrollController({required TickerProvider vsync, super.initialScrollOffset}) {
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;

  /// 累计目标位置（与当前位置的距离由 ticker 逐帧收敛）
  double _target = 0;
  bool _targetValid = false;
  Duration _lastTick = Duration.zero;

  /// 收敛速度：每秒吃掉剩余距离的比例。越大越跟手、越小越"飘"。
  static const double _rate = 17;

  /// 剩余距离小于这个值就吸附到位并停表（避免无限逼近）
  static const double _settle = 0.6;

  /// 把位移**累加**到目标上并启动连续动画
  void scrollBy(double delta) {
    if (!hasClients) return;
    final pos = position;
    if (!_targetValid) {
      _target = pos.pixels;
      _targetValid = true;
    }
    _target = (_target + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _startIfNeeded();
  }

  /// 滚到某个绝对位置（同样走连续动画）
  void scrollTo(double value) {
    if (!hasClients) return;
    final pos = position;
    _target = value.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _targetValid = true;
    _startIfNeeded();
  }

  /// 外部（拖动、程序跳转、切换页面恢复位置）改过位置后调用：
  /// 不清掉基准的话，下一次滚动会从**过期的目标**开始，出现一下跳变。
  void invalidateTarget() {
    _targetValid = false;
    _ticker.stop();
  }

  void _startIfNeeded() {
    if (_ticker.isActive) return;
    _lastTick = Duration.zero;
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    if (!hasClients) {
      _ticker.stop();
      return;
    }
    // 用真实帧间隔推进（首帧没有上一帧，按 60fps 估）
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.001, 0.05);
    _lastTick = elapsed;

    final pos = position;
    final diff = _target - pos.pixels;
    if (diff.abs() < _settle) {
      jumpTo(_target.clamp(pos.minScrollExtent, pos.maxScrollExtent));
      _targetValid = false;
      _ticker.stop();
      return;
    }
    // 指数逼近：速度连续，不会像 animateTo 那样每次回到 0
    final step = diff * (1 - math.exp(-_rate * dt));
    jumpTo((pos.pixels + step).clamp(pos.minScrollExtent, pos.maxScrollExtent));
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// 滚动物理：**禁用内置的滚轮滚动**。
///
/// 滚轮改由 [SmoothScrollController] 自己接管；
/// 若不禁用，滚轮事件会被 Scrollable 和控制器各处理一次（滚动翻倍）。
///
/// ⚠️ 这个开关**连键盘滚动一起禁掉了** —— 框架的 `ScrollAction` 也用
/// `shouldAcceptUserOffset` 判断「用户能不能滚」，所以 PgUp/PgDn、方向键、
/// 空格需要在外面显式补回来（见 `AppShell._onRootKey`）。
///
/// 只覆盖滚轮路径，不影响拖动/滚动条拖拽。
class _SmoothWheelPhysics extends ClampingScrollPhysics {
  const _SmoothWheelPhysics({super.parent});

  @override
  _SmoothWheelPhysics applyTo(ScrollPhysics? ancestor) =>
      _SmoothWheelPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => false;
}

class _SmoothScrollBehavior extends ScrollBehavior {
  const _SmoothScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const _SmoothWheelPhysics();
}

/// 给鼠标滚轮接上 [SmoothScrollController]。
///
/// 用法：把页面里的滚动视图包一层即可（滚动视图不要自带 `physics`，
/// 否则会覆盖这里的配置）。
class SmoothWheelScroll extends StatefulWidget {
  const SmoothWheelScroll({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  State<SmoothWheelScroll> createState() => _SmoothWheelScrollState();
}

class _SmoothWheelScrollState extends State<SmoothWheelScroll> {
  /// 用户拖动/滚动条操作时不做动画，避免互相打架
  bool _userDragging = false;

  bool get _attached =>
      widget.controller.hasClients && widget.controller.positions.length == 1;

  void _onScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification) {
      _userDragging = n.dragDetails != null;
      if (_userDragging) _controller?.invalidateTarget();
    } else if (n is ScrollEndNotification) {
      _userDragging = false;
    }
  }

  SmoothScrollController? get _controller {
    final c = widget.controller;
    return c is SmoothScrollController ? c : null;
  }

  void _handleWheel(PointerScrollEvent event) {
    if (_userDragging || !_attached) return;
    final c = _controller;
    if (c != null) {
      // 累加目标，动画由控制器那条连续曲线负责
      c.scrollBy(event.scrollDelta.dy);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: const _SmoothScrollBehavior(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          _onScrollNotification(n);
          return false; // 不拦截，正常向上传递
        },
        child: Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) _handleWheel(event);
          },
          child: widget.child,
        ),
      ),
    );
  }
}
