param([string]$Output = 'windows-ui-desktop.png')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class UiCapture {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)]
  public struct Rect { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@
[UiCapture]::SetProcessDPIAware() | Out-Null
$app = Get-Process vhdx_reader | Where-Object { $_.Path -eq "$root\artifacts\gui-windows-ui-preview\vhdx_reader.exe" } | Select-Object -First 1
if (-not $app) { throw 'UI preview is not running' }
$handle = $app.MainWindowHandle
[UiCapture]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Milliseconds 500
$rect = New-Object UiCapture+Rect
if (-not [UiCapture]::GetWindowRect($handle, [ref]$rect)) { throw 'Cannot read preview bounds' }
$bitmap = New-Object Drawing.Bitmap(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
$graphics = [Drawing.Graphics]::FromImage($bitmap)
try {
  $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
  $path = Join-Path "$root\artifacts" $Output
  $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
  Write-Output $path
  Write-Output "Window: $($rect.Left),$($rect.Top) $($bitmap.Width)x$($bitmap.Height) PID=$($app.Id)"
} finally {
  $graphics.Dispose()
  $bitmap.Dispose()
}
