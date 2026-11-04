$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tools = Join-Path $root '.tools'
[IO.Directory]::CreateDirectory($tools) | Out-Null
$release = Get-Content "$PSScriptRoot\flutter-sdk.json" -Raw | ConvertFrom-Json
if (Test-Path "$tools\flutter\bin\flutter.bat") {
    Write-Output "Local Flutter: $tools\flutter\bin\flutter.bat"
    return
}
$archive = "$tools\flutter.zip"
if (-not (Test-Path $archive)) {
    & curl.exe -fL --retry 3 -o "$archive.part" ($release.base_url + $release.archive)
    if ($LASTEXITCODE -ne 0) { throw 'Flutter download failed' }
    [IO.File]::Move("$archive.part", $archive)
}
$sha = [Security.Cryptography.SHA256]::Create()
$stream = [IO.File]::OpenRead($archive)
try { $actual = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
finally { $stream.Dispose(); $sha.Dispose() }
if ($actual -ne $release.sha256) { throw 'Flutter SHA256 mismatch' }
& tar.exe -xf $archive -C $tools
if ($LASTEXITCODE -ne 0) { throw 'Flutter extraction failed' }
Write-Output "Installed Flutter $($release.version) inside the project."
