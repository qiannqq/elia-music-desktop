import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/playlist_link.dart';
import '../../models/playlist.dart';
import '../../state/app_state.dart';
import '../icons.dart';
import '../widgets/common.dart';
import '../widgets/dialogs.dart';
import '../widgets/modal.dart';

/// 歌单的同步设置弹窗。
///
/// 骨架照 `dialogs.dart` 里的 `showSaveDialog`：`AppModalCard` + 头部 +
/// `Flexible` + `SingleChildScrollView` + 底部按钮行。弹窗底是**实色**的
/// `flyoutBg`（`AppModalCard` 自己就是），别另外套一层半透明的面。
///
/// 里面的每一项都是**改完立刻生效**（写进状态层并落盘），没有「保存」按钮 ——
/// 半保存状态（链接改了、开关没改）对同步这种后台行为没有意义。
Future<void> showPlaylistSyncDialog(
  BuildContext context,
  AppState state,
  String playlistId,
) {
  // 歌单可能在菜单弹出来之后被删掉（右键菜单是异步的）：找不到就什么都不做，
  // 别让弹窗里那句 `playlistById(...)!` 抛出去。
  if (state.playlistById(playlistId) == null) return Future<void>.value();
  return showAppModal<void>(
    context,
    _PlaylistSyncDialog(state: state, playlistId: playlistId),
  );
}

class _PlaylistSyncDialog extends StatefulWidget {
  const _PlaylistSyncDialog({required this.state, required this.playlistId});

  final AppState state;
  final String playlistId;

  @override
  State<_PlaylistSyncDialog> createState() => _PlaylistSyncDialogState();
}

class _PlaylistSyncDialogState extends State<_PlaylistSyncDialog> {
  late final Playlist _p;

  late final TextEditingController _link;

  /// 正在跑「立即同步」（按钮换成加载态）
  bool _running = false;

  /// 这一次跑完的结果短句（上一次的结论从 `syncLastResult` 读）
  String _runText = '';

  /// 链接解析结果：null = 没认出来（`source` 为空串表示只认出 id）
  ({String source, String id})? _parsed;

  /// B站没有收藏夹接口（见方案 §3.4），粘过来直接说清楚，
  /// 别让它落进「没认出歌单 id」那句更含糊的提示里。
  static final RegExp _bvRe = RegExp(r'BV[0-9A-Za-z]{10}');

  @override
  void initState() {
    super.initState();
    _p = widget.state.playlistById(widget.playlistId)!;
    _link = TextEditingController(text: _p.syncLink);
    _parsed = parsePlaylistLink(_p.syncLink);
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  void _onLinkChanged(String raw) {
    final text = raw.trim();
    final parsed = parsePlaylistLink(text);
    // 链接原文照存（用户在编辑途中关掉弹窗，下次打开还得是这一串）；
    // 只有在真解出 id 时才动音源与 id —— 半截链接不该把配置改坏。
    widget.state.setPlaylistSync(
      _p.id,
      link: text,
      source: parsed == null || parsed.source.isEmpty ? null : parsed.source,
      playlistId: parsed?.id,
    );
    setState(() => _parsed = parsed);
  }

  Future<void> _runSync() async {
    if (_running) return;
    setState(() {
      _running = true;
      _runText = '';
    });
    final run =
        await widget.state.syncPlaylist(_p.id, trigger: 'manual', silent: false);
    if (!mounted) return;
    setState(() {
      _running = false;
      _runText = switch (run?.reason) {
        null => '还没有链接或音源，先在上面填好',
        'empty' => '音源返回空，本地未改动',
        'fail' => '拉取失败，本地未改动',
        _ => run!.added == 0 && run.removed == 0
            ? '已是最新，没有变化'
            : '新增 ${run.added} 首，移除 ${run.removed} 首',
      };
    });
  }

  String get _hint {
    final text = _link.text.trim();
    if (text.isEmpty) return '把音源那边的歌单链接粘到上面';
    if (_bvRe.hasMatch(text)) return '暂不支持 B站歌单同步';
    final parsed = _parsed;
    if (parsed == null) return '没认出歌单 id —— 支持 QQ 与网易云的歌单链接';
    final name = parsed.source == 'netease'
        ? '网易云歌单'
        : parsed.source == 'qq'
            ? 'QQ 歌单'
            : '歌单';
    return '已识别：$name ${parsed.id}';
  }

  /// 上一轮同步的短状态行
  String get _status {
    if (_runText.isNotEmpty) return _runText;
    if (_p.syncLastAt == 0) return '还没有同步过';
    final t = DateTime.fromMillisecondsSinceEpoch(_p.syncLastAt);
    final hm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    return switch (_p.syncLastResult) {
      'ok' => '上次同步 $hm · 完成',
      'empty' => '上次同步 $hm · 音源返回空，本地未改动',
      'fail' => '上次同步 $hm · 拉取失败',
      _ => '上次同步 $hm',
    };
  }

  bool get _statusBad =>
      _runText.contains('失败') || _p.syncLastResult == 'fail';

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final source = _p.syncSource;

    return AppModalCard(
      maxWidth: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppModalHeader(
            title: '同步设置 · ${_p.name}',
            onClose: () => Navigator.of(context).pop(),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Label('音源', c),
                  Row(
                    children: [
                      AppButton(
                        label: 'QQ 音乐',
                        variant: source == 'netease'
                            ? AppButtonVariant.secondary
                            : AppButtonVariant.accent,
                        onPressed: () {
                          widget.state.setPlaylistSync(_p.id, source: 'qq');
                          setState(() {});
                        },
                      ),
                      const SizedBox(width: 8),
                      AppButton(
                        label: '网易云音乐',
                        variant: source == 'netease'
                            ? AppButtonVariant.accent
                            : AppButtonVariant.secondary,
                        onPressed: () {
                          widget.state
                              .setPlaylistSync(_p.id, source: 'netease');
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  _Label('歌单链接', c),
                  AppTextField(
                    controller: _link,
                    hint: '粘贴 QQ / 网易云歌单链接',
                    onChanged: _onLinkChanged,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _hint,
                    style: TextStyle(fontSize: 12, color: c.textTertiary),
                  ),
                  const SizedBox(height: 16),

                  _Label('同步机制', c),
                  Row(
                    children: [
                      for (final m in PlaylistSyncMode.values) ...[
                        if (m != PlaylistSyncMode.values.first)
                          const SizedBox(width: 8),
                        AppButton(
                          label: m.label,
                          variant: _p.syncMode == m
                              ? AppButtonVariant.accent
                              : AppButtonVariant.secondary,
                          onPressed: () {
                            widget.state
                                .setPlaylistSync(_p.id, mode: m);
                            setState(() {});
                          },
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _p.syncMode == PlaylistSyncMode.frozen
                        ? '完全单向：歌单由音源决定，本地不能增、删、排序（改歌名/歌词/封面照旧）'
                        : _p.syncMode == PlaylistSyncMode.add
                            ? '增加单向：音源新增的会置顶拉进来，本地已删的不再加回'
                            : '兼容单向：音源的增删都跟随，本地手动加的那几首不会被删',
                    style: TextStyle(fontSize: 12, color: c.textTertiary),
                  ),
                  const SizedBox(height: 16),

                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '自动同步',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: c.textSecondary,
                          ),
                        ),
                      ),
                      AppToggle(
                        value: _p.syncEnabled,
                        onChanged: (v) {
                          widget.state
                              .setPlaylistSync(_p.id, enabled: v);
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  if (_p.syncBlacklist.isNotEmpty) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '已忽略 ${_p.syncBlacklist.length} 首（同步不会再加回来）',
                            style: TextStyle(fontSize: 12, color: c.textTertiary),
                          ),
                        ),
                        AppButton(
                          label: '清空',
                          small: true,
                          onPressed: () {
                            widget.state.clearPlaylistSyncBlacklist(_p.id);
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],

                  Row(
                    children: [
                      if (_running) ...[
                        const AppSpinner(size: 16),
                        const SizedBox(width: 8),
                        Text(
                          '正在同步…',
                          style: TextStyle(
                              fontSize: 12, color: c.textSecondary),
                        ),
                      ] else
                        AppButton(
                          label: '立即同步',
                          variant: AppButtonVariant.primary,
                          icon: AppIcons.refresh,
                          onPressed: _runSync,
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _status,
                          style: TextStyle(
                            fontSize: 12,
                            color: _statusBad ? c.danger : c.textTertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.borderSubtle)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AppButton(
                  label: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 字段标题 —— 与 `dialogs.dart` 里那个私有的 `_FieldLabel` 同一套观感。
/// 那个是文件私有的，这里没法复用，尺寸与颜色照着它写。
class _Label extends StatelessWidget {
  const _Label(this.text, this.c);

  final String text;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: c.textSecondary,
        ),
      ),
    );
  }
}
