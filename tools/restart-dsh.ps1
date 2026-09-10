# 重启 DSH，让新装的桥接插件生效。
# 走 dsh-update-checker 自带的看门狗（同 GUI 上的「重启」按钮）：杀进程 → 等端口释放 → 用原命令拉起 → 健康检查。
# 重启前强制过一遍语法自检：插件有语法错会让 dsh 直接 exit（2026-09-10 真发生过一次），先拦住。
# 用法：powershell -File tools\restart-dsh.ps1 [-DelaySeconds 60] [-Force] [-SkipSyntaxCheck]
param(
  [int]$DelaySeconds = 0,
  [switch]$Force,
  [switch]$SkipSyntaxCheck
)

$handshake = Join-Path $env:USERPROFILE '.dsh\pet-bridge.json'
$log = Join-Path $env:USERPROFILE '.dsh\pet-restart-trigger.log'
$checkScript = Join-Path $PSScriptRoot 'check-syntax.ps1'

function Write-Log([string]$message) {
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $message" | Out-File -FilePath $log -Append -Encoding utf8
}

if ($DelaySeconds -gt 0) {
  Write-Log "等待 $DelaySeconds 秒后重启（留给当前回合收尾）"
  Start-Sleep -Seconds $DelaySeconds
}

if ((Test-Path $handshake) -and -not $Force) {
  Write-Log '握手文件已存在（DSH 已经加载过桥接插件），跳过重启'
  return
}

if (-not $SkipSyntaxCheck -and (Test-Path $checkScript)) {
  Write-Host '重启前语法自检…'
  & powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File $checkScript
  if ($LASTEXITCODE -ne 0) {
    Write-Log '语法自检没过，已中止重启（DSH 保持原状）'
    Write-Host '语法自检没过，已中止重启。先修文件再重跑。' -ForegroundColor Red
    exit 1
  }
  Write-Log '语法自检通过'
}

try {
  $response = Invoke-RestMethod -Uri 'http://127.0.0.1:3080/dsh-update-checker/restart' -Method Post `
    -ContentType 'application/json' -Body '{"confirm":true}' -TimeoutSec 20
  Write-Log "已请求重启：$($response.message)（port=$($response.port) pid=$($response.pid)）"
} catch {
  Write-Log "重启请求失败：$($_.Exception.Message)"
}
