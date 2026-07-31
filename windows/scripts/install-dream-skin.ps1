[CmdletBinding()]
param(
  [int]$Port = 9335,
  [switch]$NoShortcuts,
  [string]$AppExecutable,
  [switch]$ConfigureBaseTheme,
  [switch]$PromptClose,
  [switch]$ForceClose,
  [switch]$CloseTray
)

$ErrorActionPreference = 'Stop'
$PortExplicit = $PSBoundParameters.ContainsKey('Port')
$SkillRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'theme-windows.ps1')

$operationLock = Enter-DreamSkinOperationLock
try {
  Assert-DreamSkinPort -Port $Port
  $null = Get-DreamSkinNodeRuntime
  $targetApp = Get-DreamSkinCodexInstall -AppExecutable $AppExecutable
  $registeredInstalls = @($targetApp)
  foreach ($registeredCodex in @(Get-DreamSkinRegisteredCodexInstalls)) {
    if (-not ($registeredInstalls | Where-Object {
      Test-DreamSkinPathEqual -Left $_.Executable -Right $registeredCodex.Executable
    })) { $registeredInstalls += $registeredCodex }
  }
  if ((Get-DreamSkinCodexProcesses -Codex $targetApp).Count -gt 0) {
    $closeAuthorized = [bool]$ForceClose
    if (-not $closeAuthorized -and $PromptClose) {
      $closeAuthorized = Confirm-DreamSkinRestart `
        -Message '皮肤替换需要重启 Codex，未保存的输入可能丢失。现在继续吗？'
    }
    if (-not $closeAuthorized) {
      throw 'Codex 正在运行。请保存输入并允许皮肤替换阶段重启客户端。'
    }
    Stop-DreamSkinCodex -Codex $targetApp -AllowForce
  }

  $StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  $themePaths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $themePaths.Root -Root $themePaths.Root
  $StatePath = Join-Path $StateRoot 'state.json'
  $existingState = Read-DreamSkinState -Path $StatePath
  $savedPathCandidate = Get-DreamSkinCodexStatePathCandidate -State $existingState
  $savedCodex = Resolve-DreamSkinCodexInstallFromState -State $existingState -RegisteredInstalls $registeredInstalls
  if ($null -ne $savedPathCandidate -and $null -eq $savedCodex -and
    (Get-DreamSkinCodexProcesses -Codex $savedPathCandidate).Count -gt 0) {
    throw 'The saved Codex path is still running but no longer matches a registered Store package. Close it manually before installing.'
  }
  if (Test-DreamSkinTrayActive) {
    if ($CloseTray) {
      Stop-DreamSkinTrayProcess -StateRoot $StateRoot
    } else {
      throw '请先退出 Codex Dream Skin 托盘控制器，或使用 -CloseTray 完成更新。'
    }
  }
  $engine = Install-DreamSkinRuntimeEngine -SkillRoot $SkillRoot -StateRoot $StateRoot
  $null = Initialize-DreamSkinThemeStore -SkillRoot $engine.Root -StateRoot $StateRoot
  Write-DreamSkinTargetConfiguration -Target $targetApp -StateRoot $StateRoot
  if ($ConfigureBaseTheme) {
    $ConfigPath = Get-DreamSkinConfigPath
    $BackupPath = Join-Path $StateRoot 'config.before-dream-skin.toml'
    Install-DreamSkinBaseTheme -ConfigPath $ConfigPath -BackupPath $BackupPath
  }

  if (-not $NoShortcuts) {
    $shell = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $startScript = $engine.Start
    $restoreScript = $engine.Restore
    $trayScript = $engine.Tray
    $portArgument = if ($PortExplicit) { " -Port $Port" } else { '' }

    foreach ($folder in @($desktop, $startMenu)) {
      $shortcut = $shell.CreateShortcut((Join-Path $folder 'Codex Dream Skin.lnk'))
      $shortcut.TargetPath = $powershell
      $shortcut.Arguments = "-NoProfile -ExecutionPolicy RemoteSigned -File `"$startScript`"$portArgument -PromptRestart"
      $shortcut.WorkingDirectory = $engine.Root
      $shortcut.Description = 'Launch the selected ChatGPT/Codex desktop client with Dream Skin'
      $shortcut.Save()
    }

    $restore = $shell.CreateShortcut((Join-Path $desktop 'Codex Dream Skin - Restore.lnk'))
    $restore.TargetPath = $powershell
    $restore.Arguments = "-NoProfile -ExecutionPolicy RemoteSigned -File `"$restoreScript`"$portArgument -PromptRestart"
    $restore.WorkingDirectory = $engine.Root
    $restore.Description = 'Remove Dream Skin and close its CDP session'
    $restore.Save()

    foreach ($folder in @($desktop, $startMenu)) {
      $tray = $shell.CreateShortcut((Join-Path $folder 'Codex Dream Skin - Tray.lnk'))
      $tray.TargetPath = $powershell
      $tray.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$trayScript`"$portArgument"
      $tray.WorkingDirectory = $engine.Root
      $tray.Description = 'Open Codex Dream Skin status and theme controls in the system tray'
      $tray.Save()
    }
    Start-Process -FilePath $powershell -ArgumentList `
      "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$trayScript`"$portArgument" `
      -WindowStyle Hidden | Out-Null
  }

  if ($NoShortcuts) {
    Write-Host "Codex Dream Skin installed for $($targetApp.DisplayName) at $($engine.Root). Run $($engine.Start) to launch it."
  } else {
    Write-Host "Codex Dream Skin installed for $($targetApp.DisplayName). Authentication may use a GPT account or API-backed desktop client; the skin layer is independent of sign-in mode."
  }
} finally {
  Exit-DreamSkinOperationLock -Mutex $operationLock
}
