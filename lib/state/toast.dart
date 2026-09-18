import 'dart:async';

import 'package:flutter/foundation.dart';

enum ToastType { info, success, error, progress }

class ToastItem {
  final String id;
  final String message;
  ToastType type;
  bool leaving = false;

  ToastItem({required this.id, required this.message, required this.type});
}

/// Toast 管理 —— 对应原 `showToast` / `updateToast` / `dismissToast`。
class ToastCenter extends ChangeNotifier {
  ToastCenter._();

  static final ToastCenter instance = ToastCenter._();

  final List<ToastItem> items = [];
  int _counter = 0;
  final Map<String, Timer> _timers = {};

  /// 返回 toast id；`duration <= 0` 表示不自动消失
  String show(String message, {ToastType type = ToastType.info, int duration = 3000}) {
    final id = 'toast-${++_counter}';
    items.add(ToastItem(id: id, message: message, type: type));
    notifyListeners();
    if (duration > 0) {
      _timers[id] = Timer(Duration(milliseconds: duration), () => dismiss(id));
    }
    return id;
  }

  void update(String id, String message, {ToastType? type}) {
    final idx = items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    items[idx].type = type ?? items[idx].type;
    items[idx] = ToastItem(id: id, message: message, type: type ?? items[idx].type);
    notifyListeners();
  }

  void dismiss(String id) {
    _timers.remove(id)?.cancel();
    final idx = items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    items[idx].leaving = true;
    notifyListeners();
    Timer(const Duration(milliseconds: 200), () {
      items.removeWhere((e) => e.id == id);
      notifyListeners();
    });
  }

  void clear() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    items.clear();
    notifyListeners();
  }
}

final toast = ToastCenter.instance;
