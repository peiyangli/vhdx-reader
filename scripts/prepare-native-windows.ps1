$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
& (Join-Path $PSScriptRoot 'download-native.ps1')
$sources = Join-Path $root '.native\src'
[IO.Directory]::CreateDirectory($sources) | Out-Null
$items = Get-Content "$PSScriptRoot\native-sources.json" -Raw | ConvertFrom-Json
$lines = [Collections.Generic.List[string]]::new()
@('cmake_minimum_required(VERSION 3.20)', 'project(vhdx_native C)',
  'if(NOT MSVC)', 'message(FATAL_ERROR "Windows native build requires MSVC")', 'endif()',
  'set(CMAKE_C_STANDARD 11)', 'set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreadedDLL)',
  'set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")') | ForEach-Object { $lines.Add($_) }
foreach ($item in $items) {
    $name = $item.name
    $folder = "$name-$($item.version)"
    $source = Join-Path $sources $folder
    if (-not (Test-Path $source)) {
        & tar.exe -xf "$root\.native\downloads\$name-$($item.status)-$($item.version).tar.gz" -C $sources
        if ($LASTEXITCODE -ne 0) { throw "Extraction failed: $name" }
    }
    [xml]$doc = Get-Content "$source\msvscpp\$name\$name.vcproj" -Raw
    $config = $doc.VisualStudioProject.Configurations.Configuration | Where-Object { $_.Name -eq 'Release|Win32' }
    $compiler = $config.Tool | Where-Object { $_.Name -eq 'VCCLCompilerTool' }
    $definitions = @($compiler.PreprocessorDefinitions.Split(';'))
    $dependencies = @($definitions | Where-Object { $_.StartsWith('HAVE_LOCAL_') } | ForEach-Object { $_.Substring(11).ToLowerInvariant() })
    if ($name -ne 'libbfio') {
        $dependencies = @($dependencies | Where-Object { $_ -ne 'libbfio' })
        $definitions = @($definitions | Where-Object { $_ -ne 'HAVE_LOCAL_LIBBFIO' }) + 'HAVE_LIBBFIO=1'
    }
    $files = @()
    foreach ($library in (@($name) + $dependencies)) {
        $projectDir = "$source\msvscpp\$library"
        [xml]$project = Get-Content "$projectDir\$library.vcproj" -Raw
        foreach ($file in $project.SelectNodes('//File')) {
            if ($file.RelativePath.EndsWith('.c')) {
                $full = [IO.Path]::GetFullPath((Join-Path $projectDir $file.RelativePath))
                $relative = $full.Substring($sources.Length + 1).Replace('\','/')
                $files += ('  "${CMAKE_CURRENT_LIST_DIR}/src/' + $relative + '"')
            }
        }
    }
    $lines.Add("add_library($name SHARED")
    $files | Sort-Object -Unique | ForEach-Object { $lines.Add($_) }
    $lines.Add(')')
    $lines.Add("target_include_directories($name PRIVATE")
    foreach ($include in (@($name,'common','include') + $dependencies)) {
        $lines.Add(('  "${CMAKE_CURRENT_LIST_DIR}/src/' + $folder + '/' + $include + '"'))
    }
    $lines.Add(')')
    $lines.Add("target_compile_definitions($name PRIVATE " + (($definitions + '_CRT_NONSTDC_NO_WARNINGS') -join ' ') + ')')
    $lines.Add("target_link_libraries($name PRIVATE advapi32 bcrypt)")
    if ($name -ne 'libbfio') {
        $lines.Add(('target_include_directories(' + $name + ' PRIVATE "${CMAKE_CURRENT_LIST_DIR}/src/libbfio-' + $items[0].version + '/include")'))
        $lines.Add("target_link_libraries($name PRIVATE libbfio)")
    }
}
$lines.Add('include("${CMAKE_CURRENT_LIST_DIR}/../scripts/native-crypto.cmake")')
[IO.File]::WriteAllLines("$root\.native\CMakeLists.txt", $lines, [Text.UTF8Encoding]::new($false))
