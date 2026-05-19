# Elia Music Desktop — 伊莉雅音乐播放器

<p align="center">
  <img src="elia.png" width="30%" height="30%">
</p>

> 一款基于 Electron 构建的桌面端音乐播放器，支持搜索、试听、歌单导入与批量下载。

## 功能

- **歌曲搜索** — 通过 QQ 音乐 API 搜索歌曲、歌手、专辑
- **歌单导入** — 粘贴 QQ 音乐歌单 / 歌曲 / 专辑链接，一键导入
- **在线试听** — 内置播放器，支持歌词同步滚动显示
- **歌曲下载** — 单首 / 批量下载 MP3，支持自定义保存路径
- **高品质模式** — 配置 QQ 音乐 Cookie 后可获取 320kbps 资源及 VIP 歌曲
- **歌单管理** — 本地歌单管理，支持全选、反选、导出 Markdown
- **多主题** — 浅色 / 深色 / 跟随系统
- **Windows SMTC** — 系统媒体控件集成（播放/暂停/上一曲/下一曲）
- **Lyricify Lite** — 第三方歌词同步工具兼容

## 技术栈

| 层面 | 技术 |
|------|------|
| 框架 | Electron 39 + electron-egg (ee-core) |
| 前端 | 原生 HTML / CSS / JavaScript（无框架依赖） |
| 构建 | electron-builder + ee-bin |

## 快速开始

```bash
# 1. 安装依赖
npm install

# 2. 开发运行
npm run dev
```

也可直接运行 `dev.bat`（Windows）。

## 构建

```bash
# Windows (NSIS 安装包)
npm run build-w

# Windows (便携版)
npm run build-we

# Windows (7z 压缩包)
npm run build-w-7z

# macOS (Intel)
npm run build-m

# macOS (Apple Silicon)
npm run build-m-arm64

# Linux (AppImage)
npm run build-l
```

构建产物输出至 `out/` 目录。

## 使用说明

### Cookie 配置
登录 [y.qq.com](https://y.qq.com)，按 F12 打开开发者工具 → Application → Cookies，复制 Cookie 字符串粘贴至"设置"页面。配置后即可下载高品质及 VIP 歌曲。

### 歌单导入
在搜索框粘贴 QQ 音乐歌单链接（如 `https://y.qq.com/n/yqq/playlist/123456.html`），自动解析并导入。

## 目录结构

```
elia-music-desktop/
├── electron/          # 主进程代码
│   ├── config/        # 配置文件
│   ├── controller/    # IPC 控制器
│   ├── preload/       # 预加载脚本与生命周期
│   └── service/       # 业务服务（QQMusic API、HTTP Server、日志）
├── public/
│   ├── dist/          # 前端静态资源（HTML/CSS/JS）
│   └── images/        # 图标资源
├── cmd/               # electron-builder 配置与 ee-bin 配置
├── build/             # 构建资源（图标、额外资源）
├── button/            # Win11 亚克力悬浮菜单组件
└── scripts/           # 构建辅助脚本
```

## 致谢

- [Electron Egg](https://github.com/dromara/electron-egg) — 桌面应用框架
- [QQ Music](https://y.qq.com) — 音乐数据来源
- Xiaomi Mimo Token plan
- pie-xian

## 许可证

Apache-2.0
