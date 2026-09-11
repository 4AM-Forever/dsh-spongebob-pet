# 进行中会话面板：点桌宠（或气泡）弹出，列出每个会话的状态、已持续时间与工作目录。
# 面板不阻塞任何操作，桌宠那边每秒刷新一次内容；按 Esc 或再点一次桌宠关闭。

$script:SessionsPanel = $null
$script:PanelSignature = ''

$script:SessionStateText = @{
  thinking = '思考中'
  working  = '干活中'
  error    = '出错了'
  asking   = '等你拍板'
  idle     = '空闲'
}

$script:SessionStateColor = @{
  thinking = '#3E9BDE'
  working  = '#1A9F5B'
  error    = '#D93025'
  asking   = '#E0A800'
  idle     = '#9A9A9A'
}

function Format-Duration([double]$milliseconds) {
  if ($milliseconds -lt 0) { return '—' }
  $seconds = [int]($milliseconds / 1000)
  if ($seconds -lt 60) { return "$seconds 秒" }
  $minutes = [int]($seconds / 60)
  if ($minutes -lt 60) { return "$minutes 分 $($seconds % 60) 秒" }
  return "$([int]($minutes / 60)) 小时 $($minutes % 60) 分"
}

# 路径最后一段，作为没有标题时的会话名（与 DSH 侧同口径）
function Get-WorkspaceName([string]$path) {
  if ([string]::IsNullOrEmpty($path)) { return '' }
  $trimmed = $path.TrimEnd([char[]]@('/', '\'))
  $index = [Math]::Max($trimmed.LastIndexOf('/'), $trimmed.LastIndexOf('\'))
  if ($index -lt 0) { return $trimmed }
  return $trimmed.Substring($index + 1)
}

# 界面上只出现会话名：宿主给的 label → 标题 → 工作目录名 → 未命名会话。
# 会话 id 是内部标识，任何情况下都不上界面。
function Get-SessionDisplayName($session) {
  foreach ($candidate in @($session.label, $session.title)) {
    if (-not [string]::IsNullOrEmpty($candidate)) { return [string]$candidate }
  }
  $base = Get-WorkspaceName ([string]$session.cwd)
  if (-not [string]::IsNullOrEmpty($base)) { return $base }
  return '未命名会话'
}

function New-SessionRow($session, [int]$index) {
  $row = New-Object System.Windows.Controls.StackPanel
  $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, $(if ($index -eq 0) { 10 } else { 10 }))

  $state = [string]$session.state
  $color = if ($script:SessionStateColor.ContainsKey($state)) { $script:SessionStateColor[$state] } else { '#9A9A9A' }
  $label = if ($script:SessionStateText.ContainsKey($state)) { $script:SessionStateText[$state] } else { $state }

  $head = New-Object System.Windows.Controls.StackPanel
  $head.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 9
  $dot.Height = 9
  $dot.Fill = New-Brush $color
  $dot.Margin = New-Object System.Windows.Thickness(0, 6, 8, 0)
  $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
  $head.Children.Add($dot) | Out-Null

  $title = New-Text (Get-SessionDisplayName $session) 13.5 '#2A2A2A' $true
  $title.MaxWidth = 360
  $title.TextTrimming = 'CharacterEllipsis'
  $head.Children.Add($title) | Out-Null
  $row.Children.Add($head) | Out-Null

  $since = 0
  if ($null -ne $session.stateSince) { $since = [double]$session.stateSince }
  # Windows PowerShell 5.1 跑在 .NET Framework 上：DateTime 没有 ToUnixTimeMilliseconds，只有 DateTimeOffset 有
  $elapsed = if ($since -gt 0) { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $since } else { -1 }
  $metaParts = @("$label · 已 $(Format-Duration $elapsed)")
  if ($session.lastTool) { $metaParts += "工具 $($session.lastTool)" }
  if ($session.cwd) { $metaParts += [string]$session.cwd }
  $meta = New-Text ($metaParts -join '  ·  ') 11.5 '#8A8A8A' $false
  $meta.MaxWidth = 400
  $meta.Margin = New-Object System.Windows.Thickness(17, 2, 0, 0)
  $meta.TextTrimming = 'CharacterEllipsis'
  $row.Children.Add($meta) | Out-Null

  return $row
}

function Show-SessionsPanel($Config) {
  if ($null -ne $script:SessionsPanel) { return }
  if ($null -eq $window) { return }

  $panel = New-Object System.Windows.Window
  $panel.WindowStyle = [System.Windows.WindowStyle]::None
  # 无边框窗口默认没有标题；填上标题栏文字，无障碍工具与自动化脚本才认得出这个窗口
  $panel.Title = '进行中的会话'
  $panel.AllowsTransparency = $true
  $panel.Background = [System.Windows.Media.Brushes]::Transparent
  $panel.ShowInTaskbar = $false
  $panel.Topmost = $true
  $panel.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $panel.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight

  $card = New-Border 14 '#FFFDF0' '#CBA41F' 2.5 14
  $card.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
    BlurRadius = 18; ShadowDepth = 3; Opacity = 0.35; Color = [System.Windows.Media.Colors]::Black
  }
  $stack = New-Object System.Windows.Controls.StackPanel
  $stack.Width = 430
  $heading = New-Text '进行中的会话' 15 '#6B4E0E' $true
  $stack.Children.Add($heading) | Out-Null
  $script:SessionListBox = New-Object System.Windows.Controls.StackPanel
  $script:SessionListBox.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
  $stack.Children.Add($script:SessionListBox) | Out-Null
  $hint = New-Text '点桌宠再点一次或按 Esc 关闭 · 每秒自动刷新' 11 '#9A9A9A' $false
  $hint.Margin = New-Object System.Windows.Thickness(0, 12, 0, 0)
  $stack.Children.Add($hint) | Out-Null
  $card.Child = $stack
  $panel.Content = $card

  # 贴在桌宠左边，左边放不下就换右边
  $panel.Left = $window.Left - 460
  $panel.Top = [math]::Max(10, $window.Top - 40)
  if ($panel.Left -lt [System.Windows.SystemParameters]::VirtualScreenLeft + 10) {
    $panel.Left = $window.Left + $window.Width + 16
  }

  $panel.Add_KeyDown({
    $eventArgs = $args[1]
    if ($null -ne $eventArgs -and $eventArgs.Key -eq [System.Windows.Input.Key]::Escape) { Hide-SessionsPanel }
  })

  $panel.Show() | Out-Null
  $script:SessionsPanel = $panel
  Write-PetLog ("会话面板已打开：({0},{1})" -f [int]$panel.Left, [int]$panel.Top)
  Update-SessionsPanel $script:LastSessions
}

function Update-SessionsPanel($sessions) {
  if ($null -eq $script:SessionsPanel -or $null -eq $script:SessionListBox) { return }
  $script:SessionListBox.Children.Clear()
  $list = @($sessions)
  if ($list.Count -eq 0) {
    Write-PetLog '会话面板内容：当前没有活跃会话'
    $script:SessionListBox.Children.Add((New-Text '当前没有活跃会话' 12.5 '#8A8A8A' $false)) | Out-Null
    return
  }
  # 面板每秒刷新，内容签名没变就不记日志，免得把 pet.log 刷爆
  $signature = (@($list | ForEach-Object { "$(Get-SessionDisplayName $_)[$($_.state)]" }) -join ' | ')
  if ($signature -ne $script:PanelSignature) {
    $script:PanelSignature = $signature
    Write-PetLog "会话面板内容：$signature"
  }
  $index = 0
  foreach ($session in $list) {
    $script:SessionListBox.Children.Add((New-SessionRow $session $index)) | Out-Null
    $index++
  }
}

function Hide-SessionsPanel {
  if ($null -eq $script:SessionsPanel) { return }
  try { $script:SessionsPanel.Close() } catch { }
  $script:SessionsPanel = $null
  $script:PanelSignature = ''
  Write-PetLog '会话面板已关闭'
}

function Toggle-SessionsPanel($Config) {
  if ($null -ne $script:SessionsPanel) { Hide-SessionsPanel } else { Show-SessionsPanel $Config }
}
