@echo off
setlocal EnableExtensions
chcp 65001 >nul
set "ROOT=%~dp0"
echo 第一步：扫描并保存桌面客户端目标。
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%ROOT%windows\scripts\scan-and-configure.ps1" -Configure
if errorlevel 2 goto :failed
echo.
echo 请保存工作并关闭 ChatGPT/Codex 桌面客户端，然后按任意键继续安装。
pause >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%windows\scripts\install-dream-skin.ps1"
if errorlevel 1 goto :failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%windows\scripts\start-dream-skin.ps1" -PromptRestart
if errorlevel 1 goto :failed
echo.
echo 安装并启动完成。GPT 账号登录或 API 桌面客户端均使用同一套皮肤注入逻辑。
pause
exit /b 0
:failed
echo.
echo 操作未完成。请查看上方错误和 %%LOCALAPPDATA%%\CodexDreamSkin\environment-report.txt。
echo 注意：纯 API/CLI 没有可换肤界面，必须选择承载 API 的 Electron/Chromium 桌面客户端 EXE。
pause
exit /b 1
