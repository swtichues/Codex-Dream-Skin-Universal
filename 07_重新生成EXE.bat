@echo off
setlocal EnableExtensions
chcp 65001 >nul
set "ROOT=%~dp0"
echo 正在使用本机 MinGW GCC 离线构建 Windows GUI EXE...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%windows\scripts\build-launcher-exe.ps1"
if errorlevel 1 (
  echo.
  echo EXE 构建失败，请检查 MinGW GCC 与 windres。
  pause
  exit /b 1
)
echo.
echo 构建完成：%ROOT%CodexDreamSkinLauncher.exe
pause
