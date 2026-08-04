@echo off
setlocal
chcp 65001 >nul
"%~dp0CodexDreamSkinLauncher.exe"
if errorlevel 1 pause
