# setup.ps1 - установка и проверка инструментов сборки.
#   SDK Gowin_PicoRV32 (make_hex, merge_bit): из архива PICORV32_SDK_ZIP в PICORV32_SDK_DIR, если их нет.
#   xPack GNU RISC-V Embedded GCC версии RISCV_GCC_VERSION с GitHub в RISCV_DIR, если его нет.
#   Проверка: Gowin EDA (gw_sh, programmer_cli), CMake >= 3.21, Ninja, компилятор, make_hex, merge_bit.

. (Join-Path $PSScriptRoot 'common.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$cfg    = Read-ProjectConfig
$sdk    = Resolve-CfgPath (Get-Cfg $cfg 'PICORV32_SDK_DIR')
$mkhex  = Join-Path $sdk 'tool\make_hex\bin\make_hex.exe'
$merge  = Join-Path $sdk 'tool\merge_bit\bin\merge_bit.exe'
$rvDir  = Resolve-CfgPath (Get-Cfg $cfg 'RISCV_DIR')
$gccExe = '{0}gcc.exe' -f (Get-Cfg $cfg 'RISCV_PREFIX')
$gcc    = Join-Path $rvDir "bin\$gccExe"

# ---------- SDK Gowin_PicoRV32 ----------
if (-not ((Test-Path -LiteralPath $mkhex) -and (Test-Path -LiteralPath $merge))) {
    $src = Resolve-CfgPath (Get-Cfg $cfg 'PICORV32_SDK_ZIP')
    if (-not (Test-Path -LiteralPath $src)) { Die "нет архива SDK Gowin_PicoRV32: $src (PICORV32_SDK_ZIP)" }
    $want = @('tool/make_hex/bin/', 'tool/merge_bit/bin/')
    $n = 0
    $z = [IO.Compression.ZipFile]::OpenRead($src)
    try {
        foreach ($e in $z.Entries) {
            if ($e.Name -eq '') { continue }
            $parts = ($e.FullName -replace '\\', '/') -split '/', 2       # верхняя папка архива отбрасывается
            if ($parts.Count -lt 2 -or -not ($want | Where-Object { $parts[1].StartsWith($_) })) { continue }
            $out = Join-Path $sdk ($parts[1] -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $out) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
            $n++
        }
    } finally { $z.Dispose() }
    if ($n -eq 0) { Die "в архиве нет tool/make_hex и tool/merge_bit: $src" }
    Ok "SDK Gowin_PicoRV32 -> $sdk"
}

# ---------- xPack RISC-V GCC ----------
if (-not (Test-Path -LiteralPath $gcc)) {
    if ((Test-Path -LiteralPath $rvDir) -and (Get-ChildItem -LiteralPath $rvDir -Force | Select-Object -First 1)) {
        Die "папка $rvDir не пуста, но компилятора в ней нет"
    }
    $ver   = Get-Cfg $cfg 'RISCV_GCC_VERSION'
    $name  = "xpack-riscv-none-elf-gcc-$ver-win32-x64.zip"
    $url   = "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v$ver/$name"
    $asset = [pscustomobject]@{ name = $name; browser_download_url = $url }
    $sha   = [pscustomobject]@{ name = "$name.sha"; browser_download_url = "$url.sha" }
    $rel   = [pscustomobject]@{ tag_name = "v$ver" }
    Say "RISC-V GCC ${ver}: скачивание с GitHub..."
    # Архив распаковывается сразу на место (без переноса папки: только что распакованные файлы может держать
    # антивирус или наблюдатель файлов VS Code). Верхняя папка архива отбрасывается.
    $zip = Join-Path $env:TEMP $asset.name
    try { Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing }
    catch { Die "ошибка скачивания: $($_.Exception.Message)" }
    try {
        $shaFile = "$zip.sha"
        $haveSha = $true
        try { Invoke-WebRequest -Uri $sha.browser_download_url -OutFile $shaFile -UseBasicParsing } catch { $haveSha = $false }
        if ($haveSha) {
            $expected = ([regex]::Match((Get-Content -LiteralPath $shaFile -Raw), '[0-9a-fA-F]{64}')).Value
            Remove-Item -LiteralPath $shaFile -Force
            if (-not $expected -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected.ToUpper()) {
                Die 'контрольная сумма архива не совпала'
            }
        } else { Warn 'файл .sha не найден - контрольная сумма не проверена' }
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            foreach ($e in $z.Entries) {
                if ($e.Name -eq '') { continue }
                $parts = ($e.FullName -replace '\\', '/') -split '/', 2
                if ($parts.Count -lt 2) { continue }
                $out = Join-Path $rvDir ($parts[1] -replace '/', '\')
                New-Item -ItemType Directory -Path (Split-Path -Parent $out) -Force | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
            }
        } finally { $z.Dispose() }
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $gcc)) { Die "в архиве нет bin\$gccExe" }
    Ok "RISC-V GCC $($rel.tag_name) -> $rvDir"
}

# ---------- Проверка ----------
$bad = 0
function Need ([bool]$ok, [string]$what) { if (-not $ok) { Fail $what; $script:bad++ } }
Need (Test-Path -LiteralPath (Join-Path (Resolve-CfgPath (Get-Cfg $cfg 'GOWIN_BIN')) 'gw_sh.exe')) 'нет gw_sh.exe (GOWIN_BIN)'
Need (Test-Path -LiteralPath (Join-Path (Resolve-CfgPath (Get-Cfg $cfg 'GOWIN_PROGRAMMER_BIN')) 'programmer_cli.exe')) 'нет programmer_cli.exe (GOWIN_PROGRAMMER_BIN)'
Need (Test-Path -LiteralPath $gcc) "нет $gcc"
Need (Test-Path -LiteralPath $mkhex) "нет $mkhex"
Need (Test-Path -LiteralPath $merge) "нет $merge"
$cm = Get-Command cmake -ErrorAction SilentlyContinue
$cv = if ($cm) { "$(& cmake --version 2>&1 | Select-Object -First 1)" } else { '' }
Need ($cv -match '(\d+)\.(\d+)' -and ([int]$Matches[1] -gt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 21))) 'нужен CMake >= 3.21 в PATH'
Need ([bool](Get-Command ninja -ErrorAction SilentlyContinue)) 'нет ninja в PATH'
if ($bad -gt 0) { exit 1 }
Ok 'инструменты на месте'
exit 0
