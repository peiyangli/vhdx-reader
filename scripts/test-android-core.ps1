param([Parameter(Mandatory=$true)][string]$Device, [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk")
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$adb = "$AndroidSdk\platform-tools\adb.exe"
$remote = "/data/local/tmp/vhdx-reader-test-$([Guid]::NewGuid().ToString('N'))"
function Invoke-AdbChecked([string[]]$Arguments) {
    & $adb -s $Device @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'ADB/native test failed' }
}
Invoke-AdbChecked @('shell', "mkdir -m 700 $remote")
try {
    Invoke-AdbChecked @('push', "$root\target\android\aarch64-linux-android\release\vhdx", "$remote/vhdx")
    foreach ($name in @('libbfio','libvhdi','libbde','libfsntfs')) {
        Invoke-AdbChecked @('push', "$root\.native\android\arm64-v8a\lib\$name.so", "$remote/$name.so")
    }
    foreach ($name in @('basicvhdx.vhdx','bitlockervhdx.vhdx','password.txt')) {
        Invoke-AdbChecked @('push', "$root\examples\$name", "$remote/$name")
    }
    Invoke-AdbChecked @('shell', "chmod 700 $remote/vhdx; chmod 600 $remote/password.txt")
    Invoke-AdbChecked @('shell', "$remote/vhdx --native-dir $remote doctor")
    $plain = Invoke-AdbChecked @('shell', "$remote/vhdx --native-dir $remote hash $remote/basicvhdx.vhdx /can.txt")
    if ($plain.Trim() -ne 'd17db066fd31241f1d01b298db6e3e705e1f3b979251c599e27cb5f77d2fee3a') { throw 'Ordinary image hash mismatch' }
    $encrypted = Invoke-AdbChecked @('shell', "$remote/vhdx --native-dir $remote hash $remote/bitlockervhdx.vhdx /hello.txt --password-file $remote/password.txt")
    if ($encrypted.Trim() -ne '486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7') { throw 'Encrypted image hash mismatch' }
    Write-Output 'Android ARM64 core: ordinary NTFS and BitLocker password read hashes match Windows/Linux.'
} finally {
    # This randomly named directory was created by this invocation only.
    & $adb -s $Device shell "rm -rf $remote"
}
