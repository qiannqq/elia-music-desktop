# Elia Music Desktop — 伊莉雅音乐播放器

<p align="center">
  <img src="old-desktop/elia.png" width="30%" height="30%">
</p>

> 一款基于 **Flutter** 构建的桌面端音乐播放器，支持搜索、试听、歌单导入与批量下载。

本项目是原 Electron 版本（保留在 `old-desktop/`）的**完整重构**：用 Flutter 替换 Electron，
原有的功能机制与界面样式保持不变。

## 接入的平台

- **网易云音乐**、**QQ音乐**、Bilibili 视频音频（已有计划，待接入）

## 功能

- **歌曲搜索** — 通过 QQ / 网易云 音乐 搜索歌曲、歌手、专辑
- **歌单导入** — 粘贴 QQ / 网易云 音乐歌单 / 歌曲 / 专辑链接，一键导入
- **在线试听** — 内置播放器，支持歌词同步滚动显示
- **歌曲下载** — 单首 / 批量下载 MP3，支持自定义保存路径
- **高品质模式** — 配置 Cookie 后可获取 320kbps 资源及 VIP 歌曲
- **歌单管理** — 本地歌单管理，支持全选、反选、导出 Markdown
- **多主题** — 浅色 / 深色 / 跟随系统
- **界面缩放** — 75% ~ 150%，支持 Ctrl + 滚轮 / Ctrl + 0 复位

## 技术栈

| 层面 | 技术 |
|------|------|
| 框架 | Flutter 3.47 + Dart 3.13 |
| UI | Flutter Widget（一对一还原原 CSS 设计令牌） |
| 窗口 | window_manager（无边框 + 自绘标题栏） |
| 音频 | audioplayers |
| 本地服务 | dart:io HttpServer（沿用原 17071 端口与全部 API 路由） |
| 图标 | flutter_svg（沿用原版 SVG 路径数据） |

## 架构说明

原 Electron 版本分为「主进程（Node 服务）+ 渲染进程（原生 HTML/CSS/JS）」两层，
两者通过本地 HTTP（`127.0.0.1:17071`）通信。重构后：

```
lib/
├── main.dart                 # 入口：初始化路径/存储/日志 → 启动 HTTP 服务 → 建窗
├── core/                     # 基础设施
│   ├── app_paths.dart        #   便携式路径（data/logs/temp 全部锚定可执行目录）
│   ├── file_logger.dart      #   ← electron/service/logger.js
│   ├── local_store.dart      #   localStorage 等价实现
│   ├── app_theme.dart        #   ← app.css 的 CSS 变量
│   └── lyric.dart            #   LRC 解析
├── models/song.dart          #   ← normalizeSong() / trimSong()
├── services/
│   ├── qqmusic_service.dart  #   ← electron/service/qqmusic.js（含 QRC 歌词 DES 解密）
│   ├── netease_service.dart  #   ← electron/service/netease.js
│   ├── http_server.dart      #   ← electron/service/httpserver.js（路由 1:1）
│   ├── api_client.dart       #   ← public/dist/js/api.js
│   └── player_controller.dart#   ← public/dist/js/player.js
├── state/                    # 全局状态（ChangeNotifier）
│   ├── app_state.dart        #   ← public/dist/js/app.js 的 state + App 对象
│   ├── theme_controller.dart #   ← public/dist/js/theme.js
│   └── toast.dart            #   ← showToast / updateToast / dismissToast
└── ui/                       # 界面
    ├── icons.dart            #   原版内联 SVG 路径
    ├── app_shell.dart        #   外壳（标题栏 + 侧边栏 + 页面 + 播放器栏 + 缩放）
    ├── titlebar.dart / sidebar.dart / player_bar.dart
    ├── pages/                #   搜索 / 歌单 / 设置 / 关于
    ├── dialogs/              #   歌词弹窗
    └── widgets/              #   通用组件 / 模态框 / 对话框 / 歌曲操作按钮
```

**保留的机制**：本地 HTTP API 服务（同端口、同路由、同响应结构）、Cookie 请求头透传
（`X-QQMusic-Cookie` / `X-NetEase-Cookie`）、音频与图片代理（含 Range 透传）、
按天滚动的文件日志、便携式数据目录。

## 开发环境

> ⚠️ 本仓库的开发环境**全部位于项目内 `.dev/` 目录**（Flutter SDK、pub 缓存、临时文件），
> 不向 C 盘写入任何内容。`.dev/` 已在 `.gitignore` 中排除。

```bash
# 1. 启用便携环境（Git Bash）
source .dev/env.sh

# 2. 运行
elia_flutter run -d windows

# 3. 构建
elia_flutter build windows --release
```

构建产物：`build/windows/x64/runner/Release/`

### 原生工具链要求

| 组件 | 本机位置 |
|------|----------|
| Visual Studio 2022（NativeDesktop 工作负载） | `E:\Program Files\Microsoft Visual Studio\2022\Community` |
| MSVC 工具集 | 14.44.35207 (v143) |
| Windows 11 SDK | `E:\Windows Kits\10\10.0.26100.0` |

### 已知环境坑（脚本已处理）

1. **`%PROGRAMFILES(X86)%` 缺失** — flutter_tools 用它定位 `vswhere.exe`，
   缺失会直接报错退出。Git Bash 无法 `export` 含括号的变量名，故用 `elia_flutter`
   包装函数通过 `env` 注入。
2. **本机未开启开发者模式** — Flutter 用目录**符号链接**挂载插件会失败
   （`Cannot create link ... 系统找不到指定的文件`）。由于 flutter_tools 的逻辑是
   「链接已存在则跳过」，改用 **junction** 预建：
   `python .dev/fix_plugin_links.py windows`（每次 `flutter pub get` 后运行）。
3. **回环地址被代理** — 若终端设置了 `HTTP_PROXY`，Dart 连接 `flutter_tester`
   的 WebSocket 会被绕进代理并报 `Invalid WebSocket upgrade request`。
   `env.sh` 已设置 `NO_PROXY=127.0.0.1,localhost`。
4. **Git Bash 路径形式** — `PATH` 用 POSIX 形式（`/d/...`），
   但传给原生程序的变量（`PUB_CACHE`/`TMP`/`TEMP`）必须用 Windows 形式（`D:/...`），
   否则会被解析成 `D:\d\desk\...` 这种错误路径。

## 使用说明

### Cookie 配置

登录 [y.qq.com](https://y.qq.com) / [music.163.com](https://music.163.com)，
按 F12 打开开发者工具 → Application → Cookies，复制 Cookie 字符串粘贴至「设置」页面。
配置后即可下载高品质及 VIP 歌曲。

### 歌单导入

在搜索框粘贴 QQ / 网易云 音乐歌单链接（如 `https://y.qq.com/n/yqq/playlist/123456.html`、
`https://music.163.com/playlist?id=123456789`），自动解析并导入。

### 快捷键

| 快捷键 | 功能 |
|--------|------|
| `Ctrl` + 滚轮 | 界面缩放 |
| `Ctrl` + `0` | 缩放复位到 100% |
| `Enter` | 搜索 |
| `Ctrl+S` / `Esc` | 歌词编辑：保存 / 取消 |

## 运行时数据

便携式布局，全部位于可执行文件同级目录：

```
<可执行目录>/
├── data/local_storage.json   # 设置、歌单、Cookie、下载记录
├── logs/YYYY-MM-DD.log       # 按天滚动的运行日志
└── temp/                     # 临时文件
```

## 测试

```bash
elia_flutter test
```

覆盖 LRC 解析、时间格式化、文件名清洗、Song 序列化、Cookie 解析、QRC 解密密钥长度。

## 致谢

- [Flutter](https://flutter.dev) — 应用框架
- [QQ Music](https://y.qq.com) — 音乐数据来源
- [NetEase Music](https://music.163.com) — 音乐数据来源
- Xiaomi Mimo Token plan
- pie-xian
- OpenCode

## 许可证

Apache-2.0
