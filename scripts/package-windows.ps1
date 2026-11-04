param([Parameter(Mandatory=$true)][string]$Directory, [Parameter(Mandatory=$true)][string]$Archive)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$directoryPath = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
$temporary = "$Archive.part"
if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
$zip = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in [IO.Directory]::EnumerateFiles($directoryPath, '*', [IO.SearchOption]::AllDirectories)) {
        $entry = $file.Substring($directoryPath.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file, $entry) | Out-Null
    }
} finally { $zip.Dispose() }
if ([IO.File]::Exists($Archive)) { [IO.File]::Delete($Archive) }
[IO.File]::Move($temporary, $Archive)
