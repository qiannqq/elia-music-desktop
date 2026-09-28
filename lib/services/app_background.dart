import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../core/app_paths.dart';
import '../core/backdrop.dart';
import '../core/file_logger.dart';
import '../core/local_store.dart';

/// 整体背景的三种模式（设置 → 外观 → 整体背景）。
enum AppBgMode {
  /// 关：界面用不透明的主题底色（默认，也是唯一零开销的一档）
  none,

  /// 用户自己挑的一张图
  image,

  /// 当前播放歌曲的封面（走播放页那套：糊一次 + 旋转 + 跟着鼓点缩放）
  cover,
}

/// 「整体背景」的状态 —— 一张铺满整窗的背景，标题栏/侧栏/播放栏都盖在它上面。
///
/// 放在 service 里而不是 `AppState`：它跟播放状态无关，只有界面在用它；
/// 而且**糊好的底图要跟着它走**（路径一变就得重糊一次）。
/// 现在播放页那套背景是「进页面才建」，这个是常驻的，所以状态必须长期活着。
class AppBackground extends ChangeNotifier {
  AppBackground._();

  static final AppBackground instance = AppBackground._();

  static const String _kMode = 'app_bg_mode';
  static const String _kImage = 'app_bg_image';
  static const String _kImageLabel = 'app_bg_image_label';
  static const String _kDim = 'app_bg_dim';
  static const String _kBlur = 'app_bg_blur';

  /// 明暗的默认值 —— 这是「背景有多接近主题底色」：
  /// 叠的是 `AppColors.bg`（不是黑），所以浅色主题下是**加白**、深色主题下是压暗，
  /// 两个方向都自动对（Spotube 也是这么做的）。0.35 是几个播放器的共识区间
  /// （调研见 `temp/win11-ui/bg-ui-refs.md`：Strawberry 40%、Spotube 50%）。
  static const double kDefaultDim = 0.35;

  AppBgMode mode = AppBgMode.none;

  /// 自定义背景图的**缓存位**（`dataDir/background/` 里的文件名）。
  ///
  /// 用户挑的那张图会被**拷一份**进来 —— 原图被删/被移走之后背景还在。
  /// 只留一份：换图就把上一份删掉，不会在数据目录里越攒越多。
  /// 存的是**文件名**不是绝对路径：便携目录整个搬走之后照样找得到。
  String imageName = '';

  /// 给界面看的**原文件名**（缓存文件名带时间戳，不适合展示）
  String imageLabel = '';

  /// 明暗（0 = 图原样，越大越接近主题底色）。做成一层的叠加而不是烤进模糊里 ——
  /// 拖动的时候可以立刻看到变化。
  double dim = kDefaultDim;

  /// 模糊程度（0 = 完全不糊，保留原图分辨率）。这个**必须重糊**，所以带防抖。
  double blurSigma = kDefaultBlur;

  /// 模糊的默认值：**0** —— 自定义背景默认是**清晰的原图**。
  /// （用户挑一张壁纸当背景，第一眼看到的应该是他自己那张图，而不是一团色块。）
  static const double kDefaultBlur = 0;

  /// 模糊滑块的量程上限（同时也是「糊」那一路的 sigma 上限）。
  static const double kMaxBlur = 100;

  /// 清晰那一路的解码宽度上限。
  ///
  /// 「保留完整分辨率」是说别像封面背景那样缩到 256，**不是**说一张 8K 壁纸也要
  /// 原样解出来（7680×4320×4 ≈ 133MB，弱显卡直接失败）。4096 已经覆盖任何
  /// 会用到的显示器宽度，再大也不会看出差别。
  static const int kMaxImagePx = 4096;

  /// 要模糊时用的解码宽度。
  ///
  /// 糊到这个程度之后细节早没了，按原分辨率去算一次上百像素的模糊纯属白烧 ——
  /// 缩小再糊、再放大，肉眼与全分辨率糊完全一致（封面背景那套也是这个道理）。
  static const int kBlurBasePx = 1280;

  /// 自定义图糊好的底图（只有 [AppBgMode.image] 用它）。
  ui.Image? texture;

  bool _loading = false;
  Timer? _debounce;

  /// 有没有背景（界面据此决定要不要走「半透明合成」那条路）
  bool get active => mode != AppBgMode.none;

  void init() {
    mode = switch (LocalStore.get(_kMode)) {
      'image' => AppBgMode.image,
      'cover' => AppBgMode.cover,
      _ => AppBgMode.none,
    };
    imageName = LocalStore.get(_kImage) ?? '';
    imageLabel = LocalStore.get(_kImageLabel) ?? '';
    dim = double.tryParse(LocalStore.get(_kDim) ?? '')?.clamp(0.0, 0.85) ?? kDefaultDim;
    blurSigma = double.tryParse(LocalStore.get(_kBlur) ?? '')?.clamp(0.0, kMaxBlur) ??
        kDefaultBlur;
    if (mode == AppBgMode.image && imageName.isNotEmpty) {
      unawaited(_loadTexture());
    }
  }

  void setMode(AppBgMode m) {
    if (mode == m) return;
    mode = m;
    LocalStore.set(_kMode, m.name);
    _disposeTexture();
    if (m == AppBgMode.image && imageName.isNotEmpty) {
      unawaited(_loadTexture());
    }
    notifyListeners();
  }

  /// 用户在对话框里挑了一张图：**拷一份进缓存位**（只留这一份），再重新糊。
  ///
  /// ⚠️ 缓存文件必须**每次换一个名字**（这里用时间戳）：`FileImage` 是拿
  /// 「路径」当缓存键的，同名覆盖的话 `ImageCache` 会把**上一张解码结果**直接还回来
  /// —— 表现就是「选第二次没反应，重启才生效」（重启后缓存空了才重新读盘）。
  Future<void> setImage(String sourcePath) async {
    if (sourcePath.isEmpty) return;
    try {
      final src = File(sourcePath);
      if (!await src.exists()) return;
      final dir = Directory(_cacheDir);
      await dir.create(recursive: true);
      final ext = _extensionOf(sourcePath);
      final name = 'bg_${DateTime.now().millisecondsSinceEpoch}$ext';
      final target = '$_cacheDir${Platform.pathSeparator}$name';
      await src.copy(target);
      // 拷好了再清旧的那一份：万一拷贝失败，缓存位里还留着一张能用的图
      final old = imageName;
      imageName = name;
      imageLabel = _baseNameOf(sourcePath);
      LocalStore.set(_kImage, name);
      LocalStore.set(_kImageLabel, imageLabel);
      if (old.isNotEmpty && old != name) {
        try {
          await File('$_cacheDir${Platform.pathSeparator}$old').delete();
        } catch (_) {}
      }
      _disposeTexture();
      notifyListeners();
      if (mode == AppBgMode.image) unawaited(_loadTexture());
    } catch (e) {
      fileLogger.warn('AppBg', '背景图拷贝失败：$e');
    }
  }

  static String _baseNameOf(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  static String _extensionOf(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0 || i == path.length - 1) return '.img';
    final ext = path.substring(i);
    // 文件名后面要拼进本地路径，只接受「点 + 几个字」这种形态
    return RegExp(r'^\.[A-Za-z0-9]{1,5}$').hasMatch(ext) ? ext.toLowerCase() : '.img';
  }

  /// 缓存目录（数据目录下的 `background/`）
  String get _cacheDir =>
      '${AppPaths.dataDir}${Platform.pathSeparator}background';

  /// 缓存位里那张图（没有就是 null）
  File? get cacheFile {
    if (imageName.isEmpty) return null;
    final f = File('$_cacheDir${Platform.pathSeparator}$imageName');
    return f.existsSync() ? f : null;
  }

  void setDim(double value) {
    final v = value.clamp(0.0, 0.85);
    if (v == dim) return;
    dim = v;
    LocalStore.set(_kDim, v.toStringAsFixed(2));
    notifyListeners();
  }

  void setBlur(double value) {
    final v = value.clamp(0.0, kMaxBlur);
    if (v == blurSigma) return;
    blurSigma = v;
    LocalStore.set(_kBlur, v.toStringAsFixed(1));
    // 模糊是**烤进底图**的，改一次要重糊一次 —— 拖滑块时防抖，
    // 别每一格都排一次 256px 的模糊。
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (mode == AppBgMode.image && mounted) unawaited(_loadTexture());
    });
    notifyListeners();
  }

  /// 可重入的「有没有被 dispose」判断 —— 单例其实不会 dispose，
  /// 但给定时器回调留一道保险，免得以后谁改成可销毁的时候踩空。
  bool mounted = true;

  /// 底图还没糊好（用来在界面上显示一个小提示）
  bool get loading => _loading;

  Future<void> _loadTexture() async {
    if (_loading) return;
    final file = cacheFile;
    if (file == null) return;
    _loading = true;
    notifyListeners();
    try {
      // 两条路：
      //  * 不糊（默认）→ 按原分辨率解（上限 [kMaxImagePx]），**不套照片滤镜**
      //    （那套对比度/饱和度是为封面调的，会把用户自己的图搞变色）；
      //  * 要糊 → 先用小图算（[kBlurBasePx]），省掉一次上百像素的全尺寸模糊。
      final sharp = blurSigma < 0.5;
      final blurred = await blurBackdrop(
        backdropProvider(
          FileImage(file),
          width: sharp ? kMaxImagePx : kBlurBasePx,
        ),
        sigma: sharp ? 0 : blurSigma,
        photoFilter: false,
      );
      if (blurred == null) return;
      _disposeTexture();
      texture = blurred;
    } catch (e) {
      fileLogger.warn('AppBg', '背景图处理失败：$e');
      _disposeTexture();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void _disposeTexture() {
    final old = texture;
    texture = null;
    if (old != null) {
      // 晚一拍再释放：这一帧的绘制记录可能还引用着它
      Future<void>.delayed(const Duration(seconds: 1), old.dispose);
    }
  }
}

/// 全局单例
final appBackground = AppBackground.instance;
