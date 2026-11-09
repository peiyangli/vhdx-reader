param([switch]$Offline, [switch]$SkipNative, [string]$ArtifactDirectory, [ValidateSet("openssl","builtin")][string]$NativeCryptoBackend = "openssl")
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $ArtifactDirectory) { $ArtifactDirectory = "$root\artifacts" }
Set-Location $root
if (-not $SkipNative) {
    if ($NativeCryptoBackend -eq 'openssl') {
        & (Join-Path $PSScriptRoot 'build-openssl-windows.ps1') -Offline:$Offline
    }
    & (Join-Path $PSScriptRoot 'prepare-native-windows.ps1')
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw 'Visual Studio C++ build tools and Windows SDK are required' }
    $cmake = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    if (-not (Test-Path $cmake)) { $cmake = (Get-Command cmake -ErrorAction Stop).Source }
    # Default VS generator is selected by the installed CMake, with an explicit x64 target.
    $openssl = if ($NativeCryptoBackend -eq 'openssl') { 'ON' } else { 'OFF' }
    & $cmake -S "$root\.native" -B "$root\.native\build-windows" -A x64 "-DVHDX_OPENSSL=$openssl" -DVHDX_CRYPTO_BENCHMARK=OFF
    if ($LASTEXITCODE -ne 0) { throw 'Native configure failed' }
    & $cmake --build "$root\.native\build-windows" --config Release --parallel 6
    if ($LASTEXITCODE -ne 0) { throw 'Native build failed' }
}
$nativeCache = Get-Content "$root\.native\build-windows\CMakeCache.txt" -Raw
$builtWithOpenSsl = $nativeCache -match '(?m)^VHDX_OPENSSL:BOOL=ON\r?$'
if ($builtWithOpenSsl -ne ($NativeCryptoBackend -eq 'openssl')) { throw 'Native crypto backend mismatch; rebuild without -SkipNative' }
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
if ($builtWithOpenSsl) {
    $crypto = Get-Content "$PSScriptRoot\openssl-source.json" -Raw | ConvertFrom-Json
    $licenseDir = "$package\licenses\openssl"
    [IO.Directory]::CreateDirectory($licenseDir) | Out-Null
    Copy-Item "$root\.native\src\openssl-$($crypto.version)\LICENSE.txt","$root\.native\src\openssl-$($crypto.version)\AUTHORS.md" $licenseDir
    Copy-Item "$PSScriptRoot\openssl-source.json" $licenseDir
}
[IO.File]::WriteAllText("$package\licenses\native-build.json", (@{crypto_backend=$NativeCryptoBackend} | ConvertTo-Json), [Text.Encoding]::UTF8)
Copy-Item "$root\README.md","$root\THIRD_PARTY.md","$root\LICENSE" $package
Copy-Item "$PSScriptRoot\native-sources.json" "$package\licenses\native-sources.json"
& "$package\vhdx.exe" doctor
if ($LASTEXITCODE -ne 0) { throw 'Packaged executable could not load native dependencies' }
Write-Output "Windows package: $package"
$archive = Join-Path $ArtifactDirectory "vhdx-reader-windows-x64.zip"
& "$PSScriptRoot\package-windows.ps1" -Directory $package -Archive $archive
