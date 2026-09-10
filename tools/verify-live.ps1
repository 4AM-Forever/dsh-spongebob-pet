# Live link check: handshake file -> plugin routes -> pet process/window -> long-poll heartbeat.
# NOTE: pet liveness counts ONLY the long poll (/pet/events). This script's own hello/state
# calls never mark the pet online, so petOnline here is trustworthy. Process + window checks
# are added as hard evidence so the check cannot fool itself.
# Usage: powershell -File tools\verify-live.ps1
# (ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 as GBK without a BOM.)
$handshake = Join-Path $env:USERPROFILE '.dsh\pet-bridge.json'

Write-Host '== 1. bridge plugin loaded? =='
if (-not (Test-Path $handshake)) {
  Write-Host '[FAIL] no handshake file: plugin not loaded (dsh web not restarted) or load failed.' -ForegroundColor Red
  Write-Host "       expected: $handshake"
  exit 1
}
$data = Get-Content $handshake -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "[OK] handshake: $($data.url)  dsh pid=$($data.pid)  plugin v$($data.pluginVersion)" -ForegroundColor Green

$headers = @{ 'x-pet-token' = $data.token }
try {
  $hello = Invoke-RestMethod -Uri "$($data.url)/pet/hello" -Headers $headers -TimeoutSec 10
  Write-Host "[OK] /pet/hello: $($hello.name) v$($hello.version) seq=$($hello.seq)" -ForegroundColor Green
} catch {
  Write-Host "[FAIL] /pet/hello: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host '== 2. pet on this machine? =='
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*-File *SpongeBobPet.ps1*' })
if ($procs.Count -gt 0) {
  Write-Host "[OK] pet process running: pid=$($procs.ProcessId -join ',')" -ForegroundColor Green
} else {
  Write-Host '[FAIL] no pet process - double-click pet\restart-pet.cmd' -ForegroundColor Red
}

Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue
$windowFound = $false
if ('System.Windows.Automation.AutomationElement' -as [type]) {
  $AE = [System.Windows.Automation.AutomationElement]
  $title = [string]([char]0x6D77 + [char]0x7EF5 + [char]0x5B9D + [char]0x5B9D + [char]0x684C + [char]0x5BA0)
  $condition = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $title)
  $window = $AE::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
  if ($null -ne $window) {
    $rect = $window.Current.BoundingRectangle
    Write-Host ("[OK] pet window on screen: ({0},{1}) {2}x{3} offscreen={4}" -f [int]$rect.X, [int]$rect.Y, [int]$rect.Width, [int]$rect.Height, $window.Current.IsOffscreen) -ForegroundColor Green
    $windowFound = $true
  }
}
if (-not $windowFound) {
  Write-Host '[WARN] no pet window found (process may be starting, hidden, or off-screen)' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '== 3. bridge state (long-poll heartbeat) =='
$state = Invoke-RestMethod -Uri "$($data.url)/pet/state" -Headers $headers -TimeoutSec 10
Write-Host ("  petOnline (heartbeat) : {0}" -f $state.petOnline)
Write-Host ("  takeover enabled      : {0}" -f $state.enabled)
Write-Host ("  do-not-disturb        : {0}" -f $state.dnd)
Write-Host ("  aggregate state       : {0}" -f $state.state)
Write-Host ("  pending requests      : {0}" -f @($state.pending).Count)
Write-Host ("  live sessions         : {0}" -f @($state.sessions).Count)

Write-Host ''
if ($state.petOnline -and $procs.Count -gt 0 -and $windowFound) {
  Write-Host '[OK] link is up: plugin running, pet on screen, heartbeat alive.' -ForegroundColor Green
  exit 0
}
Write-Host '[FAIL] link incomplete - fix the red/yellow items above.' -ForegroundColor Red
exit 1
