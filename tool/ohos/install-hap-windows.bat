@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

echo ========================================================
echo   帐屿 / TallyIsle — 鸿蒙设备一键安装助手 (Windows)
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

echo [1/4] 已找到调试工具: "!HDC_CMD!"

:: 2. Check connected HarmonyOS device
echo.
echo 正在检测已连接的鸿蒙设备...
set "DEVICE_ID="
for /f "delims=" %%D in ('"!HDC_CMD!" list targets 2^>nul') do (
    if not "%%D"=="" if not "%%D"=="[Empty]" (
        set "DEVICE_ID=%%D"
    )
)

if not defined DEVICE_ID (
    echo [错误] 未检测到已连接的鸿蒙设备！
    echo 请确认：
    echo   1. 手机已通过数据线连接电脑（或已启动 DevEco 模拟器）；
    echo   2. 手机「设置 - 系统 - 开发者选项」已开启「USB 调试」；
    echo   3. 手机屏幕已解锁并在弹窗中点击「允许 USB 调试」。
    echo.
    pause
    exit /b 1
)

echo [2/4] 已连接设备: !DEVICE_ID!

:: 3. Detect device ABI via const.product.cpu.abilist
set "ABILIST="
for /f "delims=" %%A in ('"!HDC_CMD!" shell param get const.product.cpu.abilist 2^>nul') do (
    if not defined ABILIST set "ABILIST=%%A"
)
set "PRIMARY_ABI="
if defined ABILIST (
    for /f "tokens=1 delims=, " %%A in ("!ABILIST!") do set "PRIMARY_ABI=%%A"
)
set "TARGET_ARCH=arm64"
if /i "!PRIMARY_ABI!"=="x86_64" (
    set "TARGET_ARCH=x64"
) else if /i "!PRIMARY_ABI!"=="arm64-v8a" (
    set "TARGET_ARCH=arm64"
) else if defined ABILIST (
    echo "!ABILIST!" | findstr /i "x86_64" >nul
    if !ERRORLEVEL! EQU 0 (
        echo "!ABILIST!" | findstr /i "arm64-v8a" >nul
        if !ERRORLEVEL! NEQ 0 set "TARGET_ARCH=x64"
    )
)

if defined ABILIST (
    echo [3/4] 设备 ABI: !ABILIST! -^> 选择架构: %TARGET_ARCH%
) else (
    echo [3/4] 设备 ABI: 未能获取（默认回退 arm64-v8a）-^> 选择架构: %TARGET_ARCH%
)

:: 4. Locate HAP file matching target arch (drag-and-drop argument or current folder)
set "HAP_FILE=%~1"
if not defined HAP_FILE (
    for %%F in (
        "%~dp0TallyIsle-HarmonyOS-%TARGET_ARCH%-signed-debug.hap"
        "%~dp0*-%TARGET_ARCH%-signed*.hap"
        "%CD%\TallyIsle-HarmonyOS-%TARGET_ARCH%-signed-debug.hap"
        "%CD%\*-%TARGET_ARCH%-signed*.hap"
        "%~dp0TallyIsle-HarmonyOS-%TARGET_ARCH%-unsigned.hap"
        "%CD%\TallyIsle-HarmonyOS-%TARGET_ARCH%-unsigned.hap"
    ) do (
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
    echo 请把 GitHub Actions 下载解压出的「TallyIsle-HarmonyOS-arm64-signed-debug.hap」或「TallyIsle-HarmonyOS-x64-signed-debug.hap」放到本脚本同一目录，或直接拖到本脚本图标上！
    echo.
    pause
    exit /b 1
)

echo "!HAP_FILE!" | findstr /i "unsigned" >nul
if %ERRORLEVEL% EQU 0 (
    echo [警告] 检测到未签名安装包: "!HAP_FILE!"
    echo 鸿蒙真机无法直接安装未签名包（会报错 9568320）。
    echo 请先配置 GitHub Secrets 生成「TallyIsle-HarmonyOS-%TARGET_ARCH%-signed-debug.hap」（ARM64 真机为「TallyIsle-HarmonyOS-arm64-signed-debug.hap」，x86_64 模拟器/设备为「TallyIsle-HarmonyOS-x64-signed-debug.hap」），或在 DevEco Studio 中打开 ohos 目录自动签名运行。
    echo.
)

echo [4/4] 准备安装包: "!HAP_FILE!"
echo 正在安装帐屿到设备，请稍候...
"!HDC_CMD!" install -r "!HAP_FILE!"
if %ERRORLEVEL% EQU 0 (
    echo.
    echo ========================================================
    echo   安装完成！现在可以在鸿蒙设备桌面上打开「帐屿」体验了。
    echo ========================================================
) else (
    echo.
    echo [提示] 安装返回非零状态码。若提示签名或 UDID 不匹配（如 9568320 / 9568332），
    echo 请在连接本设备后用 DevEco Studio 重新点击一次 Auto Generate Signature 更新调试证书。
)

echo.
pause
