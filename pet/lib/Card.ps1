# 确认/选择卡片：桌宠最高优先级弹出的作答窗口（置顶 + 抢焦点 + 闪烁 + 提示音，可选全屏压暗）。
# 事件回调跨函数存活，因此卡片上下文一律放在 $script:CardCtx（PowerShell 处理器看不到函数局部变量）。

function New-DimWindow {
  $window = New-Object System.Windows.Window
  $window.WindowStyle = [System.Windows.WindowStyle]::None
  $window.AllowsTransparency = $true
  $window.Background = New-Brush '#99000000'
  $window.ShowInTaskbar = $false
  $window.Topmost = $true
  $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $window.Left = [System.Windows.SystemParameters]::VirtualScreenLeft
  $window.Top = [System.Windows.SystemParameters]::VirtualScreenTop
  $window.Width = [System.Windows.SystemParameters]::VirtualScreenWidth
  $window.Height = [System.Windows.SystemParameters]::VirtualScreenHeight
  return $window
}

$script:CardCtx = $null

function Close-PetCard([hashtable]$payload) {
  $ctx = $script:CardCtx
  $script:CardCtx = $null
  if ($null -eq $ctx) { return }
  try { if ($null -ne $ctx.Dim) { $ctx.Dim.Close() } } catch { }
  try { $ctx.Window.Close() } catch { }
  if ($null -ne $payload) { & $ctx.OnAnswer $payload }
}

function Show-PetCard {
  param(
    [Parameter(Mandatory = $true)] $Item,
    [Parameter(Mandatory = $true)] $Config,
    [Parameter(Mandatory = $true)] [scriptblock] $OnAnswer
  )

  $isApproval = $Item.kind -eq 'approval'
  $dim = $null
  if ($Config.dimScreen) {
    $dim = New-DimWindow
    $dim.Show() | Out-Null
  }

  $window = New-Object System.Windows.Window
  $window.WindowStyle = [System.Windows.WindowStyle]::None
  $window.AllowsTransparency = $true
  $window.Background = [System.Windows.Media.Brushes]::Transparent
  $window.ShowInTaskbar = $true
  $window.Topmost = $true
  $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $window.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
  $window.Title = '海绵宝宝桌宠 · 待你拍板'
  $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
  $window.ShowActivated = $true

  $card = New-Border 18 '#FFFDF0' '#CBA41F' 3 20
  $card.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
    BlurRadius = 24; ShadowDepth = 4; Opacity = 0.45; Color = [System.Windows.Media.Colors]::Black
  }
  $stack = New-Object System.Windows.Controls.StackPanel
  $stack.Width = 560

  $title = if ($isApproval) { '🍍 皇上，有个操作要你点头！' } else { '🍍 皇上，需要你拍板！' }
  $stack.Children.Add((New-Text $title 19 '#6B4E0E' $true)) | Out-Null

  $subtitle = if ($isApproval) { "工具：$($Item.approval.toolName)" } else { "共 $(@($Item.questions).Count) 个问题" }
  if ($Item.session.title) { $subtitle = "$subtitle`n会话：$($Item.session.title)" }
  $stack.Children.Add((New-Text $subtitle 12 '#8A7A3E' $false)) | Out-Null

  $separator = New-Object System.Windows.Controls.Border
  $separator.Height = 2
  $separator.Margin = New-Object System.Windows.Thickness(0, 12, 0, 12)
  $separator.Background = New-Brush '#F0E3A8'
  $stack.Children.Add($separator) | Out-Null

  $scroll = New-Object System.Windows.Controls.ScrollViewer
  # 多题卡片要尽量一屏放下，超出才滚动；1080p 下 540 不会顶出屏幕
  $scroll.MaxHeight = 540
  $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
  $scroll.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
  $body = New-Object System.Windows.Controls.StackPanel
  $inputs = @()

  if ($isApproval) {
    $body.Children.Add((New-Text 'DSH 请求执行一个需要审批的操作：' 14 '#3A3A3A' $false)) | Out-Null
    $body.Children.Add((New-Text $Item.approval.toolName 15 '#B8860B' $true)) | Out-Null
    if ($Item.approval.reason) { $body.Children.Add((New-Text $Item.approval.reason 13 '#5A5A5A' $false)) | Out-Null }
    if ($Item.approval.callId) { $body.Children.Add((New-Text "调用 id：$($Item.approval.callId)" 11 '#9A9A9A' $false)) | Out-Null }
  } else {
    foreach ($question in @($Item.questions)) {
      if ($question.header) { $body.Children.Add((New-Text $question.header 13 '#B8860B' $true)) | Out-Null }
      $body.Children.Add((New-Text $question.question 15 '#2A2A2A' $true)) | Out-Null
      if ($question.detail) {
        $detailBox = New-Border 8 '#FBF6DE' '#EADFA6' 1 10
        $detailBox.Margin = New-Object System.Windows.Thickness(0, 8, 0, 6)
        $detailScroll = New-Object System.Windows.Controls.ScrollViewer
        $detailScroll.MaxHeight = 170
        $detailScroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        $detailScroll.Content = New-Text ([string]$question.detail) 12 '#4A4A4A' $false 'Consolas'
        $detailBox.Child = $detailScroll
        $body.Children.Add($detailBox) | Out-Null
      }

      $choices = @()
      $optionPanel = New-Object System.Windows.Controls.StackPanel
      $optionPanel.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
      foreach ($option in @($question.options)) {
        if ($question.multiSelect) { $control = New-Object System.Windows.Controls.CheckBox }
        else {
          $control = New-Object System.Windows.Controls.RadioButton
          $control.GroupName = "q-$($question.id)"
        }
        $control.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
        $control.FontSize = 14
        $control.Foreground = New-Brush '#2A2A2A'
        $control.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
        $control.Cursor = [System.Windows.Input.Cursors]::Hand
        $control.Tag = @{ QuestionId = [string]$question.id; Label = [string]$option.label }
        if ($option.description) {
          $optionStack = New-Object System.Windows.Controls.StackPanel
          $optionStack.Children.Add((New-Text $option.label 14 '#2A2A2A' $true)) | Out-Null
          $optionStack.Children.Add((New-Text $option.description 11.5 '#8A8A8A' $false)) | Out-Null
          $control.Content = $optionStack
        } else {
          $control.Content = $option.label
        }
        $optionPanel.Children.Add($control) | Out-Null
        $choices += $control
      }
      if (@($question.options).Count -eq 0) {
        $optionPanel.Children.Add((New-Text '（这题没有预设选项，请在下面直接写）' 12 '#9A9A9A' $false)) | Out-Null
      }
      $body.Children.Add($optionPanel) | Out-Null

      $custom = New-Object System.Windows.Controls.TextBox
      $custom.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
      $custom.FontSize = 13
      $custom.Padding = New-Object System.Windows.Thickness(8, 6, 8, 6)
      $custom.Margin = New-Object System.Windows.Thickness(0, 8, 0, 14)
      $custom.Background = New-Brush '#FFFFFF'
      $custom.BorderBrush = New-Brush '#E0D296'
      $custom.BorderThickness = New-Object System.Windows.Thickness(1.5)
      $custom.ToolTip = '也可以直接写你的回答'
      if (@($question.options).Count -eq 0) { $custom.MinHeight = 60; $custom.AcceptsReturn = $true; $custom.TextWrapping = 'Wrap' }
      $body.Children.Add($custom) | Out-Null
      $inputs += @{ Question = $question; Choices = $choices; Custom = $custom }
    }
  }

  $scroll.Content = $body
  $stack.Children.Add($scroll) | Out-Null

  $hint = New-Text '' 12.5 '#C0392B' $true
  $hint.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
  $stack.Children.Add($hint) | Out-Null

  $footer = New-Object System.Windows.Controls.StackPanel
  $footer.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $footer.Margin = New-Object System.Windows.Thickness(0, 16, 0, 0)

  # 上下文先落地，再挂回调：处理器只认 $script:CardCtx。
  $script:CardCtx = @{
    Id       = $Item.id
    Window   = $window
    Dim      = $dim
    Hint     = $hint
    Inputs   = $inputs
    OnAnswer = $OnAnswer
  }

  if ($isApproval) {
    $allow = New-Button '✅ 允许一次' '#F6E14B' '#5A4410'
    $allow.Add_Click({ Close-PetCard @{ id = $script:CardCtx.Id; decision = 'allow' } })
    $deny = New-Button '⛔ 拒绝' '#F1C6C6' '#7A2E22'
    $deny.Add_Click({ Close-PetCard @{ id = $script:CardCtx.Id; decision = 'deny' } })
    $footer.Children.Add($allow) | Out-Null
    $footer.Children.Add($deny) | Out-Null
  } else {
    $submit = New-Button '✅ 提交回答' '#F6E14B' '#5A4410'
    $submit.Add_Click({
      $ctx = $script:CardCtx
      $answers = @()
      $filled = 0
      foreach ($input in $ctx.Inputs) {
        $selected = @()
        foreach ($choice in $input.Choices) {
          if ($choice.IsChecked -eq $true) { $selected += [string]$choice.Tag.Label }
        }
        $custom = ([string]$input.Custom.Text).Trim()
        $answer = @{ id = [string]$input.Question.id; selected = $selected }
        if ($custom -ne '') { $answer.custom = $custom }
        if ($selected.Count -gt 0 -or $custom -ne '') { $filled++ }
        $answers += $answer
      }
      if ($filled -eq 0) {
        $ctx.Hint.Text = '还没作答呢 —— 选一个，或者直接写两句也行。'
        return
      }
      Close-PetCard @{ id = $ctx.Id; answers = $answers }
    })
    $footer.Children.Add($submit) | Out-Null
  }

  $delegate = New-Button '↩︎ 交给网页回答' '#F4EFD8' '#6B4E0E'
  $delegate.Add_Click({ Close-PetCard @{ id = $script:CardCtx.Id; delegate = $true } })
  $footer.Children.Add($delegate) | Out-Null
  $stack.Children.Add($footer) | Out-Null

  $card.Child = $stack
  $window.Content = $card
  $window.Add_KeyDown({
    $eventArgs = $args[1]
    if ($null -eq $eventArgs -or $null -eq $script:CardCtx) { return }
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
      Close-PetCard @{ id = $script:CardCtx.Id; delegate = $true }
    }
  })
  # 窗口被别的途径关掉时不能把请求悬着：一律当作「交给网页」。
  $window.Add_Closed({
    if ($null -eq $script:CardCtx) { return }
    $ctx = $script:CardCtx
    $script:CardCtx = $null
    try { if ($null -ne $ctx.Dim) { $ctx.Dim.Close() } } catch { }
    & $ctx.OnAnswer @{ id = $ctx.Id; delegate = $true }
  })

  $window.Show() | Out-Null
  if ($Config.sound) { [System.Media.SystemSounds]::Exclamation.Play() }
  Invoke-WindowAlert $window 8

  return [pscustomobject]@{
    Id     = $Item.id
    Window = $window
    Close  = { Close-PetCard $null }
  }
}
