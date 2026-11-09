# merge.ps1 - добавление прошивки ядра в битстрим без пересинтеза:
#   merge_bit.exe <bin> <fs> <ITCM КБ> <posp>  (SDK Gowin_PicoRV32, IPUG913 гл. 3).
# Вход: firmware\build\<FW_NAME>.bin, fpga\impl\pnr\<FPGA_PROJECT>.fs и .posp (Post-Place File).
# Результат: fpga\impl\pnr\<FPGA_PROJECT>_fw.fs.
# merge_bit запускается во временной папке без пробелов и пишет результат как new_<имя>.fs.

. (Join-Path $PSScriptRoot 'common.ps1')
$cfg  = Read-ProjectConfig
$name = Get-Cfg $cfg 'FPGA_PROJECT'
$pnr  = Join-Path $script:Root 'fpga\impl\pnr'
$fs   = Join-Path $pnr "$name.fs"
$posp = Join-Path $pnr "$name.posp"
$bin  = Join-Path $script:Root ('firmware\build\{0}.bin' -f (Get-Cfg $cfg 'FW_NAME'))
$out  = Join-Path $pnr "${name}_fw.fs"
$mb   = Join-Path (Resolve-CfgPath (Get-Cfg $cfg 'PICORV32_SDK_DIR')) 'tool\merge_bit\bin\merge_bit.exe'
$itcm = Get-Cfg $cfg 'CPU_ITCM_KB'
if (-not (Test-Path -LiteralPath $mb))   { Die "не найден merge_bit.exe: $mb (scripts\setup.ps1)" }
if (-not (Test-Path -LiteralPath $bin))  { Die "нет прошивки: $bin" }
if (-not (Test-Path -LiteralPath $fs))   { Die "нет битстрима: $fs (нужна полная сборка)" }
if (-not (Test-Path -LiteralPath $posp)) { Die "нет Post-Place File: $posp (нужен синтез с Generate_Post_Place_File)" }

$work = Join-Path $env:TEMP 'primer_kvm_merge'
if ($work -match ' ') { Die "в пути временной папки есть пробел: $work" }
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null
Copy-Item -LiteralPath $bin  -Destination (Join-Path $work 'fw.bin')
Copy-Item -LiteralPath $fs   -Destination (Join-Path $work 'top.fs')
Copy-Item -LiteralPath $posp -Destination (Join-Path $work 'top.posp')

Push-Location -LiteralPath $work
try { $o = @(& $mb 'fw.bin' 'top.fs' $itcm 'top.posp' 2>&1 | ForEach-Object { "$_" }) } finally { Pop-Location }
$res = Join-Path $work 'new_top.fs'
if (-not (Test-Path -LiteralPath $res)) {
    $o | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 20 | ForEach-Object { Say "  $_" }
    Die 'merge_bit не создал битстрим'
}
Copy-Item -LiteralPath $res -Destination $out -Force
Ok "битстрим: $out"
exit 0
