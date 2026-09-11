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
  celebrateMs = 4000
  bridgeUrl   = "http://127.0.0.1:$port"
  pollTimeout = 30
  position    = @{ x = 320; y = 260 }
}
$noBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $work 'config.json'), ($config | ConvertTo-Json -Depth 5), $noBom)

# 看门狗：脚本万一被强杀（finally 跑不到），5 分钟后也把这个临时副本收掉。
# 桌宠是摆在桌面上的东西，绝不能留一只测试副本赖在用户屏幕上。
$watchdogPath = Join-Path $tmp 'watchdog.ps1'
$watchdog = @"
Start-Sleep -Seconds 300
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { `$_.CommandLine -like '*$work*SpongeBobPet.ps1*' } |
  ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }
"@
[System.IO.File]::WriteAllText($watchdogPath, $watchdog, $noBom)
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', $watchdogPath) | Out-Null

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
static System.IntPtr CenterPoint(int width, int height) {
  int x = width / 2, y = height / 2;
  return (System.IntPtr)((y << 16) | (x & 0xFFFF));
}
public static void ClickCenter(System.IntPtr hWnd, int width, int height) {
  // 先抢回前台：窗口失去激活时系统会收回鼠标捕获，桌宠那边就认不到这一下「点击」了
  SetForegroundWindow(hWnd);
  ButtonDown(hWnd, width, height);
  System.Threading.Thread.Sleep(60);
  ButtonUp(hWnd, width, height);
}
public static void ButtonDown(System.IntPtr hWnd, int width, int height) {
  PostMessage(hWnd, 0x0201, (System.IntPtr)1, CenterPoint(width, height));   // WM_LBUTTONDOWN
}
public static void ButtonUp(System.IntPtr hWnd, int width, int height) {
  PostMessage(hWnd, 0x0202, System.IntPtr.Zero, CenterPoint(width, height)); // WM_LBUTTONUP
}
public static void MouseMoveAt(System.IntPtr hWnd, int x, int y) {
  PostMessage(hWnd, 0x0200, System.IntPtr.Zero, (System.IntPtr)(((y & 0xFFFF) << 16) | (x & 0xFFFF))); // WM_MOUSEMOVE
}
public static void MoveCursor(int x, int y) { SetCursorPos(x, y); }
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
// 把窗口搬到指定屏幕坐标（不改大小、不动 Z 序、不抢焦点）——用来模拟「桌宠被拖到副屏」
public static void MoveWindowTo(System.IntPtr hWnd, int x, int y) {
  SetWindowPos(hWnd, System.IntPtr.Zero, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010);
}
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

# 等某句话「又出现一次」：日志里早有同样内容时，只 Contains 会立刻返回，等不到新发生的那一次
function Wait-LogAgain([string]$needle, [int]$timeoutSec = 8) {
  $before = ([regex]::Matches((Get-PetLogText), [regex]::Escape($needle))).Count
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    $text = Get-PetLogText
    if ($null -ne $text -and ([regex]::Matches($text, [regex]::Escape($needle))).Count -gt $before) { return $true }
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
      # sess-a：宿主给了显示名 label（真宿主由标题/目录名算出来）→ 面板就显示它
      @{ id = 'sess-a'; label = '任务A'; title = '任务A'; cwd = 'D:\demo-a'; state = 'working'; stateSince = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); lastTool = 'pwsh' },
      # sess-b：宿主什么名字都没给 → 面板必须回退到工作目录名 demo-b，绝不能把 sess-b 摆出来
      @{ id = 'sess-b'; cwd = 'D:\demo-b'; state = 'thinking'; stateSince = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); lastTool = $null }
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
  Step ("可见窗口数（点之前）：$windowsBefore；窗口矩形 X=$([int]$rect.X) Y=$([int]$rect.Y) W=$([int]$rect.Width) H=$([int]$rect.Height)")

  # 点击/拖动都基于「真光标位置」：桌宠按光标位移区分点击与拖动，所以得先把光标放到它身上。
  # 这个脚本的进程必须连在交互桌面上——远程/服务会话里 Cursor.Position 恒为 0,0，根本挪不动。
  function Move-CursorTo([int]$x, [int]$y) {
    for ($i = 0; $i -lt 12; $i++) {
      [E2E.Win]::MoveCursor($x, $y) | Out-Null
      Start-Sleep -Milliseconds 120
      $now = [System.Windows.Forms.Cursor]::Position
      if ([math]::Abs($now.X - $x) -le 2 -and [math]::Abs($now.Y - $y) -le 2) { return $true }
    }
    $last = [System.Windows.Forms.Cursor]::Position
    Step ("光标挪不到目标：想让它在 ($x,$y)，实际停在 ($($last.X),$($last.Y))；这个进程多半不在交互桌面上")
    return $false
  }

  function Invoke-PetClick {
    Move-CursorTo ([int]($rect.X + $rect.Width / 2)) ([int]($rect.Y + $rect.Height / 2)) | Out-Null
    [E2E.Win]::ClickCenter($handle, [int]$rect.Width, [int]$rect.Height)
  }

  # 以「屏幕上的窗口数」为准反复点到达成为止：窗口多一个/少一个是用户真正看得见的结果，
  # 比日志先到后到可靠（合成点击偶尔会被系统吞掉，尤其刚失去激活的那一下）。
  # 注意：桌宠的点击/拖动判定读的是真光标位置，跑这个脚本时别动鼠标，否则你的手会被算成拖动。
  function Set-PanelState([int]$wantOpen) {
    $target = if ($wantOpen -eq 1) { $windowsBefore + 1 } else { $windowsBefore }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
      if ([E2E.Win]::CountVisibleWindows([uint32]$petProcess.Id) -eq $target) { return $true }
      Invoke-PetClick
      $deadline = (Get-Date).AddSeconds(4)
      while ((Get-Date) -lt $deadline -and [E2E.Win]::CountVisibleWindows([uint32]$petProcess.Id) -ne $target) {
        Start-Sleep -Milliseconds 200
      }
    }
    if ([E2E.Win]::CountVisibleWindows([uint32]$petProcess.Id) -ne $target) {
      $current = [E2E.Win]::CountVisibleWindows([uint32]$petProcess.Id)
      Step "面板没到期望状态（期望 $target，当前 $current）"
    }
    return ([E2E.Win]::CountVisibleWindows([uint32]$petProcess.Id) -eq $target)
  }

  Check '点一下桌宠 → 会话面板弹出（屏幕多一个窗口）' (Set-PanelState 1)
  Check '面板显示会话标题「任务A」（干活中）' (Wait-LogText '任务A[working]' 5)
  Check '没有标题的会话回退到工作目录名「demo-b」（思考中）' (Wait-LogText 'demo-b[thinking]' 5)
  Check '面板打开有日志留痕' (Wait-LogText '会话面板已打开' 3)
  # 会话 id 是内部标识：面板内容行里一个都不许出现
  $panelLine = @((Get-PetLogText) -split "`n" | Where-Object { $_.Contains('会话面板内容：') })[-1]
  Check '面板内容不出现会话 id' ($null -ne $panelLine -and -not $panelLine.Contains('sess-'))

  # ---- 3. 再点一下：收起面板 ----
  Check '再点一下桌宠 → 会话面板收起（窗口少回去）' (Set-PanelState 0)
  Check '面板关闭有日志留痕' (Wait-LogText '会话面板已关闭' 3)

  # ---- 4. 挪桌宠：面板要立刻收掉（它不跟着窗口走，留在原地就是没人管的浮窗） ----
  Check '拖动前先把面板打开' (Set-PanelState 1)
  $panelWasOpen = [E2E.Win]::CountVisibleWindows([uint32]$petProcess.Id) -eq ($windowsBefore + 1)
  $dragWindow = Find-Window '海绵宝宝桌宠' $petProcess.Id
  $dragRect = $dragWindow.Current.BoundingRectangle
  $dragHandle = [IntPtr]$dragWindow.Current.NativeWindowHandle
  $startX = [int]($dragRect.X + $dragRect.Width / 2)
  $startY = [int]($dragRect.Y + $dragRect.Height / 2)

  # 合成拖动：按下 → 真光标挪一段（桌宠按光标位移判定）→ 补一条移动消息 → 抬键；被吞掉就重试。
  # 每次调用都重新取窗口位置：桌宠可能刚吸附到边缘、或已经被挪到别的屏上。
  function Invoke-PetDrag([int]$dx, [int]$dy) {
    $win = Find-Window '海绵宝宝桌宠' $petProcess.Id
    if ($null -eq $win) { Step '拖不动：找不到桌宠窗口'; return }
    $r = $win.Current.BoundingRectangle
    $h = [IntPtr]$win.Current.NativeWindowHandle
    $pressX = [int]($r.X + $r.Width / 2)
    $pressY = [int]($r.Y + $r.Height / 2)
    $cx = [int]($r.Width / 2)
    $cy = [int]($r.Height / 2)
    Move-CursorTo $pressX $pressY | Out-Null
    [E2E.Win]::ButtonDown($h, [int]$r.Width, [int]$r.Height)
    Start-Sleep -Milliseconds 150
    Move-CursorTo ($pressX + $dx) ($pressY + $dy) | Out-Null
    [E2E.Win]::MouseMoveAt($h, $cx + $dx, $cy + $dy)
    Start-Sleep -Milliseconds 150
    [E2E.Win]::ButtonUp($h, [int]$r.Width, [int]$r.Height)
  }

  $dragged = $false
  for ($attempt = 1; $attempt -le 3 -and -not $dragged; $attempt++) {
    Invoke-PetDrag 30 20
    if (Wait-LogText '位移判定=拖动' 5) { $dragged = $true } else { Step "第 $attempt 次拖动没被认成拖动，再试一次" }
  }
  Check '拖动桌宠被判定为「拖动」而非「点击」' $dragged
  $dragDeadline = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $dragDeadline -and [E2E.Win]::CountVisibleWindows([uint32]$petProcess.Id) -ne $windowsBefore) {
    Start-Sleep -Milliseconds 200
  }
  Check '一开始挪动，会话面板就自动收起' ([E2E.Win]::CountVisibleWindows([uint32]$petProcess.Id) -eq $windowsBefore)
  # 拖动期间气泡让开、松手后自己回来。这一步必须紧跟着拖完就查：晚了气泡早回来了，就等不到「新的一次」
  Check '松手后气泡自己回来' (Wait-LogAgain '气泡：多线程烧脑中（2）')

  # ---- 5. 贴边吸附：拖到屏幕左缘松手，要吸上去并换成趴墙探头姿态 ----
  $petScreen = [System.Windows.Forms.Screen]::FromPoint(
    (New-Object System.Drawing.Point([int]($dragRect.X + $dragRect.Width / 2), [int]($dragRect.Y + $dragRect.Height / 2))))
  $screenArea = $petScreen.WorkingArea
  $edgeDragDx = [int]($screenArea.Left + 10 - ($dragRect.X + $dragRect.Width / 2))
  Invoke-PetDrag $edgeDragDx 0
  Check '拖到屏幕左缘 → 吸附并换成趴墙探头姿态' (Wait-LogText '吸附到屏幕左边缘' 6)
  Start-Sleep -Milliseconds 700
  $dockedRect = (Find-Window '海绵宝宝桌宠' $petProcess.Id).Current.BoundingRectangle
  Step ("吸附后窗口 X={0}（屏幕左缘 {1}）" -f [int]$dockedRect.X, $screenArea.Left)
  Check '吸附后贴在屏幕左缘上（略微藏进边缘）' ([math]::Abs($dockedRect.X - $screenArea.Left) -le 24)
  $dockConfig = Get-Content (Join-Path $work 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Check '吸附状态写进配置（重启后接着吸）' ([string]$dockConfig.dock -eq 'left')

  # 再拖走：应当解除吸附、恢复站姿
  Invoke-PetDrag 260 60
  Check '拖离边缘 → 解除吸附、恢复正常站姿' (Wait-LogText '离开屏幕边缘，恢复正常站姿' 6)
  $undockConfig = Get-Content (Join-Path $work 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Check '解除吸附也写进配置' ([string]$undockConfig.dock -eq '')

  # ---- 6. 多显示器：摆在副屏不能被拽回主屏 ----
  # 回归：自动回收判定原来用 SystemParameters.WorkArea（只是主屏工作区），
  # 摆在副屏的桌宠每 5 秒被当成「跑出屏幕」拽回主屏（皇上实测就是这么烦）。
  $otherScreens = @([System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary })
  if ($otherScreens.Count -eq 0) {
    Step '这台机器只有一块屏，跳过副屏用例'
  } else {
    $area = $otherScreens[0].WorkingArea
    $targetX = [int]($area.Left + ($area.Width - $dragRect.Width) / 2)
    $targetY = [int]($area.Top + 140)
    [E2E.Win]::MoveWindowTo($dragHandle, $targetX, $targetY)
    Start-Sleep -Seconds 7
    $onOther = (Find-Window '海绵宝宝桌宠' $petProcess.Id).Current.BoundingRectangle
    Step ("搬到副屏后停在 ({0},{1})；副屏工作区 {2},{3} {4}x{5}" -f [int]$onOther.X, [int]$onOther.Y, $area.Left, $area.Top, $area.Width, $area.Height)
    Check '摆在副屏不会被拽回主屏' (($onOther.X -ge ($area.Left - 4)) -and (($onOther.X + $onOther.Width) -le ($area.Right + 4)))

    # 再故意丢到虚拟桌面之外：回收逻辑本身还得在（拔副屏/改分辨率后要能自己回来）
    [E2E.Win]::MoveWindowTo($dragHandle, ($area.Right + 800), $targetY)
    Start-Sleep -Seconds 7
    $back = (Find-Window '海绵宝宝桌宠' $petProcess.Id).Current.BoundingRectangle
    # 用 WinForms 的虚拟屏（物理像素），与 SetWindowPos / UIA 的坐标口径一致
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    Step ("丢到屏幕外后回到 ({0},{1})；虚拟屏 {2},{3} {4}x{5}" -f [int]$back.X, [int]$back.Y, $vs.Left, $vs.Top, $vs.Width, $vs.Height)
    Check '丢到屏幕外能自己拉回可视范围' (
      ($back.X -ge ($vs.Left - 4)) -and ($back.Y -ge ($vs.Top - 4)) -and
      (($back.X + $back.Width) -le ($vs.Right + 4)) -and (($back.Y + $back.Height) -le ($vs.Bottom + 4))
    )
  }

  # ---- 7. 任务完成：庆祝（有过程，不是闪一下） ----
  Send-Stub '/stub/celebrate' @{ title = '任务A'; durationMs = 12000 } | Out-Null
  Check '桥接推 celebrate → 桌宠开始庆祝' (Wait-LogText '任务完成，庆祝 4000ms（任务A）')
  Check '庆祝头一段先喊一嗓子' (Wait-LogText '气泡：「任务A」搞定，收工～')
  # 气泡是到中段（35%）才让给派对帽的，所以要等新的一次「气泡收起」，不能立刻查
  $bubbleYielded = Wait-LogAgain '气泡收起' 6
  $afterLog = Get-PetLogText
  $celebrateAt = $afterLog.IndexOf('任务完成，庆祝')
  $bubbleClearedAt = $afterLog.LastIndexOf('气泡收起')
  Check '庆祝中段气泡让位给派对帽' ($bubbleYielded -and $celebrateAt -ge 0 -and $bubbleClearedAt -gt $celebrateAt)
  Check '庆祝走完全程并收尾' (Wait-LogText '庆祝结束，回到待命' 20)

  # 起止两行日志的时间差＝庆祝实际时长，必须接近配置值（有过程，不是闪一下）
  $finalLog = Get-PetLogText
  $stamp = @($finalLog -split "`n" | Where-Object { $_.Contains('任务完成，庆祝') -or $_.Contains('庆祝结束，回到待命') })
  $elapsedMs = -1
  if ($stamp.Count -ge 2) {
    $parse = { param($line) [datetime]::ParseExact($line.Substring(0, 23), 'yyyy-MM-dd HH:mm:ss.fff', $null) }
    $elapsedMs = ((& $parse $stamp[-1]) - (& $parse $stamp[-2])).TotalMilliseconds
  }
  Check ("庆祝实际时长接近 4000ms（实测 {0:N0}ms）" -f $elapsedMs) ($elapsedMs -ge 3200 -and $elapsedMs -le 7000)

  # ---- 6. 全程无异常 ----
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
