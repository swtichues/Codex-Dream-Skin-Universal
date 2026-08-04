@echo off
setlocal
chcp 65001 >nul
"%~dp0CodexDreamSkinLauncher.exe" -ApplyAndVerify
if errorlevel 1 pause
