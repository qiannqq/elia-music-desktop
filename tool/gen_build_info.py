#!/usr/bin/env python3
"""把当前提交写进 lib/core/build_info.dart。

关于页要能说清「这个 exe 是从哪个提交编出来的」—— 不然拿到一个构建产物，
根本对不上代码。构建前跑一次即可：`.dev/env.sh` 里的 `elia_flutter` 包装
和 CI 都会自动调用。

工作区有未提交改动时，哈希后面会带一个 `+`，跟 `git describe` 的习惯一致 ——
这样一眼能看出「这个包不是干净提交编的」。
"""

import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def git(*args: str) -> str:
    # 必须显式指定 utf-8：不指定时 Windows 按 locale 编码（cp1252）解码子进程输出，
    # git 返回的中文提交信息一读就 UnicodeDecodeError，脚本直接崩。
    # errors="replace" 是兜底：万一 git 吐出非 UTF-8 字节，也别让构建挂在这。
    r = subprocess.run(
        ["git", *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return r.stdout.strip() if r.returncode == 0 else ""


def dart_string(value: str) -> str:
    """包成 Dart 的字符串字面量。`$` 在 Dart 里是插值，必须转义。"""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")
    return f'"{escaped}"'


def main() -> None:
    sha = git("rev-parse", "--short", "HEAD") or "unknown"
    title = git("log", "-1", "--format=%s") or "(未知提交)"
    date = git("log", "-1", "--format=%cd", "--date=format:%Y-%m-%d %H:%M")
    dirty = bool(git("status", "--porcelain"))

    out = ROOT / "lib" / "core" / "build_info.dart"
    out.write_text(
        "// 由 tool/gen_build_info.py 生成，不要手改。\n"
        "//\n"
        "// 关于页显示的就是这里的内容：构建产物得能说清自己是从哪个提交编出来的。\n"
        "\n"
        "/// 构建所用的提交（短哈希）。工作区有未提交改动时会带 `+` 后缀。\n"
        f"const String kBuildCommit = {dart_string(sha + ('+' if dirty else ''))};\n"
        "\n"
        "/// 该提交的标题 —— 鼠标停在提交号上时显示。\n"
        f"const String kBuildCommitTitle = {dart_string(title)};\n"
        "\n"
        "/// 构建时间。\n"
        f"const String kBuildTime = {dart_string(date)};\n",
        encoding="utf-8",
    )
    print(f"build_info.dart: {sha}{'+' if dirty else ''}  {title}")


if __name__ == "__main__":
    main()
