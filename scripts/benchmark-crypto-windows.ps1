param(
    [Parameter(Mandatory=$true)][string]$Image,
    [Parameter(Mandatory=$true)][string]$File,
    [string]$PasswordFile,
    [Parameter(Mandatory=$true)][string]$BaselineNative,
    [Parameter(Mandatory=$true)][string]$CandidateNative,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\file-sha256.ps1"
$root = Split-Path $PSScriptRoot -Parent
$reader = "$root\target\windows\release\examples\pipeline_benchmark.exe"
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$oldNative = $env:VHDX_NATIVE_DIR
$oldPassword = $env:VHDX_BENCH_PASSWORD_FILE
$oldRounds = $env:VHDX_BENCH_ROUNDS
try {
    $env:VHDX_BENCH_PASSWORD_FILE = $PasswordFile
    $env:VHDX_BENCH_ROUNDS = '1'
    $expectedHash = $null
    # Discard pass 0. Alternate order to reduce bias from clock/thermal drift.
    for ($pass = 0; $pass -le 5; $pass++) {
        $backends = if ($pass % 2) { @('builtin','openssl') } else { @('openssl','builtin') }
        foreach ($backend in $backends) {
            $env:VHDX_NATIVE_DIR = if ($backend -eq 'builtin') { $BaselineNative } else { $CandidateNative }
            foreach ($mode in @('ram','file')) {
                $lines = & $reader $Image $File $mode
                if ($LASTEXITCODE -ne 0) { throw "Read benchmark failed: $backend $mode" }
                $hash = @($lines | Where-Object { $_ -like '# sha256=*' })
                if ($hash.Count -ne 1) { throw 'Missing integrity hash' }
                if ($null -eq $expectedHash) { $expectedHash = $hash[0] }
                if ($expectedHash -ne $hash[0]) { throw 'Backend plaintext mismatch' }
                $lines | Set-Content "$OutputDirectory\$backend-$mode-$pass.csv" -Encoding ASCII
            }
        }
    }
    foreach ($backend in @('builtin','openssl')) {
        & "$CandidateNative\crypto_$backend.exe" "$OutputDirectory\$backend-vectors.bin" | Set-Content "$OutputDirectory\$backend-sectors.csv" -Encoding ASCII
        if ($LASTEXITCODE -ne 0) { throw "Sector benchmark failed: $backend" }
    }
    if ((Get-ArchiveSha256 "$OutputDirectory\builtin-vectors.bin") -ne (Get-ArchiveSha256 "$OutputDirectory\openssl-vectors.bin")) { throw 'CBC/XTS ciphertext mismatch' }
    Write-Output 'PASS: file hashes, cross-sector reads, CBC known answer, CBC/XTS 128/256 roundtrips and ciphertext equivalence'
} finally {
    $env:VHDX_NATIVE_DIR = $oldNative
    $env:VHDX_BENCH_PASSWORD_FILE = $oldPassword
    $env:VHDX_BENCH_ROUNDS = $oldRounds
}
