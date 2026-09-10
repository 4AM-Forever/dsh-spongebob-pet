# 交付前自检：JS 走 node --check、PS1 走 PowerShell 解析器、JSON 走 ConvertFrom-Json。
# 任何一项不过就以非零码退出。规矩：改完文件先跑这个，过了才准重启 dsh。
# 用法：powershell -ExecutionPolicy RemoteSigned -File tools\check-syntax.ps1
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$fail = 0
$checked = 0

Write-Host "自检根目录：$Root"
Write-Host ''

Write-Host '== JS / MJS =='
foreach ($file in (Get-ChildItem $Root -Recurse -Include *.js, *.mjs -File |
    Where-Object { $_.FullName -notlike '*\node_modules\*' -and $_.FullName -notlike '*\.test-home\*' })) {
  $checked++
  $output = & node --check $file.FullName 2>&1
  if ($LASTEXITCODE -ne 0) {
    $fail++
    Write-Host ("  [FAIL] {0}" -f $file.FullName.Replace($Root, '.')) -ForegroundColor Red
    $output | Select-Object -First 6 | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
  } else {
    Write-Host ("  [ok]   {0}" -f $file.Name)
  }
}

Write-Host ''
Write-Host '== PS1 =='
foreach ($file in (Get-ChildItem $Root -Recurse -Filter *.ps1 -File)) {
  $checked++
  $errors = $null
  $tokens = $null
  [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -gt 0) {
    $fail++
    Write-Host ("  [FAIL] {0}: {1}" -f $file.Name, $errors[0].Message) -ForegroundColor Red
  } else {
    Write-Host ("  [ok]   {0}" -f $file.Name)
  }
}

Write-Host ''
Write-Host '== JSON =='
foreach ($file in (Get-ChildItem $Root -Recurse -Filter *.json -File |
    Where-Object { $_.FullName -notlike '*\node_modules\*' })) {
  $checked++
  try {
    Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
    Write-Host ("  [ok]   {0}" -f $file.Name)
  } catch {
    $fail++
    Write-Host ("  [FAIL] {0}: {1}" -f $file.Name, $_.Exception.Message) -ForegroundColor Red
  }
}

Write-Host ''
if ($fail -gt 0) {
  Write-Host ("[FAIL] {0}/{1} 项没过 —— 先修文件，别重启 dsh。" -f $fail, $checked) -ForegroundColor Red
  exit 1
}
Write-Host ("[OK] {0} 个文件全部通过（可以重启 dsh）。" -f $checked) -ForegroundColor Green
exit 0
