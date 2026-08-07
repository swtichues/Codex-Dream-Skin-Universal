[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
$stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'

try {
  # Keep the installed runtime in sync before choosing an image.  Previously
  # this entry point loaded its scripts from the existing runtime first, so a
  # stale verifier could reject a correctly applied skin after a Codex update.
  . (Join-Path $PSScriptRoot 'common-windows.ps1')
  . (Join-Path $PSScriptRoot 'theme-windows.ps1')
  $null = Install-DreamSkinRuntimeEngine -SkillRoot $sourceRoot -StateRoot $stateRoot

  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $dialog = [System.Windows.Forms.OpenFileDialog]::new()
  $dialog.Title = '选择 Codex Dream Skin 背景图'
  $dialog.Filter = 'Image files|*.png;*.jpg;*.jpeg;*.webp|All files|*.*'
  $dialog.Multiselect = $false
  try {
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }
    $null = Set-DreamSkinActiveTheme -ImagePath $dialog.FileName -Theme $null -StateRoot $stateRoot
    Set-DreamSkinPaused -Paused $false -StateRoot $stateRoot | Out-Null
  } finally {
    $dialog.Dispose()
  }

  # A running watcher can reload the new theme without restarting Codex.
  # Restarting the Store package interrupts API-backed sessions and can leave
  # the model picker with only the custom provider.
  $session = Get-DreamSkinLiveSessionContext -StateRoot $stateRoot
  $liveSession = $false
  if ($null -ne $session) {
    try {
      $savedCodex = Get-DreamSkinCodexInstallFromState -State $session.State
      $identity = if ($null -ne $savedCodex) {
        Get-DreamSkinVerifiedCdpIdentity -Port $session.Port -Codex $savedCodex
      } else { $null }
      $injectorLive = $false
      if ($session.State.injectorPid -and $session.State.injectorStartedAt) {
        $injectorStartedAt = Get-DreamSkinProcessStartedAt -ProcessId ([int]$session.State.injectorPid)
        $injectorLive = $injectorStartedAt -eq "$($session.State.injectorStartedAt)"
      }
      $liveSession = $null -ne $identity -and $identity.BrowserId -ceq $session.BrowserId -and $injectorLive
    } catch {
      $liveSession = $false
    }
  }
  if ($liveSession) {
    [void][System.Windows.Forms.MessageBox]::Show(
      '背景图已更新。当前 Codex 不会重启，皮肤将在片刻后自动刷新。',
      'Codex Dream Skin',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    )
    exit 0
  }

  $startScript = Join-Path $PSScriptRoot 'start-dream-skin.ps1'
  $startOutput = & powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File $startScript -PromptRestart 2>&1
  if ($LASTEXITCODE -ne 0) {
    $detail = ($startOutput | Out-String).Trim()
    if ($detail) { throw "皮肤重新应用失败：$detail" }
    throw '皮肤重新应用失败。'
  }
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
