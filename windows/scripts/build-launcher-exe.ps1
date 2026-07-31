[CmdletBinding()]
param(
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
try {
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  [Console]::OutputEncoding = $utf8
  $OutputEncoding = $utf8
} catch {}

$packageRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $packageRoot 'windows\launcher-native.c'
$resourceSource = Join-Path $packageRoot 'windows\launcher.rc'
$output = if ($OutputPath) {
  [System.IO.Path]::GetFullPath($OutputPath)
} else {
  Join-Path $packageRoot 'CodexDreamSkinLauncher.exe'
}

function Resolve-Tool {
  param([string]$Name, [string[]]$Candidates)
  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  foreach ($candidate in $Candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }
  throw "缺少构建工具：$Name"
}

$gcc = Resolve-Tool -Name 'gcc.exe' -Candidates @(
  'C:\software\VScode\mingw64\bin\gcc.exe',
  (Join-Path ${env:ProgramFiles} 'mingw64\bin\gcc.exe')
)
$windres = Resolve-Tool -Name 'windres.exe' -Candidates @(
  'C:\software\VScode\mingw64\bin\windres.exe',
  (Join-Path ${env:ProgramFiles} 'mingw64\bin\windres.exe')
)

foreach ($required in @($source, $resourceSource)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "缺少构建源文件：$required"
  }
}

$outputDirectory = [System.IO.Path]::GetDirectoryName($output)
if (-not [System.IO.Directory]::Exists($outputDirectory)) {
  [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
  ('CodexDreamSkin-Build-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
$resourceObject = Join-Path $temporaryRoot 'launcher-resource.o'
$temporaryExe = Join-Path $temporaryRoot 'CodexDreamSkinLauncher.exe'

try {
  & $windres '--codepage=65001' '--include-dir' (Join-Path $packageRoot 'windows') `
    '-i' $resourceSource '-o' $resourceObject
  if ($LASTEXITCODE -ne 0) { throw "windres 构建失败，错误代码：$LASTEXITCODE" }

  & $gcc '-std=c11' '-O2' '-s' '-municode' '-mwindows' `
    '-Wl,--dynamicbase,--nxcompat,--high-entropy-va' `
    $source $resourceObject '-o' $temporaryExe '-lkernel32' '-luser32'
  if ($LASTEXITCODE -ne 0) { throw "gcc 构建失败，错误代码：$LASTEXITCODE" }

  $bytes = [System.IO.File]::ReadAllBytes($temporaryExe)
  if ($bytes.Length -lt 4096 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
    throw '生成结果不是有效的 Windows PE 可执行文件。'
  }
  Copy-Item -LiteralPath $temporaryExe -Destination $output -Force
  $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
  Write-Host "已生成：$output" -ForegroundColor Green
  Write-Host "SHA-256：$hash"
} finally {
  if (Test-Path -LiteralPath $temporaryRoot) {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
  }
}
