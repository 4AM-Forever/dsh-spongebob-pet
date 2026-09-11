# 编译桌宠启动器（pet\SpongeBobPet.exe）。
# 用系统自带的 .NET Framework 编译器，不需要装任何 SDK。
# 用法：powershell -ExecutionPolicy RemoteSigned -File tools\build-launcher.ps1
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'pet\launcher\PetLauncher.cs'
$output = Join-Path $root 'pet\SpongeBobPet.exe'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if (-not (Test-Path $csc)) { throw "找不到编译器：$csc" }
if (-not (Test-Path $source)) { throw "找不到源码：$source" }

& $csc /nologo /target:winexe /out:$output /r:System.Windows.Forms.dll $source
if ($LASTEXITCODE -ne 0) { throw "编译失败（退出码 $LASTEXITCODE）" }

$exe = Get-Item $output
"已生成 $($exe.FullName)  $([math]::Round($exe.Length / 1KB, 1)) KB"
