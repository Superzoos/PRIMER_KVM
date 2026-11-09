# flash.ps1 - запись битстрима во внешнюю SPI-flash платы (адрес 0x000000), сохраняется после выключения.
# programmer_cli, операция 37: exFlash Erase,Program,Verify thru GAO-Bridge
# (для Arora/GW2A по IPUG914 3.8 и IPUG913 4.4.1; номер - из programmer_cli --help V1.9.11.03).
# По умолчанию пишется fpga\impl\pnr\<FPGA_PROJECT>_fw.fs (битстрим с ПО, если он не старее
# обычного), иначе <FPGA_PROJECT>.fs; другой файл: -File <путь>.
param([string]$File = '')

. (Join-Path $PSScriptRoot 'common.ps1')
$cfg  = Read-ProjectConfig
$name = Get-Cfg $cfg 'FPGA_PROJECT'
$prog = Join-Path (Resolve-CfgPath (Get-Cfg $cfg 'GOWIN_PROGRAMMER_BIN')) 'programmer_cli.exe'
if (-not (Test-Path -LiteralPath $prog)) { Die "не найден programmer_cli.exe: $prog" }
if ($File -eq '') {
    $plain = Join-Path $script:Root "fpga\impl\pnr\$name.fs"
    $withFw = Join-Path $script:Root "fpga\impl\pnr\${name}_fw.fs"
    $File = $plain
    if ((Test-Path -LiteralPath $withFw) -and (Test-Path -LiteralPath $plain) -and
        (Get-Item -LiteralPath $withFw).LastWriteTime -ge (Get-Item -LiteralPath $plain).LastWriteTime) { $File = $withFw }
}
if (-not (Test-Path -LiteralPath $File)) { Die "нет битстрима: $File (сначала сборка)" }

$argv = @(
    '--device',          (Get-Cfg $cfg 'FPGA_DEVICE'),
    '--cable',           (Get-Cfg $cfg 'PROG_CABLE'),
    '--operation_index', '37',
    '--fsFile',          $File,
    '--spiaddr',         '0x000000'
)
Say ('Запись во flash: {0}...' -f (Split-Path -Leaf $File))
$t0  = Get-Date
$out = @(& $prog @argv 2>&1 | ForEach-Object { "$_" })
$rc  = $LASTEXITCODE
$bad = @($out | Where-Object { $_ -match '(?i)\b(error|fail(ed)?)\b' })

if ($rc -ne 0 -or $bad.Count -gt 0) {
    $out | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 15 | ForEach-Object { Say "  $_" }
    Die ("прошивка не удалась (код programmer_cli {0})" -f $rc)
}
Ok ('flash записана и проверена за {0:N0} с' -f ((Get-Date) - $t0).TotalSeconds)
exit 0
