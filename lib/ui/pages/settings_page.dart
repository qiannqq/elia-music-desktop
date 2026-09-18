import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../services/api_client.dart';
import '../../state/app_state.dart';
import '../../state/theme_controller.dart';
import '../../state/toast.dart';
import '../icons.dart';
import '../widgets/common.dart';
import '../widgets/dialogs.dart';

/// 设置页 —— 对应 `#page-settings`
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state, required this.scrollController});

  final AppState state;
  final ScrollController scrollController;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _qqCookie = TextEditingController();
  final TextEditingController _neteaseCookie = TextEditingController();
  final TextEditingController _savePath = TextEditingController();

  bool _showQqCookie = false;
  bool _showNeteaseCookie = false;
  bool _qqVerifying = false;
  bool _neVerifying = false;
  bool _synced = false;

  @override
  void dispose() {
    _qqCookie.dispose();
    _neteaseCookie.dispose();
    _savePath.dispose();
    super.dispose();
  }

  void _syncFromState() {
    if (!_synced) {
      _synced = true;
      _qqCookie.text = widget.state.qqCookie;
      _neteaseCookie.text = widget.state.neteaseCookie;
    }
    final path = widget.state.savePath;
    if (_savePath.text != path) _savePath.text = path;
  }

  @override
  Widget build(BuildContext context) {
    _syncFromState();
    final c = context.c;
    final state = widget.state;

    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Text(
              '设置',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c.text),
            ),
          ),

          // ---------------- QQ 音乐 Cookie ----------------
          _Section(
            title: 'QQ音乐 Cookie',
            desc: '设置 QQ音乐 Cookie 以获取高品质资源。在浏览器中登录 y.qq.com，按 F12 打开开发者工具，'
                '在 Application > Cookies 中复制 Cookie 字符串。',
            children: [
              _FieldLabel('Cookie 状态', c),
              _CookieStatus(
                hasCookie: state.qqCookie.isNotEmpty,
                status: state.qqCookieStatus,
              ),
              const SizedBox(height: 16),
              _FieldLabel('Cookie 字符串', c),
              AppTextField(
                controller: _qqCookie,
                hint: '粘贴 QQ音乐 Cookie 字符串...',
                obscure: !_showQqCookie,
                mono: true,
                trailing: AppIconButton(
                  icon: _showQqCookie ? AppIcons.eyeClosed : AppIcons.eyeOpen,
                  size: 28,
                  iconSize: 16,
                  tooltip: '显示/隐藏',
                  onTap: () => setState(() => _showQqCookie = !_showQqCookie),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  AppButton(
                    label: _qqVerifying ? '验证中...' : '验证',
                    variant: AppButtonVariant.primary,
                    onPressed: _qqVerifying ? null : _verifyQq,
                  ),
                  const SizedBox(width: 8),
                  AppButton(
                    label: '保存',
                    variant: AppButtonVariant.accent,
                    onPressed: () {
                      final v = _qqCookie.text.trim();
                      if (v.isEmpty) {
                        toast.show('请输入 Cookie', type: ToastType.error);
                        return;
                      }
                      state.setQqCookie(v);
                      toast.show('Cookie 已保存', type: ToastType.success);
                    },
                  ),
                  const SizedBox(width: 8),
                  AppButton(
                    label: '清除',
                    onPressed: () async {
                      final ok = await showConfirmDialog(context, '确定清除已保存的 Cookie 吗？');
                      if (!ok) return;
                      state.clearQqCookie();
                      _qqCookie.text = '';
                      setState(() {});
                      toast.show('Cookie 已清除', type: ToastType.info);
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---------------- 网易云 Cookie ----------------
          _Section(
            title: '网易云音乐 Cookie',
            desc: '设置网易云音乐 Cookie (MUSIC_U) 以获取高品质资源和完整歌单。在浏览器中登录 music.163.com，'
                '按 F12 打开开发者工具，在 Application > Cookies 中找到 MUSIC_U 的键值。',
            children: [
              _FieldLabel('Cookie 状态', c),
              _CookieStatus(
                hasCookie: state.neteaseCookie.isNotEmpty,
                status: state.neteaseCookieStatus,
              ),
              const SizedBox(height: 16),
              _FieldLabel('MUSIC_U Cookie', c),
              AppTextField(
                controller: _neteaseCookie,
                hint: '粘贴 MUSIC_U Cookie 键值，例如：MUSIC_U=XXXXXX ...',
                obscure: !_showNeteaseCookie,
                mono: true,
                trailing: AppIconButton(
                  icon: _showNeteaseCookie ? AppIcons.eyeClosed : AppIcons.eyeOpen,
                  size: 28,
                  iconSize: 16,
                  tooltip: '显示/隐藏',
                  onTap: () => setState(() => _showNeteaseCookie = !_showNeteaseCookie),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  AppButton(
                    label: _neVerifying ? '验证中...' : '验证',
                    variant: AppButtonVariant.primary,
                    onPressed: _neVerifying ? null : _verifyNetease,
                  ),
                  const SizedBox(width: 8),
                  AppButton(
                    label: '保存',
                    variant: AppButtonVariant.accent,
                    onPressed: () {
                      final v = _neteaseCookie.text.trim();
                      if (v.isEmpty) {
                        toast.show('请输入 MUSIC_U Cookie', type: ToastType.error);
                        return;
                      }
                      state.setNeteaseCookie(v);
                      toast.show('网易云 Cookie 已保存', type: ToastType.success);
                    },
                  ),
                  const SizedBox(width: 8),
                  AppButton(
                    label: '清除',
                    onPressed: () async {
                      final ok = await showConfirmDialog(context, '确定清除已保存的网易云 Cookie 吗？');
                      if (!ok) return;
                      state.clearNeteaseCookie();
                      _neteaseCookie.text = '';
                      setState(() {});
                      toast.show('网易云 Cookie 已清除', type: ToastType.info);
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---------------- 下载设置 ----------------
          _Section(
            title: '下载设置',
            children: [
              _FieldLabel('默认保存目录', c),
              Row(
                children: [
                  Expanded(
                    child: AppTextField(
                      controller: _savePath,
                      readOnly: true,
                      hint: '未设置（每次下载时选择）',
                    ),
                  ),
                  const SizedBox(width: 8),
                  AppButton(
                    label: '浏览',
                    onPressed: () async {
                      final dir = await AppState.pickDirectory();
                      if (dir != null && dir.isNotEmpty) {
                        state.setSavePath(dir);
                        setState(() {});
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  AppButton(
                    label: '清除',
                    onPressed: () {
                      state.clearSavePath();
                      setState(() {});
                    },
                  ),
                ],
              ),
              if (state.recentDirs.isNotEmpty) ...[
                const SizedBox(height: 16),
                _FieldLabel('常用目录', c),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final dir in state.recentDirs)
                      HoverBuilder(
                        builder: (_, hovered) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: hovered ? c.hover : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              AppIcon(AppIcons.folder,
                                  size: 14, color: c.textSecondary.withValues(alpha: 0.5)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  dir,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                                ),
                              ),
                              AppIconButton(
                                icon: AppIcons.trash,
                                size: 24,
                                iconSize: 14,
                                tooltip: '删除',
                                onTap: () {
                                  state.removeRecentDir(dir);
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),

          // ---------------- 音质设置 ----------------
          _Section(
            title: '音质设置',
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => state.setHighQuality(!state.highQuality),
                  child: Row(
                    children: [
                      AppToggle(
                        value: state.highQuality,
                        onChanged: state.setHighQuality,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '高品质模式 (320kbps)',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: c.text,
                        ),
                      ),
                      if (state.highQuality) ...[
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: c.accentLight,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'HQ',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: c.accent,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---------------- 外观 ----------------
          _Section(
            title: '外观',
            children: [
              _FieldLabel('界面缩放', c),
              Row(
                children: [
                  SizedBox(
                    width: 200,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        activeTrackColor: c.accent,
                        inactiveTrackColor: c.progressBg,
                        thumbColor: c.accent,
                        overlayColor: c.accentLight,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                      ),
                      child: Slider(
                        value: state.zoom,
                        min: 75,
                        max: 150,
                        divisions: 15,
                        onChanged: (v) => state.setZoom(v),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 48,
                    child: Text(
                      '${state.zoom.round()}%',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 13,
                        color: c.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  for (final mode in AppThemeMode.values) ...[
                    Expanded(
                      child: _ThemeOption(
                        mode: mode,
                        selected: themeController.mode == mode,
                        onTap: () {
                          themeController.setMode(mode);
                          setState(() {});
                        },
                      ),
                    ),
                    if (mode != AppThemeMode.values.last) const SizedBox(width: 8),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _verifyQq() async {
    final v = _qqCookie.text.trim();
    if (v.isEmpty) {
      toast.show('请输入 Cookie', type: ToastType.error);
      return;
    }
    setState(() => _qqVerifying = true);
    try {
      await ApiClient.verifyCookie(v);
      widget.state.qqCookieStatus = 'valid';
      widget.state.setQqCookie(v);
      widget.state.qqCookieStatus = 'valid';
      toast.show('Cookie 验证通过', type: ToastType.success);
    } catch (e) {
      widget.state.qqCookieStatus = 'invalid';
      toast.show('$e', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _qqVerifying = false);
    }
  }

  Future<void> _verifyNetease() async {
    final v = _neteaseCookie.text.trim();
    if (v.isEmpty) {
      toast.show('请输入 MUSIC_U Cookie', type: ToastType.error);
      return;
    }
    setState(() => _neVerifying = true);
    try {
      await ApiClient.verifyNeteaseCookie(v);
      widget.state.neteaseCookieStatus = 'valid';
      widget.state.setNeteaseCookie(v);
      widget.state.neteaseCookieStatus = 'valid';
      toast.show('网易云 Cookie 验证通过', type: ToastType.success);
    } catch (e) {
      widget.state.neteaseCookieStatus = 'invalid';
      toast.show('$e', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _neVerifying = false);
    }
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, this.desc, required this.children});

  final String title;
  final String? desc;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.borderSubtle),
        borderRadius: BorderRadius.circular(c.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.text),
          ),
          if (desc != null) ...[
            const SizedBox(height: 4),
            Text(
              desc!,
              style: TextStyle(fontSize: 12, color: c.textTertiary, height: 1.6),
            ),
          ],
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text, this.c);
  final String text;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textSecondary),
      ),
    );
  }
}

class _CookieStatus extends StatelessWidget {
  const _CookieStatus({required this.hasCookie, required this.status});

  final bool hasCookie;
  final String status;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    late Color dot;
    late String text;

    if (!hasCookie) {
      dot = c.textTertiary;
      text = '未配置';
    } else if (status == 'valid') {
      dot = c.success;
      text = '有效';
    } else if (status == 'invalid') {
      dot = c.danger;
      text = '无效';
    } else {
      dot = c.textTertiary;
      text = '已保存（待验证）';
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(text, style: TextStyle(fontSize: 13, color: c.textSecondary)),
          ],
        ),
      ),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({required this.mode, required this.selected, required this.onTap});

  final AppThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return HoverBuilder(
      builder: (_, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? c.accentLight : Colors.transparent,
            border: Border.all(
              color: selected ? c.accent : (hovered ? c.textTertiary : c.border),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(c.radius),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon(mode.icon, size: 16, color: selected ? c.accent : c.textSecondary),
              const SizedBox(width: 8),
              Text(
                mode.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: selected ? c.accent : c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
