# common.ps1 - общие функции скриптов PRIMER_KVM. Подключается через dot-source:
#   . (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$script:Root = Split-Path -Parent $PSScriptRoot

function Say  ([string]$m) { Write-Host $m }
function Ok   ([string]$m) { Write-Host "[OK]    $m" -ForegroundColor Green }
function Warn ([string]$m) { Write-Host "[ВНИМ]  $m" -ForegroundColor Yellow }
function Fail ([string]$m) { Write-Host "[ОШИБКА] $m" -ForegroundColor Red }
function Die  ([string]$m) { Fail $m; exit 1 }

# Чтение config\project.cfg в хэш-таблицу.
function Read-ProjectConfig {
    $path = Join-Path $script:Root 'config\project.cfg'
    if (-not (Test-Path -LiteralPath $path)) { Die "нет файла конфигурации: $path" }
    $cfg = @{}
    $n = 0
    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
        $n++
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { Die "project.cfg, строка ${n}: ожидается КЛЮЧ=значение" }
        $k = $t.Substring(0, $i).Trim()
        if ($cfg.ContainsKey($k)) { Die "project.cfg, строка ${n}: ключ $k задан повторно" }
        $cfg[$k] = $t.Substring($i + 1).Trim()
    }
    return $cfg
}

# Значение обязательного ключа.
function Get-Cfg ([hashtable]$cfg, [string]$key) {
    if (-not $cfg.ContainsKey($key) -or $cfg[$key] -eq '') { Die "в project.cfg нет ключа $key" }
    return $cfg[$key]
}

# Путь из конфига: абсолютный - как есть, относительный - от корня проекта.
function Resolve-CfgPath ([string]$p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path $script:Root $p)
}

# Записать текст (UTF-8 без BOM, CRLF), только если содержимое изменилось.
function Write-IfChanged ([string]$path, [string]$text, [switch]$Quiet) {
    $text = $text -replace "`r?`n", "`r`n"
    if ((Test-Path -LiteralPath $path) -and ([IO.File]::ReadAllText($path) -ceq $text)) {
        if (-not $Quiet) { Ok "без изменений: $path" }
        return
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
    if (-not $Quiet) { Ok "записан: $path" }
}

# Запуск gw_sh со списком Tcl-команд. Каждая команда выполняется в catch:
# при ошибке печатается "TCLERR: <команда> -> <сообщение>" и gw_sh завершается с кодом 1.
# Вывод и поток ошибок пишутся в файлы (без искажений PowerShell) и возвращаются строками.
function Invoke-GwSh ([string]$gwsh, [string[]]$commands, [string]$tag) {
    $tcl = Join-Path $env:TEMP "primer_kvm_$tag.tcl"
    $so  = Join-Path $env:TEMP "primer_kvm_${tag}_out.txt"
    $se  = Join-Path $env:TEMP "primer_kvm_${tag}_err.txt"
    $lines = @(
        'proc kvm_do {c} {'
        '    if {[catch {uplevel #0 $c} msg]} {'
        '        puts "TCLERR: $c -> $msg"'
        '        exit 1'
        '    }'
        '}'
    )
    foreach ($cmd in $commands) { $lines += "kvm_do {$cmd}" }
    Set-Content -LiteralPath $tcl -Encoding ASCII -Value $lines
    $p = Start-Process -FilePath $gwsh -ArgumentList ('"{0}"' -f $tcl) -NoNewWindow -Wait -PassThru `
                       -RedirectStandardOutput $so -RedirectStandardError $se
    $out = @(Get-Content -LiteralPath $so -ErrorAction SilentlyContinue) +
           @(Get-Content -LiteralPath $se -ErrorAction SilentlyContinue)
    return @{ Code = $p.ExitCode; Lines = @($out | Where-Object { "$_".Trim() -ne '' }) }
}
