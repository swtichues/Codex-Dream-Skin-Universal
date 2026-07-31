[CmdletBinding()]
param(
  [ValidateRange(1, 3)][int]$Stage,
  [switch]$Warn,
  [switch]$Fail
)

$ErrorActionPreference = 'Stop'
try {
  $encoding = [System.Text.UTF8Encoding]::new($false)
  [Console]::OutputEncoding = $encoding
  $OutputEncoding = $encoding
} catch {}

if ($Warn) { Write-Warning "GUI 阶段 $Stage 警告状态测试；该提示不应标记为失败。" }
if ($Fail) {
  Write-Error "GUI 阶段 $Stage 失败状态测试。"
  exit 7
}
Write-Host "GUI 阶段 $Stage 返回代码同步测试通过。"
Start-Sleep -Milliseconds 250
exit 0
