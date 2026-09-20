import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 滚动物理：**禁用内置的滚轮滚动**。
///
/// 滚轮改由 [SmoothWheelScroll] 自己接管并加过渡动画；
/// 若不禁用，滚轮事件会被 Scrollable 和本组件各处理一次（滚动翻倍）。
///
/// 只覆盖 `shouldAcceptUserOffset`（滚轮路径），不影响拖动/滚动条拖拽。
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

/// 给鼠标滚轮加一点平滑过渡。
///
/// 原版浏览器里滚轮同样是「一格一跳」，这里做了超出原版的优化：
/// 每格滚轮不再瞬移，而是用 ~150ms 缓动滑过去。**不改变滚动速度**，
/// 只是把位移摊开，连续滚动时每格仍从当前位置累加，所以不会「跟不上手」。
///
/// 用法：把页面里的滚动视图包一层即可（滚动视图不要自带 `physics`，
/// 否则会覆盖这里的配置）。
class SmoothWheelScroll extends StatefulWidget {
  const SmoothWheelScroll({
    super.key,
    required this.controller,
    required this.child,
    this.duration = const Duration(milliseconds: 150),
    this.curve = Curves.easeOutCubic,
  });

  final ScrollController controller;
  final Widget child;
  final Duration duration;
  final Curve curve;

  @override
  State<SmoothWheelScroll> createState() => _SmoothWheelScrollState();
}

class _SmoothWheelScrollState extends State<SmoothWheelScroll> {
  /// 用户拖动/滚动条操作时不做动画，避免互相打架
  bool _userDragging = false;

  /// 累计目标位置。
  ///
  /// 必须**累计**，不能每次都用 `当前 pixels + delta`：
  /// 快速连续滚动时上一段动画还没走完就被取消，
  /// 那部分位移会被丢掉 —— 表现为「滚起来很费劲/滚不动」
  /// （设置页尤其明显：那里一屏内容长、滚轮事件密集）。
  double _target = 0;
  bool _targetValid = false;

  bool get _attached =>
      widget.controller.hasClients &&
      widget.controller.positions.length == 1;

  void _onScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification) {
      // 拖动（含滚动条拖拽）时标记，滚轮动画让位
      _userDragging = n.dragDetails != null;
      if (_userDragging) _targetValid = false;
    } else if (n is ScrollEndNotification) {
      _userDragging = false;
    }
  }

  void _handleWheel(PointerScrollEvent event) {
    if (_userDragging || !_attached) return;
    final pos = widget.controller.position;
    // 若外部（拖动/程序）改过位置，重置累计基准
    if (!_targetValid) {
      _target = pos.pixels;
      _targetValid = true;
    }
    _target = (_target + event.scrollDelta.dy)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (_target == pos.pixels) return;
    widget.controller.animateTo(
      _target,
      duration: widget.duration,
      curve: widget.curve,
    );
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
