import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../services/app_background.dart';
import '../../services/player_controller.dart';
import '../../state/app_state.dart';
import 'song_backdrop.dart';

/// 整窗背景层 —— 贴在 shell 的**最底下**，标题栏 / 侧边栏 / 内容区 / 播放栏
/// 全都盖在它上面（那几处本来就是透明或半透明的，见 `AppColors` 的说明）。
///
/// 两种模式共用一套壳：
///  * [AppBgMode.image]：用户挑的图 → 糊一次（[AppBackground.texture]）→ 贴图 + 压暗。
///    **不旋转、不律动** —— 那是给封面准备的；自己的壁纸跟着鼓点晃没有道理。
///  * [AppBgMode.cover]：当前歌曲封面，直接交给 [SongBackdrop]
///    （和现在播放页**同一个组件**：一样的糊法、一样的旋转与律动、
///    一样的 B站视频背景），参数也还是那两个（`bgPulse` / `bgSpin`）。
class AppBackdropLayer extends StatefulWidget {
  const AppBackdropLayer({super.key});

  @override
  State<AppBackdropLayer> createState() => _AppBackdropLayerState();
}

class _AppBackdropLayerState extends State<AppBackdropLayer> {
  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    appBackground.addListener(_onChanged);
    // 封面模式要跟着换歌走
    player.addListener(_onChanged);
  }

  @override
  void dispose() {
    appBackground.removeListener(_onChanged);
    player.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = appBackground;
    switch (bg.mode) {
      case AppBgMode.none:
        return const SizedBox.shrink();

      case AppBgMode.image:
        final img = bg.texture;
        // 图还没糊好 / 文件已经不在 → 什么都不画，露出主题底色（不闪、不报错）
        if (img == null) return const SizedBox.shrink();
        // ⚠️ 必须自己关一层 `RepaintBoundary`：这是一张**原分辨率**的贴图
        // （上限 4096 宽），跟内容合在同一层里的话，上面任何一个每帧重画的小东西
        // （进度条、歌词）都会把这张全窗贴图带着重画一遍。
        // 关起来之后它只在自身内容变化时重新栅格化，平时就是一次图层合成。
        return RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              RawImage(
                image: img,
                fit: BoxFit.cover,
                // 放大用 low 就够；缩小时也用 low —— 代价是轻微锯齿，
                // 换来的是每帧一次廉价的采样
                filterQuality: FilterQuality.low,
              ),
              // 明暗 = 叠一层**主题底色**（不是黑）：浅色主题下是加白、深色下是压暗，
              // 两个方向都自动对。用纯黑的话浅色主题里这张图只会越来越黑，
              // 白天用浅色主题时不好使。
              ColoredBox(color: context.c.bg.withValues(alpha: bg.dim)),
            ],
          ),
        );

      case AppBgMode.cover:
        final song = player.currentSong;
        if (song == null || song.coverPic.isEmpty) {
          return const SizedBox.shrink();
        }
        // ⚠️ 律动幅度 / 旋转速度是设置里的**活值**：单独听 AppState 重建这一小块
        // （跟现在播放页里那个 AnimatedBuilder 是同一个理由与同一个做法）。
        return AnimatedBuilder(
          animation: app,
          builder: (_, _) => SongBackdrop(
            pic: song.coverPic,
            mid: song.mid,
            amount: app.bgPulse,
            spin: app.bgSpin,
          ),
        );
    }
  }
}
