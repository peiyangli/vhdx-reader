$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$env:PUB_CACHE = "$root\.tools\pub-cache"
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
Set-Location "$root\app"
& "$root\.tools\flutter\bin\dart.bat" format lib/playback_controls.dart lib/media_preview.dart lib/screen_layout.dart lib/reader_navigation.dart lib/main.dart lib/file_browser.dart lib/window_chrome.dart lib/preview.dart test/playback_controls_test.dart test/screen_layout_test.dart test/workspace_navigation_test.dart integration_test/android_test.dart test/file_browser_test.dart test/windows_workspace_test.dart test/reader_test.dart test/ui_actions.dart integration_test/native_test.dart integration_test/pdf_test.dart integration_test/media_test.dart
if ($LASTEXITCODE -ne 0) { throw 'Dart format failed' }
& "$root\.tools\flutter\bin\flutter.bat" analyze --no-pub
if ($LASTEXITCODE -ne 0) { throw 'Flutter analyze failed' }
