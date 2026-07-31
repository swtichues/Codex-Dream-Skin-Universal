@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\scripts\start-dream-skin.ps1" -PromptRestart
if errorlevel 1 pause
