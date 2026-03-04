<#
.SYNOPSIS
    Оркестратор VPN-инфраструктуры — управление жизненным циклом узлов.

.DESCRIPTION
    Центральный инструмент управления VPN-инфраструктурой на базе AmneziaWG.
    Реализует полный цикл: генерация ключей → планирование → рендеринг
    конфигураций → деплой на серверы → проверка здоровья.

    Топология:
        [Клиенты] → [MikroTik/RouterOS] ──wg-core──► [Gateway]
                                                          │
                                                          ┌───awg0───► [Exit-1]
                                                          └───awg1───► [Exit-2]
                                                          └───awgN───► [Exit-N]

    Gateway — единственная точка входа клиентского трафика.
    Exits — точки выхода в интернет с маскировкой через NAT.
    gw-failover демон на Gateway автоматически переключает активный Exit
    при деградации туннеля.

.PARAMETER InfraPath
    Путь к infra.json — описание инфраструктуры (хосты, порты, профиль AWG).
    По умолчанию: .\infra.json

.PARAMETER Mode
    plan    — показать план изменений, сохранить state.json (без деплоя)
    render  — сгенерировать все конфигурации в out\<RunId>\ (без деплоя)
    apply   — render + загрузить на серверы + выполнить деплой
    health  — проверить состояние всех узлов (Gateway + все Exits)

.PARAMETER StatePath
    Путь к state.json — хранилище ключей и распределения awgX по exits.
    По умолчанию: .\out\state.json
    ВАЖНО: содержит приватные ключи. Добавить out\ в .gitignore.

.EXAMPLE
    # Первый деплой
    .\orchestrator.ps1 .\infra.json -Mode plan
    .\orchestrator.ps1 .\infra.json -Mode apply

    # Добавление нового exit-сервера (добавить в infra.json, затем)
    .\orchestrator.ps1 .\infra.json -Mode apply

    # Проверка здоровья инфраструктуры
    .\orchestrator.ps1 .\infra.json -Mode health

    # Только рендеринг без деплоя (для проверки конфигов)
    .\orchestrator.ps1 .\infra.json -Mode render

.NOTES
    Версия:     v1.0
    Проект:     AWG VPN Infrastructure
    Требования: PowerShell 5.1+, OpenSSH (ssh.exe, scp.exe в PATH)

    СТРУКТУРА ФАЙЛОВ:
    ├── orchestrator.ps1        этот файл
    ├── infra.json              описание инфраструктуры (редактировать)
    ├── deploy-gateway.sh       деплой-скрипт Gateway (не редактировать)
    ├── deploy-exit.sh          деплой-скрипт Exit (не редактировать)
    ├── gw-failover.sh          демон failover (не редактировать)
    ├── ssh
	│   └── orchestrator_ed25519  SSH-ключ для подключения к серверам
    └── out
    	├── state.json          ключи + распределение awgX (СЕКРЕТ)
        └── <RunId>\            артефакты конкретного apply
            ├── plan.json
            ├── state.before.json
            ├── state.after.json
            ├── rendered
            │   └── exits
			│       ├── exit-1\ конфиги для exit-1
            │       └── exit-N
            │   ├── gateway\    конфиги для Gateway
			└── ssh_*.log       логи SSH/SCP операций    

	ГЕНЕРАЦИЯ КЛЮЧЕЙ:
    Реализована на чистом PowerShell через System.Numerics.BigInteger
    (Montgomery ladder, RFC 7748). Не требует wg.exe или awg.exe.
    Ключи совместимы с WireGuard и AmneziaWG.

    УПРАВЛЕНИЕ STATE:
    state.json создаётся автоматически при первом запуске.
    При добавлении exit: новый awgX-индекс и порт выбираются автоматически.
    При удалении exit: запись удаляется из state, старый awgX убирается с
    Gateway при следующем apply (cleanup_stale_awg в deploy-gateway.sh).
    Индексы awgX переиспользуются (заполняются дыры).

    БЕЗОПАСНОСТЬ:
    - SSH строго по ключу (StrictHostKeyChecking=accept-new)
    - Приватные ключи AWG передаются через env, не хранятся в rendered/*
      в открытом виде на диске сервера дольше деплоя
    - Приватный ключ wg-core передаётся через файл, не через env
    - Рекомендуется: icacls ".\out" /inheritance:r /grant:r "%USERNAME%:(OI)(CI)F"
#>

param(
    [Parameter(Position = 0)]
    [string]$InfraPath = ".\infra.json",

    [Parameter(Mandatory = $true)]
    [ValidateSet("plan", "render", "apply", "health")]
    [string]$Mode,

    [string]$StatePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ==========================================================
# ПУТИ
# ==========================================================

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $ScriptRoot "out\state.json"
}

# ==========================================================
# УТИЛИТЫ
# ==========================================================

function Ensure-Directory {
    param([string]$Path)
    if (!(Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (!(Test-Path $Path)) { throw "Файл не найден: $Path" }
    (Get-Content -Raw -Path $Path) | ConvertFrom-Json -Depth 64
}

function Write-JsonFile {
    param([string]$Path,[object]$Obj)
    $dir = Split-Path -Parent $Path
    if ($dir) { Ensure-Directory $dir }
    $json = $Obj | ConvertTo-Json -Depth 64
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-TextFile {
    param([string]$Path,[string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir) { Ensure-Directory $dir }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-TextFileLF {
    param([string]$Path,[string]$Text)
    # Строго LF для bash-скриптов (генерируются на Windows)
    $dir = Split-Path -Parent $Path
    if ($dir) { Ensure-Directory $dir }
    $lf = $Text -replace "`r`n","`n" -replace "`r","`n"
    [System.IO.File]::WriteAllText($Path, $lf, (New-Object System.Text.UTF8Encoding($false)))
}

function Append-TextFile {
    param([string]$Path,[string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir) { Ensure-Directory $dir }
    [System.IO.File]::AppendAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-NowIso { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
function Get-RunId  { (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmssZ") }

function Convert-ToHashtable {
    param([object]$Obj)
    if ($null -eq $Obj) { return $null }

    if ($Obj -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $Obj.Keys) { $h[$k] = Convert-ToHashtable $Obj[$k] }
        return $h
    }

    if ($Obj -is [PSCustomObject]) {
        $h = @{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = Convert-ToHashtable $p.Value }
        return $h
    }

    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
        $arr = @()
        foreach ($x in $Obj) { $arr += (Convert-ToHashtable $x) }
        return $arr
    }

    return $Obj
}

# ==========================================================
# CURVE25519 KEYGEN
# Генерация пары ключей WireGuard/AmneziaWG без зависимости от wg.exe.
# Алгоритм строго по RFC 7748. Совместим с wg genkey / awg genkey.
# ==========================================================

function New-Curve25519KeyPair {
    <#
    .SYNOPSIS
        Генерирует пару ключей Curve25519, совместимых с WireGuard/AmneziaWG.
    .OUTPUTS
        Hashtable: @{ private_key = "base64..."; public_key = "base64..." }
    #>

    Add-Type -AssemblyName System.Numerics

    $P   = [System.Numerics.BigInteger]::Pow(2, 255) - 19
    $A24 = [System.Numerics.BigInteger]121665

    # Basepoint Curve25519: u=9, little-endian 32 байта
    $baseBytes    = [byte[]]::new(32)
    $baseBytes[0] = 9

    # Генерация случайных байт через криптографически стойкий RNG
    $privBytes = [byte[]]::new(32)
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $rng.GetBytes($privBytes)
    $rng.Dispose()

    # Clamp по RFC 7748 §5
    $privBytes[0]  = $privBytes[0]  -band 0xF8   # очищаем 3 младших бита
    $privBytes[31] = $privBytes[31] -band 0x7F   # очищаем старший бит
    $privBytes[31] = $privBytes[31] -bor  0x40   # устанавливаем бит 254

    # BigInteger из little-endian байт
    # Добавляем 0x00 в конец чтобы BigInteger трактовал как беззнаковое
    $privBytesUnsigned = [byte[]]($privBytes + [byte]0)
    $baseBytesUnsigned = [byte[]]($baseBytes + [byte]0)

    $k = [System.Numerics.BigInteger]::new($privBytesUnsigned)
    $u = [System.Numerics.BigInteger]::new($baseBytesUnsigned)

    # Montgomery ladder (RFC 7748)
    $x1 = $u
    $x2 = [System.Numerics.BigInteger]::One
    $z2 = [System.Numerics.BigInteger]::Zero
    $x3 = $u
    $z3 = [System.Numerics.BigInteger]::One
    $swap = [System.Numerics.BigInteger]::Zero

    for ($t = 254; $t -ge 0; $t--) {
        $kt = ($k -shr $t) -band [System.Numerics.BigInteger]::One

        $doSwap = $swap -bxor $kt
        if ($doSwap -ne [System.Numerics.BigInteger]::Zero) {
            $tmp = $x2; $x2 = $x3; $x3 = $tmp
            $tmp = $z2; $z2 = $z3; $z3 = $tmp
        }
        $swap = $kt

        $A  = ($x2 + $z2) % $P
        $AA = ($A * $A)    % $P
        $B  = ($x2 - $z2 + $P) % $P
        $BB = ($B * $B)    % $P
        $E  = ($AA - $BB + $P) % $P
        $C  = ($x3 + $z3) % $P
        $D  = ($x3 - $z3 + $P) % $P
        $DA = ($D * $A)    % $P
        $CB = ($C * $B)    % $P

        $x3 = [System.Numerics.BigInteger]::ModPow(($DA + $CB),       2, $P)
        $z3 = ($x1 * [System.Numerics.BigInteger]::ModPow(($DA - $CB + $P), 2, $P)) % $P
        $x2 = ($AA * $BB) % $P
        $z2 = ($E * ($AA + $A24 * $E)) % $P
    }

    if ($swap -ne [System.Numerics.BigInteger]::Zero) {
        $tmp = $x2; $x2 = $x3; $x3 = $tmp
        $tmp = $z2; $z2 = $z3; $z3 = $tmp
    }

    # Финальное деление через теорему Ферма: x2 * z2^(P-2) mod P
    $pubInt = ($x2 * [System.Numerics.BigInteger]::ModPow($z2, $P - 2, $P)) % $P

    # Публичный ключ: little-endian, строго 32 байта
    $pubBytesRaw = $pubInt.ToByteArray()  # little-endian, может быть 31 или 33 байт
    $pubFixed    = [byte[]]::new(32)
    $copyLen     = [Math]::Min($pubBytesRaw.Length, 32)
    [Array]::Copy($pubBytesRaw, $pubFixed, $copyLen)

    $privB64 = [Convert]::ToBase64String($privBytes)
    $pubB64  = [Convert]::ToBase64String($pubFixed)

    return @{
        private_key = $privB64
        public_key  = $pubB64
    }
}

# ==========================================================
# VALIDATE INFRA
# ==========================================================

function Validate-Infra {
    param([object]$Infra)

    if ($null -eq $Infra.ssh)                                      { throw "infra.ssh отсутствует" }
    if ([string]::IsNullOrWhiteSpace($Infra.ssh.user))             { throw "infra.ssh.user пустой" }
    if (-not $Infra.ssh.port)                                      { throw "infra.ssh.port отсутствует" }
    if ([string]::IsNullOrWhiteSpace($Infra.ssh.key_path))         { throw "infra.ssh.key_path пустой" }

    if ($null -eq $Infra.ports)      { throw "infra.ports отсутствует" }
    if (-not $Infra.ports.min)       { throw "infra.ports.min отсутствует" }
    if (-not $Infra.ports.max)       { throw "infra.ports.max отсутствует" }

    if ($null -eq $Infra.ip_plan)                                          { throw "infra.ip_plan отсутствует" }
    if ([string]::IsNullOrWhiteSpace($Infra.ip_plan.base_cidr))            { throw "infra.ip_plan.base_cidr пустой" }
    if ([int]$Infra.ip_plan.link_prefix -ne 30)                            { throw "Фиксируем link_prefix=30" }
    if (-not $Infra.ip_plan.max_exits)                                     { throw "infra.ip_plan.max_exits отсутствует" }

    if ($null -eq $Infra.awg_profile)                                      { throw "infra.awg_profile отсутствует" }
    if (-not $Infra.awg_profile.mtu)                                       { throw "infra.awg_profile.mtu отсутствует" }
    if (-not $Infra.awg_profile.persistent_keepalive)                      { throw "infra.awg_profile.persistent_keepalive отсутствует" }

    if ($null -eq $Infra.routing)                                          { throw "infra.routing отсутствует" }
    if ([string]::IsNullOrWhiteSpace($Infra.routing.awg_table_name))       { throw "infra.routing.awg_table_name пустой" }
    if ([int]$Infra.routing.awg_table_id -ne 200)                          { throw "Фиксируем awg_table_id=200" }
    if (-not $Infra.routing.ip_rule_priority)                              { throw "infra.routing.ip_rule_priority отсутствует" }
    if ($null -eq $Infra.routing.monitor)                                  { throw "infra.routing.monitor отсутствует" }

    if ($null -eq $Infra.gateway)                                          { throw "infra.gateway отсутствует" }
    if ([string]::IsNullOrWhiteSpace($Infra.gateway.host))                 { throw "infra.gateway.host пустой" }

    if ($null -eq $Infra.gateway.wg_core)                                  { throw "infra.gateway.wg_core отсутствует" }
    if ([string]::IsNullOrWhiteSpace($Infra.gateway.wg_core.ifname))       { throw "infra.gateway.wg_core.ifname пустой" }
    if ([string]::IsNullOrWhiteSpace($Infra.gateway.wg_core.address_cidr)) { throw "infra.gateway.wg_core.address_cidr пустой" }
    if (-not $Infra.gateway.wg_core.listen_port)                           { throw "infra.gateway.wg_core.listen_port отсутствует" }
    if (-not $Infra.gateway.wg_core.mtu)                                   { throw "infra.gateway.wg_core.mtu отсутствует" }

    if ($null -eq $Infra.gateway.wg_core.peer)                             { throw "infra.gateway.wg_core.peer отсутствует" }
    if ([string]::IsNullOrWhiteSpace($Infra.gateway.wg_core.peer.public_key))  { throw "infra.gateway.wg_core.peer.public_key пустой" }
    if ([string]::IsNullOrWhiteSpace($Infra.gateway.wg_core.peer.endpoint))    { throw "infra.gateway.wg_core.peer.endpoint пустой" }
    if ($null -eq $Infra.gateway.wg_core.peer.allowed_ips)                { throw "infra.gateway.wg_core.peer.allowed_ips отсутствует" }

    if ($null -eq $Infra.exits)                                            { throw "infra.exits отсутствует" }
    if ($Infra.exits.Count -gt [int]$Infra.ip_plan.max_exits)             { throw "exits.Count > ip_plan.max_exits" }

    foreach ($e in $Infra.exits) {
        if ([string]::IsNullOrWhiteSpace($e.name)) { throw "exits[].name пустой" }
        if ([string]::IsNullOrWhiteSpace($e.host)) { throw "exits[].host пустой" }
    }
}

# ==========================================================
# STATE
# ==========================================================

function Initialize-State {
    param([object]$Infra)

    Write-Host "[keygen] Генерирую ключи wg-core..."
    $wgCoreKeys = New-Curve25519KeyPair

    @{
        meta = @{
            version    = "v6"
            created_at = (Get-NowIso)
        }
        wg_core = @{
            listen_port = [int]$Infra.gateway.wg_core.listen_port
            public_key  = $wgCoreKeys.public_key
            private_key = $wgCoreKeys.private_key
        }
        exits = @{}
    }
}

function Normalize-State {
    param([hashtable]$State)

    if ($null -eq $State.meta)                { $State.meta = @{} }
    if ($null -eq $State.exits)               { $State.exits = @{} }
    if ($null -eq $State.wg_core)             { $State.wg_core = @{} }
    if ($null -eq $State.wg_core.listen_port) { $State.wg_core.listen_port = 0 }

    # Миграция: старый state без ключей wg_core
    if ([string]::IsNullOrWhiteSpace([string]$State.wg_core.public_key)) {
        Write-Host "[keygen] Генерирую ключи wg-core (миграция state v5→v6)..."
        $keys = New-Curve25519KeyPair
        $State.wg_core.public_key  = $keys.public_key
        $State.wg_core.private_key = $keys.private_key
    }

    $State
}

function Load-OrCreate-State {
    param([object]$Infra,[string]$Path)

    if (Test-Path $Path) {
        $obj = Read-JsonFile $Path
        $h   = Convert-ToHashtable $obj
        return (Normalize-State $h)
    }

    $state = Initialize-State $Infra
    $dir   = Split-Path -Parent $Path
    if ($dir) { Ensure-Directory $dir }
    return (Normalize-State $state)
}

function Get-UsedAwgIndexes {
    param([hashtable]$State)
    $used = @()
    foreach ($k in $State.exits.Keys) {
        $awgIf = [string]$State.exits[$k].awg_if
        if ($awgIf -match "^awg(\d+)$") { $used += [int]$Matches[1] }
    }
    $used
}

function Get-FreeAwgIndex {
    param([int[]]$Used,[int]$Max)
    for ($i = 0; $i -lt $Max; $i++) {
        if ($Used -notcontains $i) { return $i }
    }
    throw "Нет свободного awgX (max_exits=$Max)"
}

function Get-UsedPorts {
    param([hashtable]$State)
    $used = @()
    foreach ($k in $State.exits.Keys) {
        $p = $State.exits[$k].listen_port
        if ($p) { $used += [int]$p }
    }
    $used
}

function Generate-FreePort {
    param([int]$Min,[int]$Max,[int[]]$Used)

    $rnd = New-Object System.Random
    for ($i = 0; $i -lt 200; $i++) {
        $p = $rnd.Next($Min, $Max + 1)
        if ($Used -notcontains $p) { return $p }
    }
    for ($p = $Min; $p -le $Max; $p++) {
        if ($Used -notcontains $p) { return $p }
    }
    throw "Нет свободных портов в диапазоне $Min..$Max"
}

# ==========================================================
# IPv4 (вычисление /30 по awgX)
# ==========================================================

function IpToUInt32 {
    param([string]$Ip)
    $addr  = [System.Net.IPAddress]::Parse($Ip)
    $bytes = $addr.GetAddressBytes()
    ([uint32]$bytes[0] -shl 24) -bor
    ([uint32]$bytes[1] -shl 16) -bor
    ([uint32]$bytes[2] -shl 8)  -bor
    ([uint32]$bytes[3])
}

function UInt32ToIp {
    param([uint32]$Int)
    $o1 = ($Int -shr 24) -band 0xFF
    $o2 = ($Int -shr 16) -band 0xFF
    $o3 = ($Int -shr 8)  -band 0xFF
    $o4 = ($Int)         -band 0xFF
    "{0}.{1}.{2}.{3}" -f $o1, $o2, $o3, $o4
}

function Compute-LinkFromAwg {
    param([string]$BaseCidr,[int]$AwgIndex)

    $baseIp  = $BaseCidr.Split("/")[0]
    $baseInt = IpToUInt32 $baseIp

    $networkInt = [uint32]($baseInt + ([uint32]($AwgIndex * 4)))
    $gatewayInt = [uint32]($networkInt + 1)
    $exitInt    = [uint32]($networkInt + 2)

    @{
        subnet_cidr = "$(UInt32ToIp $networkInt)/30"
        gw_tun_ip   = UInt32ToIp $gatewayInt
        exit_tun_ip = UInt32ToIp $exitInt
    }
}

# ==========================================================
# SYNC STATE
# ==========================================================

function Sync-State {
    param([object]$Infra,[hashtable]$State)

    $actions    = New-Object System.Collections.Generic.List[string]
    $infraNames = @($Infra.exits | ForEach-Object { [string]$_.name })

    # Удаляем exits которых больше нет в infra.json
    foreach ($k in @($State.exits.Keys)) {
        if ($infraNames -notcontains $k) {
            $State.exits.Remove($k)
            $actions.Add("delete:$k") | Out-Null
        }
    }

    foreach ($exit in $Infra.exits) {
        $name = [string]$exit.name

        if ($State.exits.ContainsKey($name)) {
            # Миграция: state v5 без ключей — добавляем ключи
            $entry = $State.exits[$name]
            if ([string]::IsNullOrWhiteSpace([string]$entry.gw_public_key)) {
                Write-Host "[keygen] Генерирую ключи AWG Gateway для '$name' (миграция)..."
                $gwKeys = New-Curve25519KeyPair
                $entry.gw_public_key  = $gwKeys.public_key
                $entry.gw_private_key = $gwKeys.private_key
            }
            if ([string]::IsNullOrWhiteSpace([string]$entry.exit_public_key)) {
                Write-Host "[keygen] Генерирую ключи AWG Exit для '$name' (миграция)..."
                $exitKeys = New-Curve25519KeyPair
                $entry.exit_public_key  = $exitKeys.public_key
                $entry.exit_private_key = $exitKeys.private_key
            }
            $actions.Add("keep:$name") | Out-Null
            continue
        }

        # Новый exit
        $usedAwg  = Get-UsedAwgIndexes $State
        $newIndex = Get-FreeAwgIndex $usedAwg ([int]$Infra.ip_plan.max_exits)

        $usedPorts = Get-UsedPorts $State
        $newPort   = Generate-FreePort ([int]$Infra.ports.min) ([int]$Infra.ports.max) $usedPorts

        Write-Host "[keygen] Генерирую ключи AWG Gateway для '$name'..."
        $gwKeys = New-Curve25519KeyPair

        Write-Host "[keygen] Генерирую ключи AWG Exit для '$name'..."
        $exitKeys = New-Curve25519KeyPair

        $State.exits[$name] = @{
            awg_if           = "awg$newIndex"
            listen_port      = [int]$newPort
            gw_public_key    = $gwKeys.public_key
            gw_private_key   = $gwKeys.private_key
            exit_public_key  = $exitKeys.public_key
            exit_private_key = $exitKeys.private_key
        }

        $actions.Add("create:${name}:awg$newIndex") | Out-Null
    }

    @{
        state   = $State
        actions = $actions.ToArray()
    }
}

# ==========================================================
# PLAN MODEL
# ==========================================================

function Build-PlanModel {
    param([object]$Infra,[hashtable]$State,[string[]]$Actions,[string]$RunId)

    $exitPlans = @()
    foreach ($exit in $Infra.exits) {
        $name  = [string]$exit.name
        $entry = $State.exits[$name]
        $awgIf = [string]$entry.awg_if

        if ($awgIf -notmatch "^awg(\d+)$") { throw "В state для exit '$name' некорректный awg_if: $awgIf" }
        $awgIndex = [int]$Matches[1]
        $link     = Compute-LinkFromAwg $Infra.ip_plan.base_cidr $awgIndex

        $exitPlans += @{
            name            = $name
            host            = [string]$exit.host
            awg_if          = $awgIf
            listen_port     = [int]$entry.listen_port
            subnet_cidr     = [string]$link.subnet_cidr
            gw_tun_ip       = [string]$link.gw_tun_ip
            exit_tun_ip     = [string]$link.exit_tun_ip
            gw_public_key   = [string]$entry.gw_public_key
            exit_public_key = [string]$entry.exit_public_key
        }
    }

    @{
        meta = @{
            run_id       = $RunId
            generated_at = (Get-NowIso)
            mode         = $Mode
        }
        gateway = @{
            host    = [string]$Infra.gateway.host
            wg_core = @{
                ifname       = [string]$Infra.gateway.wg_core.ifname
                listen_port  = [int]$State.wg_core.listen_port
                address_cidr = [string]$Infra.gateway.wg_core.address_cidr
                mtu          = [int]$Infra.gateway.wg_core.mtu
                public_key   = [string]$State.wg_core.public_key
                peer         = @{
                    public_key           = [string]$Infra.gateway.wg_core.peer.public_key
                    endpoint             = [string]$Infra.gateway.wg_core.peer.endpoint
                    allowed_ips          = $Infra.gateway.wg_core.peer.allowed_ips
                    persistent_keepalive = [int]$Infra.gateway.wg_core.peer.persistent_keepalive
                }
            }
        }
        exits   = $exitPlans
        actions = $Actions
    }
}

# ==========================================================
# RENDER
# ==========================================================

function Get-InitialActiveAwg {
    param([object]$Infra,[hashtable]$State)

    $min   = $null
    $minIf = $null

    foreach ($exit in $Infra.exits) {
        $name  = [string]$exit.name
        $awgIf = [string]$State.exits[$name].awg_if
        if ($awgIf -match "^awg(\d+)$") {
            $idx = [int]$Matches[1]
            if ($null -eq $min -or $idx -lt $min) {
                $min   = $idx
                $minIf = $awgIf
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($minIf)) { throw "Невозможно определить активный awg (нет exits)." }
    $minIf
}

function Render-Gateway-WgCoreParamsEnv {
    param([object]$Infra,[hashtable]$State,[string]$GwDir)

    $allowed = ($Infra.gateway.wg_core.peer.allowed_ips -join ",")

    # Публичные параметры — в .env (читается через source в deploy)
    $envTxt = @"
# Параметры wg-core (без приватного ключа)
WG_CORE_IFNAME=$($Infra.gateway.wg_core.ifname)
WG_CORE_LISTEN_PORT=$([int]$State.wg_core.listen_port)
WG_CORE_ADDRESS_CIDR=$($Infra.gateway.wg_core.address_cidr)
WG_CORE_MTU=$([int]$Infra.gateway.wg_core.mtu)

WG_CORE_PEER_PUBLIC_KEY=$($Infra.gateway.wg_core.peer.public_key)
WG_CORE_PEER_ENDPOINT=$($Infra.gateway.wg_core.peer.endpoint)
WG_CORE_PEER_ALLOWED_IPS=$allowed
WG_CORE_PEER_PERSISTENT_KEEPALIVE=$([int]$Infra.gateway.wg_core.peer.persistent_keepalive)
"@
    Write-TextFileLF (Join-Path $GwDir "wg-core.params.env") ($envTxt.TrimEnd() + "`n")

    # Приватный ключ — отдельный файл, права 600 выставит deploy-gateway.sh
    Write-TextFileLF (Join-Path $GwDir "wg-core.privkey") ($State.wg_core.private_key + "`n")

    # Публичный ключ для справки (вставить в MikroTik)
    Write-TextFileLF (Join-Path $GwDir "wg-core.pubkey") ($State.wg_core.public_key + "`n")
}

function Render-Gateway-AwgParamsEnv {
    param(
        [object]$Infra,
        [hashtable]$State,
        [string]$ExitName,
        [string]$ExitHost,
        [string]$AwgIf,
        [int]$ListenPort,
        [string]$GwTunIp,
        [string]$ExitTunIp,
        [string]$Path
    )

    $p     = $Infra.awg_profile
    $entry = $State.exits[$ExitName]

    $txt = @"
# Параметры $AwgIf на Gateway
AWG_IFNAME=$AwgIf
AWG_LISTEN_PORT=$ListenPort
AWG_MTU=$([int]$p.mtu)
AWG_LOCAL_TUN_IP=$GwTunIp
AWG_PEER_TUN_IP=$ExitTunIp

# Ключи
AWG_PRIVATE_KEY=$([string]$entry.gw_private_key)
AWG_PEER_PUBLIC_KEY=$([string]$entry.exit_public_key)

# Peer (Exit)
AWG_PEER_ENDPOINT=${ExitHost}:${ListenPort}

# Профиль AmneziaWG
AWG_JC=$([int]$p.jc)
AWG_JMIN=$([int]$p.jmin)
AWG_JMAX=$([int]$p.jmax)
AWG_S1=$([int]$p.s1)
AWG_S2=$([int]$p.s2)
AWG_S3=$([int]$p.s3)
AWG_S4=$([int]$p.s4)
AWG_H1=$([int]$p.h1)
AWG_H2=$([int]$p.h2)
AWG_H3=$([int]$p.h3)
AWG_H4=$([int]$p.h4)
AWG_ADVANCED_SECURITY=$($p.advanced_security)
AWG_PERSISTENT_KEEPALIVE=$([int]$p.persistent_keepalive)
"@

    Write-TextFileLF $Path ($txt.TrimEnd() + "`n")
}

function Render-Gateway-Nft {
    param([string]$WgCoreIf,[string]$ActiveAwgIf,[string]$Path)

    $txt = @"
# NAT правила Gateway для трафика из wg-core в активный awg-интерфейс

table inet awg-gateway {
  chain postrouting {
    type nat hook postrouting priority 100;
    policy accept;

    iifname "$WgCoreIf" oifname "$ActiveAwgIf" masquerade
  }
}
"@
    Write-TextFileLF $Path ($txt.TrimEnd() + "`n")
}

function Render-GwFailoverEnv {
    param([object]$Infra,[hashtable]$State,[string]$Path)

    $ifaces = @()
    foreach ($exit in $Infra.exits) {
        $name   = [string]$exit.name
        $ifaces += [string]$State.exits[$name].awg_if
    }
    $ifaceList = ($ifaces -join " ")

    $m = $Infra.routing.monitor

    $txt = @"
# Конфигурация failover демона на Gateway
# Генерируется оркестратором — не редактировать вручную

ROUTING_TABLE_NAME=$($Infra.routing.awg_table_name)
ROUTING_TABLE_ID=$([int]$Infra.routing.awg_table_id)
WG_CORE_IFNAME=$($Infra.gateway.wg_core.ifname)
FAILOVER_AWG_IFACES="$ifaceList"

HEALTH_INTERVAL_SEC=$([int]$m.health_interval_sec)
FAIL_THRESHOLD=$([int]$m.fail_threshold)
RECOVERY_THRESHOLD=$([int]$m.recovery_threshold)
HANDSHAKE_MAX_AGE_SEC=$([int]$m.handshake_max_age_sec)

# Ping-проверка туннельных IP (ENABLE_PING_CHECK=1 для включения)
ENABLE_PING_CHECK=0
"@

    # Добавляем PEER_TUN_IP для каждого awgX — нужно для ping-проверки failover
    foreach ($exit in $Infra.exits) {
        $name  = [string]$exit.name
        $awgIf = [string]$State.exits[$name].awg_if
        if ($awgIf -match "^awg(\d+)$") {
            $idx  = [int]$Matches[1]
            $link = Compute-LinkFromAwg $Infra.ip_plan.base_cidr $idx
            $txt += "`nPEER_TUN_IP_${awgIf}=$($link.exit_tun_ip)"
        }
    }

    Write-TextFileLF $Path ($txt.TrimEnd() + "`n")
}

function Render-AwgRoutingServiceEnv {
    param([object]$Infra,[hashtable]$State,[string]$ActiveAwgIf,[string]$Path)

    # Собираем список всех AWG-интерфейсов для After= в awg-routing.service
    $ifaces = @()
    foreach ($exit in $Infra.exits) {
        $name = [string]$exit.name
        $ifaces += [string]$State.exits[$name].awg_if
    }
    $ifaceList = ($ifaces -join " ")

    $txt = @"
# Параметры для awg-routing.service (персистентный ip rule + ip route)
# Генерируется оркестратором

ROUTING_TABLE_NAME=$($Infra.routing.awg_table_name)
ROUTING_TABLE_ID=$([int]$Infra.routing.awg_table_id)
ROUTING_RULE_PRIORITY=$([int]$Infra.routing.ip_rule_priority)
WG_CORE_IFNAME=$($Infra.gateway.wg_core.ifname)
ACTIVE_AWG_IFNAME=$ActiveAwgIf
FAILOVER_AWG_IFACES="$ifaceList"
"@

    Write-TextFileLF $Path ($txt.TrimEnd() + "`n")
}

function Render-Exit-AwgParamsEnv {
    param(
        [object]$Infra,
        [hashtable]$State,
        [string]$ExitName,
        [string]$ExitHost,
        [string]$AwgIf,
        [int]$ListenPort,
        [string]$GwTunIp,
        [string]$ExitTunIp,
        [string]$GatewayHost,
        [string]$Path
    )

    $p     = $Infra.awg_profile
    $entry = $State.exits[$ExitName]

    $txt = @"
# Параметры $AwgIf на Exit
AWG_IFNAME=$AwgIf
AWG_LISTEN_PORT=$ListenPort
AWG_MTU=$([int]$p.mtu)
AWG_LOCAL_TUN_IP=$ExitTunIp
AWG_GATEWAY_TUN_IP=$GwTunIp

# Ключи
AWG_PRIVATE_KEY=$([string]$entry.exit_private_key)
AWG_GATEWAY_PUBLIC_KEY=$([string]$entry.gw_public_key)

# Peer (Gateway)
AWG_GATEWAY_ENDPOINT=${GatewayHost}:${ListenPort}

# Профиль AmneziaWG
AWG_JC=$([int]$p.jc)
AWG_JMIN=$([int]$p.jmin)
AWG_JMAX=$([int]$p.jmax)
AWG_S1=$([int]$p.s1)
AWG_S2=$([int]$p.s2)
AWG_S3=$([int]$p.s3)
AWG_S4=$([int]$p.s4)
AWG_H1=$([int]$p.h1)
AWG_H2=$([int]$p.h2)
AWG_H3=$([int]$p.h3)
AWG_H4=$([int]$p.h4)
AWG_ADVANCED_SECURITY=$($p.advanced_security)
AWG_PERSISTENT_KEEPALIVE=$([int]$p.persistent_keepalive)
"@

    Write-TextFileLF $Path ($txt.TrimEnd() + "`n")
}

function Render-Exit-NftTemplate {
    param([string]$Path)

    $txt = @"
# NAT для Exit-сервера
# WAN-интерфейс определяется автоматически на сервере при деплое

table inet exit-nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    policy accept;

    oifname "__WAN_IF__" masquerade
  }
}
"@
    Write-TextFileLF $Path ($txt.TrimEnd() + "`n")
}

function Render-ApplyGatewaySh {
    param([object]$Infra,[hashtable]$State,[string]$ActiveAwgIf,[string]$GwDir)

    # @'...'@ — одинарные кавычки: PowerShell не интерпретирует ничего внутри.
    # Bash-переменные ($RUN_DIR, ${BASH_SOURCE[0]} и т.д.) попадают в файл as-is.
    $txt = @'
#!/usr/bin/env bash
set -euo pipefail

# apply-gateway.sh — генерируется оркестратором, выполняется на Gateway
# Запускает deploy-gateway.sh по стадиям, передавая env-переменные

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$RUN_DIR/../.." && pwd)"

log() { echo "[apply-gateway] $*"; }

log "run_dir=$RUN_DIR"
log "root_dir=$ROOT_DIR"

chmod +x "$ROOT_DIR/deploy-gateway.sh" "$ROOT_DIR/gw-failover.sh"

# --- Стадия 1: установка пакетов, ip_forward, nftables ---
log "=== Стадия 1: установка ==="
GATEWAY_STAGE=1 "$ROOT_DIR/deploy-gateway.sh"

# --- Стадия 2: wg-core ---
log "=== Стадия 2: wg-core ==="
set -a
source "$RUN_DIR/wg-core.params.env"
WG_CORE_PRIVATE_KEY_FILE="$RUN_DIR/wg-core.privkey"
set +a
GATEWAY_STAGE=2 WG_CORE_PRIVATE_KEY_FILE="$WG_CORE_PRIVATE_KEY_FILE" "$ROOT_DIR/deploy-gateway.sh"

# --- Стадия 3: awgX (по одному на каждый exit) ---
log "=== Стадия 3: awg-интерфейсы ==="
for ENV_FILE in "$RUN_DIR"/awg*.params.env; do
  [ -f "$ENV_FILE" ] || continue
  log "Применяю $(basename $ENV_FILE)..."
  set -a
  source "$ENV_FILE"
  set +a
  GATEWAY_STAGE=3 "$ROOT_DIR/deploy-gateway.sh"
done

# --- Стадия 4: routing table + ip rule + nft NAT ---
log "=== Стадия 4: routing ==="
set -a
source "$RUN_DIR/awg-routing.env"
set +a
GATEWAY_STAGE=4 "$ROOT_DIR/deploy-gateway.sh"

# --- Стадия 5: failover демон ---
log "=== Стадия 5: failover ==="
set -a
source "$RUN_DIR/gw-failover.env"
FAILOVER_SCRIPT="$ROOT_DIR/gw-failover.sh"
set +a
GATEWAY_STAGE=5 FAILOVER_SCRIPT="$FAILOVER_SCRIPT" "$ROOT_DIR/deploy-gateway.sh"

log "=== apply-gateway завершён ==="
'@

    Write-TextFileLF (Join-Path $GwDir "apply-gateway.sh") ($txt.TrimEnd() + "`n")
}

function Render-ApplyExitSh {
    param([object]$Infra,[hashtable]$State,[string]$ExitDir)

    $txt = @'
#!/usr/bin/env bash
set -euo pipefail

# apply-exit.sh — генерируется оркестратором, выполняется на Exit
# Загружает env и запускает deploy-exit.sh

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$RUN_DIR/../../.." && pwd)"

log() { echo "[apply-exit] $*"; }

log "run_dir=$RUN_DIR"
log "root_dir=$ROOT_DIR"

chmod +x "$ROOT_DIR/deploy-exit.sh"

# Загружаем env-файл для awgX данного exit
ENV_FILE="$(ls "$RUN_DIR"/awg*.params.env 2>/dev/null | head -n1)"
[ -f "$ENV_FILE" ] || { echo "[apply-exit][ошибка] Не найден awg*.params.env в $RUN_DIR" >&2; exit 1; }

log "Загружаю env: $(basename $ENV_FILE)"
set -a
source "$ENV_FILE"
set +a

"$ROOT_DIR/deploy-exit.sh"

log "=== apply-exit завершён ==="
'@

    Write-TextFileLF (Join-Path $ExitDir "apply-exit.sh") ($txt.TrimEnd() + "`n")
}

function Render-All {
    param([object]$Infra,[hashtable]$State,[string[]]$Actions)

    $runId   = Get-RunId
    $runDir  = Join-Path $ScriptRoot ("out\$runId")

    $renderRoot = Join-Path $runDir "rendered"
    $gwDir      = Join-Path $renderRoot "gateway"
    $exitsRoot  = Join-Path $renderRoot "exits"

    Ensure-Directory $runDir
    Ensure-Directory $renderRoot
    Ensure-Directory $gwDir
    Ensure-Directory $exitsRoot

    @{
        run_id             = $runId
        run_dir            = $runDir
        render_root        = $renderRoot
        gateway_dir        = $gwDir
        exits_dir          = $exitsRoot
        state_before_path  = (Join-Path $runDir "state.before.json")
        state_after_path   = (Join-Path $runDir "state.after.json")
        plan_path          = (Join-Path $runDir "plan.json")
    }
}

# ==========================================================
# PLAN OUTPUT
# ==========================================================

function Show-Plan {
    param([object]$Infra,[hashtable]$State,[string[]]$Actions,[string]$RenderRoot)

    Write-Host ""
    Write-Host "========== PLAN =========="

    if ([string]::IsNullOrWhiteSpace($RenderRoot)) {
        $RenderRoot = Join-Path $ScriptRoot ("out\<RunId>\rendered")
    }

    Write-Host ""
    Write-Host "WG-Core (Gateway):"
    Write-Host ("  Host        : {0}" -f $Infra.gateway.host)
    Write-Host ("  IfName      : {0}" -f $Infra.gateway.wg_core.ifname)
    Write-Host ("  ListenPort  : {0}" -f $State.wg_core.listen_port)
    Write-Host ("  Address     : {0}" -f $Infra.gateway.wg_core.address_cidr)
    Write-Host ("  MTU         : {0}" -f $Infra.gateway.wg_core.mtu)
    Write-Host ("  PublicKey   : {0}" -f $State.wg_core.public_key)

    foreach ($exit in $Infra.exits) {
        $name  = [string]$exit.name
        $entry = $State.exits[$name]
        $awgIf = [string]$entry.awg_if

        if ($awgIf -notmatch "^awg(\d+)$") { throw "В state для exit '$name' некорректный awg_if: $awgIf" }
        $awgIndex = [int]$Matches[1]
        $link     = Compute-LinkFromAwg $Infra.ip_plan.base_cidr $awgIndex

        Write-Host ""
        Write-Host ("Exit: {0}" -f $name)
        Write-Host ("  Host            : {0}" -f $exit.host)
        Write-Host ("  Interface       : {0}" -f $awgIf)
        Write-Host ("  Port            : {0}" -f $entry.listen_port)
        Write-Host ("  Subnet          : {0}" -f $link.subnet_cidr)
        Write-Host ("  GW Tun IP       : {0}" -f $link.gw_tun_ip)
        Write-Host ("  Exit Tun IP     : {0}" -f $link.exit_tun_ip)
        Write-Host ("  GW PubKey (AWG) : {0}" -f $entry.gw_public_key)
        Write-Host ("  Exit PubKey     : {0}" -f $entry.exit_public_key)
    }

    Write-Host ""
    Write-Host "Artifacts (v6):"
    Write-Host ("  RenderRoot: {0}" -f $RenderRoot)

    Write-Host ""
    Write-Host "Actions:"
    foreach ($a in $Actions) { Write-Host ("  {0}" -f $a) }

    Write-Host "=========================="
}

# ==========================================================
# SSH / SCP (OpenSSH Windows)
# ==========================================================

function Get-SshBaseArgs {
    param([object]$Infra)

    $argList = New-Object System.Collections.Generic.List[string]

    $keyPathRaw = [string]$Infra.ssh.key_path
    $keyPathAbs = (Resolve-Path -Path $keyPathRaw).Path

    $argList.Add("-i") | Out-Null
    $argList.Add($keyPathAbs) | Out-Null

    $argList.Add("-p") | Out-Null
    $argList.Add([string]$Infra.ssh.port) | Out-Null

    $userProfile = [string]$env:USERPROFILE

    foreach ($x in $Infra.ssh.extra_opts) {
        $s = ([string]$x).Replace("%USERPROFILE%", $userProfile)
        $argList.Add($s) | Out-Null
    }

    return $argList.ToArray()
}

function Invoke-Ssh {
    param(
        [object]$Infra,
        [string]$RemoteHost,
        [string]$Command,
        [string]$LogPath
    )

    $cmdOneLine = [regex]::Replace($Command, '\s+', ' ').Trim()

    $base   = Get-SshBaseArgs $Infra
    $user   = [string]$Infra.ssh.user
    $target = "$user@$RemoteHost"

    $argList = New-Object System.Collections.Generic.List[string]
    foreach ($a in $base) { $argList.Add($a) | Out-Null }
    $argList.Add($target) | Out-Null
    $argList.Add($cmdOneLine) | Out-Null

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = "ssh"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    # Явно UTF-8: bash на сервере пишет UTF-8, без этого .NET декодирует в CP1252/CP866
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    foreach ($a in $argList) { $psi.ArgumentList.Add($a) | Out-Null }

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    # Исправлен баг: используем Append-TextFile вместо Write-TextFile для CMD-строки
    if ($LogPath) {
        Append-TextFile $LogPath ("=== CMD: " + $cmdOneLine + "`n")
    }

    $null   = $p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    $all = $stdout + $stderr

    if ($LogPath) {
        Append-TextFile $LogPath $all
        Append-TextFile $LogPath "`n"
    }

    if ($p.ExitCode -ne 0) {
        throw "SSH ошибка на $RemoteHost (exit=$($p.ExitCode)). Команда: $cmdOneLine"
    }
}

function Invoke-ScpUploadDir {
    param(
        [object]$Infra,
        [string]$LocalPath,
        [string]$RemoteHost,
        [string]$RemoteDir,
        [string]$LogPath
    )

    if (!(Test-Path $LocalPath)) {
        throw "Локальный путь не найден: $LocalPath"
    }

    $base   = Get-SshBaseArgs $Infra
    $user   = [string]$Infra.ssh.user
    $target = "$user@${RemoteHost}:$RemoteDir"

    $argList = New-Object System.Collections.Generic.List[string]

    if ((Get-Item $LocalPath).PSIsContainer) {
        $argList.Add("-r") | Out-Null
    }

    # Для scp: -p → -P (порт), остальные аргументы без изменений
    $skipNext = $false
    for ($i = 0; $i -lt $base.Length; $i++) {
        if ($skipNext) { $skipNext = $false; $argList.Add($base[$i]) | Out-Null; continue }
        if ($base[$i] -eq "-p") {
            $argList.Add("-P") | Out-Null
            $skipNext = $false
            # Значение порта идёт следующим элементом — оно добавится на следующей итерации
            continue
        }
        $argList.Add($base[$i]) | Out-Null
    }

    $localAbs = (Resolve-Path $LocalPath).Path
    $argList.Add($localAbs) | Out-Null
    $argList.Add($target)   | Out-Null

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = "scp"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    # Явно UTF-8: scp/ssh пишут UTF-8, без этого .NET декодирует в CP1252/CP866
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    foreach ($a in $argList) { $psi.ArgumentList.Add($a) | Out-Null }

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    if ($LogPath) {
        Append-TextFile $LogPath ("=== SCP: " + ($argList -join " ") + "`n")
    }

    $null   = $p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    $all = $stdout + $stderr

    if ($LogPath) {
        Append-TextFile $LogPath $all
        Append-TextFile $LogPath "`n"
    }

    if ($p.ExitCode -ne 0) {
        throw "SCP ошибка на $RemoteHost (exit=$($p.ExitCode)). Upload: $localAbs -> $RemoteDir"
    }
}

# ==========================================================
# APPLY — вспомогательные
# ==========================================================

function Require-LocalFile {
    param([string]$Path,[string]$Hint)
    if (!(Test-Path $Path)) { throw "Не найден файл: $Path. $Hint" }
}

# ==========================================================
# MAIN
# ==========================================================

$infra = Read-JsonFile $InfraPath
Validate-Infra $infra

$state       = Load-OrCreate-State $infra $StatePath
$stateBefore = Convert-ToHashtable $state

$result  = Sync-State $infra $state
$state   = $result.state
$actions = $result.actions

if ($Mode -eq "plan") {
    Show-Plan $infra $state $actions ""
    Write-JsonFile $StatePath $state
    exit 0
}

if ($Mode -eq "render" -or $Mode -eq "apply") {

    $meta       = Render-All $infra $state $actions
    $runId      = [string]$meta.run_id
    $runDir     = [string]$meta.run_dir
    $renderRoot = [string]$meta.render_root
    $gwDir      = [string]$meta.gateway_dir
    $exitsRoot  = [string]$meta.exits_dir

    Write-JsonFile $meta.state_before_path $stateBefore
    Write-JsonFile $meta.state_after_path  $state
    Write-JsonFile $meta.plan_path         (Build-PlanModel $infra $state $actions $runId)

    # --- Gateway rendered ---
    Render-Gateway-WgCoreParamsEnv $infra $state $gwDir

    $activeAwg = Get-InitialActiveAwg $infra $state
    Render-Gateway-Nft $infra.gateway.wg_core.ifname $activeAwg (Join-Path $gwDir "gw-awg-nat.nft")
    Render-GwFailoverEnv $infra $state (Join-Path $gwDir "gw-failover.env")
    Render-AwgRoutingServiceEnv $infra $state $activeAwg (Join-Path $gwDir "awg-routing.env")
    Render-ApplyGatewaySh $infra $state $activeAwg $gwDir

    foreach ($exit in $infra.exits) {
        $name     = [string]$exit.name
        $exitHost = [string]$exit.host
        $entry    = $state.exits[$name]
        $awgIf    = [string]$entry.awg_if

        if ($awgIf -notmatch "^awg(\d+)$") { throw "Некорректный awg_if: $awgIf" }
        $idx  = [int]$Matches[1]
        $link = Compute-LinkFromAwg $infra.ip_plan.base_cidr $idx

        $envPath = Join-Path $gwDir ("$awgIf.params.env")
        Render-Gateway-AwgParamsEnv $infra $state $name $exitHost $awgIf ([int]$entry.listen_port) $link.gw_tun_ip $link.exit_tun_ip $envPath
    }

    # --- Exit rendered ---
    foreach ($exit in $infra.exits) {
        $name     = [string]$exit.name
        $exitHost = [string]$exit.host
        $entry    = $state.exits[$name]
        $awgIf    = [string]$entry.awg_if

        if ($awgIf -notmatch "^awg(\d+)$") { throw "Некорректный awg_if: $awgIf" }
        $idx  = [int]$Matches[1]
        $link = Compute-LinkFromAwg $infra.ip_plan.base_cidr $idx

        $exitDir = Join-Path $exitsRoot $name
        Ensure-Directory $exitDir

        $envPath = Join-Path $exitDir ("$awgIf.params.env")
        Render-Exit-AwgParamsEnv $infra $state $name $exitHost $awgIf ([int]$entry.listen_port) $link.gw_tun_ip $link.exit_tun_ip $infra.gateway.host $envPath
        Render-Exit-NftTemplate (Join-Path $exitDir "exit-nat.nft")
        Render-ApplyExitSh $infra $state $exitDir
    }

    Write-JsonFile $StatePath $state
    Show-Plan $infra $state $actions $renderRoot

    if ($Mode -eq "render") {
        Write-Host ""
        Write-Host "========== RENDER =========="
        Write-Host ("RunDir: {0}" -f $runDir)
        Write-Host "==========================="
        exit 0
    }

    # ======================================================
    # APPLY (upload + execute)
    # ======================================================

    Write-Host ""
    Write-Host "========== APPLY =========="
    Write-Host ("RunDir: {0}" -f $runDir)

    $localDeployGateway = Join-Path $ScriptRoot "deploy-gateway.sh"
    $localDeployExit    = Join-Path $ScriptRoot "deploy-exit.sh"
    $localGwFailover    = Join-Path $ScriptRoot "gw-failover.sh"

    Require-LocalFile $localDeployGateway "Положи deploy-gateway.sh рядом с orchestrator.ps1"
    Require-LocalFile $localDeployExit    "Положи deploy-exit.sh рядом с orchestrator.ps1"
    Require-LocalFile $localGwFailover    "Положи gw-failover.sh рядом с orchestrator.ps1"

    # --- Gateway ---
    $gwHost           = [string]$infra.gateway.host
    $remoteRoot       = "/root/awg-deploy/$runId"
    $remoteRendered   = "$remoteRoot/rendered"
    $remoteGatewayDir = "$remoteRendered/gateway"
    $remoteExitsDir   = "$remoteRendered/exits"

    Invoke-Ssh $infra $gwHost `
        "mkdir -p `"$remoteGatewayDir`" `"$remoteExitsDir`" && chmod 700 `"$remoteRoot`"" `
        (Join-Path $runDir "ssh_gw_mkdir.log")

    Invoke-ScpUploadDir $infra $localDeployGateway $gwHost $remoteRoot       (Join-Path $runDir "scp_gw_deploy.log")
    Invoke-ScpUploadDir $infra $localGwFailover    $gwHost $remoteRoot       (Join-Path $runDir "scp_gw_failover.log")
    Invoke-ScpUploadDir $infra $gwDir              $gwHost $remoteRendered   (Join-Path $runDir "scp_gw_rendered.log")

    # Права на приватный ключ wg-core до запуска deploy
    Invoke-Ssh $infra $gwHost `
        "chmod 600 `"$remoteGatewayDir/wg-core.privkey`"" `
        (Join-Path $runDir "ssh_gw_chmod.log")

    Invoke-Ssh $infra $gwHost `
        "bash `"$remoteGatewayDir/apply-gateway.sh`"" `
        (Join-Path $runDir "ssh_gw_apply.log")

    # --- Exits ---
    foreach ($exit in $infra.exits) {
        $name     = [string]$exit.name
        $exitHost = [string]$exit.host

        $remoteExitsParent = "$remoteRoot/rendered/exits"
        $remoteExitDir     = "$remoteExitsParent/$name"

        Invoke-Ssh $infra $exitHost `
            "mkdir -p `"$remoteExitsParent`" && chmod 700 `"$remoteRoot`"" `
            (Join-Path $runDir "ssh_${name}_mkdir.log")

        $localExitRendered = Join-Path $renderRoot "exits\$name"
        Invoke-ScpUploadDir $infra $localExitRendered $exitHost $remoteExitsParent (Join-Path $runDir "scp_${name}_rendered.log")
        Invoke-ScpUploadDir $infra $localDeployExit   $exitHost $remoteRoot        (Join-Path $runDir "scp_${name}_deploy.log")

        Invoke-Ssh $infra $exitHost `
            "bash `"$remoteExitDir/apply-exit.sh`"" `
            (Join-Path $runDir "ssh_${name}_apply.log")
    }

    Write-Host "==========================="
    Write-Host "[OK] APPLY завершён."
    exit 0
}

# ==========================================================
# HEALTH
# ==========================================================

function Write-HealthLine {
    param([string]$Status,[string]$Label,[string]$Detail="")
    $colors = @{ "OK" = "Green"; "WARN" = "Yellow"; "FAIL" = "Red" }
    $color  = $colors[$Status]
    if (-not $color) { $color = "White" }
    $pad   = " " * [Math]::Max(0, 6 - $Status.Length)
    $line  = "  [$Status]$pad $Label"
    if ($Detail) { $line += "  ($Detail)" }
    Write-Host $line -ForegroundColor $color
}

function Invoke-SshCapture {
    # Как Invoke-Ssh, но возвращает stdout+stderr как строку вместо записи в лог
    param([object]$Infra,[string]$RemoteHost,[string]$Command)

    $cmdOneLine = [regex]::Replace($Command, '\s+', ' ').Trim()
    $base = Get-SshBaseArgs $Infra
    $user = [string]$Infra.ssh.user

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "ssh"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false

    foreach ($a in $base) { $psi.ArgumentList.Add($a) | Out-Null }
    $psi.ArgumentList.Add("$user@$RemoteHost") | Out-Null
    $psi.ArgumentList.Add($cmdOneLine)          | Out-Null

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    return @{
        ExitCode = $p.ExitCode
        Output   = ($stdout + $stderr).Trim()
    }
}

function Get-HandshakeAgeSec {
    param([string]$RawOutput,[string]$PeerPubKey)
    # Парсим вывод "awg show <if> latest-handshakes": "<pubkey> <epoch>"
    foreach ($line in ($RawOutput -split "`n")) {
        $parts = $line.Trim() -split "\s+"
        if ($parts.Count -ge 2) {
            # Нормализуем ключ (убираем trailing =)
            $key = $parts[0].TrimEnd("=")
            $want = $PeerPubKey.TrimEnd("=")
            if ($key -eq $want) {
                $epoch = [long]$parts[1]
                if ($epoch -eq 0) { return 999999 }
                $now = [long](Get-Date -UFormat %s)
                return [Math]::Max(0, $now - $epoch)
            }
        }
    }
    return 999999
}

function Invoke-HealthCheck {
    param([object]$Infra,[hashtable]$State)

    $outDir = Join-Path $ScriptRoot "out"
    Ensure-Directory $outDir

    $totalChecks = 0
    $failCount   = 0
    $warnCount   = 0

    $gwHost      = [string]$Infra.gateway.host
    $handshakeMax = 180  # секунд — из infra.routing.monitor.handshake_max_age_sec

    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "┌─ Gateway: $gwHost" -ForegroundColor Cyan

    # 1. Сервисы на Gateway
    $gwServices = @("wg-quick@wg-core", "awg-routing", "gw-failover")
    foreach ($exit in $Infra.exits) {
        $name  = [string]$exit.name
        $awgIf = [string]$State.exits[$name].awg_if
        $gwServices += "awg-quick@$awgIf"
    }

    foreach ($svc in $gwServices) {
        $totalChecks++
        $r = Invoke-SshCapture $Infra $gwHost "systemctl is-active $svc"
        if ($r.ExitCode -eq 0 -and $r.Output -eq "active") {
            Write-HealthLine "OK"   "svc: $svc"
        } else {
            Write-HealthLine "FAIL" "svc: $svc" $r.Output
            $failCount++
        }
    }

    # 2. ip rule
    $totalChecks++
    $r = Invoke-SshCapture $Infra $gwHost "ip rule show"
    $prio = [string]$Infra.routing.ip_rule_priority
    # Проверяем построчно — -match без ^ не работает на многострочном выводе
    $ruleFound = ($r.Output -split "`n") | Where-Object { $_ -match "^${prio}:.*iif.*wg-core" }
    if ($ruleFound) {
        Write-HealthLine "OK" "ip rule priority $prio iif wg-core"
    } else {
        Write-HealthLine "FAIL" "ip rule priority $prio iif wg-core — не найдено"
        $failCount++
    }

    # 3. ip route table awg-out
    $totalChecks++
    $r = Invoke-SshCapture $Infra $gwHost "ip route show table $([int]$Infra.routing.awg_table_id)"
    if ($r.Output -match "default dev awg") {
        $activeIf = [regex]::Match($r.Output, "default dev (\S+)").Groups[1].Value
        Write-HealthLine "OK" "ip route table awg-out → default dev $activeIf"
    } else {
        Write-HealthLine "FAIL" "ip route table awg-out — default route отсутствует"
        $failCount++
    }

    # 4. nft таблица
    $totalChecks++
    $r = Invoke-SshCapture $Infra $gwHost "nft list table inet awg-gateway 2>&1"
    if ($r.ExitCode -eq 0 -and $r.Output -match "masquerade") {
        $oif = [regex]::Match($r.Output, 'oifname "(\S+)"').Groups[1].Value
        Write-HealthLine "OK" "nft awg-gateway → masquerade oif $oif"
    } else {
        Write-HealthLine "FAIL" "nft awg-gateway — таблица не найдена или нет masquerade"
        $failCount++
    }

    # 5. wg-core handshake
    $totalChecks++
    $r = Invoke-SshCapture $Infra $gwHost "wg show wg-core latest-handshakes"
    $peerPub = [string]$Infra.gateway.wg_core.peer.public_key
    $age = Get-HandshakeAgeSec $r.Output $peerPub
    if ($age -le $handshakeMax) {
        Write-HealthLine "OK" "wg-core handshake age ${age}s"
    } elseif ($age -eq 999999) {
        Write-HealthLine "FAIL" "wg-core handshake — нет данных (туннель не установлен?)"
        $failCount++
    } else {
        Write-HealthLine "WARN" "wg-core handshake age ${age}s (max=${handshakeMax}s)"
        $warnCount++
    }

    # 6. awgX handshakes + ping — проверяем со стороны Gateway (отдельный цикл)
    foreach ($exit in $Infra.exits) {
        $name      = [string]$exit.name
        $awgIf     = [string]$State.exits[$name].awg_if

        if ($awgIf -notmatch "^awg(\d+)$") { continue }
        $idx       = [int]$Matches[1]
        $link      = Compute-LinkFromAwg $Infra.ip_plan.base_cidr $idx
        $exitTunIp = [string]$link.exit_tun_ip

        # handshake с Exit — со стороны Gateway
        $totalChecks++
        $r     = Invoke-SshCapture $Infra $gwHost "awg show $awgIf latest-handshakes"
        $peerR = Invoke-SshCapture $Infra $gwHost "grep -A20 '^\[Peer\]' /etc/amnezia/amneziawg/${awgIf}.conf | grep '^PublicKey' | head -1 | cut -d= -f2- | tr -d ' '"
        $peerKey = $peerR.Output.Trim()
        $age = Get-HandshakeAgeSec $r.Output $peerKey
        if ($age -le $handshakeMax) {
            Write-HealthLine "OK"   "$awgIf ($name) handshake age ${age}s"
        } elseif ($age -eq 999999) {
            Write-HealthLine "FAIL" "$awgIf ($name) handshake — нет данных"
            $failCount++
        } else {
            Write-HealthLine "WARN" "$awgIf ($name) handshake age ${age}s (max=${handshakeMax}s)"
            $warnCount++
        }

        # ping через туннель к Exit — со стороны Gateway
        $totalChecks++
        $r = Invoke-SshCapture $Infra $gwHost "ping -c 2 -W 2 -I $awgIf $exitTunIp 2>&1"
        if ($r.ExitCode -eq 0 -and $r.Output -match "0% packet loss") {
            $rtt = [regex]::Match($r.Output, "rtt[^=]+=\s*([\d.]+)").Groups[1].Value
            Write-HealthLine "OK"   "ping $awgIf → $exitTunIp  rtt=${rtt}ms"
        } else {
            Write-HealthLine "FAIL" "ping $awgIf → $exitTunIp  недоступен"
            $failCount++
        }
    }

    # 7. Проверка каждого Exit-сервера (отдельный цикл — каждый exit знает только свой awgX)
    foreach ($exit in $Infra.exits) {
        $name      = [string]$exit.name
        $exitHost  = [string]$exit.host
        $awgIf     = [string]$State.exits[$name].awg_if

        if ($awgIf -notmatch "^awg(\d+)$") { continue }
        $idx       = [int]$Matches[1]
        $link      = Compute-LinkFromAwg $Infra.ip_plan.base_cidr $idx
        $gwTunIp   = [string]$link.gw_tun_ip

        Write-Host "│"
        Write-Host "├─ Exit: $name ($exitHost)" -ForegroundColor Cyan

        # Сервис awg на Exit
        $totalChecks++
        $r = Invoke-SshCapture $Infra $exitHost "systemctl is-active awg-quick@$awgIf"
        if ($r.ExitCode -eq 0 -and $r.Output -eq "active") {
            Write-HealthLine "OK"   "svc: awg-quick@$awgIf"
        } else {
            Write-HealthLine "FAIL" "svc: awg-quick@$awgIf" $r.Output
            $failCount++
        }

        # nftables на Exit
        $totalChecks++
        $r = Invoke-SshCapture $Infra $exitHost "nft list table inet exit-nat 2>&1"
        if ($r.ExitCode -eq 0 -and $r.Output -match "masquerade") {
            $oif = [regex]::Match($r.Output, 'oifname "(\S+)"').Groups[1].Value
            Write-HealthLine "OK"   "nft exit-nat → masquerade oif $oif"
        } else {
            Write-HealthLine "FAIL" "nft exit-nat — таблица не найдена или нет masquerade"
            $failCount++
        }

        # handshake со стороны Exit — видит только своего peer (Gateway)
        $totalChecks++
        $r        = Invoke-SshCapture $Infra $exitHost "awg show $awgIf latest-handshakes"
        $gwPeerR  = Invoke-SshCapture $Infra $exitHost "grep -A20 '^\[Peer\]' /etc/amnezia/amneziawg/${awgIf}.conf | grep '^PublicKey' | head -1 | cut -d= -f2- | tr -d ' '"
        $gwPeerKey = $gwPeerR.Output.Trim()
        $age = Get-HandshakeAgeSec $r.Output $gwPeerKey
        if ($age -le $handshakeMax) {
            Write-HealthLine "OK"   "$awgIf handshake age ${age}s"
        } elseif ($age -eq 999999) {
            Write-HealthLine "FAIL" "$awgIf handshake — нет данных"
            $failCount++
        } else {
            Write-HealthLine "WARN" "$awgIf handshake age ${age}s (max=${handshakeMax}s)"
            $warnCount++
        }

        # ping от Exit к Gateway через туннель
        $totalChecks++
        $r = Invoke-SshCapture $Infra $exitHost "ping -c 2 -W 2 -I $awgIf $gwTunIp 2>&1"
        if ($r.ExitCode -eq 0 -and $r.Output -match "0% packet loss") {
            $rtt = [regex]::Match($r.Output, "rtt[^=]+=\s*([\d.]+)").Groups[1].Value
            Write-HealthLine "OK"   "ping $awgIf → $gwTunIp (gw-tun)  rtt=${rtt}ms"
        } else {
            Write-HealthLine "FAIL" "ping $awgIf → $gwTunIp (gw-tun)  недоступен"
            $failCount++
        }
    }

    # ------------------------------------------------------------------
    Write-Host ""
    $total = $totalChecks
    $ok    = $total - $failCount - $warnCount

    if ($failCount -gt 0) {
        Write-Host "ИТОГ: FAIL  ($ok OK / $warnCount WARN / $failCount FAIL из $total проверок)" -ForegroundColor Red
    } elseif ($warnCount -gt 0) {
        Write-Host "ИТОГ: WARN  ($ok OK / $warnCount WARN / 0 FAIL из $total проверок)" -ForegroundColor Yellow
    } else {
        Write-Host "ИТОГ: OK    ($ok/$total проверок успешно)" -ForegroundColor Green
    }

    return $failCount
}

if ($Mode -eq "health") {
    Write-Host ""
    Write-Host "========== HEALTH ==========" -ForegroundColor Cyan

    $fails = Invoke-HealthCheck $infra $state

    Write-Host "============================" -ForegroundColor Cyan

    if ($fails -gt 0) { exit 1 } else { exit 0 }
}
