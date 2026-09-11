# 把桌宠加入开机启动（当前用户的启动文件夹快捷方式），并可选立即启动。
# 快捷方式指向无控制台启动器 SpongeBobPet.exe：开机时不会闪 cmd 窗口、任务栏也不留黑框。
param(
  [switch]$StartNow,
  [switch]$Remove
)

$startup = [Environment]::GetFolderPath('Startup')
$link = Join-Path $startup '海绵宝宝桌宠.lnk'
$exe = Join-Path $PSScriptRoot 'SpongeBobPet.exe'

if ($Remove) {
  if (Test-Path $link) { Remove-Item $link -Force; Write-Host "已移除开机启动：$link" }
  else { Write-Host '本来就没在开机启动里。' }
  return
}

if (-not (Test-Path $exe)) { throw "找不到启动器 $exe（先跑 tools\build-launcher.ps1 编译）" }

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($link)
$shortcut.TargetPath = $exe
$shortcut.Arguments = ''
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = '海绵宝宝桌宠（DSH 确认弹窗）'
$shortcut.Save()
Write-Host "已加入开机启动：$link"

if ($StartNow) {
  Start-Process -FilePath $exe
  Write-Host '桌宠已启动。'
}
