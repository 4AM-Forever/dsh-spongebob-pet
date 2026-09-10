# 无头驱动确认卡片（UI Automation）：用于改完卡片后自动回归，不需要人点。
# 例：powershell -File test\drive-card.ps1 -Toggle 桥接插件,文档 -Answer "补充说明" 
param(
  [string[]]$Toggle = @(),
  [string]$Answer = '',
  [string]$Button = '提交回答',
  [string]$WindowTitle = '海绵宝宝桌宠 · 待你拍板'
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

$window = $AE::RootElement.FindFirst($TS::Children, (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $WindowTitle)))
if ($null -eq $window) { Write-Error "没找到卡片窗口「$WindowTitle」"; exit 1 }

function Find-All($type) {
  $condition = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $type)
  return $window.FindAll($TS::Descendants, $condition)
}

foreach ($checkBox in (Find-All $CT::CheckBox)) {
  if ($Toggle -contains $checkBox.Current.Name) {
    $checkBox.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Write-Host "勾选：$($checkBox.Current.Name)"
  }
}
foreach ($radio in (Find-All $CT::RadioButton)) {
  if ($Toggle -contains $radio.Current.Name) {
    $radio.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Write-Host "选中：$($radio.Current.Name)"
  }
}
if ($Answer -ne '') {
  $edits = Find-All $CT::Edit
  if ($edits.Count -gt 0) {
    $edits[$edits.Count - 1].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Answer)
    Write-Host "写入自定义回答：$Answer"
  }
}
foreach ($item in (Find-All $CT::Button)) {
  if ($item.Current.Name -like "*$Button*") {
    $item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Write-Host "点击：$($item.Current.Name)"
  }
}
