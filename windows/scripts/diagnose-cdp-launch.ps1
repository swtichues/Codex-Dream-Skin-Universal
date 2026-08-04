[CmdletBinding()]
param(
  [int]$Port = 9338,
  [int]$DurationSeconds = 90
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) '..'))
$reportDir = Join-Path $repoRoot 'live-diagnostic'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $reportDir "cdp-launch-$stamp.json"
$screenshotDir = Join-Path $reportDir "cdp-launch-$stamp"
New-Item -ItemType Directory -Force -Path $screenshotDir | Out-Null

. (Join-Path $PSScriptRoot 'common-windows.ps1')
$node = Get-DreamSkinNodeRuntime
$probeScript = Join-Path $PSScriptRoot 'diagnose-cdp-probe.mjs'
$codex = Get-DreamSkinCodexInstall

Write-Host "Closing Codex for a controlled CDP launch on port $Port ..."
Stop-DreamSkinCodex -Codex $codex -AllowForce
Start-Sleep -Milliseconds 1200

$report = [System.Collections.Generic.List[object]]::new()
$report.Add([pscustomobject][ordered]@{
  stage = 'launch'
  t = (Get-Date).ToString('HH:mm:ss.fff')
  port = $Port
  codexExe = $codex.Executable
  codexVersion = $codex.Version
})

try {
  $null = Start-DreamSkinCodex -Codex $codex -Arguments @(
    '--remote-debugging-address=127.0.0.1',
    "--remote-debugging-port=$Port"
  )
} catch {
  $report.Add([pscustomobject][ordered]@{
    stage = 'launch-error'
    t = (Get-Date).ToString('HH:mm:ss.fff')
    error = $_.Exception.Message
  })
}

$deadline = (Get-Date).AddSeconds($DurationSeconds)
$startedAt = Get-Date
$lastSnapshot = ''
$probed = @{}
$probeCount = @{}
$phaseBStarted = $false

while ((Get-Date) -lt $deadline) {
  $entry = [ordered]@{ t = (Get-Date).ToString('HH:mm:ss.fff') }
  try {
    $version = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 -MaximumRedirection 0
    $entry.browserId = [regex]::Match(
      "$($version.webSocketDebuggerUrl)",
      '/devtools/browser/([A-Za-z0-9._-]+)'
    ).Groups[1].Value
    $entry.browser = "$($version.Browser)"
    $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2 -MaximumRedirection 0)
    $entry.targets = @($targets | ForEach-Object {
      [ordered]@{
        id = $_.id
        type = $_.type
        url = $_.url
        title = $_.title
      }
    })

    foreach ($target in $targets) {
      if ($target.type -cne 'page' -or "$($target.url)" -notlike 'app://*') { continue }
      $key = "$($target.id)|$($target.url)"
      $probeCount[$target.id] = if ($probeCount.ContainsKey($target.id)) { $probeCount[$target.id] + 1 } else { 1 }
      if ($probed.ContainsKey($key) -or $probeCount[$target.id] -gt 4) { continue }
      $probed[$key] = $true
      $shotPath = Join-Path $screenshotDir "target-$($target.id)-$($probeCount[$target.id]).png"
      $probeOut = @(& $node.Path $probeScript "$($target.webSocketDebuggerUrl)" $shotPath 2>&1 | ForEach-Object { "$_" })
      $entry.probe = [ordered]@{
        targetId = $target.id
        url = $target.url
        attempt = $probeCount[$target.id]
        output = $probeOut
      }
    }

    # Phase B: once the app is up, reproduce the real start-dream-skin flow so
    # we can observe what happens to the CDP targets while it runs.
    $elapsed = ((Get-Date) - $startedAt).TotalSeconds
    if (-not $phaseBStarted -and $elapsed -ge 45 -and $targets.Count -gt 0) {
      $phaseBStarted = $true
      $startScript = Join-Path $PSScriptRoot 'start-dream-skin.ps1'
      $phaseBOut = Join-Path $screenshotDir 'phase-b.out.log'
      $phaseBErr = Join-Path $screenshotDir 'phase-b.err.log'
      Write-Host "Phase B: running the real start-dream-skin flow on port $Port ..."
      $phaseB = Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$startScript`"", '-Port', "$Port", '-RestartExisting'
      ) -PassThru -RedirectStandardOutput $phaseBOut -RedirectStandardError $phaseBErr
      $entry.phaseBStarted = $phaseB.Id
      $phaseBDeadline = (Get-Date).AddSeconds(150)
      while (-not $phaseB.HasExited -and (Get-Date) -lt $phaseBDeadline) {
        Start-Sleep -Milliseconds 400
        $inner = [ordered]@{ t = (Get-Date).ToString('HH:mm:ss.fff') }
        try {
          $inner.targets = @((Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2 -MaximumRedirection 0) |
            ForEach-Object { [ordered]@{ id = $_.id; type = $_.type; url = $_.url; title = $_.title } })
        } catch {
          $inner.error = $_.Exception.Message
        }
        $innerSnapshot = ($inner | ConvertTo-Json -Compress -Depth 6)
        if ($innerSnapshot -cne $lastSnapshot) {
          $report.Add([pscustomobject]$inner)
          $lastSnapshot = $innerSnapshot
        }
      }
      $entry.phaseBExit = if ($phaseB.HasExited) { $phaseB.ExitCode } else { 'timeout' }
      $entry.phaseBOutLog = if (Test-Path -LiteralPath $phaseBOut) {
        @(Get-Content -LiteralPath $phaseBOut -ErrorAction SilentlyContinue)
      } else { @() }
      $entry.phaseBErrLog = if (Test-Path -LiteralPath $phaseBErr) {
        @(Get-Content -LiteralPath $phaseBErr -ErrorAction SilentlyContinue)
      } else { @() }
      if (-not $phaseB.HasExited) {
        try { Stop-Process -Id $phaseB.Id -Force -ErrorAction Stop } catch {}
      }
    }
  } catch {
    $entry.error = $_.Exception.Message
  }

  $snapshot = ($entry | ConvertTo-Json -Compress -Depth 8)
  if ($snapshot -cne $lastSnapshot) {
    $report.Add([pscustomobject]$entry)
    $lastSnapshot = $snapshot
  }
  Start-Sleep -Milliseconds 400
}

$report.Add([pscustomobject][ordered]@{
  stage = 'summary'
  t = (Get-Date).ToString('HH:mm:ss.fff')
  probedTargets = @($probed.Keys)
  screenshots = @(Get-ChildItem -LiteralPath $screenshotDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
})

Write-Host "Closing the CDP diagnostic instance and reopening Codex normally ..."
Stop-DreamSkinCodex -Codex $codex -AllowForce
Start-Sleep -Milliseconds 800
try {
  $null = Start-DreamSkinCodex -Codex $codex
} catch {
  Write-Warning "Codex could not be reopened automatically: $($_.Exception.Message)"
}

$json = $report | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($reportPath, $json, [System.Text.UTF8Encoding]::new($false))
Write-Host "Diagnostic report written to $reportPath"
