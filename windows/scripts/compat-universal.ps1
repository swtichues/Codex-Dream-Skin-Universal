# Universal target and configuration compatibility layer.
# Loaded after common-windows.ps1 so these functions intentionally replace
# the original Store-only implementations.

function Get-DreamSkinTargetConfigPath {
  param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'))
  return Join-Path ([System.IO.Path]::GetFullPath($StateRoot)) 'target.json'
}

function Get-DreamSkinCodexHome {
  $value = "$env:CODEX_HOME".Trim()
  if ($value) {
    if (-not [System.IO.Path]::IsPathRooted($value)) {
      throw "CODEX_HOME must be an absolute path: $value"
    }
    return [System.IO.Path]::GetFullPath($value)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $HOME '.codex'))
}

function Get-DreamSkinConfigPath {
  return Join-Path (Get-DreamSkinCodexHome) 'config.toml'
}

function Read-DreamSkinTargetConfiguration {
  param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'))
  $path = Get-DreamSkinTargetConfigPath -StateRoot $StateRoot
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try {
    $config = (Read-DreamSkinUtf8File -Path $path) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $config -or $config -is [array] -or $config -is [string]) {
      throw 'Target configuration root must be an object.'
    }
    return $config
  } catch {
    throw "Dream Skin target configuration is unreadable: $path"
  }
}

function Write-DreamSkinTargetConfiguration {
  param(
    [Parameter(Mandatory = $true)][object]$Target,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $fullRoot = [System.IO.Path]::GetFullPath($StateRoot)
  New-Item -ItemType Directory -Path $fullRoot -Force | Out-Null
  $kind = if ($Target.TargetKind) { "$($Target.TargetKind)" } else { 'Executable' }
  $data = [ordered]@{
    schemaVersion = 1
    targetKind = $kind
    appExecutable = "$($Target.Executable)"
    packageFullName = "$($Target.PackageFullName)"
    packageFamilyName = "$($Target.PackageFamilyName)"
    displayName = "$($Target.DisplayName)"
    configuredAt = (Get-Date).ToUniversalTime().ToString('o')
  }
  $json = $data | ConvertTo-Json -Depth 5
  Write-DreamSkinUtf8FileAtomically -Path (Get-DreamSkinTargetConfigPath -StateRoot $fullRoot) `
    -Content ($json + "`r`n")
}

function Get-DreamSkinPathIdentityHash {
  param([Parameter(Mandatory = $true)][string]$Path)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes(([System.IO.Path]::GetFullPath($Path)).ToLowerInvariant())
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($bytes)
  } finally {
    $sha.Dispose()
  }
  return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 24)
}

function New-DreamSkinExecutableTarget {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [string]$DisplayName
  )
  if (-not [System.IO.Path]::IsPathRooted($Executable)) {
    throw "The desktop client executable must be an absolute path: $Executable"
  }
  $fullPath = [System.IO.Path]::GetFullPath($Executable)
  if ($fullPath.StartsWith('\\')) {
    throw 'For safety, a desktop client executable on a network/UNC path is not supported.'
  }
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "The configured desktop client executable does not exist: $fullPath"
  }
  if ([System.IO.Path]::GetExtension($fullPath) -ine '.exe') {
    throw "The configured desktop client must be a Windows .exe file: $fullPath"
  }
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "The configured desktop client executable cannot be a symbolic link: $fullPath"
  }
  $version = ''
  try { $version = "$($item.VersionInfo.FileVersion)" } catch {}
  if (-not $DisplayName) {
    try { $DisplayName = "$($item.VersionInfo.ProductName)" } catch {}
  }
  if (-not $DisplayName) { $DisplayName = [System.IO.Path]::GetFileNameWithoutExtension($fullPath) }
  $identity = Get-DreamSkinPathIdentityHash -Path $fullPath
  return [pscustomobject]@{
    TargetKind = 'Executable'
    LaunchKind = 'Executable'
    DisplayName = $DisplayName
    PackageRoot = [System.IO.Path]::GetDirectoryName($fullPath)
    Executable = $fullPath
    ProcessName = [System.IO.Path]::GetFileName($fullPath)
    Version = $version
    PackageFullName = "CodexDreamSkin.Custom.$identity"
    PackageFamilyName = "CodexDreamSkin.Custom.$identity"
    ApplicationId = ''
    AppUserModelId = ''
    SignatureKind = 'Custom'
    RegisteredPackageVerified = $false
  }
}

function ConvertTo-DreamSkinCodexInstall {
  param(
    [Parameter(Mandatory = $true)][object]$Package,
    [AllowNull()][object]$Manifest
  )
  $packageName = "$($Package.Name)"
  $publisher = "$($Package.Publisher)"
  $looksRelevant = $packageName -match '(?i)(openai|chatgpt|codex)' -or
    $publisher -match '(?i)openai'
  if (-not $looksRelevant -or -not $Package.InstallLocation -or
    -not $Package.PackageFullName -or -not $Package.PackageFamilyName -or
    "$($Package.SignatureKind)" -ine 'Store' -or [bool]$Package.IsDevelopmentMode) {
    return $null
  }
  try {
    if (-not $PSBoundParameters.ContainsKey('Manifest')) {
      $Manifest = Get-AppxPackageManifest -Package $Package -ErrorAction Stop
    }
    $applications = @($Manifest.Package.Applications.Application)
  } catch {
    return $null
  }
  $selected = $null
  foreach ($application in $applications) {
    $relativeExecutable = "$($application.Executable)".Replace('/', '\')
    $leaf = [System.IO.Path]::GetFileName($relativeExecutable)
    if ($leaf -match '^(?i:ChatGPT|Codex)\.exe$') {
      $candidate = Join-Path "$($Package.InstallLocation)" $relativeExecutable
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $selected = [pscustomobject]@{
          Application = $application
          RelativeExecutable = $relativeExecutable
          Executable = $candidate
        }
        break
      }
    }
  }
  if ($null -eq $selected) { return $null }
  $applicationId = "$($selected.Application.Id)"
  $packageFamilyName = "$($Package.PackageFamilyName)"
  if ($packageFamilyName -cnotmatch '^[A-Za-z0-9._-]{1,180}$' -or
    $applicationId -cnotmatch '^[A-Za-z0-9._-]{1,96}$') {
    return $null
  }
  $displayName = if ($packageName -match '(?i)chatgpt') { 'ChatGPT / Codex' } else { 'OpenAI Codex / ChatGPT' }
  return [pscustomobject]@{
    TargetKind = 'Package'
    LaunchKind = 'Package'
    DisplayName = $displayName
    PackageRoot = "$($Package.InstallLocation)"
    Executable = "$($selected.Executable)"
    ProcessName = [System.IO.Path]::GetFileName("$($selected.Executable)")
    Version = "$($Package.Version)"
    PackageFullName = "$($Package.PackageFullName)"
    PackageFamilyName = $packageFamilyName
    ApplicationId = $applicationId
    AppUserModelId = "$packageFamilyName!$applicationId"
    SignatureKind = "$($Package.SignatureKind)"
    RegisteredPackageVerified = $true
  }
}

function Get-DreamSkinRegisteredCodexInstalls {
  $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
    "$($_.Name)" -match '(?i)(openai|chatgpt|codex)' -or "$($_.Publisher)" -match '(?i)openai'
  } | Sort-Object Version -Descending)
  $installs = @()
  foreach ($package in $packages) {
    $install = ConvertTo-DreamSkinCodexInstall -Package $package
    if ($null -ne $install) { $installs += $install }
  }
  return @($installs)
}

function Get-DreamSkinKnownExecutableTargets {
  $candidates = @()
  if ($env:LOCALAPPDATA) {
    $candidates += @(
      (Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT\ChatGPT.exe'),
      (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\ChatGPT.exe'),
      (Join-Path $env:LOCALAPPDATA 'Programs\Codex\Codex.exe')
    )
  }
  if ($env:ProgramFiles) {
    $candidates += @(
      (Join-Path $env:ProgramFiles 'ChatGPT\ChatGPT.exe'),
      (Join-Path $env:ProgramFiles 'OpenAI\ChatGPT.exe'),
      (Join-Path $env:ProgramFiles 'Codex\Codex.exe')
    )
  }
  $results = @()
  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      try { $results += New-DreamSkinExecutableTarget -Executable $candidate } catch {}
    }
  }
  return @($results)
}

function Resolve-DreamSkinTargetByExecutable {
  param([Parameter(Mandatory = $true)][string]$Executable)
  $fullPath = [System.IO.Path]::GetFullPath($Executable)
  foreach ($install in @(Get-DreamSkinRegisteredCodexInstalls)) {
    if (Test-DreamSkinPathEqual -Left $fullPath -Right $install.Executable) { return $install }
  }
  return New-DreamSkinExecutableTarget -Executable $fullPath
}

function Get-DreamSkinCodexInstall {
  param([string]$AppExecutable)
  if ($AppExecutable) { return Resolve-DreamSkinTargetByExecutable -Executable $AppExecutable }

  $envExecutable = "$env:CODEX_DREAM_SKIN_APP_EXE".Trim()
  if ($envExecutable) { return Resolve-DreamSkinTargetByExecutable -Executable $envExecutable }

  $configured = Read-DreamSkinTargetConfiguration
  if ($null -ne $configured -and $configured.appExecutable) {
    try { return Resolve-DreamSkinTargetByExecutable -Executable "$($configured.appExecutable)" } catch {
      Write-Warning "The saved Dream Skin target is unavailable and automatic detection will be used: $($_.Exception.Message)"
    }
  }

  $registered = @(Get-DreamSkinRegisteredCodexInstalls)
  if ($registered.Count -gt 0) { return $registered[0] }
  $known = @(Get-DreamSkinKnownExecutableTargets)
  if ($known.Count -gt 0) { return $known[0] }
  throw 'No supported ChatGPT/Codex desktop client was found. Run 00_环境扫描与配置.bat, or set CODEX_DREAM_SKIN_APP_EXE to an Electron/Chromium desktop client executable.'
}

function Start-DreamSkinCodex {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][string[]]$Arguments = @()
  )
  if ("$($Codex.LaunchKind)" -ieq 'Package' -or $Codex.AppUserModelId) {
    $appUserModelId = "$($Codex.AppUserModelId)"
    if ($appUserModelId -cnotmatch '^[A-Za-z0-9._-]{1,180}![A-Za-z0-9._-]{1,96}$') {
      throw 'The registered ChatGPT/Codex AppUserModelId is unavailable or invalid.'
    }
    Initialize-DreamSkinPackageLauncher
    $argumentLine = ConvertTo-DreamSkinArgumentLine -Arguments $Arguments
    $processId = [CodexDreamSkin.PackageLauncher]::Launch($appUserModelId, $argumentLine)
    if ($processId -le 0) { throw 'Windows did not return a process ID after package activation.' }
    return $processId
  }

  $executable = "$($Codex.Executable)"
  if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "The configured desktop client executable is unavailable: $executable"
  }
  $argumentLine = ConvertTo-DreamSkinArgumentLine -Arguments $Arguments
  $startArguments = @{
    FilePath = $executable
    WorkingDirectory = [System.IO.Path]::GetDirectoryName($executable)
    PassThru = $true
    ErrorAction = 'Stop'
  }
  if ($argumentLine) { $startArguments.ArgumentList = $argumentLine }
  $process = Start-Process @startArguments
  if ($null -eq $process -or $process.Id -le 0) { throw 'Windows did not return a desktop client process ID.' }
  return $process.Id
}

function Get-DreamSkinCodexStatePathCandidate {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or -not $State.codexExe) { return $null }
  $executable = "$($State.codexExe)"
  $packageRoot = if ($State.codexPackageRoot) { "$($State.codexPackageRoot)" } else {
    [System.IO.Path]::GetDirectoryName($executable)
  }
  $kind = if ($State.targetKind) { "$($State.targetKind)" } elseif (
    "$($State.codexPackageFullName)" -like 'CodexDreamSkin.Custom.*') { 'Executable' } else { 'Package' }
  return [pscustomobject]@{
    TargetKind = $kind
    LaunchKind = $kind
    DisplayName = if ($State.targetDisplayName) { "$($State.targetDisplayName)" } else { 'ChatGPT / Codex' }
    PackageRoot = $packageRoot
    Executable = $executable
    ProcessName = [System.IO.Path]::GetFileName($executable)
    Version = "$($State.codexVersion)"
    PackageFullName = "$($State.codexPackageFullName)"
    PackageFamilyName = "$($State.codexPackageFamilyName)"
    ApplicationId = "$($State.codexApplicationId)"
    AppUserModelId = "$($State.codexAppUserModelId)"
    SignatureKind = "$($State.codexSignatureKind)"
    FromState = $true
    RegisteredPackageVerified = $false
  }
}

function Resolve-DreamSkinCodexInstallFromState {
  param(
    [AllowNull()][object]$State,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$RegisteredInstalls
  )
  $candidate = Get-DreamSkinCodexStatePathCandidate -State $State
  if ($null -eq $candidate) { return $null }
  foreach ($install in $RegisteredInstalls) {
    if ((Test-DreamSkinPathEqual -Left $candidate.Executable -Right $install.Executable) -and
      (Test-DreamSkinPathEqual -Left $candidate.PackageRoot -Right $install.PackageRoot)) {
      $install | Add-Member -NotePropertyName FromState -NotePropertyValue $true -Force
      return $install
    }
  }
  if ("$($candidate.TargetKind)" -ieq 'Executable' -and
    (Test-Path -LiteralPath $candidate.Executable -PathType Leaf)) {
    try {
      $target = New-DreamSkinExecutableTarget -Executable $candidate.Executable -DisplayName $candidate.DisplayName
      $target | Add-Member -NotePropertyName FromState -NotePropertyValue $true -Force
      return $target
    } catch { return $null }
  }
  return $null
}

function Get-DreamSkinCodexInstallFromState {
  param([AllowNull()][object]$State)
  $installs = @()
  try { $installs = @(Get-DreamSkinRegisteredCodexInstalls) } catch {}
  return Resolve-DreamSkinCodexInstallFromState -State $State -RegisteredInstalls $installs
}

function Get-DreamSkinCodexProcesses {
  param([Parameter(Mandatory = $true)][object]$Codex)
  $processName = [System.IO.Path]::GetFileName("$($Codex.Executable)")
  if (-not $processName) { return @() }
  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    "$($_.Name)" -ieq $processName -and
    (Test-DreamSkinPathEqual -Left (Get-DreamSkinProcessExecutablePath -ProcessInfo $_) -Right "$($Codex.Executable)")
  })
}

function Test-DreamSkinCdpPageTarget {
  param([AllowNull()][object]$Target, [int]$Port)
  if ($null -eq $Target -or "$($Target.type)" -cne 'page') { return $false }
  if ($Target.id -isnot [string]) { return $false }
  $targetId = "$($Target.id)"
  $targetUrl = "$($Target.url)"
  if (-not $targetUrl -or $targetUrl -match '^(?i)(?:devtools|chrome|edge|chrome-extension|about):') {
    return $false
  }
  try {
    $uri = [Uri]$targetUrl
    if (-not $uri.IsAbsoluteUri) { return $false }
  } catch {
    return $false
  }
  $webSocketUrl = "$($Target.webSocketDebuggerUrl)"
  if (-not (Test-DreamSkinBrowserId -Value $targetId) -or
    -not (Test-DreamSkinWebSocketUrl -Value $webSocketUrl -Port $Port)) {
    return $false
  }
  try { return ([Uri]$webSocketUrl).AbsolutePath -ceq "/devtools/page/$targetId" } catch { return $false }
}

function Get-DreamSkinNodeRuntime {
  param([int]$MinimumMajor = 22)
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
      $candidates += @(Get-ChildItem -LiteralPath $nvmRoot -Filter node.exe -Recurse -File `
        -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    }
  }
  $validated = @()
  foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    try {
      $versionProbe = Invoke-DreamSkinNative -FilePath $candidate -ArgumentList @('-p', 'process.versions.node') -DiscardStderr
      $version = ($versionProbe.Output -join '').Trim()
      $major = 0
      if ($versionProbe.ExitCode -eq 0 -and $version -and
        [int]::TryParse(($version -split '\.')[0], [ref]$major)) {
        $validated += [pscustomobject]@{
          Path = [System.IO.Path]::GetFullPath($candidate)
          Version = $version
          Major = $major
        }
      }
    } catch {}
  }
  $runtime = @($validated | Where-Object { $_.Major -ge $MinimumMajor } |
    Sort-Object Major -Descending | Select-Object -First 1)
  if ($runtime.Count -gt 0) { return $runtime[0] }
  if ($validated.Count -gt 0) {
    $best = @($validated | Sort-Object Major -Descending | Select-Object -First 1)[0]
    throw "Node.js $MinimumMajor or newer is required; found $($best.Version) at $($best.Path)."
  }
  throw "Node.js $MinimumMajor or newer is required and was not found in PATH or common Windows installation locations."
}
