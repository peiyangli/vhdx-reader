param(
    [switch]$SkipNative,
    [switch]$Offline,
    [switch]$DebugBuild,
    [switch]$Preview,
    [string]$ArtifactDirectory,
    [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk",
    [string]$MsysRoot = 'C:\msys64',
    [string]$JavaHome = 'C:\Program Files\Android\Android Studio\jbr'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\file-sha256.ps1"
$root = Split-Path $PSScriptRoot -Parent
if (-not $ArtifactDirectory) { $ArtifactDirectory = "$root\artifacts" }
$ndk = "$AndroidSdk\ndk\27.3.13750724"
if (-not (Test-Path "$ndk\source.properties")) { throw 'Install Android NDK 27.3.13750724 first' }
$env:VHDX_OFFLINE = if ($Offline) { '1' } else { '0' }
$env:JAVA_HOME = $JavaHome
$env:ANDROID_HOME = $AndroidSdk
$env:PUB_CACHE = "$root\.tools\pub-cache"
if (-not (Test-Path "$root\.tools\flutter\bin\flutter.bat")) { & "$PSScriptRoot\install-flutter-windows.ps1" }
$flutter = "$root\.tools\flutter\bin\flutter.bat"
$cmake = "$root\.tools\cmake-3.31.6-windows-x86_64"
if (-not (Test-Path "$cmake\bin\cmake.exe")) {
    $archive = "$root\.native\downloads\cmake-3.31.6-windows-x86_64.zip"
    [IO.Directory]::CreateDirectory((Split-Path $archive)) | Out-Null
    if (-not (Test-Path $archive)) {
        if ($Offline) { throw 'Missing pinned CMake archive' }
        & curl.exe -fL --retry 3 https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-windows-x86_64.zip -o "$archive.part"
        if ($LASTEXITCODE -ne 0) { throw 'CMake download failed' }
        Move-Item "$archive.part" $archive
    }
    if ((Get-ArchiveSha256 $archive) -ne '83d9c4a7caac0d4b56c0a0123ddc6c07502eb8ab358c77c7866a7004fe41e72f') { throw 'CMake checksum mismatch' }
    & tar.exe -xf $archive -C "$root\.tools"
    if ($LASTEXITCODE -ne 0) { throw 'CMake extraction failed' }
}
if (-not $SkipNative) {
    $tools = @(
        @{name='make'; file='make-4.4.1-3-x86_64.pkg.tar.zst'; sha='af0bdba17f06fe037f0194069adaa31a8fe45f1a11381501896aea1fae37bd5d'},
        @{name='pkgconf'; file='pkgconf-3.0.10-1-x86_64.pkg.tar.zst'; sha='ab9fdaf563938752aecd8b5495954e1e04f6ac5721a6522b35374e548fc357c2'}
    )
    foreach ($tool in $tools) {
        $folder = "$root\.tools\msys-$($tool.name)"
        $archive = "$folder\$($tool.name).pkg.tar.zst"
        [IO.Directory]::CreateDirectory($folder) | Out-Null
        if (-not (Test-Path $archive)) {
            if ($Offline) { throw "Missing $($tool.file)" }
            & curl.exe -fL --retry 3 "https://repo.msys2.org/msys/x86_64/$($tool.file)" -o "$archive.part"
            if ($LASTEXITCODE -ne 0) { throw 'Build tool download failed' }
            Move-Item "$archive.part" $archive
        }
        if ((Get-ArchiveSha256 $archive) -ne $tool.sha) { throw 'Build tool checksum mismatch' }
        & "$MsysRoot\usr\bin\bsdtar.exe" -xf $archive -C $folder
        if ($LASTEXITCODE -ne 0) { throw 'Build tool extraction failed' }
    }
    # Download/extract exactly the same audited sources as the desktop build.
    & "$PSScriptRoot\prepare-native-windows.ps1"
    $env:VHDX_ANDROID_NDK = & "$MsysRoot\usr\bin\cygpath.exe" -u $ndk
    $posixRoot = & "$MsysRoot\usr\bin\cygpath.exe" -u $root
    & "$MsysRoot\usr\bin\bash.exe" --login "$posixRoot/scripts/build-native-android.sh"
    if ($LASTEXITCODE -ne 0) { throw 'Android C library build failed; inspect .native/build-android logs' }
}
$crypto = Get-Content "$PSScriptRoot\openssl-source.json" -Raw | ConvertFrom-Json
$backend = Get-Content "$root\.native\android\arm64-v8a\native-crypto.json" -Raw | ConvertFrom-Json
if ($backend.backend -ne 'openssl-evp' -or $backend.sha256 -ne $crypto.sha256 -or $backend.version -ne $crypto.version) { throw 'Native crypto backend mismatch; rebuild without -SkipNative' }
$env:CARGO_TARGET_DIR = "$root\target\android"
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = "$ndk\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android24-clang.cmd"
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS = '-C link-arg=-Wl,-z,max-page-size=16384'
Set-Location $root
$cargoArgs = @('build','-p','vhdx-app','-p','vhdx-cli','--release','--locked','--target','aarch64-linux-android')
if ($Offline) { $cargoArgs += '--offline' }
& cargo @cargoArgs
if ($LASTEXITCODE -ne 0) { throw 'Android Rust build failed' }
$jni = "$root\app\android\app\src\main\jniLibs\arm64-v8a"
[IO.Directory]::CreateDirectory($jni) | Out-Null
Copy-Item "$root\target\android\aarch64-linux-android\release\libvhdx_app.so" $jni -Force
$licenses = "$root\app\android\app\src\main\assets\licenses"
if (Test-Path $licenses) { Remove-Item $licenses -Recurse -Force }
[IO.Directory]::CreateDirectory($licenses) | Out-Null
foreach ($item in (Get-Content "$PSScriptRoot\native-sources.json" -Raw | ConvertFrom-Json)) {
    Copy-Item "$root\.native\android\arm64-v8a\lib\$($item.name).so" $jni -Force
    $dir = "$licenses\$($item.name)"
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    Copy-Item "$root\.native\src\$($item.name)-$($item.version)\COPYING*","$root\.native\src\$($item.name)-$($item.version)\AUTHORS" $dir -Force
}
[IO.Directory]::CreateDirectory("$licenses\openssl") | Out-Null
Copy-Item "$root\.native\src\openssl-$($crypto.version)\LICENSE.txt","$root\.native\src\openssl-$($crypto.version)\AUTHORS.md","$PSScriptRoot\openssl-source.json" "$licenses\openssl" -Force
Copy-Item "$root\.native\android\arm64-v8a\native-crypto.json" $licenses -Force
Copy-Item "$root\THIRD_PARTY.md","$PSScriptRoot\native-sources.json","$PSScriptRoot\media-android.json" $licenses -Force
& "$PSScriptRoot\prepare-pdfium-android.ps1" -Offline:$Offline
Copy-Item "$root\third_party\rust" "$licenses\rust" -Recurse -Force
[IO.Directory]::CreateDirectory("$licenses\pdfium") | Out-Null
Copy-Item "$root\.native\pdfium-android-arm64\LICENSE","$root\.native\pdfium-android-arm64\VERSION","$root\.native\pdfium-android-arm64\args.gn" "$licenses\pdfium" -Force
Copy-Item "$root\.native\pdfium-android-arm64\licenses" "$licenses\pdfium\licenses" -Recurse -Force
Set-Location "$root\app"
$pubArgs = @('pub','get')
if ($Offline) { $pubArgs += '--offline' }
& $flutter @pubArgs
if ($LASTEXITCODE -ne 0) { throw 'Flutter pub get failed' }
Copy-Item "$env:PUB_CACHE\hosted\pub.dev\media_kit_libs_android_video-1.3.8\LICENSE" "$licenses\media_kit_libs_android_video.txt" -Force
# Pre-cache the plugin's pinned native archives with SHA-256 verification.
$media = Get-Content "$PSScriptRoot\media-android.json" -Raw | ConvertFrom-Json
foreach ($item in $media.archives) {
    $archive = "$root\app\build\media_kit_libs_android_video\$($media.release)\$($item.archive)"
    [IO.Directory]::CreateDirectory((Split-Path $archive)) | Out-Null
    if (-not (Test-Path $archive)) {
        if ($Offline) { throw "Missing Android media archive: $($item.archive)" }
        & curl.exe -fL --retry 3 $item.url -o "$archive.part"
        if ($LASTEXITCODE -ne 0) { throw 'Android media download failed' }
        Move-Item "$archive.part" $archive
    }
    if ((Get-ArchiveSha256 $archive) -ne $item.sha256) { throw 'Android media checksum mismatch' }
}
$mode = if ($DebugBuild) { 'debug' } else { 'release' }
$properties = "$root\app\android\local.properties"
$lines = if (Test-Path $properties) { @(Get-Content $properties | Where-Object { $_ -notmatch '^cmake.dir=' }) } else { @() }
[IO.File]::WriteAllLines($properties, @($lines) + "cmake.dir=$($cmake.Replace('\','/'))")
# Flutter must regenerate the plugin registrant for the selected build mode.
# --no-pub would retain debug-only integration_test registration in a release build.
& $flutter build apk "--$mode" --target-platform android-arm64
if ($LASTEXITCODE -ne 0) { throw 'Android APK build failed' }
[IO.Directory]::CreateDirectory($ArtifactDirectory) | Out-Null
$artifactName = if ($Preview -and -not $DebugBuild) { "ui-preview" } else { $mode }
$output = Join-Path $ArtifactDirectory "vhdx-reader-android-arm64-$artifactName.apk"
& "$PSScriptRoot\verify-android-apk.ps1" -Apk "$root\app\build\app\outputs\flutter-apk\app-$mode.apk"
Copy-Item "$root\app\build\app\outputs\flutter-apk\app-$mode.apk" $output -Force
$outputHash = Get-ArchiveSha256 $output
[IO.File]::WriteAllText("$output.sha256", "$outputHash  $([IO.Path]::GetFileName($output))`n", [Text.Encoding]::ASCII)
Write-Output "Android APK (development signing): $output"
Write-Output "SHA256: $outputHash"
