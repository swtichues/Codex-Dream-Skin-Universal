@echo off
setlocal EnableExtensions
chcp 65001 >nul
set "ROOT=%~dp0"
echo 正在扫描 Windows、Node.js、ChatGPT/Codex 桌面客户端、API 环境、CODEX_HOME 与 CDP 端口...
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%ROOT%windows\scripts\scan-and-configure.ps1" -Configure
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo 环境扫描与配置完成，可以继续运行 01_首次安装主题.bat。
) else (
  echo 扫描发现需要处理的项目。请查看上方结果和 %%LOCALAPPDATA%%\CodexDreamSkin\environment-report.txt。
)
pause
exit /b %RC%
