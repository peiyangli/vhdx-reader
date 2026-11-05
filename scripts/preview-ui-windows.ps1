param([switch]$NoLaunch)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$env:PUB_CACHE = "$root\.tools\pub-cache"
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:VHDX_SAMPLE_DIR = "$root\examples"
$env:VHDX_NATIVE_DIR = "$root\.native\build-windows\bin\Release"
$env:CARGO_TARGET_DIR = "$root\target\windows"
$log = "$root\artifacts\windows-ui-preview-build.log"
Start-Transcript -Path $log -Force
try {
    & "$PSScriptRoot\check-ui-windows.ps1"
    Set-Location "$root\app"
    & "$root\.tools\flutter\bin\flutter.bat" test --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Flutter regression tests failed' }
    Set-Location $root
    & cargo test --workspace --locked --offline -- --include-ignored
    if ($LASTEXITCODE -ne 0) { throw 'Rust regression tests failed' }
    Set-Location "$root\app"
    $env:VHDX_SCREENSHOT = "$root\artifacts\windows-ui-preview.png"
    & "$root\.tools\flutter\bin\flutter.bat" test integration_test/native_test.dart -d windows --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows native integration tests failed' }
    $preview = Get-Process vhdx_reader -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq "$root\artifacts\gui-windows-ui-preview\vhdx_reader.exe" }
    foreach ($app in $preview) {
        $app.CloseMainWindow() | Out-Null
        if (-not $app.WaitForExit(10000)) { throw 'Close the preview before rebuilding' }
    }
    & "$PSScriptRoot\build-desktop-windows.ps1" -SkipNative -Offline -Preview
    if (-not $NoLaunch) {
        Start-Process -FilePath "$root\artifacts\gui-windows-ui-preview\vhdx_reader.exe" `
            -WorkingDirectory "$root\artifacts\gui-windows-ui-preview" `
            -ArgumentList ('"' + "$root\examples\basicvhdx.vhdx" + '"')
    }
} finally {
    Stop-Transcript
}
