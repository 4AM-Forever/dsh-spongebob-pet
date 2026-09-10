# 停掉正在跑的桌宠进程。
# 匹配要够严：只认「-File ...SpongeBobPet.ps1」这种真正拉起桌宠的命令行，
# 并排除自己和父进程 —— 否则调用者只要命令行里提到过这个文件名，就会把自己一并杀掉。
$self = $PID
$parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$self" -ErrorAction SilentlyContinue).ParentProcessId
$targets = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
  Where-Object {
    $_.ProcessId -ne $self -and
    $_.ProcessId -ne $parent -and
    $_.CommandLine -like '*-File *SpongeBobPet.ps1*'
  }
if (-not $targets) { Write-Host '桌宠没在运行。'; return }
foreach ($item in $targets) {
  Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
  Write-Host "已结束桌宠进程 $($item.ProcessId)"
}
