[CmdletBinding()]
param(
  [switch]$SelfTest,
  [string]$SelfTestReport,
  [switch]$UiSmokeTest,
  [switch]$SmokeComplete,
  [switch]$PipelineSmokeTest,
  [ValidateRange(0, 3)][int]$PipelineSmokeWarnStage = 0,
  [ValidateRange(0, 3)][int]$PipelineSmokeFailStage = 0,
  [switch]$ApplyAndVerify,
  [string]$ApplyScreenshotPath,
  [string]$ApplyReportPath,
  [string]$SnapshotPath
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)

try {
  [Console]::InputEncoding = $script:Utf8NoBom
  [Console]::OutputEncoding = $script:Utf8NoBom
  $OutputEncoding = $script:Utf8NoBom
} catch {}

function Resolve-PackageRoot {
  $candidates = @(
    $PSScriptRoot,
    [AppDomain]::CurrentDomain.BaseDirectory,
    (Get-Location).Path
  ) | Where-Object { $_ } | Select-Object -Unique

  foreach ($candidate in $candidates) {
    try {
      $full = [System.IO.Path]::GetFullPath("$candidate").TrimEnd('\')
      if (Test-Path -LiteralPath (Join-Path $full 'windows\scripts') -PathType Container) {
        return $full
      }
    } catch {}
  }
  throw '找不到 windows\scripts。请保留 EXE、启动脚本和 windows 目录的相对位置。'
}

$BaseDir = Resolve-PackageRoot
$ScriptsDir = Join-Path $BaseDir 'windows\scripts'
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'

function ConvertTo-WindowsProcessArgument {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
  if ($Value.IndexOf([char]0) -ge 0) { throw '进程参数包含 NUL 字符。' }
  if ($Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  $builder = New-Object System.Text.StringBuilder
  [void]$builder.Append('"')
  $slashes = 0
  foreach ($character in $Value.ToCharArray()) {
    if ($character -eq '\') {
      $slashes++
      continue
    }
    if ($character -eq '"') {
      [void]$builder.Append(('\' * ($slashes * 2 + 1)))
      [void]$builder.Append('"')
      $slashes = 0
      continue
    }
    if ($slashes -gt 0) {
      [void]$builder.Append(('\' * $slashes))
      $slashes = 0
    }
    [void]$builder.Append($character)
  }
  if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
  [void]$builder.Append('"')
  return $builder.ToString()
}

function Write-StrictUtf8 {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
  )
  $full = [System.IO.Path]::GetFullPath($Path)
  $parent = [System.IO.Path]::GetDirectoryName($full)
  if (-not [System.IO.Directory]::Exists($parent)) {
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
  }
  [System.IO.File]::WriteAllText($full, $Content, $script:Utf8NoBom)
}

function Invoke-LauncherSelfTest {
  $checks = New-Object System.Collections.Generic.List[object]

  function Add-Check {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $checks.Add([pscustomobject]@{ name = $Name; pass = $Pass; detail = $Detail })
    if (-not $Pass) { throw "$Name：$Detail" }
  }

  try {
    Add-Check -Name 'package-root' -Pass (Test-Path -LiteralPath $ScriptsDir -PathType Container) `
      -Detail $BaseDir

    $scriptFiles = @(
      Get-Item -LiteralPath (Join-Path $BaseDir 'CodexDreamSkinLauncher.ps1')
      Get-ChildItem -LiteralPath $ScriptsDir -Filter '*.ps1' -File
    )
    foreach ($file in $scriptFiles) {
      $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
      $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
      Add-Check -Name "powershell-bom/$($file.Name)" -Pass $hasBom `
        -Detail 'Windows PowerShell 5.1 需要 UTF-8 BOM 才能可靠解析中文。'

      $tokens = $null
      $parseErrors = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors)
      Add-Check -Name "powershell-parse/$($file.Name)" -Pass ($parseErrors.Count -eq 0) `
        -Detail (($parseErrors | ForEach-Object { $_.Message }) -join ' | ')
    }

    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $BaseDir 'windows') -Recurse -File |
      Where-Object { $_.Extension -in @('.mjs', '.js', '.css', '.json') }) {
      try {
        $null = $script:Utf8NoBom.GetString([System.IO.File]::ReadAllBytes($file.FullName))
        Add-Check -Name "strict-utf8/$($file.Name)" -Pass $true -Detail $file.FullName
      } catch {
        Add-Check -Name "strict-utf8/$($file.Name)" -Pass $false -Detail $_.Exception.Message
      }
      if ($file.Extension -eq '.json') {
        try {
          $null = ([System.IO.File]::ReadAllText($file.FullName, $script:Utf8NoBom) |
            ConvertFrom-Json -ErrorAction Stop)
          Add-Check -Name "json/$($file.Name)" -Pass $true -Detail $file.FullName
        } catch {
          Add-Check -Name "json/$($file.Name)" -Pass $false -Detail $_.Exception.Message
        }
      }
    }

    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
      ("Codex换肤 路径编码测试 " + [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    try {
      . (Join-Path $ScriptsDir 'config-utf8.ps1')
      $unicodePath = Join-Path $testRoot '配置 文件.json'
      $unicodeText = "{`r`n  `"主题`": `"星河皮肤`",`r`n  `"path`": `"C:\\测试 路径`"`r`n}`r`n"
      Write-DreamSkinUtf8FileAtomically -Path $unicodePath -Content $unicodeText
      $roundTrip = Read-DreamSkinUtf8File -Path $unicodePath
      $roundTripBytes = [System.IO.File]::ReadAllBytes($unicodePath)
      $noBom = -not ($roundTripBytes.Length -ge 3 -and $roundTripBytes[0] -eq 0xEF -and
        $roundTripBytes[1] -eq 0xBB -and $roundTripBytes[2] -eq 0xBF)
      Add-Check -Name 'unicode-path-roundtrip' -Pass ($roundTrip -ceq $unicodeText) `
        -Detail $unicodePath
      Add-Check -Name 'data-utf8-no-bom' -Pass $noBom `
        -Detail '运行状态和配置数据保持严格 UTF-8（无 BOM）。'

      $configPath = Join-Path $testRoot '配置 目录\config.toml'
      $backupPath = Join-Path $testRoot '状态 目录\config.before-dream-skin.toml'
      $originalConfig = "# 中文注释`r`nmodel = `"gpt-test`"`r`n`r`n[desktop]`r`nappearanceTheme = `"dark`"`r`ncustomSetting = `"保留值`"`r`n"
      Write-DreamSkinUtf8FileAtomically -Path $configPath -Content $originalConfig
      $originalConfigBytes = [System.IO.File]::ReadAllBytes($configPath)
      Install-DreamSkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath
      $installedConfig = Read-DreamSkinUtf8File -Path $configPath
      $installedBytes = [System.IO.File]::ReadAllBytes($configPath)
      $installedHasNoBom = -not ($installedBytes.Length -ge 3 -and
        $installedBytes[0] -eq 0xEF -and $installedBytes[1] -eq 0xBB -and
        $installedBytes[2] -eq 0xBF)
      $installedPreserved = $installedConfig.Contains('# 中文注释') -and
        $installedConfig.Contains('customSetting = "保留值"') -and
        $installedConfig.Contains('appearanceLightCodeThemeId')
      Add-Check -Name 'config-install-preserves-unicode' `
        -Pass ($installedHasNoBom -and $installedPreserved) -Detail $configPath
      Add-Check -Name 'config-backup-byte-exact' `
        -Pass (Test-DreamSkinBytesEqual -Left $originalConfigBytes `
          -Right ([System.IO.File]::ReadAllBytes($backupPath))) -Detail $backupPath
      Restore-DreamSkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath
      Add-Check -Name 'config-selective-restore-byte-exact' `
        -Pass (Test-DreamSkinBytesEqual -Left $originalConfigBytes `
          -Right ([System.IO.File]::ReadAllBytes($configPath))) -Detail $configPath

      $probeScript = Join-Path $testRoot '参数 探测.ps1'
      $probeOutput = Join-Path $testRoot '参数 结果.txt'
      $probePayload = 'C:\测试 路径\皮肤 图片.png'
      $probeSource = @'
param([string]$OutputPath, [string]$Payload)
$encoding = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($OutputPath, $Payload, $encoding)
'@
      [System.IO.File]::WriteAllText(
        $probeScript, $probeSource, [System.Text.UTF8Encoding]::new($true))
      $probeArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        $probeScript, '-OutputPath', $probeOutput, '-Payload', $probePayload
      ) | ForEach-Object { ConvertTo-WindowsProcessArgument -Value "$_" }
      $probeProcess = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source `
        -ArgumentList ($probeArguments -join ' ') -WindowStyle Hidden -PassThru -Wait
      $probeResult = if (Test-Path -LiteralPath $probeOutput) {
        [System.IO.File]::ReadAllText($probeOutput, $script:Utf8NoBom)
      } else { '' }
      Add-Check -Name 'unicode-process-arguments' `
        -Pass ($probeProcess.ExitCode -eq 0 -and $probeResult -ceq $probePayload) `
        -Detail $probePayload
    } finally {
      if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
      }
    }

    $result = [ordered]@{
      schemaVersion = 1
      pass = $true
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      packageRoot = $BaseDir
      powershell = "$($PSVersionTable.PSVersion)"
      checks = $checks.ToArray()
    }
  } catch {
    $result = [ordered]@{
      schemaVersion = 1
      pass = $false
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      packageRoot = $BaseDir
      powershell = "$($PSVersionTable.PSVersion)"
      error = $_.Exception.Message
      checks = $checks.ToArray()
    }
  }

  $json = $result | ConvertTo-Json -Depth 8
  if ($SelfTestReport) { Write-StrictUtf8 -Path $SelfTestReport -Content ($json + "`r`n") }
  if (-not $result.pass) { exit 1 }
  exit 0
}

if ($SelfTest) { Invoke-LauncherSelfTest }

function Invoke-ApplyAndVerifyFromExe {
  $startedAt = [datetime]::UtcNow
  $startExitCode = $null
  $verifyExitCode = $null
  $errorMessage = $null
  try {
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    # Apply through the EXE must also refresh the managed engine.  Otherwise an
    # image change can relaunch an old verifier even after the source package is
    # fixed, which makes a successful render look like a failed application.
    . (Join-Path $ScriptsDir 'common-windows.ps1')
    . (Join-Path $ScriptsDir 'theme-windows.ps1')
    $runtimeSourceRoot = Split-Path -Parent $ScriptsDir
    $null = Install-DreamSkinRuntimeEngine -SkillRoot $runtimeSourceRoot -StateRoot $StateRoot
    $startScript = Join-Path $ScriptsDir 'start-dream-skin.ps1'
    $verifyScript = Join-Path $ScriptsDir 'verify-dream-skin.ps1'
    foreach ($required in @($startScript, $verifyScript)) {
      if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "缺少脚本：$required"
      }
    }

    $startArguments = @(
      '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', $startScript, '-PromptRestart'
    ) | ForEach-Object { ConvertTo-WindowsProcessArgument -Value "$_" }
    $startProcess = Start-Process -FilePath $powershell -ArgumentList ($startArguments -join ' ') `
      -WindowStyle Hidden -PassThru -Wait
    $startExitCode = [int]$startProcess.ExitCode
    if ($startExitCode -ne 0) { throw "皮肤应用失败，错误代码：$startExitCode" }

    $verifyArguments = @(
      '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', $verifyScript
    )
    if ($ApplyScreenshotPath) {
      $verifyArguments += @('-ScreenshotPath', [System.IO.Path]::GetFullPath($ApplyScreenshotPath))
    }
    $verifyArgumentLine = ($verifyArguments | ForEach-Object {
      ConvertTo-WindowsProcessArgument -Value "$_"
    }) -join ' '
    $verifyProcess = Start-Process -FilePath $powershell -ArgumentList $verifyArgumentLine `
      -WindowStyle Hidden -PassThru -Wait
    $verifyExitCode = [int]$verifyProcess.ExitCode
    if ($verifyExitCode -ne 0) { throw "实时验证失败，错误代码：$verifyExitCode" }
  } catch {
    $errorMessage = $_.Exception.Message
  }

  $result = [ordered]@{
    schemaVersion = 1
    action = 'apply-and-verify'
    pass = [bool](-not $errorMessage -and $startExitCode -eq 0 -and $verifyExitCode -eq 0)
    startedAt = $startedAt.ToString('o')
    completedAt = [datetime]::UtcNow.ToString('o')
    packageRoot = $BaseDir
    startExitCode = $startExitCode
    verifyExitCode = $verifyExitCode
    screenshotPath = if ($ApplyScreenshotPath) { [System.IO.Path]::GetFullPath($ApplyScreenshotPath) } else { $null }
    error = $errorMessage
  }
  if ($ApplyReportPath) {
    Write-StrictUtf8 -Path $ApplyReportPath -Content (($result | ConvertTo-Json -Depth 4) + "`r`n")
  }
  if (-not $result.pass) { exit 1 }
  exit 0
}

if ($ApplyAndVerify) { Invoke-ApplyAndVerifyFromExe }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex Dream Skin'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(780, 620)
$form.MinimumSize = New-Object System.Drawing.Size(796, 659)
$form.BackColor = [System.Drawing.Color]::FromArgb(247, 249, 252)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.MaximizeBox = $false

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(780, 108)
$header.Anchor = 'Top,Left,Right'
$header.BackColor = [System.Drawing.Color]::FromArgb(48, 42, 88)
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Codex Dream Skin'
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(28, 18)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Windows 一键换肤 · Unicode 路径 · 严格 UTF-8'
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(211, 207, 236)
$subtitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(31, 65)
$header.Controls.Add($subtitle)

$stagePanels = @()
$stageIcons = @()
$stageTitles = @('环境检测', '皮肤替换', '功能验证')
$stageDescriptions = @(
  '检查 Windows、Node.js、桌面客户端与端口',
  '安装运行组件、应用皮肤并启动客户端',
  '验证实时渲染、交互区域与注入状态'
)

for ($index = 0; $index -lt 3; $index++) {
  $panel = New-Object System.Windows.Forms.Panel
  $panel.Location = New-Object System.Drawing.Point(26, (128 + 92 * $index))
  $panel.Size = New-Object System.Drawing.Size(728, 76)
  $panel.Anchor = 'Top,Left,Right'
  $panel.BackColor = [System.Drawing.Color]::White
  $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $form.Controls.Add($panel)

  $icon = New-Object System.Windows.Forms.Label
  $icon.Text = '○'
  $icon.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
  $icon.ForeColor = [System.Drawing.Color]::FromArgb(156, 163, 175)
  $icon.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 23, [System.Drawing.FontStyle]::Bold)
  $icon.Location = New-Object System.Drawing.Point(16, 11)
  $icon.Size = New-Object System.Drawing.Size(52, 52)
  $panel.Controls.Add($icon)

  $stageTitle = New-Object System.Windows.Forms.Label
  $stageTitle.Text = ("{0}. {1}" -f ($index + 1), $stageTitles[$index])
  $stageTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
  $stageTitle.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
  $stageTitle.AutoSize = $true
  $stageTitle.Location = New-Object System.Drawing.Point(82, 14)
  $panel.Controls.Add($stageTitle)

  $description = New-Object System.Windows.Forms.Label
  $description.Text = $stageDescriptions[$index]
  $description.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
  $description.AutoSize = $true
  $description.Location = New-Object System.Drawing.Point(84, 43)
  $panel.Controls.Add($description)

  $stagePanels += $panel
  $stageIcons += $icon
}

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '准备就绪'
$statusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(48, 42, 88)
$statusLabel.AutoSize = $true
$statusLabel.Location = New-Object System.Drawing.Point(28, 413)
$form.Controls.Add($statusLabel)

$statusBox = New-Object System.Windows.Forms.TextBox
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.TabStop = $false
$statusBox.ScrollBars = 'Vertical'
$statusBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$statusBox.BackColor = [System.Drawing.Color]::White
$statusBox.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$statusBox.Location = New-Object System.Drawing.Point(26, 439)
$statusBox.Size = New-Object System.Drawing.Size(728, 92)
$statusBox.Anchor = 'Top,Left,Right'
$statusBox.Text = "点击「开始安装 / 修复」后，程序会依次完成三个阶段。`r`n若客户端正在运行，皮肤替换阶段会先显示一次重启确认。"
$form.Controls.Add($statusBox)

$primaryButton = New-Object System.Windows.Forms.Button
$primaryButton.Text = '开始安装 / 修复'
$primaryButton.Location = New-Object System.Drawing.Point(26, 550)
$primaryButton.Size = New-Object System.Drawing.Size(190, 44)
$primaryButton.BackColor = [System.Drawing.Color]::FromArgb(91, 73, 179)
$primaryButton.ForeColor = [System.Drawing.Color]::White
$primaryButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$primaryButton.FlatAppearance.BorderSize = 0
$primaryButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($primaryButton)

function New-AuxButton {
  param([string]$Text, [int]$X)
  $button = New-Object System.Windows.Forms.Button
  $button.Text = $Text
  $button.Location = New-Object System.Drawing.Point($X, 550)
  $button.Size = New-Object System.Drawing.Size(160, 44)
  $button.BackColor = [System.Drawing.Color]::White
  $button.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
  $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(209, 213, 219)
  $form.Controls.Add($button)
  return $button
}

$changeButton = New-AuxButton -Text '更换皮肤图片' -X 232
$restoreButton = New-AuxButton -Text '恢复官方外观' -X 400
$logButton = New-AuxButton -Text '打开日志目录' -X 568
$logButton.Size = New-Object System.Drawing.Size(186, 44)

$script:RunningProcess = $null
$script:Pipeline = @()
$script:PipelineIndex = 0
$script:CurrentCommand = $null
$script:CurrentStdout = $null
$script:CurrentStderr = $null
$script:CurrentStdoutTask = $null
$script:CurrentStderrTask = $null
$script:CurrentStartedAtUtc = $null
$script:EnvironmentReportStampBefore = $null
$script:PipelineActive = $false
$script:LastStage = -1
$script:PipelineSmokeTestResult = $null

function Set-StageState {
  param([int]$Stage, [ValidateSet('pending', 'running', 'success', 'failed')][string]$State)
  $panel = $stagePanels[$Stage]
  $icon = $stageIcons[$Stage]
  switch ($State) {
    'pending' {
      $icon.Text = '○'
      $icon.ForeColor = [System.Drawing.Color]::FromArgb(156, 163, 175)
      $panel.BackColor = [System.Drawing.Color]::White
    }
    'running' {
      $icon.Text = '…'
      $icon.ForeColor = [System.Drawing.Color]::FromArgb(217, 144, 26)
      $panel.BackColor = [System.Drawing.Color]::FromArgb(255, 251, 235)
    }
    'success' {
      $icon.Text = '√'
      $icon.ForeColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
      $panel.BackColor = [System.Drawing.Color]::FromArgb(240, 253, 244)
    }
    'failed' {
      $icon.Text = '×'
      $icon.ForeColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
      $panel.BackColor = [System.Drawing.Color]::FromArgb(254, 242, 242)
    }
  }
}

function Set-ControlsEnabled {
  param([bool]$Enabled)
  $primaryButton.Enabled = $Enabled
  $changeButton.Enabled = $Enabled
  $restoreButton.Enabled = $Enabled
  $logButton.Enabled = $true
}

function Read-LogTail {
  param([string[]]$Paths)
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($path in $Paths) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    try {
      $text = [System.IO.File]::ReadAllText($path, $script:Utf8NoBom)
      foreach ($line in ($text -split "\r?\n")) {
        if ($line.Trim()) { $lines.Add($line) }
      }
    } catch {
      try {
        foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::Default)) {
          if ($line.Trim()) { $lines.Add($line) }
        }
      } catch {}
    }
  }
  return @($lines | Select-Object -Last 9)
}

function Start-DirectProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string]$ArgumentLine,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [switch]$CaptureOutput
  )
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = $ArgumentLine
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  if ($CaptureOutput) {
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    try {
      $startInfo.StandardOutputEncoding = $script:Utf8NoBom
      $startInfo.StandardErrorEncoding = $script:Utf8NoBom
    } catch {}
  }

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    $process.Dispose()
    throw "进程启动失败：$FilePath"
  }
  return $process
}

function Start-DetachedPowerShell {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$Arguments = @(),
    [switch]$Sta
  )
  $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
  $tokens = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass')
  if ($Sta) { $tokens += '-STA' }
  $tokens += @('-File', $ScriptPath)
  $tokens += @($Arguments)
  $line = ($tokens | ForEach-Object {
    ConvertTo-WindowsProcessArgument -Value "$_"
  }) -join ' '
  return Start-DirectProcess -FilePath $powershell -ArgumentLine $line `
    -WorkingDirectory $BaseDir
}

function Get-FreshEnvironmentReportResult {
  param(
    [datetime]$StartedAtUtc,
    [string]$PreviousStamp
  )
  $reportPath = Join-Path $StateRoot 'environment-report.json'
  if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { return $null }
  try {
    $item = Get-Item -LiteralPath $reportPath -ErrorAction Stop
    $currentStamp = "$($item.LastWriteTimeUtc.Ticks):$($item.Length)"
    if ($PreviousStamp -and $currentStamp -ceq $PreviousStamp) { return $null }
    if ($StartedAtUtc -and $item.LastWriteTimeUtc -lt $StartedAtUtc.AddSeconds(-2)) {
      return $null
    }
    $report = @(
      [System.IO.File]::ReadAllText($reportPath, $script:Utf8NoBom) |
        ConvertFrom-Json -ErrorAction Stop
    )
    $failed = @($report | Where-Object { "$($_.Status)" -eq 'FAIL' })
    $warnings = @($report | Where-Object { "$($_.Status)" -eq 'WARN' })
    return [pscustomobject]@{
      Success = $failed.Count -eq 0
      FailedCount = $failed.Count
      WarningCount = $warnings.Count
      ReportPath = $reportPath
    }
  } catch {
    return $null
  }
}

function Stop-PipelineWithError {
  param([string]$Message)
  if ($script:CurrentCommand) { Set-StageState -Stage $script:CurrentCommand.Stage -State failed }
  $statusLabel.Text = '操作未完成'
  $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
  $statusBox.Text = $Message
  $script:PipelineActive = $false
  $script:RunningProcess = $null
  if ($PipelineSmokeTest) { $script:PipelineSmokeTestResult = $false }
  Set-ControlsEnabled -Enabled $true
}

function Start-NextPipelineCommand {
  if ($script:PipelineIndex -ge $script:Pipeline.Count) {
    if ($script:LastStage -ge 0) { Set-StageState -Stage $script:LastStage -State success }
    $statusLabel.Text = '全部完成'
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
    $statusBox.Text = "三个阶段均已通过。皮肤已启动并完成实时功能验证。`r`n需要撤销时可点击「恢复官方外观」。"
    $script:PipelineActive = $false
    if ($PipelineSmokeTest) { $script:PipelineSmokeTestResult = $true }
    Set-ControlsEnabled -Enabled $true
    return
  }

  $command = $script:Pipeline[$script:PipelineIndex]
  if ($script:LastStage -ge 0 -and $script:LastStage -ne $command.Stage) {
    Set-StageState -Stage $script:LastStage -State success
  }
  $script:LastStage = $command.Stage
  $script:CurrentCommand = $command
  Set-StageState -Stage $command.Stage -State running
  $statusLabel.Text = ("正在执行：{0}" -f $stageTitles[$command.Stage])
  $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(146, 92, 16)
  $statusBox.Text = $command.Message

  $scriptPath = Join-Path $ScriptsDir $command.Script
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Stop-PipelineWithError -Message "缺少脚本：$scriptPath"
    return
  }

  try {
    [System.IO.Directory]::CreateDirectory($StateRoot) | Out-Null
    $token = "{0}-{1}-{2}" -f ($command.Stage + 1), $script:PipelineIndex,
      [guid]::NewGuid().ToString('N')
    $script:CurrentStdout = Join-Path $StateRoot "gui-$token.out.log"
    $script:CurrentStderr = Join-Path $StateRoot "gui-$token.err.log"
    $script:CurrentStartedAtUtc = [datetime]::UtcNow
    $script:EnvironmentReportStampBefore = $null
    if ($command.Stage -eq 0 -and -not $PipelineSmokeTest) {
      $reportBefore = Join-Path $StateRoot 'environment-report.json'
      if (Test-Path -LiteralPath $reportBefore -PathType Leaf) {
        $reportItem = Get-Item -LiteralPath $reportBefore -ErrorAction SilentlyContinue
        if ($reportItem) {
          $script:EnvironmentReportStampBefore = `
            "$($reportItem.LastWriteTimeUtc.Ticks):$($reportItem.Length)"
        }
      }
    }
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass')
    if ($command.Sta) { $arguments += '-STA' }
    $arguments += @('-File', $scriptPath)
    $arguments += @($command.Arguments)
    $argumentLine = ($arguments | ForEach-Object {
      ConvertTo-WindowsProcessArgument -Value "$_"
    }) -join ' '

    $script:RunningProcess = Start-DirectProcess -FilePath $powershell `
      -ArgumentLine $argumentLine -WorkingDirectory $BaseDir -CaptureOutput
    $script:CurrentStdoutTask = $script:RunningProcess.StandardOutput.ReadToEndAsync()
    $script:CurrentStderrTask = $script:RunningProcess.StandardError.ReadToEndAsync()
  } catch {
    Stop-PipelineWithError -Message $_.Exception.Message
  }
}

function Start-MainPipeline {
  for ($i = 0; $i -lt 3; $i++) { Set-StageState -Stage $i -State pending }
  if ($PipelineSmokeTest) {
    $smokeArguments = @{}
    for ($smokeStage = 1; $smokeStage -le 3; $smokeStage++) {
      $stageArguments = @('-Stage', "$smokeStage")
      if ($PipelineSmokeWarnStage -eq $smokeStage) { $stageArguments += '-Warn' }
      if ($PipelineSmokeFailStage -eq $smokeStage) { $stageArguments += '-Fail' }
      $smokeArguments[$smokeStage] = $stageArguments
    }
    $script:Pipeline = @(
      [pscustomobject]@{ Stage = 0; Script = 'gui-stage-smoke.ps1'; Arguments = $smokeArguments[1]; Sta = $false; Message = '测试环境检测状态……' },
      [pscustomobject]@{ Stage = 1; Script = 'gui-stage-smoke.ps1'; Arguments = $smokeArguments[2]; Sta = $false; Message = '测试皮肤替换状态……' },
      [pscustomobject]@{ Stage = 2; Script = 'gui-stage-smoke.ps1'; Arguments = $smokeArguments[3]; Sta = $false; Message = '测试功能验证状态……' }
    )
  } else {
    $script:Pipeline = @(
      [pscustomobject]@{
        Stage = 0
        Script = 'scan-and-configure.ps1'
        Arguments = @('-Configure')
        Sta = $true
        Message = '正在检测 Windows、Node.js、客户端路径、配置目录和可用端口……'
      },
      [pscustomobject]@{
        Stage = 1
        Script = 'install-dream-skin.ps1'
        Arguments = @('-NoShortcuts', '-PromptClose', '-CloseTray')
        Sta = $true
        Message = '正在安装皮肤运行组件。若客户端正在运行，将显示一次重启确认……'
      },
      [pscustomobject]@{
        Stage = 1
        Script = 'start-dream-skin.ps1'
        Arguments = @()
        Sta = $false
        Message = '正在启动客户端并应用皮肤……'
      },
      [pscustomobject]@{
        Stage = 2
        Script = 'verify-dream-skin.ps1'
        Arguments = @()
        Sta = $false
        Message = '正在验证实时渲染、原生侧栏、输入区与交互状态……'
      }
    )
  }
  $script:PipelineIndex = 0
  $script:CurrentCommand = $null
  $script:LastStage = -1
  $script:PipelineActive = $true
  Set-ControlsEnabled -Enabled $false
  Start-NextPipelineCommand
}

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 350
$pollTimer.Add_Tick({
  if (-not $script:PipelineActive -or $null -eq $script:RunningProcess) { return }
  try { $script:RunningProcess.Refresh() } catch {}
  if (-not $script:RunningProcess.HasExited) { return }

  $exitCode = $null
  try {
    # On Windows PowerShell 5.1, ExitCode may still be null immediately after
    # HasExited changes. WaitForExit synchronizes the process handle and all
    # redirected output before the result is evaluated.
    $script:RunningProcess.WaitForExit()
    $exitCode = [int]$script:RunningProcess.ExitCode
  } catch {
    $exitCode = $null
  }
  $capturedStdout = ''
  $capturedStderr = ''
  try {
    if ($script:CurrentStdoutTask) { $capturedStdout = "$($script:CurrentStdoutTask.Result)" }
    if ($script:CurrentStderrTask) { $capturedStderr = "$($script:CurrentStderrTask.Result)" }
    [System.IO.File]::WriteAllText(
      $script:CurrentStdout, $capturedStdout, $script:Utf8NoBom)
    [System.IO.File]::WriteAllText(
      $script:CurrentStderr, $capturedStderr, $script:Utf8NoBom)
  } catch {}
  $tail = @(Read-LogTail -Paths @($script:CurrentStdout, $script:CurrentStderr))
  $script:RunningProcess.Dispose()
  $script:RunningProcess = $null
  $script:CurrentStdoutTask = $null
  $script:CurrentStderrTask = $null

  $environmentResult = $null
  if ($script:CurrentCommand.Stage -eq 0 -and -not $PipelineSmokeTest) {
    $environmentResult = Get-FreshEnvironmentReportResult `
      -StartedAtUtc $script:CurrentStartedAtUtc `
      -PreviousStamp $script:EnvironmentReportStampBefore
    if ($null -ne $environmentResult) {
      # The freshly written structured report is the canonical result for
      # environment detection. WARN entries are informational, not failures.
      $exitCode = if ($environmentResult.Success) { 0 } else { 2 }
    }
  }

  if ($null -eq $exitCode -or $exitCode -ne 0) {
    $detail = if ($tail.Count -gt 0) { $tail -join "`r`n" } else {
      if ($null -eq $exitCode) { '未能读取阶段返回代码，请查看日志后重试。' }
      else { "阶段返回错误代码：$exitCode" }
    }
    Stop-PipelineWithError -Message $detail
    return
  }

  if ($tail.Count -gt 0) { $statusBox.Text = $tail -join "`r`n" }
  if ($null -ne $environmentResult -and $environmentResult.WarningCount -gt 0) {
    $statusLabel.Text = "环境检测完成（$($environmentResult.WarningCount) 项提示，不影响继续）"
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
  }
  $script:PipelineIndex++
  Start-NextPipelineCommand
})
$pollTimer.Start()

$primaryButton.Add_Click({
  if (-not $script:PipelineActive) { Start-MainPipeline }
})

$changeButton.Add_Click({
  try {
    $scriptPath = Join-Path $ScriptsDir 'change-codex-dream-skin-background.ps1'
    $process = Start-DetachedPowerShell -ScriptPath $scriptPath -Sta
    $process.Dispose()
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show(
      $_.Exception.Message, 'Codex Dream Skin',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error)
  }
})

$restoreButton.Add_Click({
  try {
    $answer = [System.Windows.Forms.MessageBox]::Show(
      '将关闭当前皮肤会话并恢复官方外观，是否继续？',
      'Codex Dream Skin',
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $scriptPath = Join-Path $ScriptsDir 'restore-dream-skin.ps1'
    $process = Start-DetachedPowerShell -ScriptPath $scriptPath `
      -Arguments @('-ForceRestart')
    $process.Dispose()
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show(
      $_.Exception.Message, 'Codex Dream Skin',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error)
  }
})

$logButton.Add_Click({
  try {
    [System.IO.Directory]::CreateDirectory($StateRoot) | Out-Null
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'explorer.exe'
    $startInfo.Arguments = ConvertTo-WindowsProcessArgument -Value $StateRoot
    $startInfo.UseShellExecute = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($process) { $process.Dispose() }
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show(
      $_.Exception.Message, 'Codex Dream Skin',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error)
  }
})

$form.Add_FormClosing({
  if ($script:PipelineActive) {
    $answer = [System.Windows.Forms.MessageBox]::Show(
      '操作仍在进行。关闭窗口不会强制终止当前脚本，是否关闭？',
      'Codex Dream Skin',
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $_.Cancel = $true }
  }
})

$form.Add_FormClosed({
  $pollTimer.Stop()
  $pollTimer.Dispose()
  if ($script:RunningProcess) { $script:RunningProcess.Dispose() }
})

if ($UiSmokeTest) {
  if ($SmokeComplete -and -not $PipelineSmokeTest) {
    for ($i = 0; $i -lt 3; $i++) { Set-StageState -Stage $i -State success }
    $statusLabel.Text = '全部完成'
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
    $statusBox.Text = '三个阶段均已通过。皮肤已启动并完成实时功能验证。'
  }
  $smokeTimer = New-Object System.Windows.Forms.Timer
  $smokeTimer.Interval = if ($PipelineSmokeTest) { 300 } else { 900 }
  $script:SmokeTicks = 0
  $smokeTimer.Add_Tick({
    $script:SmokeTicks++
    if ($PipelineSmokeTest -and $script:PipelineActive -and $script:SmokeTicks -lt 100) {
      return
    }
    $smokeTimer.Stop()
    try {
      if ($SnapshotPath) {
        $fullSnapshot = [System.IO.Path]::GetFullPath($SnapshotPath)
        $snapshotParent = [System.IO.Path]::GetDirectoryName($fullSnapshot)
        if (-not [System.IO.Directory]::Exists($snapshotParent)) {
          [System.IO.Directory]::CreateDirectory($snapshotParent) | Out-Null
        }
        $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        try {
          $form.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
          $bitmap.Save($fullSnapshot, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally {
          $bitmap.Dispose()
        }
      }
    } finally {
      $form.Close()
      $smokeTimer.Dispose()
    }
  })
  $smokeTimer.Start()
}

$form.Add_Shown({
  $form.ActiveControl = $primaryButton
  if ($PipelineSmokeTest) { $primaryButton.PerformClick() }
})
[void]$form.ShowDialog()
if ($PipelineSmokeTest -and $script:PipelineSmokeTestResult -ne $true) { exit 1 }
