param([switch]$Offline)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\file-sha256.ps1"
$root = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content "$PSScriptRoot\media-windows.json" -Raw | ConvertFrom-Json
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$cmake = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
foreach ($item in $manifest.archives) {
    $archive = "$root\.native\downloads\$($item.archive)"
    [IO.Directory]::CreateDirectory((Split-Path $archive)) | Out-Null
    if (-not (Test-Path $archive)) {
        if ($Offline) { throw "Missing media archive: $($item.archive)" }
        & curl.exe -fL --retry 3 -o "$archive.part" $item.url
        if ($LASTEXITCODE -ne 0) { throw 'Media download failed' }
        Move-Item "$archive.part" $archive
    }
    if ((Get-ArchiveSha256 $archive) -ne $item.sha256) {
        throw "Media SHA256 mismatch: $($item.archive)"
    }
    $build = "$root\app\build\windows\x64"
    [IO.Directory]::CreateDirectory($build) | Out-Null
    Copy-Item $archive $build -Force
    $source = "$root\.native\media-verified\$($item.name)"
    [IO.Directory]::CreateDirectory($source) | Out-Null
    Push-Location $source
    try {
        & $cmake -E tar xf $archive
        if ($LASTEXITCODE -ne 0) { throw 'Media extraction failed' }
    } finally { Pop-Location }
    Write-Output "Verified media archive: $($item.archive)"
}
