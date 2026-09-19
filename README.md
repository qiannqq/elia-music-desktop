# Elia Music Desktop — 伊莉雅音乐播放器

<p align="center">
  <img src="elia.png" width="30%" height="30%">
</p>

> 一款基于 Flutter 构建的桌面端音乐播放器，支持搜索、试听、歌单导入与批量下载。

该项目已使用 Flutter 完全重构，原版 Electron 在 master 分支里。

## 接入的平台
- **网易云音乐**、**QQ音乐**、**Bilibili视频音频(已有计划，待接入)**

## 功能

- **歌曲搜索** — 通过 QQ/网易云 音乐 搜索歌曲、歌手、专辑
- **歌单导入** — 粘贴 QQ/网易云 音乐歌单 / 歌曲 / 专辑链接，一键导入
- **在线试听** — 内置播放器，支持逐字歌词同步滚动显示
- **歌曲下载** — 单首 / 批量下载 MP3，支持自定义保存路径
- **高品质模式** — 配置 QQ/网易云 音乐 Cookie 后可获取 320kbps 资源及 VIP 歌曲
- **歌单管理** — 本地歌单管理，支持全选、反选、导出 Markdown
- **多主题** — 浅色 / 深色 / 跟随系统
- **界面缩放** — 滑块调节，或按住 Ctrl 滚轮快捷缩放
- **Windows SMTC** — 系统媒体控件集成（播放/暂停/上一曲/下一曲）
- **Lyricify Lite** — 第三方歌词同步工具兼容

## UI/界面样式

> 界面预览待补充

## 技术栈

| 层面 | 技术 |
|------|------|
| 框架 | Flutter 3（Windows 桌面） |
| 语言 | Dart |
| 音频 | just_audio + 本地 HTTP 代理转发 |
| 构建 | Flutter Windows（MSVC + CMake） |

## 快速开始

```bash
# 1. 获取依赖
flutter pub get

# 2. 开发运行
flutter run -d windows
```

需要 Flutter 3.x 与 Visual Studio（含 C++ 桌面开发工作负载）。

## 构建

```bash
# Release 构建
flutter build windows --release
```

构建产物输出至 `build/windows/x64/runner/Release/`。

## 使用说明

### Cookie 配置
登录 [y.qq.com](https://y.qq.com) / [music.163.com](https://music.163.com)，按 F12 打开开发者工具 → Application → Cookies，复制 Cookie 字符串粘贴至"设置"页面。配置后即可下载高品质及 VIP 歌曲。

### 歌单导入
在搜索框粘贴 QQ/网易云 音乐歌单链接（如 `https://y.qq.com/n/yqq/playlist/123456.html`，`https://music.163.com/playlist?id=123456789`），自动解析并导入。

## 目录结构

```
elia-music-desktop/
├── lib/                    # 应用源码
│   ├── core/               # 主题、歌词解析、本地存储等基础模块
│   ├── models/             # 数据模型
│   ├── services/           # 业务服务（接口、播放器、歌词、下载）
│   ├── state/              # 全局状态
│   └── ui/                 # 界面
│       ├── pages/          # 页面
│       ├── widgets/        # 通用组件
│       └── dialogs/        # 弹窗
├── windows/                # Windows 平台工程（C++ runner）
├── assets/                 # 图标等静态资源
└── test/                   # 测试
```

## 致谢

- Flutter — 桌面应用框架
- [QQ Music](https://y.qq.com) — 音乐数据来源
- [NetEase Music](https://music.163.com) — 音乐数据来源
- workbuddy国际版 — harness
- deepseek-v4.1-flash — 主力开发模型
- 伊莉雅二世 — Agent

## 许可证

GPL-3.0
