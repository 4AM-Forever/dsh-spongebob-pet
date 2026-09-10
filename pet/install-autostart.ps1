# 把桌宠加入开机启动（当前用户的启动文件夹快捷方式），并可选立即启动。
param(
  [switch]$StartNow,
  [switch]$Remove
)

$startup = [Environment]::GetFolderPath('Startup')
$link = Join-Path $startup '海绵宝宝桌宠.lnk'
$script = Join-Path $PSScriptRoot 'SpongeBobPet.ps1'

if ($Remove) {
  if (Test-Path $link) { Remove-Item $link -Force; Write-Host "已移除开机启动：$link" }
  else { Write-Host '本来就没在开机启动里。' }
  return
}

if (-not (Test-Path $script)) { throw "找不到 $script" }

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($link)
$shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$script`""
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = '海绵宝宝桌宠（DSH 确认弹窗）'
$shortcut.Save()
Write-Host "已加入开机启动：$link"

if ($StartNow) {
  Start-Process -FilePath $shortcut.TargetPath -ArgumentList $shortcut.Arguments
  Write-Host '桌宠已启动。'
}
