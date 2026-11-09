# fw-build.ps1 - сборка прошивки ядра PicoRV32 (CMake + Ninja + xPack RISC-V GCC).
# Результат в firmware\build: <FW_NAME>.elf, <FW_NAME>.bin (для merge_bit),
# ram32.hex (начальное содержимое ITCM для генерации IP; make_hex из SDK).

. (Join-Path $PSScriptRoot 'common.ps1')
$cfg = Read-ProjectConfig

& (Join-Path $PSScriptRoot 'gen-config.ps1') 6>$null
if ($LASTEXITCODE -ne 0) { Die 'gen-config.ps1 завершился с ошибкой (запустите его отдельно)' }

$fw    = Join-Path $script:Root 'firmware'
$bld   = Join-Path $fw 'build'
$name  = Get-Cfg $cfg 'FW_NAME'
$itcm  = [int](Get-Cfg $cfg 'CPU_ITCM_KB')
$dtcm  = [int](Get-Cfg $cfg 'CPU_DTCM_KB')
$rvDir = Resolve-CfgPath (Get-Cfg $cfg 'RISCV_DIR')
$pre   = Get-Cfg $cfg 'RISCV_PREFIX'
$gcc   = Join-Path $rvDir "bin\${pre}gcc.exe"
$size  = Join-Path $rvDir "bin\${pre}size.exe"
$mkhex = Join-Path (Resolve-CfgPath (Get-Cfg $cfg 'PICORV32_SDK_DIR')) 'tool\make_hex\bin\make_hex.exe'
foreach ($p in @($gcc, $size, $mkhex)) {
    if (-not (Test-Path -LiteralPath $p)) { Die "не найден: $p (scripts\setup.ps1)" }
}
foreach ($t in @('cmake', 'ninja')) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Die "$t не найден в PATH" }
}

# libgcc должна быть собрана под rv32imc/ilp32 (иначе в прошивку попадут чужие инструкции)
$ml = "$(& $gcc -march=rv32imc_zicsr -mabi=ilp32 -print-multi-directory 2>&1 | Select-Object -First 1)".Trim()
if ($ml -ne 'rv32imc/ilp32') { Die "в тулчейне нет библиотек rv32imc/ilp32 (получено: $ml)" }

function Run-Step ([string]$what, [string]$exe, [string[]]$argv) {
    $out = @(& $exe @argv 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Say "  $_" }
        Die "${what}: ошибка"
    }
}

Run-Step 'CMake' 'cmake' @(
    '-S', $fw, '-B', $bld, '-G', 'Ninja',
    ('-DCMAKE_TOOLCHAIN_FILE=' + ($fw -replace '\\', '/') + '/cmake/riscv-none-elf.cmake'),
    ('-DRISCV_DIR=' + ($rvDir -replace '\\', '/')),
    "-DRISCV_PREFIX=$pre", "-DFW_NAME=$name", "-DCPU_ITCM_KB=$itcm", "-DCPU_DTCM_KB=$dtcm"
)
Run-Step 'Компиляция' 'cmake' @('--build', $bld)

$elf = Join-Path $bld "$name.elf"
$bin = Join-Path $bld "$name.bin"
if (-not (Test-Path -LiteralPath $bin)) { Die "не создан $bin" }

# make_hex пишет ram32.hex в текущую папку
$hex = Join-Path $bld 'ram32.hex'
if (Test-Path -LiteralPath $hex) { Remove-Item -LiteralPath $hex -Force }
Push-Location -LiteralPath $bld
try { $mo = @(& $mkhex "$name.bin" 2>&1 | ForEach-Object { "$_" }) } finally { Pop-Location }
if (-not (Test-Path -LiteralPath $hex)) { $mo | ForEach-Object { Say "  $_" }; Die 'make_hex не создал ram32.hex' }

# Занятость памяти
$sec = @{ text = 0; data = 0; bss = 0 }
foreach ($l in (& $size -A $elf)) {
    if ("$l" -match '^\.(text|data|bss)\s+(\d+)') { $sec[$Matches[1]] = [int]$Matches[2] }
}
$iu = $sec.text + $sec.data
$du = $sec.data + $sec.bss
Ok ('прошивка: ITCM {0} из {1} байт ({2:N0}%), DTCM {3} из {4} байт ({5:N0}%)' -f `
    $iu, ($itcm * 1024), (100.0 * $iu / ($itcm * 1024)), $du, ($dtcm * 1024), (100.0 * $du / ($dtcm * 1024)))
exit 0
