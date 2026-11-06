param([switch]$Offline, [switch]$SkipNative, [string]$ArtifactDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $ArtifactDirectory) { $ArtifactDirectory = "$root\artifacts" }
Set-Location $root
if (-not $SkipNative) {
    & (Join-Path $PSScriptRoot 'prepare-native-windows.ps1')
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw 'Visual Studio C++ build tools and Windows SDK are required' }
    $cmake = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    if (-not (Test-Path $cmake)) { $cmake = (Get-Command cmake -ErrorAction Stop).Source }
    # Default VS generator is selected by the installed CMake, with an explicit x64 target.
    & $cmake -S "$root\.native" -B "$root\.native\build-windows" -A x64
    if ($LASTEXITCODE -ne 0) { throw 'Native configure failed' }
    & $cmake --build "$root\.native\build-windows" --config Release --parallel 6
    if ($LASTEXITCODE -ne 0) { throw 'Native build failed' }
}
$env:CARGO_TARGET_DIR = "$root\target\windows"
$cargoArgs = @('build', '--release', '--locked')
if ($Offline) { $cargoArgs += '--offline' }
& cargo @cargoArgs
if ($LASTEXITCODE -ne 0) { throw 'Rust build failed' }
$package = Join-Path $ArtifactDirectory "windows-x64"
[IO.Directory]::CreateDirectory("$package\native") | Out-Null
[IO.Directory]::CreateDirectory("$package\licenses") | Out-Null
Copy-Item "$root\target\windows\release\vhdx.exe" "$package\vhdx.exe"
foreach ($item in (Get-Content "$PSScriptRoot\native-sources.json" -Raw | ConvertFrom-Json)) {
    Copy-Item "$root\.native\build-windows\bin\Release\$($item.name).dll" "$package\native\"
    $licenseDir = "$package\licenses\$($item.name)"
    [IO.Directory]::CreateDirectory($licenseDir) | Out-Null
    Get-ChildItem "$root\.native\src\$($item.name)-$($item.version)" -Filter 'COPYING*' | Copy-Item -Destination $licenseDir
    Copy-Item "$root\.native\src\$($item.name)-$($item.version)\AUTHORS" $licenseDir
}
Copy-Item "$root\README.md","$root\THIRD_PARTY.md","$root\LICENSE" $package
Copy-Item "$PSScriptRoot\native-sources.json" "$package\licenses\native-sources.json"
& "$package\vhdx.exe" doctor
if ($LASTEXITCODE -ne 0) { throw 'Packaged executable could not load native dependencies' }
Write-Output "Windows package: $package"
$archive = Join-Path $ArtifactDirectory "vhdx-reader-windows-x64.zip"
& "$PSScriptRoot\package-windows.ps1" -Directory $package -Archive $archive
