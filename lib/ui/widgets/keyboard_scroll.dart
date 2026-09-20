import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 键盘滚动的**按键映射**与**焦点判定**。
///
/// 这两件事单独抽出来是为了能直接单测：滚动动作本身要跑整个 shell 才成立，
/// 但「哪个键对应哪种滚动」「此刻到底该不该滚动」都是纯逻辑。
///
/// 背景：`smooth_scroll.dart` 为了让滚轮不被 Scrollable 处理两次，把 physics
/// 的 `shouldAcceptUserOffset` 关掉了，而框架的 `ScrollAction` 用同一个判断
/// 来挡键盘滚动 —— 于是键盘必须由我们自己接。接的位置在根 `Focus` 的
/// `onKeyEvent` 上。

/// 一次键盘滚动请求的类型。具体滚多少由调用方决定（要视口高度）。
enum KeyScrollIntent {
  pageUp,
  pageDown,
  lineUp,
  lineDown,
  top,
  bottom,
}

/// 把按键映射成滚动意图；不是滚动键就返回 null。
KeyScrollIntent? scrollIntentFor(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.pageDown) return KeyScrollIntent.pageDown;
  if (key == LogicalKeyboardKey.pageUp) return KeyScrollIntent.pageUp;
  // 空格等同翻页，这是浏览器的习惯
  if (key == LogicalKeyboardKey.space) return KeyScrollIntent.pageDown;
  if (key == LogicalKeyboardKey.arrowDown) return KeyScrollIntent.lineDown;
  if (key == LogicalKeyboardKey.arrowUp) return KeyScrollIntent.lineUp;
  if (key == LogicalKeyboardKey.home) return KeyScrollIntent.top;
  if (key == LogicalKeyboardKey.end) return KeyScrollIntent.bottom;
  return null;
}

/// 当前键盘焦点是否落在文本输入控件里。
///
/// 有焦点在输入框时**一个滚动键都不能吃**：空格是输入内容，方向键是移光标，
/// PgUp/PgDn/Home/End 是文本翻页与跳行 —— 全归文本编辑器。
///
/// 必须显式判断，不能指望「输入框会先把键吃掉」：挂 `onKeyEvent` 的节点在
/// 冒泡链上比 `DefaultTextEditingShortcuts` 更靠近焦点，所以滚动处理**先于**
/// 文本编辑拿到按键 —— 不在这里放行，输入框里的空格和方向键就全被抢走了。
bool isTextFieldFocused() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  // 焦点节点可能就挂在 EditableText 上，也可能是它内部某个 Focus
  return ctx.widget is EditableText ||
      ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}
