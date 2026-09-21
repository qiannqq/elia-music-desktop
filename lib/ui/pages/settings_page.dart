import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../services/api_client.dart';
import '../../services/netease_service.dart';
import '../../services/qqmusic_service.dart';
import '../../state/app_state.dart';
import '../../state/theme_controller.dart';
import '../../state/toast.dart';
import '../icons.dart';
import '../widgets/common.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/dialogs.dart';

/// 设置页 —— 对应 `#page-settings`
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.state,
    required this.scrollController,
    required this.qqCookie,
    required this.neteaseCookie,
    required this.savePath,
  });

  final AppState state;
  final ScrollController scrollController;

  /// 输入框控制器由 shell 持有（见 AppShell 里的说明）：
  /// 切到别的页面再回来，没保存的编辑内容还在。
  final TextEditingController qqCookie;
  final TextEditingController neteaseCookie;
  final TextEditingController savePath;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  TextEditingController get _qqCookie => widget.qqCookie;
  TextEditingController get _neteaseCookie => widget.neteaseCookie;
  TextEditingController get _savePath => widget.savePath;

  bool _showQqCookie = false;
  bool _showNeteaseCookie = false;
  bool _qqVerifying = false;
  bool _neVerifying = false;

  /// 保存目录会随「选择目录」而变，每次构建对齐一次。
  ///
  /// ck **不在这里同步** —— 它是用户正在编辑的内容，由 shell 在启动时灌一次；
  /// 每次构建都从状态覆盖的话，没保存的编辑会被冲掉。
  void _syncFromState() {
    final path = widget.state.savePath;
    if (_savePath.text != path) _savePath.text = path;
  }

  @override
  Widget build(BuildContext context) {
    _syncFromState();
    final c = context.c;
    final state = widget.state;

    // 滚轮加过渡动画（不影响速度，只是不再一格一跳）
    return SmoothWheelScroll(
      controller: widget.scrollController,
      child: SingleChildScrollView(
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
                hasCookie: state.qqCookie.isEmpty == false,
                status: state.qqCookieStatus,
              ),
              if (state.qqNickname.isNotEmpty) ...[
                const SizedBox(height: 16),
                _FieldLabel('账号信息', c),
                _AccountTags(
                  nickname: state.qqNickname,
                  loginLabel: state.qqIsWechat ? '微信登录' : 'QQ登录',
                  isVip: state.qqIsVip,
                  vipLabel: '绿钻',
                ),
              ],
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
                    label: _qqVerifying ? '验证中...' : '验证并保存',
                    variant: AppButtonVariant.primary,
                    onPressed: _qqVerifying ? null : _verifyQq,
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
            desc: '设置网易云音乐 Cookie 以获取高品质资源和完整歌单。'
                '填入完整 cookie 字符串、MUSIC_U 的键值、或者只有 MUSIC_U 那一长串的值都行 '
                '—— 一般直接粘完整 cookie 字符串就会自动识别。'
                '在浏览器中登录 music.163.com，按 F12 打开开发者工具，在 Application > Cookies 里找。',
            children: [
              _FieldLabel('Cookie 状态', c),
              _CookieStatus(
                hasCookie: state.neteaseCookie.isNotEmpty,
                status: state.neteaseCookieStatus,
              ),
              if (state.neNickname.isNotEmpty) ...[
                const SizedBox(height: 16),
                _FieldLabel('账号信息', c),
                _AccountTags(
                  nickname: state.neNickname,
                  // 网易云 cookie 里看不出登录方式，这一项就空着
                  loginLabel: '',
                  isVip: state.neIsVip,
                  vipLabel: '黑胶',
                ),
              ],
              const SizedBox(height: 16),
              _FieldLabel('Cookie 字符串 / MUSIC_U', c),
              AppTextField(
                controller: _neteaseCookie,
                hint: '粘贴完整 Cookie，或 MUSIC_U 键值 / 纯值...',
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
                    label: _neVerifying ? '验证中...' : '验证并保存',
                    variant: AppButtonVariant.primary,
                    onPressed: _neVerifying ? null : _verifyNetease,
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
                            color: hovered ? c.hover : c.hover.withValues(alpha: 0),
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
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  _FieldLabel('界面缩放', c),
                  const SizedBox(width: 8),
                  Text(
                    '按住 ctrl 使用滚轮可以快捷调整缩放',
                    style: TextStyle(fontSize: 12, color: c.textTertiary),
                  ),
                ],
              ),
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
    ));
  }

  Future<void> _verifyQq() async {
    final v = _qqCookie.text.trim();
    if (v.isEmpty) {
      toast.show('请输入 Cookie', type: ToastType.error);
      return;
    }
    setState(() => _qqVerifying = true);
    try {
      // 必须去 QQ 的账号接口问一次「这是谁」。
      // 走本地代理取播放地址是不算数的：那个地址在未登录状态下同样取得到，
      // 于是随便填一串字符都会「验证通过」。
      final info = await qqMusicService.fetchUserInfo(ck: v);
      if (info == null) {
        widget.state.markQqCookieInvalid();
        toast.show('Cookie 无效或已失效，未保存', type: ToastType.error);
        return;
      }
      widget.state.setQqCookie(v);
      widget.state.applyQqUserInfo(
        nickname: info.nickname,
        isWechat: info.isWechat,
        isVip: info.isVip,
      );
      toast.show('验证通过：${info.nickname}', type: ToastType.success);
    } catch (e) {
      widget.state.markQqCookieInvalid();
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
      // 存整理后的形式（纯值会补上 `MUSIC_U=`），下次启动直接用，不必再整理
      final normalized = NeteaseMusicService.normalizeCookie(v);
      widget.state.setNeteaseCookie(normalized);
      if (mounted) _neteaseCookie.text = normalized;
      final info = await neteaseMusicService.getUserInfo();
      if (info != null) {
        widget.state.applyNeUserInfo(
          nickname: (info['nickname'] ?? '').toString(),
          isVip: info['isVip'] == true,
        );
        toast.show('验证通过：${info['nickname']}', type: ToastType.success);
      } else {
        widget.state.neteaseCookieStatus = 'valid';
        toast.show('网易云 Cookie 验证通过', type: ToastType.success);
      }
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

/// 账号信息：昵称 + 登录方式 + 会员。
class _AccountTags extends StatelessWidget {
  const _AccountTags({
    required this.nickname,
    required this.loginLabel,
    required this.isVip,
    required this.vipLabel,
  });

  final String nickname;

  /// 登录方式。空串表示不显示（网易云 cookie 里看不出登录方式）。
  final String loginLabel;

  final bool isVip;

  /// 会员叫法：QQ 是「绿钻」、网易云是「黑胶」。
  final String vipLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    // 会员用绿色 —— 绿钻本来就是绿的
    const vipColor = Color(0xFF12B76A);
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _Tag(text: nickname, color: c.textSecondary, bg: c.surfaceAlt),
          if (loginLabel.isNotEmpty)
            _Tag(text: loginLabel, color: c.textSecondary, bg: c.surfaceAlt),
          _Tag(
            text: isVip ? vipLabel : '非$vipLabel',
            color: isVip ? vipColor : c.textTertiary,
            bg: isVip ? vipColor.withValues(alpha: 0.12) : c.surfaceAlt,
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color, required this.bg});

  final String text;
  final Color color;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: TextStyle(fontSize: 13, color: color)),
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
            color: selected ? c.accentLight : c.accentLight.withValues(alpha: 0),
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
