# windows/third_party/ffmpeg

这里放**随包自带**的 `ffmpeg.exe`。

播放器只用它做一件事：把 B站视频流解成帧，给「现在播放页」当背景
（见 `lib/services/video_bg.dart`）。不依赖用户机器上装没装 ffmpeg。

## 怎么来

```
python tool/fetch_ffmpeg.py            # 下载官方 release-essentials，只留 bin/ffmpeg.exe
python tool/fetch_ffmpeg.py --local    # 直接用本机已有的那份（离线、秒完）
```

产物**不入库**（`.gitignore` 里挡了 `windows/third_party/ffmpeg/*.exe`）。

## 它怎么进产物

* 构建：`windows/CMakeLists.txt` 把它 `install` 到 exe 旁边（`OPTIONAL` —— 没有也能编过）；
* 便携版 / 安装包：`packaging/windows/make_portable.py` 与 `elia_music.iss` 各带一份。

缺了它不会报错，只是「视频背景用不了，背景继续用旋转的封面」。
