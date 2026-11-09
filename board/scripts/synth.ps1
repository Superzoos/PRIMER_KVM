# synth.ps1 - синтез и Place&Route проекта FPGA консольным Gowin (gw_sh).
#   1) gen-config.ps1 - параметры из project.cfg;
#   2) список файлов fpga\<FPGA_PROJECT>.gprj собирается из fpga\rtl, fpga\ip, fpga\constraints;
#   3) настройки: fpga\process_config.json -> fpga\impl\<FPGA_PROJECT>_process_config.json
#      (IncludePath: fpga\rtl и все папки fpga\ip - вычисляются);
#      (этот файл читает Gowin 1.9.11); TopModule и OUTPUT_BASE_NAME - из project.cfg.
#      Настройки менять в fpga\process_config.json: копия в impl\ перезаписывается при синтезе;
#   4) gw_sh: open_project + run all.
# Вывод Gowin не показывается; при ошибке печатаются его строки с ERROR.
# Отчёты синтеза Gowin пишет сам в fpga\impl\.

. (Join-Path $PSScriptRoot 'common.ps1')
$cfg  = Read-ProjectConfig
$fpga = Join-Path $script:Root 'fpga'
$name = Get-Cfg $cfg 'FPGA_PROJECT'
$gprj = Join-Path $fpga "$name.gprj"
$pcfg = Join-Path $fpga 'process_config.json'
$json = Join-Path $fpga "impl\${name}_process_config.json"
$fs   = Join-Path $fpga "impl\pnr\$name.fs"
$gwsh = Join-Path (Resolve-CfgPath (Get-Cfg $cfg 'GOWIN_BIN')) 'gw_sh.exe'
if (-not (Test-Path -LiteralPath $gwsh)) { Die "не найден gw_sh.exe: $gwsh" }
if (-not (Test-Path -LiteralPath $pcfg)) { Die "нет настроек проекта: $pcfg" }

# --- 1. Параметры
& (Join-Path $PSScriptRoot 'gen-config.ps1') 6>$null
if ($LASTEXITCODE -ne 0) { Die 'gen-config.ps1 завершился с ошибкой (запустите его отдельно)' }

# --- 2. Список файлов проекта
function Rel ([string]$full) { return $full.Substring($fpga.Length + 1) -replace '\\', '/' }

$hdl = @()
foreach ($d in @('rtl', 'ip')) {
    $dir = Join-Path $fpga $d
    if (Test-Path -LiteralPath $dir) {
        $hdl += @(Get-ChildItem -LiteralPath $dir -Recurse -File |
                  Where-Object { $_.Extension -in @('.v', '.sv', '.vh', '.svh') -and $_.Name -notlike '*_tmp.v' })
    }
}
# В fpga\ip файлы .v без "module" и без шифрованного блока - только для `include (настройки IP):
# отдельно не компилируются. Всё из fpga\rtl компилируется всегда.
$ipPath = Join-Path $fpga 'ip'
$hdl = @($hdl | Where-Object { -not $_.FullName.StartsWith($ipPath + '\') -or $_.Extension -in @('.vh', '.svh') -or
                               (Select-String -LiteralPath $_.FullName -Pattern 'module|pragma protect' -Quiet) })
# Зашифрованный файл, который открытые файлы IP подключают через `include (DDR3: gwmc_local_param.v), -
# тоже только для `include.
$incNames = @{}
foreach ($f in @($hdl | Where-Object { $_.FullName.StartsWith($ipPath + '\') })) {
    foreach ($m in (Select-String -LiteralPath $f.FullName -Pattern '`include\s+"([^"]+)"' -AllMatches)) {
        foreach ($g in $m.Matches) { $incNames[[IO.Path]::GetFileName($g.Groups[1].Value).ToLowerInvariant()] = $true }
    }
}
$hdl = @($hdl | Where-Object { -not ($_.FullName.StartsWith($ipPath + '\') -and $incNames.ContainsKey($_.Name.ToLowerInvariant()) -and
                                     (Select-String -LiteralPath $_.FullName -Pattern 'pragma protect' -Quiet)) })
# порядок: пакеты (*_pkg.sv), открытые файлы, зашифрованные IP; внутри - по алфавиту
$hdl = @($hdl | Sort-Object @{ Expression = { $_.Name -notlike '*_pkg.sv' } },
                            @{ Expression = { [bool](Select-String -LiteralPath $_.FullName -Pattern 'pragma protect' -Quiet) } },
                            FullName)
$con = Join-Path $fpga 'constraints'
$cst = @(Get-ChildItem -LiteralPath $con -File -Filter '*.cst' -ErrorAction SilentlyContinue)
$sdc = @(Get-ChildItem -LiteralPath $con -File -Filter '*.sdc' -ErrorAction SilentlyContinue)
if ($cst.Count -ne 1) { Die "в fpga\constraints нужен ровно один .cst (найдено $($cst.Count))" }
if ($hdl.Count -eq 0) { Die 'нет исходников в fpga\rtl и fpga\ip' }

$items = @()
foreach ($f in $hdl) {
    $type = if ($f.Extension -in @('.vh', '.svh')) { 'file.other' } else { 'file.verilog' }
    $items += ('        <File path="{0}" type="{1}" enable="1"/>' -f (Rel $f.FullName), $type)
}
foreach ($f in $cst) { $items += ('        <File path="{0}" type="file.cst" enable="1"/>' -f (Rel $f.FullName)) }
foreach ($f in $sdc) { $items += ('        <File path="{0}" type="file.sdc" enable="1"/>' -f (Rel $f.FullName)) }

$xml = @(
    '<?xml version="1" encoding="UTF-8"?>'
    '<!DOCTYPE gowin-fpga-project>'
    '<Project>'
    '    <Template>FPGA</Template>'
    '    <Version>5</Version>'
    ('    <Device name="{0}" pn="{1}">{2}</Device>' -f (Get-Cfg $cfg 'FPGA_DEVICE'), (Get-Cfg $cfg 'FPGA_PART'), (Get-Cfg $cfg 'FPGA_DEVICE_ID'))
    '    <FileList>'
) + $items + @('    </FileList>', '</Project>')
Write-IfChanged $gprj (($xml -join "`n") + "`n") -Quiet

# --- 3. Имя верхнего модуля и выходных файлов
$t = [IO.File]::ReadAllText($pcfg)
$inc  = @(Join-Path $fpga 'rtl')
$inc += @(Get-ChildItem -LiteralPath (Join-Path $fpga 'ip') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$incJson = '"IncludePath" : [' + "`n" + (($inc | ForEach-Object { '  "{0}"' -f ($_ -replace '\\', '/') }) -join ",`n") + "`n ]"
$t = [regex]::Replace($t, '"IncludePath"\s*:\s*\[[^\]]*\]', $incJson.Replace('$', '$$'))
$t = [regex]::Replace($t, '("TopModule"\s*:\s*)"[^"]*"',        ('${1}"' + (Get-Cfg $cfg 'FPGA_TOP') + '"'))
$t = [regex]::Replace($t, '("OUTPUT_BASE_NAME"\s*:\s*)"[^"]*"', ('${1}"' + $name + '"'))
Write-IfChanged $json $t -Quiet

# --- 4. gw_sh
if (Test-Path -LiteralPath $fs) { Remove-Item -LiteralPath $fs -Force }
$tcl = Join-Path $env:TEMP 'primer_kvm_run_all.tcl'
Set-Content -LiteralPath $tcl -Encoding ASCII -Value @(
    ('open_project "{0}"' -f ($gprj -replace '\\', '/'))
    'run all'
)
Say ('Синтез и размещение ({0} файлов)...' -f $items.Count)
$out = @(& $gwsh $tcl 2>&1 | ForEach-Object { "$_" })
$rc  = $LASTEXITCODE
$err = @($out | Where-Object { $_ -cmatch '^\s*ERROR\b' })   # Gowin: "ERROR  (код) : ..."

if ($rc -ne 0 -or $err.Count -gt 0 -or -not (Test-Path -LiteralPath $fs)) {
    if ($err.Count -gt 0) { $err | Select-Object -First 20 | ForEach-Object { Say "  $_" } }
    else                  { $out | Select-Object -Last 15  | ForEach-Object { Say "  $_" } }
    Die ("синтез не удался (код gw_sh {0})" -f $rc)
}
# --- 5. Тайминги и ресурсы (отчёты Gowin: impl\pnr\<имя>.tr и .rpt.txt)
$trFile  = Join-Path $fpga "impl\pnr\$name.tr"
$rptFile = Join-Path $fpga "impl\pnr\$name.rpt.txt"
if (-not (Test-Path -LiteralPath $trFile)) { Die "нет отчёта о таймингах: $trFile (Generate_Plain_Text_Timing_Report)" }
$tr = Get-Content -LiteralPath $trFile
$ci = [Globalization.CultureInfo]::InvariantCulture
$minK = [double]::MaxValue; $minClk = ''
foreach ($l in $tr) {
    if ($l -match '^\s*\d+\s+(\S+)\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)') {
        $k = [double]::Parse($Matches[3], $ci) / [double]::Parse($Matches[2], $ci)
        if ($k -lt $minK) { $minK = $k; $minClk = $Matches[1] }
        # запас сверх обязательного меньше 2% - следующее изменение может не уложиться
        if ($k -lt 1.02) { Warn ('такт {0}: Fmax {1} МГц при требуемых {2} МГц (худшие пути - fpga\impl\pnr\{3}.tr)' -f $Matches[1], $Matches[3], $Matches[2], $name) }
    }
}
# Каждый такт из .sdc должен попасть в отчёт: если get_pins/get_nets ничего не нашли, Gowin только
# предупреждает, а пути этого такта остаются без проверки.
$clkTable = @($tr | Where-Object { $_ -match '^\s*\d+\s+\S+\s+(Base|Generated)\s' } | ForEach-Object { ($_.Trim() -split '\s+')[1] })
foreach ($f in $sdc) {
    foreach ($m in (Select-String -LiteralPath $f.FullName -Pattern '^\s*create_(generated_)?clock\b.*?-name\s+(\S+)')) {
        $cn = $m.Matches[0].Groups[2].Value
        if ($clkTable -notcontains $cn) { Die ("такт {0} из {1} не создан (объект в get_pins/get_nets не найден) - см. предупреждения в fpga\impl\pnr\{2}.tr" -f $cn, $f.Name, $name) }
    }
}
$setup = 0; $hold = 0
foreach ($l in $tr) {
    if ($l -match '<Numbers of Setup Violated Endpoints>:(\d+)') { $setup = [int]$Matches[1] }
    if ($l -match '<Numbers of Hold Violated Endpoints>:(\d+)')  { $hold  = [int]$Matches[1] }
}
$resText = ''
if (Test-Path -LiteralPath $rptFile) {
    $res = @{}
    foreach ($l in (Get-Content -LiteralPath $rptFile)) {
        if ($l -match '^\s*(Logic|Register|BSRAM|DSP)\s*\|\s*(\d+/\d+)') { if (-not $res.ContainsKey($Matches[1])) { $res[$Matches[1]] = $Matches[2] } }
    }
    $resText = 'логика {0}, регистры {1}, BSRAM {2}' -f $res['Logic'], $res['Register'], $res['BSRAM']
}
if ($setup -gt 0 -or $hold -gt 0) {
    # худшие пути из таблиц setup/hold/recovery/removal: строки с отрицательным запасом
    $bad = @($tr | Where-Object { $_ -match '^\s+\d+\s+-\d' } | Select-Object -First 6)
    foreach ($l in $bad) {
        $c = $l.Trim() -split '\s+'
        if ($c.Count -ge 6) { Say ('  запас {0} нс: {1} -> {2} ({3} -> {4})' -f $c[1], $c[2], $c[3], $c[4], $c[5]) }
    }
    Die ("нарушены временные ограничения (с запасом TIMING_MARGIN_PCT): setup {0}, hold {1} (подробно: fpga\impl\pnr\{2}.tr)" -f $setup, $hold, $name)
}

Ok ('синтез: {0}; тайминги с запасом {1}% выполнены (меньше всего запаса у {2}: +{3:N1}%)' -f $resText, (Get-Cfg $cfg 'TIMING_MARGIN_PCT'), $minClk, (($minK - 1) * 100))
exit 0
