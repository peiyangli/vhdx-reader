param([Parameter(Mandatory=$true)][string]$Device, [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk")
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$adb = "$AndroidSdk\platform-tools\adb.exe"
$package = 'org.vhdxreader.vhdx_reader'
& $adb -s $Device shell run-as $package mkdir -p files/fixtures
if ($LASTEXITCODE -ne 0) { throw 'Install the debug APK first; run-as must be available' }
$items = @(
    @{name='basicvhdx.vhdx'; path="$root\examples\basicvhdx.vhdx"},
    @{name='bitlockervhdx.vhdx'; path="$root\examples\bitlockervhdx.vhdx"},
    @{name='password.txt'; path="$root\examples\password.txt"},
    @{name='pdf-preview.vhdx'; path="$root\.native\pdf-fixture\pdf-preview.vhdx"},
    @{name='media-preview.vhdx'; path="$root\.native\media-fixture\media-preview.vhdx"}
)
foreach ($item in $items) {
    # Binary stdin goes straight to the app's private directory. No shell/PowerShell
    # string ever contains the credential contents, and no shared-storage copy exists.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $adb
    $start.Arguments = "-s $Device exec-in `"run-as $package sh -c 'umask 077; cat > files/fixtures/$($item.name)'`""
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $process = [Diagnostics.Process]::Start($start)
    $inputFile = [IO.File]::OpenRead($item.path)
    try { $inputFile.CopyTo($process.StandardInput.BaseStream) }
    finally { $inputFile.Dispose(); $process.StandardInput.Close() }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw 'Fixture transfer failed' }
    $process.Dispose()
    Write-Output "Prepared private test fixture: $($item.name)"
}
