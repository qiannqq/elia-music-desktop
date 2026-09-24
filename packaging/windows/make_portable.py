#!/usr/bin/env python3
"""把 build/windows/x64/runner/Release 打成便携版 zip。

产物直接放 dist/，zip 内带一层顶层目录，避免解压后散一地 dll。
"""
import os
import re
import shutil
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RELEASE = os.path.join(ROOT, "build", "windows", "x64", "runner", "Release")
DIST = os.path.join(ROOT, "dist")

# 版本号取 pubspec.yaml，去掉 build number（1.1.0-alpha-002+6 -> 1.1.0-alpha-002）
with open(os.path.join(ROOT, "pubspec.yaml"), encoding="utf-8") as f:
    version_full = re.search(r"^version:\s*(\S+)", f.read(), re.M).group(1)
VERSION = version_full.split("+")[0]

NAME = f"EliaMusic-{VERSION}-Portable-x64"
STAGE = os.path.join(DIST, NAME)

if not os.path.isfile(os.path.join(RELEASE, "elia_music.exe")):
    sys.exit(f"未找到构建产物：{RELEASE}\\elia_music.exe")

if os.path.isdir(STAGE):
    shutil.rmtree(STAGE)
os.makedirs(STAGE)

shutil.copy2(os.path.join(RELEASE, "elia_music.exe"), STAGE)
for entry in os.listdir(RELEASE):
    if entry.lower().endswith(".dll"):
        shutil.copy2(os.path.join(RELEASE, entry), STAGE)
# 空 native assets 清单：runner 启动时可能会去找它
na = os.path.join(RELEASE, "native_assets.json")
if os.path.isfile(na):
    shutil.copy2(na, STAGE)
shutil.copytree(os.path.join(RELEASE, "data"), os.path.join(STAGE, "data"))

with open(os.path.join(STAGE, "启动伊莉雅音乐播放器.bat"), "w", encoding="utf-8") as f:
    f.write('@echo off\nstart "" "%~dp0elia_music.exe"\n')

readme = """Elia Music - 便携版

版本: {version}
平台: Windows x64（64 位）

使用方法:
  双击 elia_music.exe，或双击「启动伊莉雅音乐播放器.bat」即可运行。
  整个目录可以随意移动/拷贝到 U 盘，配置和数据保存在程序目录下。

GitHub: https://github.com/qiannqq/elia-music-desktop
""".format(version=VERSION)
with open(os.path.join(STAGE, "说明.txt"), "w", encoding="utf-8-sig", newline="\r\n") as f:
    f.write(readme)

zip_path = os.path.join(DIST, NAME + ".zip")
if os.path.exists(zip_path):
    os.remove(zip_path)
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dirpath, _dirnames, filenames in os.walk(STAGE):
        for filename in filenames:
            full = os.path.join(dirpath, filename)
            z.write(full, os.path.join(NAME, os.path.relpath(full, STAGE)))

shutil.rmtree(STAGE)
print(f"[ok] {zip_path}  ({os.path.getsize(zip_path) / 1024 / 1024:.2f} MB)")
