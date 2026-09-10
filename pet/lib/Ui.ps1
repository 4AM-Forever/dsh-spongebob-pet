# 桌宠 UI 基础设施：Win32 调用、窗口工厂、刷子与元素小工具。

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not ('PetWin32' -as [type])) {
  Add-Type -Namespace PetWin32 -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
[StructLayout(LayoutKind.Sequential)] public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
public const uint FLASHW_ALL = 3;
public const uint FLASHW_TIMERNOFG = 12;
public const int SW_RESTORE = 9;
public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
public const uint SWP_NOMOVE = 0x0002;
public const uint SWP_NOSIZE = 0x0001;
public const uint SWP_SHOWWINDOW = 0x0040;
public static void ForceTopmost(IntPtr hWnd) { SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW); }
public static void Flash(IntPtr hWnd, uint count) {
  FLASHWINFO info = new FLASHWINFO();
  info.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
  info.hwnd = hWnd; info.dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG; info.uCount = count; info.dwTimeout = 0;
  FlashWindowEx(ref info);
}
'@
}

function New-Brush([string]$hex) {
  $color = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
  return New-Object System.Windows.Media.SolidColorBrush($color)
}

function Set-Visible($element, [bool]$visible) {
  if ($null -eq $element) { return }
  $element.Visibility = if ($visible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
}

function Test-Visible($element) {
  return ($null -ne $element) -and ($element.Visibility -eq [System.Windows.Visibility]::Visible)
}

function Get-WindowHandle($window) {
  return (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
}

# 把窗口拽到最前：置顶 + 还原 + 抢焦点 + 任务栏闪烁
function Invoke-WindowAlert($window, [int]$flashCount = 6) {
  $window.Topmost = $true
  $handle = Get-WindowHandle $window
  if ($handle -eq [IntPtr]::Zero) { return }
  [PetWin32.Native]::ShowWindow($handle, [PetWin32.Native]::SW_RESTORE) | Out-Null
  [PetWin32.Native]::ForceTopmost($handle)
  [PetWin32.Native]::SetForegroundWindow($handle) | Out-Null
  [PetWin32.Native]::Flash($handle, [uint32]$flashCount) | Out-Null
  $window.Activate() | Out-Null
  $window.Focus() | Out-Null
}

function New-Border([double]$radius, [string]$background, [string]$borderBrush, [double]$thickness, [double]$padding) {
  $border = New-Object System.Windows.Controls.Border
  $border.CornerRadius = New-Object System.Windows.CornerRadius($radius)
  $border.Background = New-Brush $background
  if ($borderBrush) { $border.BorderBrush = New-Brush $borderBrush; $border.BorderThickness = New-Object System.Windows.Thickness($thickness) }
  $border.Padding = New-Object System.Windows.Thickness($padding)
  return $border
}

function New-Text([string]$text, [double]$size, [string]$foreground, [bool]$bold = $false, [string]$family = 'Microsoft YaHei') {
  $block = New-Object System.Windows.Controls.TextBlock
  $block.Text = $text
  $block.FontFamily = New-Object System.Windows.Media.FontFamily($family)
  $block.FontSize = $size
  $block.Foreground = New-Brush $foreground
  $block.TextWrapping = [System.Windows.TextWrapping]::Wrap
  if ($bold) { $block.FontWeight = [System.Windows.FontWeights]::Bold }
  return $block
}

function New-Button([string]$text, [string]$background, [string]$foreground, [double]$width = 0) {
  $button = New-Object System.Windows.Controls.Button
  $button.Content = $text
  $button.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
  $button.FontSize = 14
  $button.FontWeight = [System.Windows.FontWeights]::Bold
  $button.Foreground = New-Brush $foreground
  $button.Background = New-Brush $background
  $button.BorderBrush = New-Brush '#CBA41F'
  $button.BorderThickness = New-Object System.Windows.Thickness(2)
  $button.Padding = New-Object System.Windows.Thickness(14, 8, 14, 8)
  $button.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
  $button.Cursor = [System.Windows.Input.Cursors]::Hand
  if ($width -gt 0) { $button.MinWidth = $width }
  return $button
}
