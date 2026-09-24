import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/app_paths.dart';
import '../../services/api_client.dart';
import '../../services/audio_cache.dart';
import '../../services/bilibili_service.dart';
import '../../services/cache_manager.dart';
import '../../services/lyric_island_service.dart';
import '../../services/netease_service.dart';
import '../../services/qqmusic_service.dart';
import '../../state/app_state.dart';
import '../../state/theme_controller.dart';
import '../../state/toast.dart';
import '../icons.dart';
import '../widgets/common.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/dialogs.dart';

/// 设置页的分栏。顺序就是分栏条上从左到右的顺序。
enum SettingsTab {
  playback('播放设置', AppIcons.play),
  ck('CK设置', AppIcons.key),
  storage('下载与缓存', AppIcons.download),
  appearance('外观设置', AppIcons.palette);

  const SettingsTab(this.label, this.icon);

  final String label;
  final String icon;
}

/// 设置页 —— 对应 `#page-settings`
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.state,
    required this.scrollController,
    required this.qqCookie,
    required this.neteaseCookie,
    required this.biliCookie,
    required this.savePath,
  });

  final AppState state;
  final ScrollController scrollController;

  /// 输入框控制器由 shell 持有（见 AppShell 里的说明）：
  /// 切到别的页面再回来，没保存的编辑内容还在。
  final TextEditingController qqCookie;
  final TextEditingController neteaseCookie;
  final TextEditingController biliCookie;
  final TextEditingController savePath;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  TextEditingController get _qqCookie => widget.qqCookie;
  TextEditingController get _neteaseCookie => widget.neteaseCookie;
  TextEditingController get _biliCookie => widget.biliCookie;
  TextEditingController get _savePath => widget.savePath;

  bool _showQqCookie = false;
  bool _showNeteaseCookie = false;
  bool _showBiliCookie = false;
  bool _qqVerifying = false;
  bool _neVerifying = false;
  bool _biliVerifying = false;

  /// 缓存占用。null = 还没统计出来。
  CacheUsage? _usage;
  bool _cacheBusy = false;

  /// 拖动上限滑块时的临时值。松手前不写盘，免得拖一次存几十遍。
  double? _limitDraft;

  double get _limitGb => _limitDraft ?? AudioDiskCache.limitMb / 1024;

  /// 当前分栏。切到别的页面再回来会停在原来那一栏 —— 设置项位置固定，
  /// 用户回来多半还是接着调同一处。
  SettingsTab _tab = SettingsTab.playback;

  Future<void> _applyLimit(double gb) async {
    final value = gb.round();
    AudioDiskCache.setLimitGb(value);
    // 调小了就当场生效，否则用户看不到任何变化
    final removed = AudioDiskCache.enforceLimit();
    if (mounted) setState(() => _limitDraft = null);
    await _refreshCache();
    if (value <= 0) {
      toast.show(
        removed > 0 ? '缓存已停用，清掉 $removed 首' : '缓存已停用',
        type: ToastType.info,
      );
    } else if (removed > 0) {
      toast.show('已按上限清掉 $removed 首最久没听过的', type: ToastType.info);
    }
  }

  @override
  void initState() {
    super.initState();
    _refreshCache();
  }

  Future<void> _refreshCache() async {
    final u = await CacheManager.measure();
    if (mounted) setState(() => _usage = u);
  }

  /// [kind]：'audio' / 'lyric' / 'all'
  Future<void> _clearCache(String kind) async {
    if (_cacheBusy) return;
    final label = switch (kind) {
      'audio' => '音频缓存',
      'other' => '歌词与其他',
      _ => '全部缓存',
    };
    final ok = await showConfirmDialog(context, '确定清空$label吗？下次播放会重新取一遍。');
    if (!ok || !mounted) return;
    setState(() => _cacheBusy = true);
    try {
      final freed = switch (kind) {
        'audio' => CacheManager.clearAudio(),
        'other' => CacheManager.clearOther(),
        _ => CacheManager.clearAll(),
      };
      await _refreshCache();
      toast.show('已清理 $label，释放 ${CacheManager.formatBytes(freed)}',
          type: ToastType.success);
    } catch (e) {
      toast.show('清理失败：$e', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _cacheBusy = false);
    }
  }

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ---- 页头 + 分栏。固定在顶部，不跟着内容滚 ----
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '设置',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c.text),
              ),
              const SizedBox(height: 16),
              _TabBar(
                current: _tab,
                onSelect: (t) {
                  if (t == _tab) return;
                  setState(() => _tab = t);
                  // 换栏后内容整块换掉，停在半截的滚动位置没有意义
                  if (widget.scrollController.hasClients) {
                    widget.scrollController.jumpTo(0);
                  }
                },
              ),
            ],
          ),
        ),

        // ---- 当前分栏的内容 ----
        Expanded(
          child: SmoothWheelScroll(
            controller: widget.scrollController,
            child: SingleChildScrollView(
              controller: widget.scrollController,
              padding: const EdgeInsets.fromLTRB(32, 4, 32, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _sectionsOf(_tab, c, state),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 这一栏有哪些段落。段间统一 16px —— 不用每段自己记着加。
  ///
  /// 段落从 build 里搬出来，是为了让「这一栏有哪些东西」一眼看完；
  /// 之前八段全挤在一个 children 列表里，加一栏得数半天缩进。
  List<Widget> _sectionsOf(SettingsTab tab, AppColors c, AppState state) {
    final sections = switch (tab) {
      SettingsTab.playback => [
          _qualitySection(c, state),
          _silenceSection(c, state),
          _lyricIslandSection(c, state),
        ],
      SettingsTab.ck => [
          _qqCookieSection(c, state),
          _neteaseCookieSection(c, state),
          _biliCookieSection(c, state),
        ],
      SettingsTab.storage => [
          _downloadSection(c, state),
          _cacheSection(c, state),
        ],
      SettingsTab.appearance => [
          _appearanceSection(c, state),
          _accentColorSection(c, state),
        ],
    };
    return [
      for (var i = 0; i < sections.length; i++) ...[
        if (i > 0) const SizedBox(height: 16),
        sections[i],
      ],
    ];
  }

  Widget _qqCookieSection(AppColors c, AppState state) {
    return _Section(
      title: 'QQ音乐 Cookie',
      desc: '用于获取高品质音源。于 y.qq.com 登录后，从开发者工具中复制 Cookie。',
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
            vipColor: _qqVipColor,
          ),
        ],
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
    );
  }

  Widget _neteaseCookieSection(AppColors c, AppState state) {
    return _Section(
      title: '网易云音乐 Cookie',
      desc: '用于获取高品质音源与完整歌单。可填完整 Cookie 或 MUSIC_U。',
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
            vipColor: _neVipColor,
          ),
        ],
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
    );
  }

  Widget _biliCookieSection(AppColors c, AppState state) {
    return _Section(
      title: 'B站 Cookie',
      desc: '可选。填写后可访问私密投稿，搜索排序与网页端一致。'
          '可填完整 Cookie 或 SESSDATA。',
      children: [
        _FieldLabel('Cookie 状态', c),
        _CookieStatus(
          hasCookie: state.biliCookie.isNotEmpty,
          status: state.biliCookieStatus,
        ),
        if (state.biliNickname.isNotEmpty) ...[
          const SizedBox(height: 16),
          _FieldLabel('账号信息', c),
          _AccountTags(
            nickname: state.biliNickname,
            // B站 cookie 里看不出登录方式，这一项就空着
            loginLabel: '',
            isVip: state.biliIsVip,
            vipLabel: '大会员',
            vipColor: _biliVipColor,
          ),
        ],
        _FieldLabel('Cookie 字符串 / SESSDATA', c),
        AppTextField(
          controller: _biliCookie,
          hint: '粘贴完整 Cookie，或 SESSDATA 键值 / 纯值...',
          obscure: !_showBiliCookie,
          mono: true,
          trailing: AppIconButton(
            icon: _showBiliCookie ? AppIcons.eyeClosed : AppIcons.eyeOpen,
            size: 28,
            iconSize: 16,
            tooltip: '显示/隐藏',
            onTap: () => setState(() => _showBiliCookie = !_showBiliCookie),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            AppButton(
              label: _biliVerifying ? '验证中...' : '验证并保存',
              variant: AppButtonVariant.primary,
              onPressed: _biliVerifying ? null : _verifyBili,
            ),
            const SizedBox(width: 8),
            AppButton(
              label: '清除',
              onPressed: () async {
                final ok =
                    await showConfirmDialog(context, '确定清除已保存的 B站 Cookie 吗？');
                if (!ok) return;
                state.clearBiliCookie();
                _biliCookie.text = '';
                setState(() {});
                toast.show('B站 Cookie 已清除', type: ToastType.info);
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _downloadSection(AppColors c, AppState state) {
    return _Section(
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
    );
  }

  Widget _qualitySection(AppColors c, AppState state) {
    return _Section(
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
    );
  }

  Widget _silenceSection(AppColors c, AppState state) {
    return _Section(
      title: '跳过首尾无声片段',
      desc: '自动跳过歌曲开头与结尾的空白（压制时留下的那几秒）。'
          '需要解一次音频来定位，所以每首歌第一次播放时可能晚半秒才生效。',
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '开启',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: c.textSecondary,
                ),
              ),
            ),
            AppToggle(
              value: state.skipSilence,
              onChanged: state.setSkipSilence,
            ),
          ],
        ),
      ],
    );
  }

  Widget _lyricIslandSection(AppColors c, AppState state) {
    return _Section(
      title: '胶囊歌词',
      desc: '在屏幕顶部显示当前歌词。',
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '开启',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: c.textSecondary,
                ),
              ),
            ),
            AppToggle(
              value: lyricIsland.enabled,
              onChanged: (v) {
                lyricIsland.setEnabled(v);
                setState(() {});
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _appearanceSection(AppColors c, AppState state) {
    return _Section(
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
    );
  }

  Widget _cacheSection(AppColors c, AppState state) {
    return _Section(
      title: '缓存',
      desc: '播放产生的本地音频与歌词文件。',
      children: _buildCache(c),
    );
  }

  /// 主题色 —— 选中即时生效。
  ///
  /// 只让用户挑**一个**色：深浅两套主题的其余档（悬停、淡色底、主色上的字）
  /// 都由 [AccentShades] 现推。不然用户得自己把深浅两套各挑一遍，
  /// 还容易挑出互相打架的组合。
  Widget _accentColorSection(AppColors c, AppState state) {
    final current = themeController.accent;
    final hsl = HSLColor.fromColor(current);
    final isPreset = kAccentPresets.any((p) => p.toARGB32() == current.toARGB32());
    return _Section(
      title: '主题色',
      desc: '替换界面里所有的强调色：按钮、开关、进度条、歌词高亮、选中态。',
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final preset in kAccentPresets)
              _Swatch(
                color: preset,
                selected: preset.toARGB32() == current.toARGB32(),
                onTap: () => _useAccent(preset),
              ),
            // 最后一格是自定义：色不在预设里时它显示当前色并被选中
            _Swatch(
              color: current,
              custom: true,
              selected: !isPreset,
              onTap: () => _useAccent(current),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _AccentSlider(
          label: '色相',
          value: hsl.hue,
          min: 0,
          max: 360,
          display: '${hsl.hue.round()}°',
          onChanged: (v) => _useAccent(hsl.withHue(v).toColor()),
        ),
        _AccentSlider(
          label: '明度',
          value: hsl.lightness,
          min: 0.15,
          max: 0.9,
          display: '${(hsl.lightness * 100).round()}%',
          onChanged: (v) => _useAccent(hsl.withLightness(v).toColor()),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              '当前 ${_hexOf(current)}',
              style: TextStyle(
                fontSize: 12,
                color: c.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const Spacer(),
            AppButton(
              label: '恢复默认',
              small: true,
              onPressed: isPreset && current.toARGB32() == kAccentPresets.first.toARGB32()
                  ? null
                  : () => _useAccent(kAccentPresets.first),
            ),
          ],
        ),
      ],
    );
  }

  void _useAccent(Color color) {
    themeController.setAccent(color);
    setState(() {});
  }

  static String _hexOf(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  List<Widget> _buildCache(AppColors c) {
    final u = _usage;
    if (u == null) {
      return [
        Text(
          '正在统计…',
          style: TextStyle(fontSize: 13, color: c.textTertiary),
        ),
      ];
    }

    final drive = AppPaths.dataDir.length >= 2
        ? AppPaths.dataDir.substring(0, 2).toUpperCase()
        : '';
    final diskShare = u.diskShare;

    return [
      _CacheRow(
        c: c,
        label: '总占用',
        bytes: u.totalBytes,
        trailing: diskShare == null
            ? ''
            : '占 $drive ${(diskShare * 100).toStringAsFixed(2)}%',
        emphasize: true,
      ),
      const SizedBox(height: 10),
      _CacheBar(c: c, value: u.audioShare),
      const SizedBox(height: 12),
      _CacheRow(
        c: c,
        label: '音频',
        bytes: u.audioBytes,
        trailing: '占缓存 ${(u.audioShare * 100).round()}%',
        action: AppButton(
          label: '清理',
          small: true,
          onPressed: _cacheBusy ? null : () => _clearCache('audio'),
        ),
      ),
      const SizedBox(height: 8),
      _CacheRow(
        c: c,
        label: '歌词与其他',
        bytes: u.otherBytes,
        trailing: '占缓存 ${(u.otherShare * 100).round()}%',
        action: AppButton(
          label: '清理',
          small: true,
          onPressed: _cacheBusy ? null : () => _clearCache('other'),
        ),
      ),
      const SizedBox(height: 18),
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          _FieldLabel('缓存上限', c),
          const SizedBox(width: 8),
          Text(
            '超出上限就按「最久没听过」的顺序删；拖到 0 则不启用缓存',
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
                value: _limitGb
                    .clamp(
                      AudioDiskCache.minLimitGb.toDouble(),
                      AudioDiskCache.maxLimitGb.toDouble(),
                    )
                    .toDouble(),
                min: AudioDiskCache.minLimitGb.toDouble(),
                max: AudioDiskCache.maxLimitGb.toDouble(),
                divisions:
                    AudioDiskCache.maxLimitGb - AudioDiskCache.minLimitGb,
                onChanged: _cacheBusy
                    ? null
                    : (v) => setState(() => _limitDraft = v),
                onChangeEnd: _cacheBusy ? null : _applyLimit,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 64,
            child: Text(
              _limitGb.round() <= 0 ? '不启用' : '${_limitGb.round()} GB',
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
          AppButton(
            label: '清理全部缓存',
            small: true,
            icon: AppIcons.trash,
            onPressed: (_cacheBusy || u.totalBytes <= 0)
                ? null
                : () => _clearCache('all'),
          ),
          const SizedBox(width: 10),
          AppButton(
            label: '重新统计',
            small: true,
            variant: AppButtonVariant.ghost,
            onPressed: _cacheBusy ? null : _refreshCache,
          ),
        ],
      ),
    ];
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
      switch (info.outcome) {
        case CkOutcome.ok:
          widget.state.setQqCookie(v);
          widget.state.applyQqUserInfo(
            nickname: info.nickname,
            isWechat: info.isWechat,
            isVip: info.isVip,
          );
          // 凭据换了：之前缓存的音频可能只是匿名状态下拿到的试听片段，
          // 作废一代，下次播放重新取完整版。
          AudioDiskCache.bumpEpoch();
          toast.show('验证通过：${info.nickname}（旧缓存已作废）',
              type: ToastType.success);
        case CkOutcome.rejected:
          widget.state.markQqCookieInvalid();
          toast.show('Cookie 无效或已失效，未保存', type: ToastType.error);
        case CkOutcome.unreachable:
          // 连不上账号接口不等于 ck 有问题 —— 不写状态、不落盘，
          // 让用户直接再点一次就好。
          toast.show('无法连接 QQ 音乐，请检查网络后重试', type: ToastType.error);
      }
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
      // 见 _verifyQq：凭据一变，之前那份试听片段就不能再命中
      AudioDiskCache.bumpEpoch();
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

  Future<void> _verifyBili() async {
    final v = _biliCookie.text.trim();
    if (v.isEmpty) {
      toast.show('请输入 Cookie', type: ToastType.error);
      return;
    }
    setState(() => _biliVerifying = true);
    try {
      final info = await bilibiliService.fetchUserInfo(ck: v);
      if (info == null) {
        widget.state.biliCookieStatus = 'invalid';
        toast.show('Cookie 无效或已失效，未保存', type: ToastType.error);
        return;
      }
      // 存整理后的形式（纯值会补上 `SESSDATA=`），下次启动直接用
      final normalized = BilibiliService.normalizeCookie(v);
      widget.state.setBiliCookie(normalized);
      if (mounted) _biliCookie.text = normalized;
      widget.state.applyBiliUserInfo(
        nickname: info.nickname,
        isVip: info.isVip,
      );
      // 见 _verifyQq：B站换 ck 也会影响能取到哪一档音频
      AudioDiskCache.bumpEpoch();
      toast.show('验证通过：${info.nickname}（旧缓存已作废）',
          type: ToastType.success);
    } catch (e) {
      widget.state.biliCookieStatus = 'invalid';
      toast.show('$e', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _biliVerifying = false);
    }
  }
}

/// 分栏条 —— 设置页最上面那一排。
///
/// 用「胶囊 + 图标」而不是下划线 Tab：这个应用里所有「选中」都是
/// `accentLight` 底 + `accent` 描边（见 `_ThemeOption`），保持一致。
class _TabBar extends StatelessWidget {
  const _TabBar({required this.current, required this.onSelect});

  final SettingsTab current;
  final ValueChanged<SettingsTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      children: [
        for (final tab in SettingsTab.values) ...[
          Expanded(
            child: HoverBuilder(
              builder: (_, hovered) {
                final selected = tab == current;
                return GestureDetector(
                  onTap: () => onSelect(tab),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: selected
                          ? c.accentLight
                          : (hovered ? c.hover : c.hover.withValues(alpha: 0)),
                      border: Border.all(
                        color: selected ? c.accent : (hovered ? c.textTertiary : c.border),
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(c.radius),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AppIcon(tab.icon,
                            size: 15, color: selected ? c.accent : c.textSecondary),
                        const SizedBox(width: 7),
                        Text(
                          tab.label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                            color: selected ? c.accent : c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (tab != SettingsTab.values.last) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

/// 调色板里的一格。
///
/// 勾的颜色走 [AccentShades.onAccent]，所以挑到很亮的色（黄、天蓝）时
/// 勾会自己变成深色，不会白勾白底看不见。
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
    this.custom = false,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  /// 自定义那一格：没选中时显示调色板图标，提示这里能自己调
  final bool custom;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ink = AccentShades.onAccent(color);
    return HoverBuilder(
      builder: (_, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? c.accent : (hovered ? c.textSecondary : c.border),
              width: selected ? 2 : 1,
            ),
          ),
          child: Center(
            child: selected
                ? AppIcon(AppIcons.check, size: 16, color: ink)
                : (custom ? AppIcon(AppIcons.palette, size: 15, color: ink) : null),
          ),
        ),
      ),
    );
  }
}

/// 主题色的色相 / 明度滑杆 —— 样式与「界面缩放」那条一致。
class _AccentSlider extends StatelessWidget {
  const _AccentSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textSecondary),
          ),
        ),
        SizedBox(
          width: 220,
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
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 48,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 13,
              color: c.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
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
/// 绿钻 —— 绿色。
const Color _qqVipColor = Color(0xFF12B76A);

/// 黑胶 —— 黑金。比纯金暗一档，压在浅色底上不刺眼，
/// 又比普通灰标签一眼能分出档次。
const Color _neVipColor = Color(0xFFB8860B);

/// 大会员 —— B站的粉，取自「我的大会员」那张卡片上的字色。
const Color _biliVipColor = Color(0xFFFF6699);

class _AccountTags extends StatelessWidget {
  const _AccountTags({
    required this.nickname,
    required this.loginLabel,
    required this.isVip,
    required this.vipLabel,
    required this.vipColor,
  });

  final String nickname;

  /// 登录方式。空串表示不显示（网易云 cookie 里看不出登录方式）。
  final String loginLabel;

  final bool isVip;

  /// 会员叫法：QQ 是「绿钻」、网易云是「黑胶」、B站是「大会员」。
  final String vipLabel;

  /// 会员标签的颜色。三家的品牌色差得远，各用各的：
  ///  * 绿钻 —— 绿色；
  ///  * 黑胶 —— 黑金（暗金）；
  ///  * 大会员 —— B站的粉（`#FF6699`）。
  final Color vipColor;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
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

/// 缓存统计的一行：名称 + 体积 + 说明 + 可选的操作按钮。
class _CacheRow extends StatelessWidget {
  const _CacheRow({
    required this.c,
    required this.label,
    required this.bytes,
    this.trailing = '',
    this.action,
    this.emphasize = false,
  });

  final AppColors c;
  final String label;
  final int bytes;
  final String trailing;
  final Widget? action;

  /// 总占用那一行：字重和颜色都提一档
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final weight = emphasize ? FontWeight.w600 : FontWeight.w500;
    final color = emphasize ? c.text : c.textSecondary;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 13, fontWeight: weight, color: color),
          ),
        ),
        Text(
          CacheManager.formatBytes(bytes),
          style: TextStyle(
            fontSize: 13,
            fontWeight: weight,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 12),
        // 固定宽度右对齐：三行的百分比才会竖着对齐成一列
        SizedBox(
          width: 104,
          child: Text(
            trailing,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 12,
              color: c.textTertiary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (action != null) ...[
          const SizedBox(width: 12),
          SizedBox(
            width: 58,
            child: Align(alignment: Alignment.centerRight, child: action),
          ),
        ],
      ],
    );
  }
}

/// 音频与歌词的比例条。只做展示，不响应鼠标。
class _CacheBar extends StatelessWidget {
  const _CacheBar({required this.c, required this.value});

  final AppColors c;

  /// 音频占总缓存的比例（0~1）
  final double value;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: c.progressBg)),
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: v,
                  heightFactor: 1,
                  child: ColoredBox(color: c.accent),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
