@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0windows\scripts\change-codex-dream-skin-background.ps1"
if errorlevel 1 pause
