[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$engineScripts = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\engine\scripts'

try {
  if (-not (Test-Path -LiteralPath $engineScripts)) {
    throw '尚未完成首次安装。请先运行 01_首次安装主题.cmd。'
  }
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  . (Join-Path $engineScripts 'common-windows.ps1')
  . (Join-Path $engineScripts 'theme-windows.ps1')

  $dialog = [System.Windows.Forms.OpenFileDialog]::new()
  $dialog.Title = '选择 Codex Dream Skin 背景图'
  $dialog.Filter = 'Image files|*.png;*.jpg;*.jpeg;*.webp|All files|*.*'
  $dialog.Multiselect = $false
  try {
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }
    $stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
    $null = Set-DreamSkinActiveTheme -ImagePath $dialog.FileName -Theme $null -StateRoot $stateRoot
    Set-DreamSkinPaused -Paused $false -StateRoot $stateRoot | Out-Null
  } finally {
    $dialog.Dispose()
  }

  $startScript = Join-Path $engineScripts 'start-dream-skin.ps1'
  & powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File $startScript -PromptRestart
  if ($LASTEXITCODE -ne 0) { throw '皮肤重新应用失败。' }
  [void][System.Windows.Forms.MessageBox]::Show(
    '背景图已更新并重新应用。',
    'Codex Dream Skin',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
  )
} catch {
  [void][System.Windows.Forms.MessageBox]::Show(
    $_.Exception.Message,
    'Codex Dream Skin',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  )
  exit 1
}
