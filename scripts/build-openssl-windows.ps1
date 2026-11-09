param([switch]$Offline)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\file-sha256.ps1"
$root = Split-Path $PSScriptRoot -Parent
$item = Get-Content "$PSScriptRoot\openssl-source.json" -Raw | ConvertFrom-Json
$archive = "$root\.native\downloads\openssl-$($item.version).tar.gz"
$source = "$root\.native\src\openssl-$($item.version)"
$build = "$root\.native\openssl-windows-x64"
$stamp = "$build\verified-build.txt"
$identity = "$($item.sha256) VC-WIN64A no-shared no-tests no-apps MD v1"
if ((Test-Path $stamp) -and (Test-Path "$build\libcrypto.lib") -and ((Get-Content $stamp -Raw).Trim() -eq $identity)) { return }
[IO.Directory]::CreateDirectory((Split-Path $archive)) | Out-Null
if (-not (Test-Path $archive)) {
    if ($Offline) { throw "Missing pinned OpenSSL archive: $archive" }
    Invoke-WebRequest $item.url -OutFile "$archive.part"
    Move-Item "$archive.part" $archive -Force
}
if ((Get-ArchiveSha256 $archive) -ne $item.sha256) { throw 'OpenSSL archive checksum mismatch' }
if (-not (Test-Path $source)) {
    [IO.Directory]::CreateDirectory((Split-Path $source)) | Out-Null
    & tar.exe -xf $archive -C (Split-Path $source)
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSL extraction failed' }
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio C++ build tools are required' }
$perl = (Get-Command perl.exe -ErrorAction Stop).Source
$nasm = (Get-Command nasm.exe -ErrorAction Stop).Source
[IO.Directory]::CreateDirectory($build) | Out-Null
# Out-of-tree build; static libcrypto uses the same /MD runtime as libbde.
$commands = @('@echo off', ('call "' + $vs + '\VC\Auxiliary\Build\vcvars64.bat"'),
    'if errorlevel 1 exit /b 1', ('set "PATH=' + (Split-Path $nasm) + ';%PATH%"'),
    ('cd /d "' + $build + '"'),
    ('"' + $perl + '" "' + $source + '\Configure" VC-WIN64A no-shared no-tests no-apps /MD'),
    'if errorlevel 1 exit /b 1', 'nmake /nologo build_libs', 'exit /b %errorlevel%')
[IO.File]::WriteAllLines("$build\build.cmd", $commands, [Text.Encoding]::ASCII)
& cmd.exe /c "$build\build.cmd"
if ($LASTEXITCODE -ne 0) { throw 'OpenSSL build failed' }
[IO.File]::WriteAllText($stamp, $identity + "`n", [Text.Encoding]::ASCII)
