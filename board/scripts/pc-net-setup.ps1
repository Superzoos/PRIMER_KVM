# pc-net-setup.ps1 - настройка сетевого адаптера ПК для прямого подключения к плате:
#   - постоянный статический IP NET_PC_IP_ADDR/24 на адаптере, найденном по описанию NET_PC_ADAPTER
#     (netsh: адрес сохраняется после перезапуска, DHCP на этом адаптере выключается);
#   - маршрут к плате NET_IP_ADDR/32 через этот адаптер (чтобы трафик не уходил в VPN-туннель).
# Сам запрашивает права администратора. Другие адаптеры не трогает.

. (Join-Path $PSScriptRoot 'common.ps1')

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Say 'Нужны права администратора - открываю отдельное окно...'
    Start-Process powershell -Verb RunAs -ArgumentList @(
        '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    exit 0
}

$cfg   = Read-ProjectConfig
$pat   = Get-Cfg $cfg 'NET_PC_ADAPTER'
$pcIp  = Get-Cfg $cfg 'NET_PC_IP_ADDR'
$board = Get-Cfg $cfg 'NET_IP_ADDR'

$ad = @(Get-NetAdapter | Where-Object { $_.InterfaceDescription -like $pat })
if ($ad.Count -ne 1) { Die ("адаптер с описанием '{0}' найден {1} раз(а); проверьте NET_PC_ADAPTER в project.cfg" -f $pat, $ad.Count) }
$a = $ad[0]

# Статический адрес (постоянный)
$o = @(& netsh interface ipv4 set address ('name={0}' -f $a.ifIndex) static $pcIp 255.255.255.0 2>&1)
if ($LASTEXITCODE -ne 0) { $o | ForEach-Object { Say "  $_" }; Die 'netsh не смог задать адрес' }

# Маршрут к плате через этот адаптер
Get-NetRoute -DestinationPrefix "$board/32" -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
New-NetRoute -DestinationPrefix "$board/32" -InterfaceIndex $a.ifIndex -NextHop 0.0.0.0 -RouteMetric 1 -ErrorAction Stop | Out-Null

# Ждём, пока адрес станет рабочим (до 10 с)
$state = ''
for ($i = 0; $i -lt 20; $i++) {
    $state = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $pcIp -ErrorAction SilentlyContinue).AddressState
    if ("$state" -eq 'Preferred') { break }
    Start-Sleep -Milliseconds 500
}
$route = (Find-NetRoute -RemoteIPAddress $board -ErrorAction SilentlyContinue | Select-Object -First 1).InterfaceAlias

Say ('  адаптер: {0} ({1}), связь {2} {3}' -f $a.Name, $a.InterfaceDescription, $a.Status, $a.LinkSpeed)
Say ('  адрес ПК: {0}/24, состояние {1}' -f $pcIp, $state)
Say ('  к плате {0} пакеты идут через: {1}' -f $board, $route)
if ("$state" -ne 'Preferred') { Die 'адрес ПК не стал рабочим (см. строки выше)' }
if ($route -ne $a.Name) {
    Warn ('Windows выбирает для платы интерфейс {0} (VPN перехватывает маршрут). Приложение и ping -S {1} {2} работают через адрес ПК {1}.' -f $route, $pcIp, $board)
}
Ok 'сеть ПК настроена'
