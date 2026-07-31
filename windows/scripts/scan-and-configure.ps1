[CmdletBinding()]
param(
  [int]$Port = 9335,
  [switch]$Configure,
  [string]$AppExecutable,
  [switch]$NoFilePicker,
  [switch]$ConfigureBaseTheme
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common-windows.ps1')

function Add-ReportLine {
  param([string]$Name, [string]$Status, [string]$Detail)
  $script:Report += [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail }
  $prefix = if ($Status -eq 'OK') { '[ OK ]' } elseif ($Status -eq 'WARN') { '[WARN]' } else { '[FAIL]' }
  Write-Host ("{0} {1}: {2}" -f $prefix, $Name, $Detail)
}

function Find-NodeExecutable {
  $candidates = @()
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $command) { $command = Get-Command node -ErrorAction SilentlyContinue }
  if ($command) { $candidates += $command.Source }
  if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'nodejs\node.exe') }
  if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe') }
  if ($env:APPDATA) {
    $candidates += (Join-Path $env:APPDATA 'nvm\current\node.exe')
    $nvmRoot = Join-Path $env:APPDATA 'nvm'
    if (Test-Path -LiteralPath $nvmRoot -PathType Container) {
      $candidates += @(Get-ChildItem -LiteralPath $nvmRoot -Filter node.exe -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName)
    }
  }
  foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    try {
      $probe = Invoke-DreamSkinNative -FilePath $candidate -ArgumentList @('-p', 'process.versions.node') -DiscardStderr
      $version = ($probe.Output -join '').Trim()
      $major = 0
      if ($probe.ExitCode -eq 0 -and [int]::TryParse(($version -split '\.')[0], [ref]$major)) {
        return [pscustomobject]@{ Path = [System.IO.Path]::GetFullPath($candidate); Version = $version; Major = $major }
      }
    } catch {}
  }
  return $null
}

function Add-DirectoryToUserPath {
  param([Parameter(Mandatory = $true)][string]$Directory)
  $full = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\')
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $entries = @($userPath -split ';' | Where-Object { $_ })
  if (-not ($entries | Where-Object { Test-DreamSkinPathEqual -Left $_ -Right $full })) {
    $newPath = (@($entries) + $full) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
  }
  $processEntries = @($env:Path -split ';' | Where-Object { $_ })
  if (-not ($processEntries | Where-Object { Test-DreamSkinPathEqual -Left $_ -Right $full })) {
    $env:Path = "$full;$env:Path"
  }
}

function Select-DesktopClientExecutable {
  if ($NoFilePicker) { return $null }
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '选择通过 API 使用的 ChatGPT/Codex Electron 桌面客户端 EXE'
    $dialog.Filter = 'Windows 应用程序 (*.exe)|*.exe'
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
  } catch {
    Write-Warning "无法打开 EXE 选择框：$($_.Exception.Message)"
  }
  return $null
}

Assert-DreamSkinPort -Port $Port
$Report = @()
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null

Write-Host '=== Codex Dream Skin 环境扫描 ===' -ForegroundColor Cyan
Add-ReportLine -Name 'Windows' -Status 'OK' -Detail ([Environment]::OSVersion.VersionString)
$psStatus = if ($PSVersionTable.PSVersion.Major -ge 5) { 'OK' } else { 'FAIL' }
Add-ReportLine -Name 'PowerShell' -Status $psStatus -Detail "$($PSVersionTable.PSVersion)"

$node = Find-NodeExecutable
if ($null -eq $node) {
  Add-ReportLine -Name 'Node.js' -Status 'FAIL' -Detail '未找到 Node.js；请安装 Node.js 22 LTS 或更高版本。'
} elseif ($node.Major -lt 22) {
  Add-ReportLine -Name 'Node.js' -Status 'FAIL' -Detail "版本过低：$($node.Version)，路径：$($node.Path)"
} else {
  $nodeDirectory = [System.IO.Path]::GetDirectoryName($node.Path)
  if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) {
    if ($Configure) { Add-DirectoryToUserPath -Directory $nodeDirectory }
    $pathText = if ($Configure) { '；已写入当前用户 PATH' } else { '；运行配置模式可加入 PATH' }
    Add-ReportLine -Name 'Node.js' -Status 'WARN' -Detail "$($node.Version)，路径：$($node.Path)$pathText"
  } else {
    Add-ReportLine -Name 'Node.js' -Status 'OK' -Detail "$($node.Version)，路径：$($node.Path)"
  }
}

$codexHome = $null
try {
  $codexHome = Get-DreamSkinCodexHome
  $source = if ($env:CODEX_HOME) { 'CODEX_HOME' } else { '默认目录' }
  Add-ReportLine -Name 'Codex 配置目录' -Status 'OK' -Detail "$codexHome（$source）"
} catch {
  Add-ReportLine -Name 'Codex 配置目录' -Status 'FAIL' -Detail $_.Exception.Message
}
if ($codexHome) {
  $configPath = Join-Path $codexHome 'config.toml'
  if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    Add-ReportLine -Name 'config.toml' -Status 'OK' -Detail "已找到；默认不会修改。路径：$configPath"
  } else {
    Add-ReportLine -Name 'config.toml' -Status 'WARN' -Detail "未找到；不影响 CSS 注入。预期路径：$configPath"
  }
}

$apiConfigured = [bool]("$env:OPENAI_API_KEY".Trim() -or "$env:OPENAI_BASE_URL".Trim() -or
  "$env:OPENAI_API_BASE".Trim())
if ($apiConfigured) {
  Add-ReportLine -Name 'API 环境' -Status 'OK' -Detail '检测到 API 相关环境变量（报告不会记录密钥内容）。'
} else {
  Add-ReportLine -Name 'API 环境' -Status 'WARN' -Detail '未检测到 API 环境变量；GPT 账号直接登录模式不需要这些变量。'
}

$registered = @(Get-DreamSkinRegisteredCodexInstalls)
if ($registered.Count -gt 0) {
  Add-ReportLine -Name '官方桌面应用' -Status 'OK' -Detail (($registered | ForEach-Object {
    "$($_.DisplayName) $($_.Version) [$($_.Executable)]"
  }) -join '；')
} else {
  Add-ReportLine -Name '官方桌面应用' -Status 'WARN' -Detail '未发现可验证的 Microsoft Store ChatGPT/Codex 应用。'
}

$known = @(Get-DreamSkinKnownExecutableTargets)
if ($known.Count -gt 0) {
  Add-ReportLine -Name '非 Store 桌面应用' -Status 'OK' -Detail (($known | ForEach-Object { $_.Executable }) -join '；')
}

$target = $null
try {
  if ($AppExecutable) { $target = Resolve-DreamSkinTargetByExecutable -Executable $AppExecutable }
  else {
    $saved = Read-DreamSkinTargetConfiguration
    if ($saved -and $saved.appExecutable) {
      $target = Resolve-DreamSkinTargetByExecutable -Executable "$($saved.appExecutable)"
    } elseif ($registered.Count -gt 0) {
      $target = $registered[0]
    } elseif ($known.Count -gt 0) {
      $target = $known[0]
    }
  }
} catch {
  Add-ReportLine -Name '已保存目标' -Status 'WARN' -Detail $_.Exception.Message
}

if ($null -eq $target -and $Configure) {
  $selected = Select-DesktopClientExecutable
  if ($selected) { $target = Resolve-DreamSkinTargetByExecutable -Executable $selected }
}

if ($null -ne $target) {
  Add-ReportLine -Name '换肤目标' -Status 'OK' -Detail "$($target.DisplayName)，类型：$($target.TargetKind)，路径：$($target.Executable)"
  if ($Configure) {
    Write-DreamSkinTargetConfiguration -Target $target -StateRoot $StateRoot
    Add-ReportLine -Name '目标配置' -Status 'OK' -Detail (Get-DreamSkinTargetConfigPath -StateRoot $StateRoot)
  }
  $runningCount = (Get-DreamSkinCodexProcesses -Codex $target).Count
  $runStatus = if ($runningCount -gt 0) { 'WARN' } else { 'OK' }
  $runDetail = if ($runningCount -gt 0) { "正在运行 $runningCount 个进程；首次安装前请关闭。" } else { '当前未运行，可执行首次安装。' }
  Add-ReportLine -Name '目标进程' -Status $runStatus -Detail $runDetail
} else {
  Add-ReportLine -Name '换肤目标' -Status 'FAIL' -Detail '没有可配置的桌面客户端。纯 API/CLI 没有可注入界面；请选择承载 API 的 Electron/Chromium 桌面客户端 EXE。'
}

if (Test-DreamSkinPortAvailable -Port $Port) {
  Add-ReportLine -Name "CDP 端口 $Port" -Status 'OK' -Detail '当前可用。'
} elseif ($null -ne $target -and (Test-DreamSkinCodexPortOwner -Port $Port -Codex $target)) {
  Add-ReportLine -Name "CDP 端口 $Port" -Status 'OK' -Detail '已由当前目标应用的 Dream Skin 会话占用。'
} else {
  $alternate = Select-DreamSkinPort -PreferredPort ([Math]::Min(65535, $Port + 1))
  Add-ReportLine -Name "CDP 端口 $Port" -Status 'WARN' -Detail "已被其他程序占用；启动器会自动改用 $alternate 或附近空闲端口。"
}

if ($ConfigureBaseTheme) {
  $configPath = Get-DreamSkinConfigPath
  if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    Add-ReportLine -Name '基础主题配置' -Status 'WARN' -Detail '首次安装时将按显式请求修改 [desktop] 外观项并创建备份。复杂 TOML 仍可能不适合自动改写。'
  } else {
    Add-ReportLine -Name '基础主题配置' -Status 'FAIL' -Detail '请求了配置基础主题，但 config.toml 不存在。'
  }
} else {
  Add-ReportLine -Name '基础主题配置' -Status 'OK' -Detail '安全模式：安装时不修改 API/CLI 的 config.toml。'
}

$reportLines = @(
  'Codex Dream Skin 环境报告',
  "生成时间：$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))",
  ''
) + @($Report | ForEach-Object { "[$($_.Status)] $($_.Name): $($_.Detail)" })
$reportText = $reportLines -join "`r`n"
$reportPath = Join-Path $StateRoot 'environment-report.txt'
Write-DreamSkinUtf8FileAtomically -Path $reportPath -Content ($reportText + "`r`n")
$Report | ConvertTo-Json -Depth 5 | ForEach-Object {
  Write-DreamSkinUtf8FileAtomically -Path (Join-Path $StateRoot 'environment-report.json') -Content ($_ + "`r`n")
}

Write-Host "`n报告已保存：$reportPath" -ForegroundColor Cyan
$failed = @($Report | Where-Object { $_.Status -eq 'FAIL' })
if ($failed.Count -gt 0) {
  Write-Host "扫描完成，但有 $($failed.Count) 项需要处理。" -ForegroundColor Yellow
  exit 2
}
Write-Host '扫描与配置完成。' -ForegroundColor Green
exit 0
