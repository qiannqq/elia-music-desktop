import 'dart:async';

import 'package:flutter/scheduler.dart';

import 'file_logger.dart';

/// 帧耗时探针是否启用。
///
/// 默认关闭。要测性能时用构建参数打开，不必改代码：
/// ```
/// elia_flutter build windows --release --dart-define=ELIA_PERF=true
/// ```
/// 关着的时候 [PerfProbe.start] 直接返回，运行期没有任何额外开销。
const bool kPerfEnabled = bool.fromEnvironment('ELIA_PERF');

/// 帧耗时探针 —— 每 [windowSeconds] 秒往日志里写一行汇总。
///
/// 为什么要它：卡顿只靠肉眼看是没法比、也没法复现的。
/// 把 `build` / `raster` 的 p50、p95 和「超预算的帧数」记下来，
/// 优化前后才有可比的数字。
///
/// 两个时长分别对应两条线程：
///  * `build`  = UI 线程（布局、构建、绘制指令），
///  * `raster` = 光栅线程。
/// 60fps 的预算是 16.7ms，任一项超了，这一帧就是掉了。
class PerfProbe {
  PerfProbe._();

  static const int windowSeconds = 5;

  static final List<int> _build = [];
  static final List<int> _raster = [];
  static int _frames = 0;
  static int _janky = 0;
  static Timer? _timer;
  static String _label = '默认';

  /// 给接下来这段起个名字，汇总时会带上 —— 否则一堆数字不知道对应哪个操作。
  static void mark(String label) => _label = label;

  static void start() {
    if (!kPerfEnabled) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(
      const Duration(seconds: windowSeconds),
      (_) => _flush(),
    );
    fileLogger.info('Perf', '探针已启动，每 ${windowSeconds}s 汇总一次');
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final b = t.buildDuration.inMicroseconds;
      final r = t.rasterDuration.inMicroseconds;
      _build.add(b);
      _raster.add(r);
      _frames++;
      if (b > 16700 || r > 16700) _janky++;

      // 超过 40ms 的单帧单独记一条。
      // 汇总里的 max 只是个数字，看不出它发生在**什么时候** ——
      // 而「切页卡一下」这类问题，缺的恰恰是这个时间点。
      if (b > 40000 || r > 40000) {
        fileLogger.info(
          'Perf',
          '卡顿帧 build=${(b / 1000).toStringAsFixed(1)}ms '
          'raster=${(r / 1000).toStringAsFixed(1)}ms 标签=[$_label]',
        );
      }
    }
  }

  static void _flush() {
    if (_frames == 0) return;
    final build = List<int>.from(_build)..sort();
    final raster = List<int>.from(_raster)..sort();
    final fps = _frames / windowSeconds;

    fileLogger.info(
      'Perf',
      '[$_label] 帧=$_frames (${fps.toStringAsFixed(1)}fps) 掉帧=$_janky '
      'build p50=${_ms(build, 0.50)} p95=${_ms(build, 0.95)} max=${_ms(build, 1.0)} '
      'raster p50=${_ms(raster, 0.50)} p95=${_ms(raster, 0.95)} max=${_ms(raster, 1.0)}',
    );

    _build.clear();
    _raster.clear();
    _frames = 0;
    _janky = 0;
  }

  static String _ms(List<int> sorted, double p) {
    if (sorted.isEmpty) return '-';
    final i = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
    return (sorted[i] / 1000).toStringAsFixed(1);
  }
}
