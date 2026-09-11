# 海绵宝宝桌宠主程序：透明置顶宠物窗口 + 托盘 + 与 DSH 桥接（长轮询取件、卡片作答回传）。
# 运行：powershell.exe -STA -NoProfile -WindowStyle Hidden -File SpongeBobPet.ps1
param(
  [switch]$NoTray
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogPath = Join-Path $script:Root 'pet.log'

# 无控制台启动时异常会无声消失，日志是唯一的现场
function Write-PetLog([string]$message) {
  try {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [pid $PID] $message" | Out-File -FilePath $script:LogPath -Append -Encoding utf8
  } catch { }
}
trap {
  Write-PetLog ("FATAL: " + $_.Exception.GetType().Name + ': ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage)
  exit 1
}

Write-PetLog "启动：exe=$([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) 参数=$($MyInvocation.Line)"

# 单实例：重复启动只会多出一只抢同一批确认的桌宠
$script:Singleton = New-Object System.Threading.Mutex($false, 'dsh-spongebob-pet-singleton')
if (-not $script:Singleton.WaitOne(0)) {
  Write-PetLog '已有实例在跑，本次启动退出'
  Write-Host '桌宠已经在跑了，这次启动忽略。'
  exit 0
}
Write-PetLog '拿到单实例锁'

. (Join-Path $script:Root 'lib\Ui.ps1')
. (Join-Path $script:Root 'lib\Art.ps1')
. (Join-Path $script:Root 'lib\Card.ps1')
Write-PetLog '依赖库加载完成'

# ---------- 配置 ----------

# 三档尺寸：画布 220×284 就是「大」档基准，中/小按比例缩
$script:SizePresets = [ordered]@{
  large  = @{ scale = 1.0;  label = '大' }
  medium = @{ scale = 0.72; label = '中' }
  small  = @{ scale = 0.5;  label = '小' }
}
$script:CurrentSize = 'large'
$script:SizeMenuItems = @{}

$defaults = [ordered]@{
  topmost      = $true
  dimScreen    = $true
  sound        = $true
  dnd          = $false
  opacity      = 1.0
  size         = 'large'
  bridgeUrl    = ''
  pollTimeout  = 40
  position     = @{ x = -1; y = -1 }
}
$configPath = Join-Path $script:Root 'config.json'
$config = [pscustomobject]$defaults
if (Test-Path $configPath) {
  $loaded = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($name in $defaults.Keys) {
    if ($null -ne $loaded.$name) { $config.$name = $loaded.$name }
  }
}

# 写盘先读盘再合并：size 可能被 DSH 设置页改过，桌宠自己保存位置时不能把它冲掉
function Save-Config {
  param([switch]$WithSize)
  $out = [ordered]@{}
  if (Test-Path $configPath) {
    try {
      $disk = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($property in $disk.PSObject.Properties) { $out[$property.Name] = $property.Value }
    } catch { }
  }
  foreach ($name in @('topmost', 'dimScreen', 'sound', 'dnd', 'opacity', 'bridgeUrl', 'pollTimeout')) {
    if ($null -ne $config.$name) { $out[$name] = $config.$name }
  }
  if ($WithSize -or -not $out.Contains('size')) { $out['size'] = [string]$config.size }
  $out['position'] = @{ x = [int]$config.position.x; y = [int]$config.position.y }
  # Set-Content -Encoding UTF8 在 PowerShell 5.1 下会写 BOM，宿主侧 JSON.parse 认不了，必须手写无 BOM
  $json = $out | ConvertTo-Json -Depth 5
  [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Get-PetScale([string]$size) {
  if ($script:SizePresets.Contains($size)) { return [double]$script:SizePresets[$size].scale }
  return 1.0
}

# 切换档位：缩放画布 + 同步窗口尺寸（窗口必须跟着变，否则内容会被裁掉）
function Apply-PetSize([string]$size, [bool]$persist = $false) {
  if (-not $script:SizePresets.Contains($size)) { $size = 'large' }
  $scale = Get-PetScale $size
  $script:CurrentSize = $size
  if ($null -ne $script:Visual) {
    $script:Visual.Root.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($scale, $scale)
  }
  if ($null -ne $window) {
    $window.Width = [math]::Round(220 * $scale)
    $window.Height = [math]::Round(284 * $scale)
  }
  if ($persist) {
    $config.size = $size
    Save-Config -WithSize
  }
  foreach ($key in $script:SizeMenuItems.Keys) {
    foreach ($item in @($script:SizeMenuItems[$key])) {
      if ($null -ne $item) { $item.Checked = ($key -eq $size); $item.IsChecked = ($key -eq $size) }
    }
  }
  Write-PetLog "尺寸切到 $size（scale=$scale，窗口 $($window.Width)x$($window.Height)）"
}

# ---------- 与 DSH 的桥接 ----------

$handshakePath = Join-Path $env:USERPROFILE '.dsh\pet-bridge.json'
if ($env:DSH_HOME) { $handshakePath = Join-Path $env:DSH_HOME 'pet-bridge.json' }

$script:Bridge = @{ url = $config.bridgeUrl; token = ''; seq = 0; connected = $false; error = '' }

function Read-Handshake {
  try {
    if (-not (Test-Path $handshakePath)) { return $false }
    $data = Get-Content $handshakePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.bridgeUrl -eq '') { $script:Bridge.url = [string]$data.url }
    $script:Bridge.token = [string]$data.token
    return $true
  } catch {
    return $false
  }
}

function Send-BridgeAnswer($payload) {
  if (-not (Read-Handshake)) { return $false }
  try {
    $body = $payload | ConvertTo-Json -Depth 6 -Compress
    Invoke-RestMethod -Uri "$($script:Bridge.url)/pet/answer" -Method Post -TimeoutSec 10 `
      -Headers @{ 'x-pet-token' = $script:Bridge.token } -ContentType 'application/json; charset=utf-8' -Body $body | Out-Null
    return $true
  } catch {
    Show-Balloon "作答回传失败：$($_.Exception.Message)"
    return $false
  }
}

function Send-BridgeControl($payload) {
  if (-not (Read-Handshake)) { return $false }
  try {
    $body = $payload | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$($script:Bridge.url)/pet/control" -Method Post -TimeoutSec 10 `
      -Headers @{ 'x-pet-token' = $script:Bridge.token } -ContentType 'application/json; charset=utf-8' -Body $body | Out-Null
    return $true
  } catch {
    return $false
  }
}

# 网络循环跑在独立 runspace：长轮询取件，结果塞进线程安全队列，UI 线程定时取用。
$sync = @{
  Inbox   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
  Stop    = $false
  Handshake = $handshakePath
  FallbackUrl = $config.bridgeUrl
  PollTimeout = [int]$config.pollTimeout
  LogPath = $script:LogPath
}

$bridgeLoop = {
  param($sync)
  $url = $sync.FallbackUrl
  $token = ''
  $seq = 0
  $lastHandshake = [datetime]::MinValue
  [System.Net.WebRequest]::DefaultWebProxy = $null
  $loggedOnce = $false

  while (-not $sync.Stop) {
    try {
      if (((Get-Date) - $lastHandshake).TotalSeconds -gt 20 -or $token -eq '' -or $url -eq '') {
        if (Test-Path $sync.Handshake) {
          $data = Get-Content $sync.Handshake -Raw -Encoding UTF8 | ConvertFrom-Json
          if ($sync.FallbackUrl -eq '') { $url = [string]$data.url }
          $token = [string]$data.token
        }
        $lastHandshake = Get-Date
      }
      if ($token -eq '' -or $url -eq '') {
        if (-not $loggedOnce) { "$(Get-Date -Format 'HH:mm:ss') 网络线程：还没拿到握手文件" | Out-File $sync.LogPath -Append -Encoding utf8; $loggedOnce = $true }
        $sync.Inbox.Enqueue([pscustomobject]@{ type = 'transport'; connected = $false; error = '还没拿到 DSH 握手文件（DSH 未启动或桥接插件未加载）' })
        Start-Sleep -Seconds 3
        continue
      }
      # 冷启动先取一次快照：长轮询在没事件时会挂满 20 秒，
      # 不先同步的话，刚上线这段时间的免打扰开关和在途确认都是旧的。
      if ($seq -eq 0) {
        $bootstrap = Invoke-RestMethod -Uri "$url/pet/state?token=$token" -TimeoutSec 15
        $seq = [int]$bootstrap.seq
        $sync.Inbox.Enqueue([pscustomobject]@{ type = 'snapshot'; connected = $true; error = ''; data = $bootstrap })
      }
      $response = Invoke-RestMethod -Uri "$url/pet/events?since=$seq&token=$token" -TimeoutSec $sync.PollTimeout
      if (-not $loggedOnce) { "$(Get-Date -Format 'HH:mm:ss') 网络线程：已连上 $url" | Out-File $sync.LogPath -Append -Encoding utf8; $loggedOnce = $true }
      $seq = [int]$response.seq
      $sync.Inbox.Enqueue([pscustomobject]@{ type = 'snapshot'; connected = $true; error = ''; data = $response })
      foreach ($event in @($response.events)) {
        $sync.Inbox.Enqueue([pscustomobject]@{ type = 'event'; connected = $true; error = ''; data = $event })
      }
    } catch {
      if ($loggedOnce) { "$(Get-Date -Format 'HH:mm:ss') 网络线程断开：$($_.Exception.Message)" | Out-File $sync.LogPath -Append -Encoding utf8; $loggedOnce = $false }
      $sync.Inbox.Enqueue([pscustomobject]@{ type = 'transport'; connected = $false; error = $_.Exception.Message })
      Start-Sleep -Milliseconds 1500
    }
  }
}

$runspace = [runspacefactory]::CreateRunspace()
$runspace.ApartmentState = 'MTA'
$runspace.ThreadOptions = 'ReuseThread'
$runspace.Open()
$bridgeJob = [powershell]::Create()
$bridgeJob.Runspace = $runspace
$bridgeJob.AddScript($bridgeLoop).AddArgument($sync) | Out-Null
$bridgeHandle = $bridgeJob.BeginInvoke()

# ---------- 宠物窗口 ----------

$visual = New-PetVisual
$window = New-Object System.Windows.Window
$window.WindowStyle = [System.Windows.WindowStyle]::None
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.ShowInTaskbar = $false
$window.Topmost = [bool]$config.topmost
$window.ResizeMode = [System.Windows.ResizeMode]::NoResize
$window.Title = '海绵宝宝桌宠'
$window.Width = 220
$window.Height = 284
$window.Opacity = [double]$config.opacity

# 记住的位置必须校验：换显示器 / 改分辨率后旧坐标可能落在屏幕外，
# 那样桌宠窗口还在跑、卡片照弹，但皇上根本看不到海绵宝宝。
$vsLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
$vsTop = [System.Windows.SystemParameters]::VirtualScreenTop
$vsRight = $vsLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
$vsBottom = $vsTop + [System.Windows.SystemParameters]::VirtualScreenHeight
$savedX = [double]$config.position.x
$savedY = [double]$config.position.y
$savedOnScreen = ($savedX -ge $vsLeft) -and ($savedY -ge $vsTop) -and
  ($savedX -le ($vsRight - 120)) -and ($savedY -le ($vsBottom - 120))
if ($savedOnScreen) {
  $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
  $window.Left = $savedX
  $window.Top = $savedY
} else {
  $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
  $window.Left = [System.Windows.SystemParameters]::WorkArea.Right - 320
  $window.Top = [System.Windows.SystemParameters]::WorkArea.Bottom - 380
  if (-not $savedOnScreen -and $savedX -ge 0) {
    Write-Host "记住的位置 ($savedX,$savedY) 在当前屏幕外，已回到右下角"
  }
}
$window.Content = $visual.Root
$script:Visual = $visual
Apply-PetSize ([string]$config.size)

$window.Add_MouseLeftButtonDown({
  try { $window.DragMove() } catch { }
})

# ---------- 大小档位的菜单项（右键菜单与托盘共用同一套回调）----------
# 点击时从 Tag 读档位，而不是在循环里闭包捕获变量——否则每一项都会用最后一个档位。
function New-WpfSizeItem([string]$key) {
  $item = New-Object System.Windows.Controls.MenuItem
  $item.Header = $script:SizePresets[$key].label
  $item.IsCheckable = $true
  $item.IsChecked = ($script:CurrentSize -eq $key)
  $item.Tag = $key
  $item.Add_Click({ Apply-PetSize ([string]$args[0].Tag) $true })
  return $item
}
function New-TraySizeItem([string]$key) {
  $item = New-Object System.Windows.Forms.ToolStripMenuItem
  $item.Text = $script:SizePresets[$key].label
  $item.Checked = ($script:CurrentSize -eq $key)
  $item.Tag = $key
  $item.Add_Click({ Apply-PetSize ([string]$args[0].Tag) $true })
  return $item
}
function Register-SizeMenuItem([string]$key, $item) {
  if (-not $script:SizeMenuItems.ContainsKey($key)) { $script:SizeMenuItems[$key] = @() }
  $script:SizeMenuItems[$key] = @($script:SizeMenuItems[$key]) + $item
}

$window.Add_MouseRightButtonUp({
  $menu = New-Object System.Windows.Controls.ContextMenu
  $items = @(
    @{ Header = '显示/隐藏桌宠'; Action = { Toggle-PetVisibility } },
    @{ Header = '免打扰（交回网页确认）'; Action = { Toggle-Dnd } },
    @{ Header = '大小'; SizeMenu = $true },
    @{ Header = '打开 DSH 网页'; Action = { Start-Process $script:Bridge.url } },
    @{ Header = '回到右下角'; Action = { Reset-PetPosition } },
    @{ Header = '退出'; Action = { Stop-Pet } }
  )
  foreach ($item in $items) {
    if ($item.SizeMenu) {
      $sizeMenu = New-Object System.Windows.Controls.MenuItem
      $sizeMenu.Header = $item.Header
      foreach ($key in $script:SizePresets.Keys) {
        $sizeItem = New-WpfSizeItem $key
        Register-SizeMenuItem $key $sizeItem
        $sizeMenu.Items.Add($sizeItem) | Out-Null
      }
      $menu.Items.Add($sizeMenu) | Out-Null
      continue
    }
    $entry = New-Object System.Windows.Controls.MenuItem
    $entry.Header = $item.Header
    $entry.Add_Click($item.Action)
    $menu.Items.Add($entry) | Out-Null
  }
  $menu.IsOpen = $true
})

# ---------- 托盘 ----------

function New-PetIcon {
  $bitmap = New-Object System.Drawing.Bitmap 32, 32
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.Clear([System.Drawing.Color]::Transparent)
  $yellow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(246, 225, 75))
  $black = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(27, 27, 27)), 2
  $graphics.FillRectangle($yellow, 4, 6, 24, 20)
  $graphics.DrawRectangle($black, 4, 6, 24, 20)
  $white = [System.Drawing.Brushes]::White
  $graphics.FillEllipse($white, 8, 10, 7, 9)
  $graphics.FillEllipse($white, 17, 10, 7, 9)
  $graphics.FillEllipse([System.Drawing.Brushes]::Black, 10, 13, 3, 4)
  $graphics.FillEllipse([System.Drawing.Brushes]::Black, 19, 13, 3, 4)
  $graphics.Dispose()
  return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
}

$notify = $null
function Show-Balloon([string]$message) {
  if ($null -eq $script:notify) { return }
  $script:notify.BalloonTipTitle = '海绵宝宝桌宠'
  $script:notify.BalloonTipText = $message
  $script:notify.ShowBalloonTip(4000)
}

if (-not $NoTray) {
  $notify = New-Object System.Windows.Forms.NotifyIcon
  $notify.Icon = New-PetIcon
  $notify.Text = '海绵宝宝桌宠'
  $notify.Visible = $true
  $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
  $trayItems = @(
    @{ Text = '显示/隐藏桌宠'; Action = { Toggle-PetVisibility } },
    @{ Text = '免打扰（交回网页确认）'; Action = { Toggle-Dnd } },
    @{ Text = '大小'; SizeMenu = $true },
    @{ Text = '打开 DSH 网页'; Action = { Start-Process $script:Bridge.url } },
    @{ Text = '回到右下角'; Action = { Reset-PetPosition } },
    @{ Text = '退出'; Action = { Stop-Pet } }
  )
  foreach ($item in $trayItems) {
    if ($item.SizeMenu) {
      $sizeMenu = New-Object System.Windows.Forms.ToolStripMenuItem
      $sizeMenu.Text = $item.Text
      foreach ($key in $script:SizePresets.Keys) {
        $sizeItem = New-TraySizeItem $key
        Register-SizeMenuItem $key $sizeItem
        $sizeMenu.DropDownItems.Add($sizeItem) | Out-Null
      }
      $trayMenu.Items.Add($sizeMenu) | Out-Null
      continue
    }
    $entry = New-Object System.Windows.Forms.ToolStripMenuItem
    $entry.Text = $item.Text
    $entry.Add_Click($item.Action)
    $trayMenu.Items.Add($entry) | Out-Null
  }
  $notify.ContextMenuStrip = $trayMenu
  $notify.Add_MouseDoubleClick({ Toggle-PetVisibility })
  $script:notify = $notify
}

function Toggle-PetVisibility {
  if ($window.IsVisible) { $window.Hide() } else { $window.Show(); $window.Topmost = $true }
}
function Reset-PetPosition {
  $window.Left = [System.Windows.SystemParameters]::WorkArea.Right - $window.Width - 60
  $window.Top = [System.Windows.SystemParameters]::WorkArea.Bottom - $window.Height - 60
}
function Toggle-Dnd {
  $config.dnd = -not $config.dnd
  Save-Config
  Send-BridgeControl @{ dnd = [bool]$config.dnd } | Out-Null
  Set-PetBubble $(if ($config.dnd) { '免打扰中，确认都回网页' } else { '回来啦，有事喊我' })
}
function Stop-Pet {
  $sync.Stop = $true
  try { $bridgeJob.Stop() } catch { }
  try { $bridgeJob.Dispose() } catch { }
  try { $runspace.Close() } catch { }
  if ($null -ne $script:notify) { $script:notify.Visible = $false; $script:notify.Dispose() }
  $config.position = @{ x = [int]$window.Left; y = [int]$window.Top }
  Save-Config
  [System.Windows.Application]::Current.Shutdown()
}

$window.Add_LocationChanged({
  $config.position = @{ x = [int]$window.Left; y = [int]$window.Top }
})
$window.Add_Closed({ Stop-Pet })

# ---------- 表情与动画 ----------

$script:State = 'idle'
$script:Tick = 0
$script:PumpTick = 0
$script:Blink = 0
$script:Pending = New-Object System.Collections.ArrayList
$script:Card = $null
$script:DisconnectedAt = $null
$script:DndPushed = $false

function Set-PetBubble([string]$text) {
  $elements = $script:Visual.Elements
  if ([string]::IsNullOrEmpty($text)) {
    Set-Visible $elements.StatusBubble $false
    return
  }
  $elements.StatusText.Text = $text
  Set-Visible $elements.StatusBubble $true
}

function Reset-PetFace {
  $e = $script:Visual.Elements
  Set-Visible $e.EyeLineL $false; Set-Visible $e.EyeLineR $false
  Set-Visible $e.EyeXL1 $false; Set-Visible $e.EyeXL2 $false
  Set-Visible $e.EyeXR1 $false; Set-Visible $e.EyeXR2 $false
  Set-Visible $e.MouthSmile $true
  Set-Visible $e.MouthOpen $false; Set-Visible $e.MouthO $false; Set-Visible $e.MouthWave $false
  Set-Visible $e.SweatL $false; Set-Visible $e.SweatR $false
  Set-Visible $e.Exclaim $false; Set-Visible $e.Zzz $false; Set-Visible $e.ThinkDots $false
  Set-Visible $e.IrisL $true; Set-Visible $e.IrisR $true
  Set-Visible $e.PupilL $true; Set-Visible $e.PupilR $true
  Set-Visible $e.GlintL $true; Set-Visible $e.GlintR $true
  $e.IrisL.Width = 16; $e.IrisR.Width = 16
  $e.IrisL.Height = 20; $e.IrisR.Height = 20
  [System.Windows.Controls.Canvas]::SetLeft($e.IrisL, 75); [System.Windows.Controls.Canvas]::SetTop($e.IrisL, 92)
  [System.Windows.Controls.Canvas]::SetLeft($e.IrisR, 110); [System.Windows.Controls.Canvas]::SetTop($e.IrisR, 92)
  [System.Windows.Controls.Canvas]::SetLeft($e.PupilL, 79); [System.Windows.Controls.Canvas]::SetTop($e.PupilL, 98)
  [System.Windows.Controls.Canvas]::SetLeft($e.PupilR, 114); [System.Windows.Controls.Canvas]::SetTop($e.PupilR, 98)
}

function Set-PetExpression([string]$state) {
  $e = $script:Visual.Elements
  Reset-PetFace
  switch ($state) {
    'thinking' {
      $e.IrisL.Width = 14; $e.IrisR.Width = 14
      [System.Windows.Controls.Canvas]::SetLeft($e.IrisL, 80); [System.Windows.Controls.Canvas]::SetTop($e.IrisL, 88)
      [System.Windows.Controls.Canvas]::SetLeft($e.IrisR, 115); [System.Windows.Controls.Canvas]::SetTop($e.IrisR, 88)
      [System.Windows.Controls.Canvas]::SetLeft($e.PupilL, 83); [System.Windows.Controls.Canvas]::SetTop($e.PupilL, 92)
      [System.Windows.Controls.Canvas]::SetLeft($e.PupilR, 118); [System.Windows.Controls.Canvas]::SetTop($e.PupilR, 92)
      Set-Visible $e.MouthSmile $false; Set-Visible $e.MouthO $true
      Set-Visible $e.ThinkDots $true
    }
    'working' {
      Set-Visible $e.MouthSmile $false; Set-Visible $e.MouthOpen $true
    }
    'error' {
      Set-Visible $e.IrisL $false; Set-Visible $e.IrisR $false
      Set-Visible $e.PupilL $false; Set-Visible $e.PupilR $false
      Set-Visible $e.GlintL $false; Set-Visible $e.GlintR $false
      Set-Visible $e.EyeXL1 $true; Set-Visible $e.EyeXL2 $true
      Set-Visible $e.EyeXR1 $true; Set-Visible $e.EyeXR2 $true
      Set-Visible $e.MouthSmile $false; Set-Visible $e.MouthWave $true
      Set-Visible $e.SweatL $true; Set-Visible $e.SweatR $true
    }
    'asking' {
      Set-Visible $e.MouthSmile $false; Set-Visible $e.MouthOpen $true
      Set-Visible $e.Exclaim $true
      $e.IrisL.Width = 18; $e.IrisR.Width = 18
    }
    'sleep' {
      Set-Visible $e.IrisL $false; Set-Visible $e.IrisR $false
      Set-Visible $e.PupilL $false; Set-Visible $e.PupilR $false
      Set-Visible $e.GlintL $false; Set-Visible $e.GlintR $false
      Set-Visible $e.EyeLineL $true; Set-Visible $e.EyeLineR $true
      Set-Visible $e.Zzz $true
    }
    default { }
  }
}

function Update-PetState {
  $bridge = $script:Bridge
  if (-not $bridge.connected) {
    if ($script:State -ne 'sleep') { $script:State = 'sleep'; Set-PetExpression 'sleep' }
    Set-PetBubble 'DSH 没连上，等等我…'
    return
  }
  if ($script:Pending.Count -gt 0) {
    if ($script:State -ne 'asking') { $script:State = 'asking'; Set-PetExpression 'asking' }
    Set-PetBubble '皇上，需要你拍板！'
    return
  }
  $serverState = $script:ServerState
  if ([string]::IsNullOrEmpty($serverState)) { $serverState = 'idle' }
  if ($serverState -ne $script:State) {
    $script:State = $serverState
    Set-PetExpression $serverState
  }
  switch ($serverState) {
    'thinking' { Set-PetBubble '思考中…' }
    'working' { Set-PetBubble '干活中…' }
    'error' { Set-PetBubble '出错了！' }
    'asking' { Set-PetBubble '皇上，需要你拍板！' }
    default {
      if ($config.dnd) { Set-PetBubble '免打扰中，确认都回网页' } else { Set-PetBubble '' }
    }
  }
}

$script:ServerState = 'idle'

$animation = New-Object System.Windows.Threading.DispatcherTimer
$animation.Interval = [TimeSpan]::FromMilliseconds(90)
$animation.Add_Tick({
  $script:Tick++
  $e = $script:Visual.Elements
  $phase = $script:Tick / 6.0
  $e.BobTransform.Y = [math]::Round([math]::Sin($phase) * 4, 1)

  switch ($script:State) {
    'asking' {
      $e.LeftArmRotate.Angle = -35 + [math]::Sin($phase * 2.2) * 14
      $e.RightArmRotate.Angle = 35 - [math]::Sin($phase * 2.2) * 14
      $e.Exclaim.Opacity = 0.55 + 0.45 * [math]::Abs([math]::Sin($phase * 1.6))
    }
    'working' {
      $e.LeftArmRotate.Angle = -20 + [math]::Sin($phase * 2.6) * 22
      $e.RightArmRotate.Angle = 20 - [math]::Sin($phase * 2.6 + 1.2) * 22
    }
    'thinking' {
      $e.LeftArmRotate.Angle = -8
      $e.RightArmRotate.Angle = 55
      $e.ThinkDots.Opacity = 0.35 + 0.65 * [math]::Abs([math]::Sin($phase * 1.1))
    }
    'error' {
      $e.LeftArmRotate.Angle = 40
      $e.RightArmRotate.Angle = -40
      $e.SweatL.Opacity = 0.4 + 0.6 * [math]::Abs([math]::Sin($phase * 1.8))
    }
    'sleep' {
      $e.LeftArmRotate.Angle = 0
      $e.RightArmRotate.Angle = 0
      $e.Zzz.Opacity = 0.3 + 0.7 * [math]::Abs([math]::Sin($phase * 0.7))
    }
    default {
      $e.LeftArmRotate.Angle = [math]::Sin($phase) * 6
      $e.RightArmRotate.Angle = -[math]::Sin($phase) * 6
    }
  }

  # 显示器分辨率会被远程会话改来改去，窗口一旦落到可视区外就自动回右下角
  if (($script:Tick % 55) -eq 0) {
    $area = [System.Windows.SystemParameters]::WorkArea
    $outside = ($window.Left -gt ($area.Right - 60)) -or ($window.Top -gt ($area.Bottom - 60)) -or
      (($window.Left + $window.Width) -lt ($area.Left + 60)) -or (($window.Top + $window.Height) -lt ($area.Top + 60))
    if ($outside) {
      $window.Left = $area.Right - 320
      $window.Top = $area.Bottom - 380
      Write-PetLog ("窗口落在可视区外，已拉回右下角：({0},{1})" -f [int]$window.Left, [int]$window.Top)
    }
  }

  # 眨眼：随机间隔，两帧闭合
  if ($script:Blink -gt 0) {
    $script:Blink--
    if ($script:Blink -eq 0) {
      Reset-PetFace
      Set-PetExpression $script:State
      Update-PetState
    }
  } elseif ($script:State -notin @('sleep', 'error') -and (Get-Random -Minimum 0 -Maximum 60) -eq 0) {
    $script:Blink = 2
    Set-Visible $e.EyeLineL $true; Set-Visible $e.EyeLineR $true
    Set-Visible $e.IrisL $false; Set-Visible $e.IrisR $false
    Set-Visible $e.PupilL $false; Set-Visible $e.PupilR $false
    Set-Visible $e.GlintL $false; Set-Visible $e.GlintR $false
  }
})
$animation.Start()

# ---------- 待答卡片队列 ----------

function Show-NextCard {
  if ($null -ne $script:Card) { return }
  if ($script:Pending.Count -eq 0) { return }
  $item = $script:Pending[0]
  $script:Card = Show-PetCard -Item $item -Config $config -OnAnswer {
    param($payload)
    Send-BridgeAnswer $payload | Out-Null
    $script:Card = $null
    $script:Pending.RemoveAt(0) | Out-Null
    Update-PetState
    Show-NextCard
  }
}

function Sync-Pending($list) {
  $ids = @($list | ForEach-Object { $_.id })
  for ($index = $script:Pending.Count - 1; $index -ge 0; $index--) {
    $known = $script:Pending[$index]
    if ($ids -notcontains $known.id) {
      $script:Pending.RemoveAt($index) | Out-Null
      if ($null -ne $script:Card -and $script:Card.Id -eq $known.id) {
        & $script:Card.Close
        $script:Card = $null
      }
    }
  }
  foreach ($entry in @($list)) {
    if (-not ($script:Pending | Where-Object { $_.id -eq $entry.id })) {
      $script:Pending.Add($entry) | Out-Null
    }
  }
}

# ---------- 主循环：取件、更新状态、弹卡 ----------

$pump = New-Object System.Windows.Threading.DispatcherTimer
$pump.Interval = [TimeSpan]::FromMilliseconds(120)
$pump.Add_Tick({
  $item = $null
  $drained = 0
  while ($drained -lt 50 -and $sync.Inbox.TryDequeue([ref]$item)) {
    $drained++
    if ($item.type -eq 'snapshot') {
      $script:Bridge.connected = $true
      $script:Bridge.error = ''
      $script:DisconnectedAt = $null
      $script:ServerState = [string]$item.data.state
      Sync-Pending $item.data.pending
    } elseif ($item.type -eq 'event') {
      if ($item.data.type -eq 'session') { $script:ServerState = [string]$item.data.data.state }
    } elseif ($item.type -eq 'transport') {
      if ($script:Bridge.connected) { $script:DisconnectedAt = Get-Date }
      $script:Bridge.connected = $false
      $script:Bridge.error = [string]$item.error
      $script:ServerState = 'idle'
    }
  }

  # 首次连上时把本地免打扰开关同步给桥接（否则 config.json 里的 dnd 只在气泡上生效）
  if (-not $script:DndPushed -and $script:Bridge.connected) {
    if (Send-BridgeControl @{ dnd = [bool]$config.dnd }) { $script:DndPushed = $true }
  }

  # DSH 断开超过 30 秒：在途确认已经跟着进程没了，收摊别挂着假卡片
  if (-not $script:Bridge.connected -and $null -ne $script:DisconnectedAt -and $script:Pending.Count -gt 0) {
    if (((Get-Date) - $script:DisconnectedAt).TotalSeconds -gt 30) {
      if ($null -ne $script:Card) { & $script:Card.Close; $script:Card = $null }
      $script:Pending.Clear()
      Show-Balloon 'DSH 断开了，刚才那几个确认已经失效，重连后会重新问你'
    }
  }

  # 每 ~2.4 秒看一眼 config.json：设置页（宿主写文件）或手改档位后，桌宠这边跟着变
  $script:PumpTick++
  if (($script:PumpTick % 20) -eq 0) {
    try {
      if (Test-Path $configPath) {
        $fresh = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($fresh.size -and ([string]$fresh.size -ne $script:CurrentSize)) {
          Write-PetLog "配置文件里的档位变成 $($fresh.size)，跟随切换"
          Apply-PetSize ([string]$fresh.size)
        }
      }
    } catch {
      # 读失败下次再试
    }
  }

  Update-PetState
  Show-NextCard
})
$pump.Start()

# ---------- 启动 ----------

$window.Show() | Out-Null
Write-PetLog ("窗口已显示：({0},{1}) {2}x{3}  topmost={4}" -f [int]$window.Left, [int]$window.Top, [int]$window.Width, [int]$window.Height, $window.Topmost)
Read-Handshake | Out-Null
Update-PetState
Set-PetBubble '海绵宝宝待命中'

$application = New-Object System.Windows.Application
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$application.Add_DispatcherUnhandledException({
  $err = $args[1].Exception
  Write-PetLog ("UI 线程未捕获异常：" + $err.GetType().Name + ': ' + $err.Message)
})
$application.Run() | Out-Null
Write-PetLog 'Application.Run 退出，脚本结束'
