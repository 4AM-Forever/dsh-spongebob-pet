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
Write-Host '== BOM（字节序标记）=='
# 规则：含非 ASCII 的 .ps1 必须带 BOM（PowerShell 5.1 无 BOM 会按 GBK 读，中文乱码直接语法报错）；
# 其它交给 Node / 浏览器读的文件绝不能带 BOM —— JSON.parse 不剥 BOM，dsh 启动时会直接崩。
foreach ($file in (Get-ChildItem $Root -Recurse -File |
    Where-Object { $_.FullName -notlike '*\node_modules\*' -and $_.FullName -notlike '*\.git\*' -and $_.FullName -notlike '*\.test-home\*' -and
      $_.Extension -in '.ps1', '.js', '.mjs', '.json', '.yml', '.cmd' })) {
  $checked++
  $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $nonAscii = $false
  foreach ($byte in $bytes) { if ($byte -ge 0x80) { $nonAscii = $true; break } }

  if ($file.Extension -eq '.ps1') {
    if ($nonAscii -and -not $hasBom) {
      $fail++
      Write-Host ("  [FAIL] {0}：含非 ASCII 却没有 BOM（PS 5.1 会按 GBK 读）" -f $file.Name) -ForegroundColor Red
    } else {
      Write-Host ("  [ok]   {0}（BOM={1}，非 ASCII={2}）" -f $file.Name, $hasBom, $nonAscii)
    }
  } else {
    if ($hasBom) {
      $fail++
      Write-Host ("  [FAIL] {0}：给 Node/浏览器读的文件不能带 BOM（JSON.parse 会崩）" -f $file.Name) -ForegroundColor Red
    } else {
      Write-Host ("  [ok]   {0}" -f $file.Name)
    }
  }
}

Write-Host ''
if ($fail -gt 0) {
  Write-Host ("[FAIL] {0}/{1} 项没过 —— 先修文件，别重启 dsh。" -f $fail, $checked) -ForegroundColor Red
  Write-Host '       剥 BOM：[System.IO.File]::WriteAllBytes($f, $bytes[3..($bytes.Length-1)])' -ForegroundColor Yellow
  Write-Host '       写无 BOM：[System.IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding $false))' -ForegroundColor Yellow
  exit 1
}
Write-Host ("[OK] {0} 项全部通过（可以重启 dsh）。" -f $checked) -ForegroundColor Green
exit 0
