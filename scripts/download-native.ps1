$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot -Parent
$dest = Join-Path $root '.native\downloads'
[IO.Directory]::CreateDirectory($dest) | Out-Null
$items = Get-Content (Join-Path $PSScriptRoot 'native-sources.json') -Raw | ConvertFrom-Json
foreach ($item in $items) {
    $name = "$($item.name)-$($item.status)-$($item.version).tar.gz"
    $path = Join-Path $dest $name
    if (-not [IO.File]::Exists($path)) {
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/libyal/$($item.name)/releases/download/$($item.version)/$name" -OutFile "$path.part"
        [IO.File]::Move("$path.part", $path)
    }
    $stream = [IO.File]::OpenRead($path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
    if ($hash -ne $item.sha256) { throw "Checksum mismatch: $name" }
    Write-Output "Verified $name"
}
