# 桌宠功能端到端验收：临时副本 + 假桥接（test\stub-bridge.mjs），全程不碰正在跑的那只桌宠。
# 覆盖：多会话气泡文案、点桌宠弹出/收起会话面板（内容与窗口都验）、任务完成庆祝、运行期无异常。
# 用法：powershell -ExecutionPolicy RemoteSigned -File tools\e2e-pet-features.ps1 [-KeepTemp]
param(
  [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$stubScript = Join-Path $repo 'test\stub-bridge.mjs'

$checks = @()
$script:failedEarly = @()
function Check([string]$label, [bool]$ok) {
  $script:checks += [pscustomobject]@{ label = $label; ok = $ok }
  $color = if ($ok) { 'Green' } else { 'Red' }
  Write-Host ("{0}  {1}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $label) -ForegroundColor $color
}

function Resolve-Node {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidate = Join-Path $env:APPDATA 'nvm\v24.16.0\node.exe'
  if (Test-Path $candidate) { return $candidate }
  throw 'node not found (need node 18+ to run test\stub-bridge.mjs)'
}

# ---------- 准备隔离环境 ----------

$node = Resolve-Node

# 上一次跑崩（或被人中途打断）可能留下临时副本：位置一样会互相压住、把点击搅乱。
# 只按「临时目录里的 SpongeBobPet.ps1」这个特征收，绝不碰正常安装的那只桌宠。
$stalePattern = 'sbp-' + 'e2e.*SpongeBobPet'
$stale = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match $stalePattern })
foreach ($process in $stale) {
  try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop } catch { }
}
if ($stale.Count -gt 0) { Write-Host "清掉 $($stale.Count) 个上次遗留的临时副本" -ForegroundColor Yellow }

$probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = $probe.LocalEndpoint.Port
$probe.Stop()

$tmp = Join-Path $env:TEMP ('sbp-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$work = Join-Path $tmp 'pet'
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item (Join-Path $repo 'pet\*') -Destination $work -Recurse -Force
Remove-Item (Join-Path $work 'pet.log') -ErrorAction SilentlyContinue

# 临时副本自己的 config.json / 握手文件：位置挪到左上，别和真桌宠（右下角）叠在一起
$config = [ordered]@{
  topmost     = $true
  dimScreen   = $false
  sound       = $false
  dnd         = $false
  opacity     = 1.0
  size        = 'small'
  celebrateMs = 1500
  bridgeUrl   = "http://127.0.0.1:$port"
  pollTimeout = 10
  position    = @{ x = 320; y = 260 }
}
$noBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $work 'config.json'), ($config | ConvertTo-Json -Depth 5), $noBom)

$savedDshHome = $env:DSH_HOME
$env:DSH_HOME = $tmp
# 真桌宠正占着单实例锁：给副本换一个锁名，两只才能同时跑
$env:SBP_SINGLETON = 'dsh-spongebob-pet-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$handshake = [ordered]@{ url = "http://127.0.0.1:$port"; token = 'e2e-token'; pid = 0; pluginVersion = 'stub' }
[System.IO.File]::WriteAllText((Join-Path $tmp 'pet-bridge.json'), ($handshake | ConvertTo-Json), $noBom)

$logPath = Join-Path $work 'pet.log'
$stubProcess = $null
$petProcess = $null

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue
# 点桌宠用 PostMessage 直投窗口消息：合成鼠标事件（mouse_event）在这台机器上会被安全软件
# 拦着慢慢放行，实测十几秒才落地；直投消息没有全局钩子那一环，点下去立刻生效，也不抢用户的鼠标。
Add-Type -Namespace E2E -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
public static void ClickCenter(System.IntPtr hWnd, int width, int height) {
  // 先抢回前台：窗口失去激活时系统会收回鼠标捕获，桌宠那边就认不到这一下「点击」了
  SetForegroundWindow(hWnd);
  int x = width / 2, y = height / 2;
  System.IntPtr point = (System.IntPtr)((y << 16) | (x & 0xFFFF));
  PostMessage(hWnd, 0x0201, (System.IntPtr)1, point);   // WM_LBUTTONDOWN
  System.Threading.Thread.Sleep(60);
  PostMessage(hWnd, 0x0202, System.IntPtr.Zero, point); // WM_LBUTTONUP
}
public static void MoveCursor(int x, int y) { SetCursorPos(x, y); }
public static int CountVisibleWindows(uint processId) {
  int count = 0;
  EnumWindows(delegate(System.IntPtr hWnd, System.IntPtr lParam) {
    uint pid;
    GetWindowThreadProcessId(hWnd, out pid);
    if (pid == processId && IsWindowVisible(hWnd)) { count++; }
    return true;
  }, System.IntPtr.Zero);
  return count;
}
'@

$script:StartedAt = Get-Date
function Step([string]$text) {
  Write-Host ("  [t+{0,5:N1}s] {1}" -f ((Get-Date) - $script:StartedAt).TotalSeconds, $text) -ForegroundColor DarkGray
}

function Get-PetLogText {
  # 桌宠的网络线程也在往同一个文件追加写：偶发读失败/读到空都当「暂时没有」，
  # 不能让一次读盘抖动把整个用例打断。
  try {
    if (Test-Path $logPath) {
      $text = Get-Content $logPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
      if ($null -ne $text) { return [string]$text }
    }
  } catch { }
  return ''
}

function Wait-LogText([string]$needle, [int]$timeoutSec = 15) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    $text = Get-PetLogText
    if ($null -ne $text -and $text.Contains($needle)) { return $true }
    Start-Sleep -Milliseconds 250
  }
  return $false
}

# 必须按进程号找窗口：真桌宠也在跑、标题一模一样，光按标题会认到（并点到）它头上
function Find-Window([string]$title, [int]$processId = 0) {
  $AE = [System.Windows.Automation.AutomationElement]
  $condition = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $title)
  if ($processId -gt 0) {
    $byProcess = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $processId)
    $condition = New-Object System.Windows.Automation.AndCondition($condition, $byProcess)
  }
  return $AE::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
}

function Send-Stub([string]$path, $body) {
  $json = if ($null -eq $body) { '{}' } else { $body | ConvertTo-Json -Depth 6 -Compress }
  # 必须自己编成 UTF-8 字节：PowerShell 5.1 对 string body 按 Latin-1 发，中文会话标题会变乱码
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  return Invoke-RestMethod -Uri "http://127.0.0.1:$port$path" -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 10
}

try {
  Write-Host "== 桌宠端到端：临时副本 $work，假桥接 127.0.0.1:$port ==" -ForegroundColor Cyan

  $stubProcess = Start-Process -FilePath $node -ArgumentList @($stubScript, "$port") -PassThru -WindowStyle Hidden
  $ready = $false
  for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
    try {
      Invoke-RestMethod -Uri "http://127.0.0.1:$port/pet/hello" -TimeoutSec 2 | Out-Null
      $ready = $true
    } catch {
      Start-Sleep -Milliseconds 250
    }
  }
  Check '假桥接已就绪' $ready
  if (-not $ready) { throw 'stub bridge did not start' }

  $petProcess = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
    '-STA', '-NoProfile', '-ExecutionPolicy', 'RemoteSigned',
    '-File', (Join-Path $work 'SpongeBobPet.ps1'), '-NoTray'
  )

  Check '桌宠副本拿到单实例锁（没被真桌宠挤掉）' (Wait-LogText '拿到单实例锁' 40)
  Check '桌宠副本启动并显示窗口' (Wait-LogText '窗口已显示' 40)
  if (-not (Test-Path $logPath)) { throw "no pet log at $logPath" }

  # ---- 1. 多会话：气泡文案 ----
  Send-Stub '/stub/set' @{
    aggregate = 'working'
    busyCount = 2
    sessions  = @(
      @{ id = 'sess-a'; title = '任务A'; cwd = 'D:\demo-a'; state = 'working'; stateSince = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); lastTool = 'pwsh' },
      @{ id = 'sess-b'; title = '任务B'; cwd = 'D:\demo-b'; state = 'thinking'; stateSince = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); lastTool = $null }
    )
  } | Out-Null
  Check '两个会话同时忙 → 气泡显示「多线程烧脑中（2）」' (Wait-LogText '气泡：多线程烧脑中（2）')

  # ---- 2. 点桌宠：弹出会话面板 ----
  $findStarted = Get-Date
  $petWindow = Find-Window '海绵宝宝桌宠' $petProcess.Id
  Step ("UIA 找桌宠窗口用时 {0:N0}ms" -f ((Get-Date) - $findStarted).TotalMilliseconds)
  Check 'UIA 找到桌宠窗口（按进程号，不会认到真桌宠）' ($null -ne $petWindow)
  if ($null -eq $petWindow) { throw 'pet window not found' }

  $rect = $petWindow.Current.BoundingRectangle
  $handle = [IntPtr]$petWindow.Current.NativeWindowHandle
  $windowsBefore = [E2E.Win]::CountVisibleWindows([uint32]$petProcess.Id)
  Step "可见窗口数（点之前）：$windowsBefore"

  # 先把真光标挪到桌宠身上再投消息：桌宠的拖动判定读的是真光标位置（[Cursor]::Position），
  # 光标若在别处，这一下会被算成「拖动」而不是「点击」。
  # SetCursorPos 在这台机器上会被安全软件延迟放行，所以读回来确认落点，不能盲等。
  function Move-CursorTo([int]$x, [int]$y) {
    for ($i = 0; $i -lt 12; $i++) {
      [E2E.Win]::MoveCursor($x, $y) | Out-Null
      Start-Sleep -Milliseconds 120
      $now = [System.Windows.Forms.Cursor]::Position
      if ([math]::Abs($now.X - $x) -le 2 -and [math]::Abs($now.Y - $y) -le 2) { return $true }
    }
    return $false
  }

  function Invoke-PetClick {
    if (-not (Move-CursorTo ([int]($rect.X + $rect.Width / 2)) ([int]($rect.Y + $rect.Height / 2)))) {
      Step '光标没能挪到桌宠身上（被安全软件拦了？）'
    }
    [E2E.Win]::ClickCenter($handle, [int]$rect.Width, [int]$rect.Height)
  }

  # 以「屏幕上的窗口数」为准反复点到达成为止：窗口多一个/少一个是用户真正看得见的结果，
  # 比日志先到后到可靠（合成点击偶尔会被系统吞掉，尤其第二次——窗口刚失去激活）。
  function Invoke-PetClickUntil([int]$expectedWindows, [int]$tries = 3) {
    for ($attempt = 1; $attempt -le $tries; $attempt++) {
      Invoke-PetClick
      $deadline = (Get-Date).AddSeconds(4)
      while ((Get-Date) -lt $deadline) {
        if ([E2E.Win]::CountVisibleWindows([uint32]$petProcess.Id) -eq $expectedWindows) { return $true }
        Start-Sleep -Milliseconds 200
      }
      Step "第 $attempt 次点击后窗口数没到 $expectedWindows，再点一次"
    }
    return $false
  }

  Check '点一下桌宠 → 会话面板弹出（屏幕多一个窗口）' (Invoke-PetClickUntil ($windowsBefore + 1))
  Check '面板内容列出任务A（干活中）' (Wait-LogText '任务A[working]' 5)
  Check '面板内容列出任务B（思考中）' (Wait-LogText '任务B[thinking]' 5)
  Check '面板打开有日志留痕' (Wait-LogText '会话面板已打开' 3)

  # ---- 3. 再点一下：收起面板 ----
  Check '再点一下桌宠 → 会话面板收起（窗口少回去）' (Invoke-PetClickUntil $windowsBefore)
  Check '面板关闭有日志留痕' (Wait-LogText '会话面板已关闭' 3)

  # ---- 4. 任务完成：庆祝 ----
  Send-Stub '/stub/celebrate' @{ title = '任务A'; durationMs = 12000 } | Out-Null
  Check '桥接推 celebrate → 桌宠进入庆祝' (Wait-LogText '任务完成，庆祝 1500ms（任务A）')
  # 「气泡收起」别的路径也会打，必须确认它出现在庆祝那一行之后
  $afterLog = Get-PetLogText
  $celebrateAt = $afterLog.IndexOf('任务完成，庆祝')
  $bubbleClearedAt = $afterLog.IndexOf('气泡收起')
  Check '庆祝期间气泡让位' ($celebrateAt -ge 0 -and $bubbleClearedAt -gt $celebrateAt)

  # ---- 5. 全程无异常 ----
  $log = Get-PetLogText
  Check '运行期没有未捕获异常' (-not ($log.Contains('UI 线程未捕获异常') -or $log.Contains('FATAL')))
  $script:failedEarly = @($checks | Where-Object { -not $_.ok })
} finally {
  foreach ($process in @($petProcess, $stubProcess)) {
    if ($null -ne $process) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
  }
  # 桌宠进程可能自己派生过子进程，按命令行兜底收干净（只收临时副本这一份）
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$work*SpongeBobPet.ps1*" } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
  $env:DSH_HOME = $savedDshHome
  # 失败（或中途抛错）就把临时目录留下：pet.log 是唯一的现场
  if ($KeepTemp -or $script:failedEarly.Count -gt 0) {
    Write-Host "临时目录保留（含 pet.log）：$tmp" -ForegroundColor Yellow
  } else {
    Start-Sleep -Milliseconds 400
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$failed = @($checks | Where-Object { -not $_.ok })
Write-Host ''
Write-Host ("{0}/{1} 通过" -f ($checks.Count - $failed.Count), $checks.Count)
if ($failed.Count -gt 0) {
  Write-Host '失败项：' -ForegroundColor Red
  $failed | ForEach-Object { Write-Host ("  - " + $_.label) -ForegroundColor Red }
  exit 1
}
exit 0
