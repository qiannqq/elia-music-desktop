#!/usr/bin/env python3
"""把 ffmpeg.exe 取到 `windows/third_party/ffmpeg/` 下 —— 播放器**自带**解码器，
不依赖用户机器上装没装 ffmpeg。

播放器只用它做两件事：解 B站视频流、把画面缩到背景尺寸。
别的（转码、滤镜、编码）一概不用，所以不装整套、也不要 ffplay/ffprobe。

取法两种：

  * 默认：下载 gyan.dev 的官方 release-essentials（只留其中的 `bin/ffmpeg.exe`）；
  * `--local`：直接复制本机已有的一份 —— 离线、秒完，但体积取决于本机那份
    （gyan 的 full 构建比 essentials 大 40% 左右）。

产物**不入库**（见 .gitignore），构建时由 `windows/runner/CMakeLists.txt`
拷到 exe 旁边，打包脚本再把它带进 zip / 安装包。
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST_DIR = os.path.join(ROOT, "windows", "third_party", "ffmpeg")
DEST = os.path.join(DEST_DIR, "ffmpeg.exe")

URL = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"

# 本机可能已经有一份（`--local` 用；按顺序找第一个存在的）
LOCAL_CANDIDATES = [
    r"D:\FFmpeg\bin\ffmpeg.exe",
    r"E:\FFmpeg\bin\ffmpeg.exe",
    r"C:\FFmpeg\bin\ffmpeg.exe",
    r"C:\ffmpeg\bin\ffmpeg.exe",
]


def human(n: int) -> str:
    return f"{n / 1024 / 1024:.1f}MB"


def find_local() -> str | None:
    for c in LOCAL_CANDIDATES:
        if os.path.isfile(c):
            return c
    try:
        r = subprocess.run(
            ["where", "ffmpeg"], capture_output=True, text=True, encoding="utf-8"
        )
        if r.returncode == 0:
            for line in r.stdout.splitlines():
                line = line.strip()
                if line and os.path.isfile(line):
                    return line
    except Exception:
        pass
    return None


def copy_local(src: str) -> None:
    os.makedirs(DEST_DIR, exist_ok=True)
    shutil.copy2(src, DEST)


def download_and_extract(proxy: str | None = None) -> None:
    os.makedirs(DEST_DIR, exist_ok=True)
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({'http': proxy, 'https': proxy})
        if proxy
        else urllib.request.ProxyHandler()
    )
    with tempfile.TemporaryDirectory() as tmp:
        zip_path = os.path.join(tmp, "ffmpeg.zip")
        # 这个包有一百多 MB，慢链路上很容易断 —— **断点续传**，
        # 断了就从已经下到的字节继续，最多重试 8 次。
        for attempt in range(1, 9):
            have = os.path.getsize(zip_path) if os.path.exists(zip_path) else 0
            req = urllib.request.Request(URL)
            if have:
                req.add_header("Range", f"bytes={have}-")
            try:
                with opener.open(req, timeout=60) as res:
                    total = int(res.headers.get("Content-Length") or 0)
                    if res.status == 200 and have:
                        have = 0  # 服务端不支持续传：重头来
                    total += have
                    if have == 0:
                        print(f"[ffmpeg] 下载 {URL}")
                    else:
                        print(f"[ffmpeg] 续传 {URL}（已有 {human(have)}）")
                    mode = "ab" if have else "wb"
                    got = have
                    step = got // (10 << 20)
                    with open(zip_path, mode) as f:
                        while True:
                            chunk = res.read(1 << 20)
                            if not chunk:
                                break
                            f.write(chunk)
                            got += len(chunk)
                            if got // (10 << 20) > step:
                                step = got // (10 << 20)
                                pct = f"{got * 100 // total}%" if total else "?"
                                print(f"[ffmpeg]   {human(got)} / {human(total)}  {pct}")
                size = os.path.getsize(zip_path)
                if total and size < total:
                    raise IOError(f"只下到 {human(size)} / {human(total)}")
                break
            except Exception as e:
                if attempt == 8:
                    raise
                print(f"[ffmpeg] 断了（{e}），重试 {attempt}/8")

        with zipfile.ZipFile(zip_path) as z:
            member = next(
                (
                    n
                    for n in z.namelist()
                    if n.replace("\\", "/").endswith("bin/ffmpeg.exe")
                ),
                None,
            )
            if member is None:
                sys.exit("[ffmpeg] 压缩包里没找到 bin/ffmpeg.exe")
            with z.open(member) as src, open(DEST, "wb") as out:
                shutil.copyfileobj(src, out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--local", action="store_true", help="用本机已有的那份，不下载")
    ap.add_argument("--force", action="store_true", help="已经有了也重新取")
    ap.add_argument("--proxy", default=os.environ.get("HTTPS_PROXY") or None,
                    help="下载走这个代理（默认读 HTTPS_PROXY）")
    args = ap.parse_args()

    if os.path.isfile(DEST) and not args.force:
        print(f"[ffmpeg] 已有 {DEST}（{human(os.path.getsize(DEST))}），跳过")
        return

    if args.local:
        src = find_local()
        if src is None:
            sys.exit("[ffmpeg] 本机没找到 ffmpeg（去掉 --local 让它下载）")
        print(f"[ffmpeg] 复制 {src}")
        copy_local(src)
        print(f"[ffmpeg] -> {DEST} ({human(os.path.getsize(DEST))})")
        return

    try:
        download_and_extract(args.proxy)
    except Exception as e:  # 下载失败就退回本机那份，别把构建卡死
        src = find_local()
        if src is None:
            sys.exit(f"[ffmpeg] 下载失败（{e}），本机也没有可用的 ffmpeg")
        print(f"[ffmpeg] 下载失败（{e}），改用本机那份 {src}")
        copy_local(src)
    print(f"[ffmpeg] -> {DEST} ({human(os.path.getsize(DEST))})")


if __name__ == "__main__":
    main()
