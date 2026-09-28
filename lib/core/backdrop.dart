import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// 「封面 / 图片当背景」这套东西的**纯逻辑**：运动公式、照片滤镜、底图糊法。
///
/// 原来这些都长在 `lib/ui/now_playing.dart` 里。外观设置里的「整体背景」
/// 要跟播放页**一模一样**（同一套旋转、同一套律动、同一套糊法），
/// 所以搬到这里来给两处共用 —— 各留一份迟早会漂。
///
/// 这一层不依赖任何页面：只有纯函数、常量和一次性的图片处理。

// ---------------------------------------------------------------- 常量

/// 背景底图相对**窗口对角线**的放大倍数。
///
/// 绕屏幕中心转，图的内切圆半径（边长/2）只要盖得住窗口的外接圆（对角线/2）就行
/// → **1.0 倍就是下限**，这里留 6% 余量。
///
/// ⚠️ **别把它放大**：这个值直接决定「背景能采到封面的多少」——
/// 放到 2.8 倍时只看得见封面中心那一小块（宽 30%、高 30%），封面上半部的颜色
/// 根本进不了画面。实测同一张 Lover 封面：2.8 倍出来是没有人味的灰蓝
/// （R−G 只有 +17），1.06 倍能采到宽 81%、高 53%，R−G 到 +43（明显的粉，
/// iPad 上是 +34）。
/// 注意这条是从**封面**上量出来的：把底图放大，等于只取封面中心那一块。
const double kBackdropScale = 1.06;

/// 判断底图要不要重新糊时用的基准边长 —— 糊完只剩大块色域，256 足够。
const int kBackdropPx = 256;

/// 背景取封面时用哪一档（QQ 音乐只支持 150/300/500/800/1200/1500）。
///
/// 播放页的大封面、背景、以及封面预热都用这一档 —— **同一档 = 同一个 URL =
/// 一份下载与解码缓存**，错开就会各下一张。
const int kBackdropCoverPx = 1200;

/// 模糊半径（作用在 256 的小图上）。
///
/// 屏幕上看到的模糊 ≈ `sigma × (显示尺寸 / 256)` —— 18 × 5.5 ≈ **100px**，
/// 糊到这个程度就只剩大块色域、看不出照片结构了。
const double kBackdropSigma = 18;

// ---------------------------------------------------------------- 运动

/// 把低频能量（0~1 的字节值）映射成「律动强度」：−25dB 起算、−5dB 满。
double bgVolume(double level) => ((level - 0.5) / 0.4).clamp(0.0, 1.0);

/// 转角（弧度）：0.2 rad/s 的匀速慢转（约 31 秒一圈）+ 低频推角。
///
/// [spin] 是设置里的「旋转速度」倍数，**只乘在匀速那一项上** ——
/// 低频推角与缩放幅度归 [amount]（「律动幅度」）管，两个选项互不干扰；
/// 幅度调 0 依旧是「完全静止」。
double bgAngle(double seconds, double bass, double amount, {double spin = 1}) =>
    0.2 * amount * spin * seconds + 0.2 * amount * bass;

/// 低频驱动的缩放倍数（最多向内放大 25%；`amount` 再放大这个幅度）。
double bgZoom(double bass, double amount) =>
    1.0 / (1.0 - (0.2 * bass * amount).clamp(0.0, 0.6));

// ---------------------------------------------------------------- 颜色

/// 背景底图的「照片滤镜」—— 照 AMLL 的配方：
/// **对比度 0.4 → 饱和度 3.0 → 对比度 1.7**（三步都是仿射变换，合成成一个矩阵）。
///
/// 为什么要这么狠地提饱和：底图要糊成一大片色域，而模糊本身会把颜色摊平；
/// 不补回来的话整页就是灰的 —— 实测我们的背景 RGB 119/123/131（几乎没有色相），
/// 而 Apple Music 同一张封面是 197/163/156（明显的粉）。
///
/// 合成公式：对比度 `y = c·x + 128(1−c)`、饱和度按 Rec.709 亮度权重混灰，
/// 所以最终 = `c1·c2·sat(x) + 128·(c2(1−c1) + (1−c2))`。
/// 中间那两步**不 clamp**（和 AMLL 一样在浮点里算完才落盘），否则合并不了。
List<double> bgPhotoFilter({
  double contrast1 = 0.4,
  double saturate = 3.0,
  double contrast2 = 1.7,
}) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final m = 1 - saturate;
  final k = contrast1 * contrast2;
  final off = 128 * (contrast2 * (1 - contrast1) + (1 - contrast2));
  return <double>[
    (lr * m + saturate) * k, lg * m * k, lb * m * k, 0, off, //
    lr * m * k, (lg * m + saturate) * k, lb * m * k, 0, off, //
    lr * m * k, lg * m * k, (lb * m + saturate) * k, 0, off, //
    0, 0, 0, 1, 0,
  ];
}

// ---------------------------------------------------------------- 糊底图

/// 把一张图**一次性**糊成可以当背景贴的 `ui.Image`。
///
/// 为什么要糊成一张普通图片、而不是在组件树里挂 `ImageFiltered`：
/// 后者产生的是 `ImageFilterLayer`，缓存跟变换矩阵绑在一起 ——
/// 背景一旦在动（旋转/缩放）就**每帧重新糊一遍**（掉帧），
/// 而且和内容错位（背景比内容慢半拍）。糊一次之后每帧只是贴图 + 改变换，
/// 零滤镜开销、也不会错位。
///
/// [provider] 已经带着目标分辨率（调用方用 `ResizeImage` 包好）。
/// [photoFilter] 为真时套 [bgPhotoFilter]（封面/照片背景都该套；
/// 用户自己挑的壁纸也套 —— 这样两处观感一致）。
Future<ui.Image?> blurBackdrop(
  ImageProvider provider, {
  double sigma = kBackdropSigma,
  bool photoFilter = true,
}) async {
  final stream = provider.resolve(ImageConfiguration.empty);
  final done = Completer<ui.Image>();
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!done.isCompleted) done.complete(info.image);
      stream.removeListener(listener);
    },
    onError: (e, _) {
      if (!done.isCompleted) done.completeError(e);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  final src = await done.future;

  final recorder = ui.PictureRecorder();
  final paint = Paint();
  if (sigma > 0.01) {
    paint.imageFilter = ui.ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
      // 不给 clamp 的话四周会糊出一圈透明边
      tileMode: ui.TileMode.clamp,
    );
  }
  if (photoFilter) paint.colorFilter = ColorFilter.matrix(bgPhotoFilter());
  Canvas(recorder).drawImage(src, Offset.zero, paint);
  final picture = recorder.endRecording();
  final out = await picture.toImage(src.width, src.height);
  picture.dispose();
  // 源图是 ResizeImage 解出来的，ImageCache 还留着它，别在这里 dispose。
  return out;
}

/// 把某张图按「宽度固定、高度按比例」的方式解码 —— 背景要的是**比例正确**，
/// 不能像封面那样硬压成正方形（一张 16:9 的壁纸压成正方形就废了）。
ImageProvider backdropProvider(ImageProvider raw, {int width = kBackdropPx}) =>
    ResizeImage(raw, width: width);
