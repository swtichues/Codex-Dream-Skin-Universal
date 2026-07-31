@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\scripts\verify-dream-skin.ps1"
echo.
echo 若上方显示 "pass": true，表示皮肤验证通过。
pause
