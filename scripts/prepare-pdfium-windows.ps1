param([switch]$Offline)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$release = Get-Content "$PSScriptRoot\pdfium-windows.json" -Raw | ConvertFrom-Json
$archive = "$root\.native\downloads\$($release.archive)"
[IO.Directory]::CreateDirectory("$root\.native\downloads") | Out-Null
if (-not (Test-Path $archive)) {
    if ($Offline) { throw 'Pinned PDFium archive is missing; build once without -Offline' }
    & curl.exe -fL --retry 3 -o "$archive.part" $release.url
    if ($LASTEXITCODE -ne 0) { throw 'PDFium download failed' }
    [IO.File]::Move("$archive.part", $archive)
}
$sha = [Security.Cryptography.SHA256]::Create()
$stream = [IO.File]::OpenRead($archive)
try { $actual = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
finally { $stream.Dispose(); $sha.Dispose() }
if ($actual -ne $release.sha256) { throw 'PDFium SHA256 mismatch' }
$source = "$root\.native\pdfium-win-x64"
[IO.Directory]::CreateDirectory($source) | Out-Null
& tar.exe -xf $archive -C $source
if ($LASTEXITCODE -ne 0) { throw 'PDFium extraction failed' }
Write-Output "Verified PDFium $($release.release)"
