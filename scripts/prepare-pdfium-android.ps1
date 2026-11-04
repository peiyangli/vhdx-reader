param([switch]$Offline)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\file-sha256.ps1"
$root = Split-Path $PSScriptRoot -Parent
$archive = "$root\.native\downloads\pdfium-android-arm64-8125.tgz"
if (-not (Test-Path $archive)) {
    if ($Offline) { throw 'Missing pinned Android PDFium archive' }
    [IO.Directory]::CreateDirectory((Split-Path $archive)) | Out-Null
    & curl.exe -fL --retry 3 https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F8125/pdfium-android-arm64.tgz -o "$archive.part"
    if ($LASTEXITCODE -ne 0) { throw 'Android PDFium download failed' }
    Move-Item "$archive.part" $archive
}
# Independently checked against GitHub release asset digest.
if ((Get-ArchiveSha256 $archive) -ne '0495e57163429937caaee1bdd9b07924a7098dbd51d1b97645d124e349f097b4') { throw 'Android PDFium checksum mismatch' }
$source = "$root\.native\pdfium-android-arm64"
[IO.Directory]::CreateDirectory($source) | Out-Null
& tar.exe -xf $archive -C $source
if ($LASTEXITCODE -ne 0) { throw 'Android PDFium extraction failed' }
