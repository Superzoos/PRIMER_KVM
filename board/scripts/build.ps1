# build.ps1 - полная сборка: прошивка ядра, IP, синтез и размещение, битстрим с прошивкой
# (fpga\impl\pnr\<FPGA_PROJECT>_fw.fs). -FirmwareOnly - только прошивка и битстрим (без синтеза).
param([switch]$FirmwareOnly)

. (Join-Path $PSScriptRoot 'common.ps1')
$t0 = Get-Date
$steps = if ($FirmwareOnly) { @('fw-build', 'merge') } else { @('fw-build', 'ip-gen', 'synth', 'merge') }
foreach ($s in $steps) {
    & (Join-Path $PSScriptRoot "$s.ps1")
    if ($LASTEXITCODE -ne 0) { exit 1 }
}
Ok ('сборка завершена за {0:mm\:ss}' -f ((Get-Date) - $t0))
exit 0
