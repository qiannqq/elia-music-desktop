import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/build_info.dart';
import '../icons.dart';

/// 关于页 —— 对应 `#page-about`
///
/// 说明：原版「框架」一行写的是 `Electron + electron-egg`；
/// 本次重构后该行改为 `Flutter`（事实性信息，必须同步更新）。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.scrollController});

  final ScrollController scrollController;

  static const String appVersion = '1.1.0-alpha-002';

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SingleChildScrollView(
      controller: scrollController,
      child: Center(
        child: Container(
          width: 400,
          margin: const EdgeInsets.symmetric(vertical: 40, horizontal: 32),
          padding: const EdgeInsets.fromLTRB(32, 40, 32, 40),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.borderSubtle),
            borderRadius: BorderRadius.circular(c.radiusLg),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: c.accentLight,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: AppIcon(AppIcons.music, size: 48, color: c.accent, strokeWidth: 1.5),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '伊莉雅音乐播放器',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c.text),
              ),
              const SizedBox(height: 4),
              Text(
                'v$appVersion',
                style: TextStyle(fontSize: 13, color: c.textTertiary),
              ),
              const SizedBox(height: 16),
              Text(
                '一款基于 Flutter 构建的桌面端音乐播放器，支持搜索、试听、歌单导入与批量下载。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: c.textSecondary, height: 1.6),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.only(top: 16),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.borderSubtle)),
                ),
                child: Column(
                  children: [
                    const _InfoRow('框架', 'Flutter'),
                    const _InfoRow('版本', appVersion),
                    const _InfoRow('作者', 'sena-senki(千奈千祁)'),
                    // 构建产物得能说清自己是从哪个提交编出来的 ——
                    // 鼠标停上去能看到那一条提交的标题
                    const _InfoRow(
                      '构建提交',
                      kBuildCommit,
                      tooltip: kBuildCommitTitle,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.tooltip});

  final String label;
  final String value;

  /// 悬浮时显示的补充说明。提交号上放的是那一条提交的标题。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget valueWidget = Text(
      value,
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.text),
    );
    final tip = tooltip;
    if (tip != null && tip.isNotEmpty) {
      valueWidget = Tooltip(message: tip, child: valueWidget);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: c.textTertiary)),
          valueWidget,
        ],
      ),
    );
  }
}
