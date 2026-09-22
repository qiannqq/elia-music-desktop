@echo off
setlocal enabledelayedexpansion

:: 本文件保存为 UTF-8，不切代码页的话 cmd 会把中文 echo 成乱码
chcp 65001 >nul

:: Elia Music Desktop - Windows 打包脚本
:: 用法：packaging\windows\build.bat

echo ========================================
echo   Elia Music Desktop - Windows 打包
echo ========================================
echo.

:: 设置项目根目录
set "PROJECT_ROOT=%~dp0..\.."
cd /d "%PROJECT_ROOT%"

:: 检查构建产物
set "RELEASE_DIR=build\windows\x64\runner\Release"
if not exist "%RELEASE_DIR%\elia_music.exe" (
    echo [错误] 未找到构建产物，请先运行：
    echo   flutter build windows --release
    echo.
    pause
    exit /b 1
)

:: 读取版本号（pubspec 里是 1.1.0-alpha-001+6，去掉 build number 部分）
for /f "tokens=2 delims=: " %%a in ('findstr /C:"version:" pubspec.yaml') do (
    set "VERSION_FULL=%%a"
    goto :got_version
)
:got_version
for /f "tokens=1 delims=+" %%b in ("%VERSION_FULL%") do set "VERSION=%%b"
echo [信息] 当前版本: %VERSION%
echo.

:: 创建输出目录
set "DIST_DIR=dist"
if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"

:: ========================================
:: 1. 打包 Portable ZIP
:: ========================================
echo [1/2] 正在打包 Portable ZIP...

set "PORTABLE_DIR=%DIST_DIR%\EliaMusic-%VERSION%-Portable-x64"
if exist "%PORTABLE_DIR%" rmdir /s /q "%PORTABLE_DIR%"
mkdir "%PORTABLE_DIR%"

:: 复制文件
echo   复制 elia_music.exe...
copy "%RELEASE_DIR%\elia_music.exe" "%PORTABLE_DIR%\" >nul

echo   复制 DLL 文件...
for %%f in ("%RELEASE_DIR%\*.dll") do (
    copy "%%f" "%PORTABLE_DIR%\" >nul
)

echo   复制 data 目录...
xcopy "%RELEASE_DIR%\data" "%PORTABLE_DIR%\data\" /e /i /q >nul

echo   复制 native_assets.json...
if exist "%RELEASE_DIR%\native_assets.json" copy "%RELEASE_DIR%\native_assets.json" "%PORTABLE_DIR%\" >nul

:: 创建启动脚本
echo @echo off > "%PORTABLE_DIR%\启动伊莉雅音乐播放器.bat"
echo start "" "%%~dp0elia_music.exe" >> "%PORTABLE_DIR%\启动伊莉雅音乐播放器.bat"

:: 创建说明文件
echo Elia Music - 便携版 > "%PORTABLE_DIR%\说明.txt"
echo. >> "%PORTABLE_DIR%\说明.txt"
echo 版本: %VERSION% >> "%PORTABLE_DIR%\说明.txt"
echo 平台: Windows x64 >> "%PORTABLE_DIR%\说明.txt"
echo. >> "%PORTABLE_DIR%\说明.txt"
echo 使用方法: >> "%PORTABLE_DIR%\说明.txt"
echo   双击 elia_music.exe 或 启动伊莉雅音乐播放器.bat 即可运行 >> "%PORTABLE_DIR%\说明.txt"
echo. >> "%PORTABLE_DIR%\说明.txt"
echo GitHub: https://github.com/qiannqq/elia-music-desktop >> "%PORTABLE_DIR%\说明.txt"

:: 打包 ZIP
echo   正在压缩 ZIP...
powershell -Command "Compress-Archive -Path '%PORTABLE_DIR%' -DestinationPath '%DIST_DIR%\EliaMusic-%VERSION%-Portable-x64.zip' -Force"
if errorlevel 1 (
    echo [错误] ZIP 压缩失败！
) else (
    echo [完成] 已生成: %DIST_DIR%\EliaMusic-%VERSION%-Portable-x64.zip
)

:: 清理临时目录
rmdir /s /q "%PORTABLE_DIR%"

echo.

:: ========================================
:: 2. 打包 Setup EXE (Inno Setup)
:: ========================================
echo [2/2] 正在打包 Setup EXE...

:: 检查 Inno Setup（6 / 7，默认安装盘之外的盘符也找一遍）
set "ISCC="
if exist "E:\Program Files\Inno Setup 7\ISCC.exe" (
    set "ISCC=E:\Program Files\Inno Setup 7\ISCC.exe"
) else if exist "C:\Program Files (x86)\Inno Setup 7\ISCC.exe" (
    set "ISCC=C:\Program Files (x86)\Inno Setup 7\ISCC.exe"
) else if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
    set "ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
) else if exist "C:\Program Files\Inno Setup 6\ISCC.exe" (
    set "ISCC=C:\Program Files\Inno Setup 6\ISCC.exe"
)

if "%ISCC%"=="" (
    echo [警告] 未找到 Inno Setup 6，跳过 Setup EXE 打包
    echo   请安装 Inno Setup 6: https://jrsoftware.org/isdl.php
    echo   安装后重新运行此脚本即可
) else (
    echo   使用 Inno Setup: %ISCC%
    "%ISCC%" "packaging\windows\elia_music.iss"
    if errorlevel 1 (
        echo [错误] Setup EXE 打包失败！
    ) else (
        echo [完成] 已生成: %DIST_DIR%\EliaMusic-%VERSION%-Setup-x64.exe
    )
)

echo.
echo ========================================
echo   打包完成！
echo ========================================
echo.
echo 输出目录: %DIST_DIR%\
dir /b "%DIST_DIR%\EliaMusic*"
echo.
pause
