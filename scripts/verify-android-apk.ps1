param([Parameter(Mandatory=$true)][string]$Apk)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Read-Entry($Archive, [string]$Name) {
    $entry = $Archive.GetEntry($Name)
    if ($null -eq $entry) { throw "Missing APK entry: $Name" }
    $stream = $entry.Open()
    $buffer = New-Object IO.MemoryStream
    try { $stream.CopyTo($buffer); return ,$buffer.ToArray() }
    finally { $stream.Dispose(); $buffer.Dispose() }
}
function Hash-Bytes([byte[]]$Bytes) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($Bytes)) }
    finally { $hash.Dispose() }
}
$zip = [IO.Compression.ZipFile]::OpenRead($Apk)
try {
    $libs = @($zip.Entries | Where-Object { $_.FullName -match '^lib/.+\.so$' })
    if ($libs.Count -eq 0) { throw 'APK has no native libraries' }
    foreach ($entry in $libs) {
        if ($entry.FullName -notmatch '^lib/arm64-v8a/') { throw "Unexpected ABI: $($entry.FullName)" }
        [byte[]]$elf = Read-Entry $zip $entry.FullName
        if ($elf.Length -lt 64 -or $elf[0] -ne 127 -or $elf[1] -ne 69 -or $elf[2] -ne 76 -or $elf[3] -ne 70 -or $elf[4] -ne 2 -or $elf[5] -ne 1 -or [BitConverter]::ToUInt16($elf, 18) -ne 183) {
            throw "Not an ARM64 little-endian ELF: $($entry.FullName)"
        }
        $offset = [BitConverter]::ToUInt64($elf, 32)
        $stride = [BitConverter]::ToUInt16($elf, 54)
        $count = [BitConverter]::ToUInt16($elf, 56)
        for ($i = 0; $i -lt $count; $i++) {
            $header = [int]($offset + $stride * $i)
            if ([BitConverter]::ToUInt32($elf, $header) -ne 1) { continue }
            $alignment = [BitConverter]::ToUInt64($elf, $header + 48)
            $fileOffset = [BitConverter]::ToUInt64($elf, $header + 8)
            $address = [BitConverter]::ToUInt64($elf, $header + 16)
            if ($alignment -lt 16384 -or ($fileOffset % 16384) -ne ($address % 16384)) {
                throw "ELF is not 16 KiB compatible: $($entry.FullName)"
            }
        }
    }
    foreach ($name in @('libvhdx_app','libbfio','libvhdi','libbde','libfsntfs','libflutter','libpdfium','libmpv')) {
        if ($null -eq $zip.GetEntry("lib/arm64-v8a/$name.so")) { throw "Missing native library: $name" }
    }
    $pdf = Read-Entry $zip 'lib/arm64-v8a/libpdfium.so'
    if ((Hash-Bytes $pdf) -ne (Hash-Bytes ([IO.File]::ReadAllBytes("$root\.native\pdfium-android-arm64\lib\libpdfium.so")))) {
        throw 'Packaged PDFium differs from the verified archive'
    }
    $media = [IO.Compression.ZipFile]::OpenRead("$root\app\build\media_kit_libs_android_video\v1.1.7\default-arm64-v8a.jar")
    try {
        foreach ($name in @('libmpv.so','libmediakitandroidhelper.so')) {
            $original = $media.Entries | Where-Object { $_.FullName.EndsWith("/$name") } | Select-Object -First 1
            if ($null -eq $original -or (Hash-Bytes (Read-Entry $zip "lib/arm64-v8a/$name")) -ne (Hash-Bytes (Read-Entry $media $original.FullName))) {
                throw "Packaged media library differs from the verified archive: $name"
            }
        }
    } finally { $media.Dispose() }
    if ($null -eq $zip.GetEntry('assets/licenses/THIRD_PARTY.md')) { throw 'Missing dependency notice' }
    if (@($zip.Entries | Where-Object { $_.FullName -match '\.(vhdx|avhdx|bek)$|(^|/)(password\.txt|fixtures/)' }).Count -gt 0) {
        throw 'APK contains private test data'
    }
    Write-Output "APK verified: ARM64 only, $($libs.Count) aligned native libraries, pinned PDF/media binaries, dependency notice, no test images."
} finally { $zip.Dispose() }
