@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

echo ========================================================
echo   帐屿 / TallyIsle — 鸿蒙真机一键安装助手 (Windows)
echo ========================================================
echo.

:: 1. Locate hdc.exe
set "HDC_CMD="
where hdc >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    set "HDC_CMD=hdc"
)

if not defined HDC_CMD (
    if exist "%~dp0hdc.exe" set "HDC_CMD=%~dp0hdc.exe"
)

if not defined HDC_CMD (
    for %%P in (
        "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
        "D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
        "%LOCALAPPDATA%\Huawei\Sdk\default\openharmony\toolchains\hdc.exe"
    ) do (
        if not defined HDC_CMD if exist "%%~P" set "HDC_CMD=%%~P"
    )
)

if not defined HDC_CMD (
    echo [错误] 未找到鸿蒙调试工具 hdc.exe。
    echo 请先安装 DevEco Studio，或将 hdc.exe 放到本脚本同一文件夹后再双击运行。
    echo.
    pause
    exit /b 1
)

echo [1/3] 已找到调试工具: "!HDC_CMD!"

:: 2. Locate signed HAP file (drag-and-drop argument or current folder)
set "HAP_FILE=%~1"
if not defined HAP_FILE (
    for %%F in ("%~dp0TallyIsle-HarmonyOS-signed-debug.hap" "%~dp0*-signed*.hap" "%CD%\TallyIsle-HarmonyOS-signed-debug.hap" "%CD%\*-signed*.hap") do (
        if not defined HAP_FILE if exist "%%~fF" set "HAP_FILE=%%~fF"
    )
)
if not defined HAP_FILE (
    for %%F in ("%~dp0*.hap" "%CD%\*.hap") do (
        if not defined HAP_FILE if exist "%%~fF" set "HAP_FILE=%%~fF"
    )
)

if not defined HAP_FILE (
    echo [错误] 未在本文件夹找到 .hap 安装包。
    echo 请把 GitHub Actions 下载解压出的「TallyIsle-HarmonyOS-signed-debug.hap」放到本脚本同一目录，或直接拖到本脚本图标上！
    echo.
    pause
    exit /b 1
)

echo "!HAP_FILE!" | findstr /i "unsigned" >nul
if %ERRORLEVEL% EQU 0 (
    echo [警告] 检测到未签名安装包: "!HAP_FILE!"
    echo 鸿蒙真机无法直接安装未签名包（会报错 9568320）。
    echo 请先配置 GitHub Secrets 生成「TallyIsle-HarmonyOS-signed-debug.hap」，或在 DevEco Studio 中打开 ohos 目录自动签名运行。
    echo.
)

echo [2/3] 准备安装包: "!HAP_FILE!"

:: 3. Check connected HarmonyOS device
echo.
echo 正在检测已连接的鸿蒙手机...
set "DEVICE_ID="
for /f "delims=" %%D in ('"!HDC_CMD!" list targets 2^>nul') do (
    if not "%%D"=="" if not "%%D"=="[Empty]" (
        set "DEVICE_ID=%%D"
    )
)

if not defined DEVICE_ID (
    echo [错误] 未检测到已连接的鸿蒙设备！
    echo 请确认：
    echo   1. 手机已通过数据线连接电脑；
    echo   2. 手机「设置 - 系统 - 开发者选项」已开启「USB 调试」；
    echo   3. 手机屏幕已解锁并在弹窗中点击「允许 USB 调试」。
    echo.
    pause
    exit /b 1
)

echo 已连接设备: !DEVICE_ID!
echo.
echo [3/3] 正在安装帐屿到手机，请稍候...
"!HDC_CMD!" install -r "!HAP_FILE!"
if %ERRORLEVEL% EQU 0 (
    echo.
    echo ========================================================
    echo   安装完成！现在可以在鸿蒙手机桌面上打开「帐屿」体验了。
    echo ========================================================
) else (
    echo.
    echo [提示] 安装返回非零状态码。若提示签名或 UDID 不匹配（如 9568320 / 9568332），
    echo 请在连接本手机后用 DevEco Studio 重新点击一次 Auto Generate Signature 更新调试证书。
)

echo.
pause
