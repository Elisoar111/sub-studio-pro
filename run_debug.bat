@echo off
setlocal

rem ── Subtitle Studio Pro 非正式版（调试）启动脚本 ──
rem 本机 Flutter SDK 与 Git 未加入系统 PATH，需在此显式补充
set "FLUTTER_ROOT=D:\Flutter_SDK\Flutter"
set "PATH=%FLUTTER_ROOT%\bin;D:\Git\cmd;C:\Windows\System32;C:\Windows\System32\WindowsPowerShell\v1.0;%PATH%"

if not exist "%FLUTTER_ROOT%\bin\flutter.bat" (
    echo [错误] 未找到 Flutter SDK：%FLUTTER_ROOT%
    pause
    exit /b 1
)

rem 脚本须放在项目根目录；%~dp0 = 脚本所在目录（路径含空格，引号必须保留）
cd /d "%~dp0"
if not exist "pubspec.yaml" (
    echo [错误] 当前目录不是 Flutter 项目（找不到 pubspec.yaml）：%CD%
    pause
    exit /b 1
)

rem 运行模式：默认 debug；带 profile 参数时用 profile（接近正式版性能，可分析）
set "MODE=--debug"
if /i "%~1"=="profile" set "MODE=--profile"

rem ── 插件符号链接自愈 ──
rem 若在 IDE 沙箱（TRAE）内跑过 flutter pub get / test，.plugin_symlinks 会被
rem 重写为指向沙箱虚拟 pub 缓存，本机 CMake 解析不到该路径，构建时报
rem "add_subdirectory given source ... which is not an existing directory"。
rem 启动前检测链接是否失效，失效则删除并用本机 pub 缓存重建（增量秒级）。
set "NEED_FIX="
if exist "windows\flutter\ephemeral\.plugin_symlinks" (
    if not exist "windows\flutter\ephemeral\.plugin_symlinks\jni\windows" set "NEED_FIX=1"
    if not exist "windows\flutter\ephemeral\.plugin_symlinks\window_manager\windows" set "NEED_FIX=1"
    if not exist "windows\flutter\ephemeral\.plugin_symlinks\url_launcher_windows\windows" set "NEED_FIX=1"
)
if defined NEED_FIX (
    echo [自愈] 插件符号链接失效（指向了外部环境缓存），正在用本机缓存重建...
    rmdir /s /q "windows\flutter\ephemeral\.plugin_symlinks"
    call flutter pub get
    if errorlevel 1 (
        echo [错误] flutter pub get 失败，请检查网络后重试
        pause
        exit /b 1
    )
)

echo ==============================================
echo  Subtitle Studio Pro — 非正式版启动
echo  模式：%MODE:~2%
echo  热重载：终端按 r   热重启：按 R   退出：按 q
echo ==============================================
echo.

flutter run -d windows %MODE%

endlocal
