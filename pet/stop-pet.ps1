# 停掉正在跑的桌宠进程（按命令行匹配，不误杀其它 PowerShell）
$targets = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
  Where-Object { $_.CommandLine -like '*SpongeBobPet.ps1*' }
if (-not $targets) { Write-Host '桌宠没在运行。'; return }
foreach ($process in $targets) {
  Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  Write-Host "已结束桌宠进程 $($process.ProcessId)"
}
