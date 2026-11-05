param([switch]$Offline, [switch]$SkipNative, [string]$FlutterPath, [switch]$Preview, [string]$PackageDirectory, [string]$ArchivePath)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\file-sha256.ps1"
$root = Split-Path $PSScriptRoot -Parent
if (-not $FlutterPath) {
    & "$PSScriptRoot\install-flutter-windows.ps1"
    $FlutterPath = "$root\.tools\flutter\bin\flutter.bat"
}
$env:PUB_CACHE = "$root\.tools\pub-cache"
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:CI = 'true'
& "$PSScriptRoot\build-windows.ps1" -Offline:$Offline -SkipNative:$SkipNative
Set-Location "$root\app"
$pubArgs = @('pub','get')
if ($Offline) { $pubArgs += '--offline' }
& $FlutterPath @pubArgs
if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed' }
& "$PSScriptRoot\prepare-pdfium-windows.ps1" -Offline:$Offline
& "$PSScriptRoot\prepare-media-windows.ps1" -Offline:$Offline
& $FlutterPath build windows --release --no-pub
if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows build failed' }
$package = if ($PackageDirectory) { $PackageDirectory } elseif ($Preview) { "$root\artifacts\gui-windows-ui-preview" } else { "$root\artifacts\gui-windows-x64" }
[IO.Directory]::CreateDirectory($package) | Out-Null
Copy-Item "$root\app\build\windows\x64\runner\Release\*" $package -Recurse -Force
Copy-Item "$root\README.md","$root\THIRD_PARTY.md","$root\LICENSE" $package -Force
Copy-Item "$root\artifacts\windows-x64\licenses" $package -Recurse -Force
$pdfium = "$root\.native\pdfium-win-x64"
# Verify that Flutter's downloaded native asset matches the independently pinned archive.
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $expected = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes("$pdfium\bin\pdfium.dll")))
    $actual = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes("$package\pdfium.dll")))
    if ($actual -ne $expected) { throw 'Bundled PDFium DLL differs from the pinned archive' }
} finally { $sha.Dispose() }
$pdfiumLicenses = "$package\licenses\pdfium"
[IO.Directory]::CreateDirectory($pdfiumLicenses) | Out-Null
Copy-Item "$pdfium\LICENSE","$pdfium\VERSION","$pdfium\args.gn" $pdfiumLicenses -Force
Copy-Item "$pdfium\licenses\*" $pdfiumLicenses -Recurse -Force
Copy-Item "$PSScriptRoot\pdfium-windows.json" "$package\licenses\" -Force
foreach ($dependency in (Get-Content "$PSScriptRoot\pdfium-windows.json" -Raw | ConvertFrom-Json).packages) {
    Copy-Item "$env:PUB_CACHE\hosted\pub.dev\$dependency\LICENSE" "$package\licenses\$dependency.txt" -Force
}
$media = Get-Content "$PSScriptRoot\media-windows.json" -Raw | ConvertFrom-Json
foreach ($item in $media.archives) {
    foreach ($dll in Get-ChildItem "$root\.native\media-verified\$($item.name)" -Filter '*.dll') {
        $bundled = Join-Path $package $dll.Name
        # Include the archive's runtime DLLs, including optional ANGLE dependencies.
        if (-not (Test-Path $bundled)) { Copy-Item $dll.FullName $bundled }
        if ((Get-ArchiveSha256 $dll.FullName) -ne (Get-ArchiveSha256 $bundled)) {
            throw "Bundled media DLL differs from pinned archive: $($dll.Name)"
        }
    }
}
foreach ($dependency in $media.packages) {
    Copy-Item "$env:PUB_CACHE\hosted\pub.dev\$dependency\LICENSE" "$package\licenses\$dependency.txt" -Force
}
Copy-Item "$PSScriptRoot\media-windows.json" "$package\licenses\" -Force
Copy-Item "$root\third_party\media" "$package\licenses\" -Recurse -Force
Write-Output "Desktop package: $package\vhdx_reader.exe"
$archive = if ($ArchivePath) { $ArchivePath } elseif ($Preview) { "$root\artifacts\vhdx-reader-windows-ui-preview.zip" } else { "$root\artifacts\vhdx-reader-desktop-windows-x64.zip" }
& "$PSScriptRoot\package-windows.ps1" -Directory $package -Archive $archive
[IO.File]::WriteAllText("$archive.sha256", "$(Get-ArchiveSha256 $archive)  $([IO.Path]::GetFileName($archive))`n", [Text.Encoding]::ASCII)
Write-Output "Desktop archive: $archive"
