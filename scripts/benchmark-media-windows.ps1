param(
    [ValidateRange(1,100)][int]$Rounds = 7,
    [ValidateRange(1,100)][int]$Repeats = 16,
    [ValidateRange(1,100)][int]$PlaybackRounds = 3,
    [string]$OutputDirectory,
    [switch]$SkipTests,
    [switch]$SkipPlayback
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = "$root\.native\http-native" }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
# cmd owns redirection so Windows PowerShell does not turn cargo's stderr
# progress messages into terminating NativeCommandError exceptions.
function Run-Logged([string]$Command, [string]$Name) {
    $log = Join-Path $OutputDirectory $Name
    & $env:ComSpec /d /c "$Command > `"$log`" 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Get-Content $log -Tail 60
        throw "Failed ($LASTEXITCODE): $Name"
    }
    Write-Output "Saved $log"
}
Set-Location $root
$env:CARGO_TARGET_DIR = "$root\target\windows"
$env:PUB_CACHE = "$root\.tools\pub-cache"
$env:VHDX_NATIVE_DIR = "$root\.native\build-windows\bin\Release"
$env:VHDX_SAMPLE_DIR = "$root\examples"
$env:VHDX_READ_FIXTURE = "$root\.native\read-performance.vhdx"
$env:VHDX_MEDIA_FIXTURE = "$root\.native\media-fixture\media-preview.vhdx"
if (-not $SkipTests) {
    Run-Logged 'cargo test --locked --offline --workspace -- --include-ignored' 'windows-rust.log'
    Run-Logged 'cargo clippy --locked --offline --workspace --all-targets -- -D warnings' 'windows-clippy.log'
}
Run-Logged 'cargo build --release --locked --offline -p vhdx-app --example media_benchmark' 'windows-build.log'
$env:VHDX_BENCH_ROUNDS = "$Rounds"
$env:VHDX_BENCH_REPEATS = "$Repeats"
try {
    $env:VHDX_BENCH_PASSWORD_FILE = "$root\examples\password.txt"
    Run-Logged 'target\windows\release\examples\media_benchmark.exe examples\bitlockervhdx.vhdx /video/avi.avi' 'bitlocker-avi.csv'
} finally { Remove-Item Env:VHDX_BENCH_PASSWORD_FILE -ErrorAction SilentlyContinue }
Run-Logged 'target\windows\release\examples\media_benchmark.exe .native\read-performance.vhdx /payload.bin' 'plain-32m.csv'
if (-not $SkipPlayback) {
    Set-Location "$root\app"
    $flutter = "call `"$root\.tools\flutter\bin\flutter.bat`""
    Run-Logged "$flutter analyze --no-pub" 'flutter-analyze.log'
    Run-Logged "$flutter test integration_test/media_transport_test.dart -d windows --no-pub --dart-define=VHDX_MEDIA_BENCH_ROUNDS=$PlaybackRounds" 'playback.log'
    if (-not $SkipTests) {
        Run-Logged "$flutter test integration_test/media_transport_regression_test.dart -d windows --no-pub --dart-define=VHDX_MEDIA_TRANSPORT=native" 'native-regression.log'
    }
}
