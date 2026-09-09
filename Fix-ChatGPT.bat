@echo off
chcp 65001 >nul
title ChatGPT Windows Repair

set "SCRIPT=%~dp0Fix-ChatGPT.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo [FAIL] 未找到 Fix-ChatGPT.ps1
    echo.
    echo 请确保下面两个文件放在同一个文件夹：
    echo   Fix-ChatGPT.bat
    echo   Fix-ChatGPT.ps1
    echo.
    pause
    exit /b 1
)

echo.
echo ==============================================
echo    ChatGPT Windows Runtime Repair Launcher
echo ==============================================
echo.
echo 正在启动修复脚本...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

echo.
echo ==============================================
echo 修复脚本已结束。
echo ==============================================
echo.
pause
