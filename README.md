# AWG VPN Infrastructure — Руководство по эксплуатации

**Версия комплекта:** v1.0 (Gateway) / v1.0 (Exit) / v1.0 (Orchestrator)  
**Дата:** 2026-03-01

---

## Содержание

1. [Обзор архитектуры](#1-обзор-архитектуры)
2. [Компоненты комплекта](#2-компоненты-комплекта)
3. [Требования](#3-требования)
4. [Первоначальная настройка](#4-первоначальная-настройка)
5. [Структура infra.json](#5-структура-infrajson)
6. [Режимы оркестратора](#6-режимы-оркестратора)
7. [Жизненный цикл деплоя](#7-жизненный-цикл-деплоя)
8. [Управление Exit-серверами](#8-управление-exit-серверами)
9. [Failover](#9-failover)
10. [Health-проверки](#10-health-проверки)
11. [Диагностика](#11-диагностика)
12. [Безопасность](#12-безопасность)
13. [Справочник файлов на серверах](#13-справочник-файлов-на-серверах)
14. [Частые вопросы](#14-частые-вопросы)

---

## 1. Обзор архитектуры

```
[Клиенты]
    │  AmneziaWG / WireGuard
    ▼
[MikroTik / RouterOS]  ──── wg-core (WireGuard) ────►  [Gateway]
                                                              │
                                                              ┌───awg0───►  [Exit-1]  ──► Internet
                                                              ├───awg1───►  [Exit-2]  ──► Internet
                                                              └───awgN───►  [Exit-N]  ──► Internet
```

**Gateway** — единственная точка входа клиентского трафика. Принимает трафик через `wg-core` (обычный WireGuard, подключение к MikroTik), перенаправляет в один из awgX-туннелей (AmneziaWG) к выбранному Exit-серверу.

**Exit-серверы** — точки выхода. Каждый поддерживает AWG-туннель к Gateway и делает masquerade NAT через свой WAN-интерфейс. Клиенты выходят в интернет с IP этого сервера.

**Failover** — демон `gw-failover` на Gateway мониторит все awgX-туннели. При деградации активного Exit автоматически переключает трафик на следующий живой Exit (меняет default route в таблице `awg-out` и nft NAT правило).

### Модель адресации

| Узел | Диапазон | Пример |
|------|----------|--------|
| wg-core Gateway | `172.30.0.2/30` | фиксировано в infra.json |
| awg0: Gateway-сторона | `172.30.255.1/30` | base_cidr + 0*4 + 1 |
| awg0: Exit-сторона | `172.30.255.2/30` | base_cidr + 0*4 + 2 |
| awg1: Gateway-сторона | `172.30.255.5/30` | base_cidr + 1*4 + 1 |
| awg1: Exit-сторона | `172.30.255.6/30` | base_cidr + 1*4 + 2 |
| awgN: Gateway-сторона | base_cidr + N*4 + 1 | — |

---

## 2. Компоненты комплекта

| Файл | Тип | Назначение |
|------|-----|-----------|
| `orchestrator.ps1` | PowerShell | Центральный инструмент: keygen, план, рендер, деплой, health |
| `infra.json` | JSON | Описание инфраструктуры (редактируется пользователем) |
| `deploy-gateway.sh` | Bash | Деплой-скрипт Gateway (5 блоков) |
| `deploy-exit.sh` | Bash | Деплой-скрипт Exit (3 блока) |
| `gw-failover.sh` | Bash | Демон мониторинга и автопереключения |
| `out/state.json` | JSON | Ключи + распределение awgX (**секрет**) |

---

## 3. Требования

### Рабочая станция (Windows)
- PowerShell 5.1 или новее
- OpenSSH: `ssh.exe` и `scp.exe` в PATH  
  *(Установить: Параметры → Дополнительные компоненты → OpenSSH Client)*
- SSH-ключ для подключения к серверам (Ed25519 рекомендуется)

### Gateway-сервер
- Ubuntu 22.04 или 24.04 (Debian-based)
- Root-доступ по SSH
- Доступ к интернету (apt, PPA amnezia/ppa)
- Минимум 1 CPU, 512 MB RAM

### Exit-серверы
- Ubuntu 22.04 или 24.04 (Debian-based)
- Root-доступ по SSH
- Доступ к интернету
- Порт из диапазона `ports.min`–`ports.max` должен быть открыт по UDP

---

## 4. Первоначальная настройка

### 4.1 Структура рабочей папки

```
VPS_Deploy\                   ← рабочая папка проекта
├── orchestrator.ps1
├── infra.json
├── deploy-gateway.sh
├── deploy-exit.sh
├── gw-failover.sh
└── ssh\
    └── orchestrator_ed25519  ← приватный SSH-ключ
```

### 4.2 Генерация SSH-ключа

```powershell
mkdir ssh
ssh-keygen -t ed25519 -f .\ssh\orchestrator_ed25519 -N ""
```

### 4.3 Установка ключа на серверы

```powershell
# Для каждого сервера (Gateway + все Exit):
$pub = Get-Content ".\ssh\orchestrator_ed25519.pub"
ssh root@<IP> "mkdir -p ~/.ssh; echo '$pub' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"
```

### 4.4 Настройка infra.json

Отредактируйте `infra.json` — укажите реальные IP серверов, порт SSH и путь к ключу. Подробнее в разделе [5. Структура infra.json](#5-структура-infrajson).

### 4.5 Первый деплой

```powershell
# 1. Посмотреть план без изменений
.\orchestrator.ps1 .\infra.json -Mode plan

# 2. Задеплоить
.\orchestrator.ps1 .\infra.json -Mode apply

# 3. Проверить здоровье
.\orchestrator.ps1 .\infra.json -Mode health
```

---

## 5. Структура infra.json

```jsonc
{
  "ssh": {
    "user": "root",
    "port": 22,
    "key_path": ".\\ssh\\orchestrator_ed25519",
    "extra_opts": [
      "-o", "StrictHostKeyChecking=accept-new",
      "-o", "UserKnownHostsFile=%USERPROFILE%\\.ssh\\known_hosts",
      "-o", "ServerAliveInterval=15",
      "-o", "ServerAliveCountMax=3"
    ]
  },

  // Диапазон случайных UDP-портов для awgX-туннелей
  "ports": { "min": 30000, "max": 50000 },

  "ip_plan": {
    "base_cidr": "172.30.255.0/24",  // Base для /30 подсетей туннелей
    "link_prefix": 30,                // Фиксировано = 30
    "max_exits": 10                   // Максимум Exit-серверов
  },

  // Профиль обфускации AmneziaWG — одинаковый для всех туннелей
  "awg_profile": {
    "mtu": 1380,
    "persistent_keepalive": 25,
    // Параметры обфускации (Jc, Jmin, Jmax, S1-S4, H1-H4)
    "jc": 5, "jmin": 60, "jmax": 170,
    "s1": 45, "s2": 80, "s3": 55, "s4": 95,
    "h1": 7,  "h2": 12, "h3": 3,  "h4": 15,
    "advanced_security": "on"
  },

  "routing": {
    "awg_table_name": "awg-out",  // Имя таблицы маршрутизации
    "awg_table_id": 200,           // Числовой ID (фиксировано = 200)
    "ip_rule_priority": 1000,      // Приоритет ip rule

    "monitor": {
      "health_interval_sec": 10,   // Интервал проверки failover
      "fail_threshold": 3,          // N подряд неудач → переключение
      "recovery_threshold": 2,      // N подряд успехов → считается живым
      "handshake_max_age_sec": 180  // Макс. возраст handshake (3 мин)
    }
  },

  "gateway": {
    "host": "1.2.3.4",            // IP Gateway-сервера
    "wg_core": {
      "ifname": "wg-core",
      "address_cidr": "172.30.0.2/30",  // IP Gateway в wg-core
      "listen_port": 44321,
      "mtu": 1380,
      "peer": {
        // Параметры MikroTik (или другого маршрутизатора)
        "public_key": "<pubkey MikroTik>",
        "endpoint": "<IP MikroTik>:44321",
        "allowed_ips": ["172.30.0.1/32"],
        "persistent_keepalive": 25
      }
    }
  },

  // Список Exit-серверов
  "exits": [
    { "name": "exit-1", "host": "5.6.7.8" },
    { "name": "exit-2", "host": "9.10.11.12" }
  ]
}
```

> **Что не нужно указывать вручную:** порты awgX, ключи, IP туннелей — всё генерируется оркестратором автоматически и сохраняется в `state.json`.

---

## 6. Режимы оркестратора

### `plan` — планирование

Показывает что будет сделано без реальных изменений. Сохраняет `state.json` с новыми ключами для новых узлов.

```powershell
.\orchestrator.ps1 .\infra.json -Mode plan
```

Вывод показывает:
- Параметры wg-core (IP, порт, публичный ключ)
- Для каждого exit: интерфейс awgX, порт, подсеть, IP туннеля, публичные ключи
- Список действий: `create:exit-1:awg0`, `keep:exit-2`, `delete:exit-old`

### `render` — рендеринг

Генерирует все конфигурационные файлы в `out\<RunId>\` без деплоя на серверы. Удобно для проверки перед деплоем.

```powershell
.\orchestrator.ps1 .\infra.json -Mode render
```

### `apply` — деплой

Полный цикл: render → загрузка на серверы по SCP → выполнение деплой-скриптов. Безопасен для повторного применения (идемпотентен).

```powershell
.\orchestrator.ps1 .\infra.json -Mode apply
```

Порядок действий:
1. Gateway: блок 1 (пакеты) → блок 2 (wg-core) → блок 3 × N (awgX) → блок 4 (routing) → блок 5 (failover)
2. Exit-1: установка + awg0 + NAT
3. Exit-N: установка + awgX + NAT

### `health` — проверка здоровья

Подключается к каждому серверу по SSH и проверяет 21 параметр. Возвращает exit code 1 при наличии FAIL.

```powershell
.\orchestrator.ps1 .\infra.json -Mode health
```

Пример успешного вывода:
```
========== HEALTH ==========
┌─ Gateway: 1.2.3.4
  [OK]     svc: wg-quick@wg-core
  [OK]     svc: awg-routing
  [OK]     svc: gw-failover
  [OK]     svc: awg-quick@awg0
  [OK]     svc: awg-quick@awg1
  [OK]     ip rule priority 1000 iif wg-core
  [OK]     ip route table awg-out → default dev awg0
  [OK]     nft awg-gateway → masquerade oif awg0
  [OK]     wg-core handshake age 29s
  [OK]     awg0 (exit-1) handshake age 10s
  [OK]     ping awg0 → 172.30.255.2  rtt=65ms
  [OK]     awg1 (exit-2) handshake age 13s
  [OK]     ping awg1 → 172.30.255.6  rtt=66ms
│
├─ Exit: exit-1 (5.6.7.8)
  [OK]     svc: awg-quick@awg0
  [OK]     nft exit-nat → masquerade oif eth0
  [OK]     awg0 handshake age 32s
  [OK]     ping awg0 → 172.30.255.1 (gw-tun)  rtt=65ms
│
├─ Exit: exit-2 (9.10.11.12)
  [OK]     svc: awg-quick@awg1
  [OK]     nft exit-nat → masquerade oif eth0
  [OK]     awg1 handshake age 42s
  [OK]     ping awg1 → 172.30.255.5 (gw-tun)  rtt=66ms
ИТОГ: OK    (21/21 проверок успешно)
============================
```

Статусы:
- `[OK]` — зелёный, всё нормально
- `[WARN]` — жёлтый, требует внимания (напр. handshake age близко к пределу)
- `[FAIL]` — красный, критическая проблема

---

## 7. Жизненный цикл деплоя

### Что происходит при `apply`

```
orchestrator.ps1 apply
    │
    ├─ plan + render → out\20260228-120000Z\
    │
    ├─ SCP на Gateway:
    │     deploy-gateway.sh, gw-failover.sh
    │     rendered\gateway\{wg-core.params.env, awg0.params.env, awg1.params.env,
    │                        wg-core.privkey, gw-failover.env, awg-routing.env,
    │                        gw-awg-nat.nft, apply-gateway.sh}
    │
    ├─ SSH на Gateway: bash apply-gateway.sh
    │     ├─ GATEWAY_STAGE=1 deploy-gateway.sh  # пакеты
    │     ├─ GATEWAY_STAGE=2 deploy-gateway.sh  # wg-core
    │     ├─ GATEWAY_STAGE=3 deploy-gateway.sh  # awg0
    │     ├─ GATEWAY_STAGE=3 deploy-gateway.sh  # awg1
    │     ├─ GATEWAY_STAGE=4 deploy-gateway.sh  # routing + cleanup
    │     └─ GATEWAY_STAGE=5 deploy-gateway.sh  # failover
    │
    ├─ SCP на Exit-1:
    │     deploy-exit.sh
    │     rendered\exits\exit-1\{awg0.params.env, apply-exit.sh}
    │
    ├─ SSH на Exit-1: bash apply-exit.sh
    │     └─ source awg0.params.env; deploy-exit.sh  # блоки 1-2-3
    │
    └─ (аналогично для Exit-2..N)
```

### RunId и логи

Каждый `apply` создаёт папку `out\<RunId>\` где RunId = дата-время UTC (например `20260228-120000Z`). В ней:

```
out\20260228-120000Z\
├── plan.json              — финальный план
├── state.before.json      — state до apply
├── state.after.json       — state после apply
├── rendered\              — сгенерированные конфиги
├── ssh_gw_apply.log       — полный лог деплоя Gateway
├── ssh_exit-1_apply.log   — полный лог деплоя Exit-1
└── scp_*.log              — логи загрузки файлов
```

При ошибке смотрите соответствующий `.log` файл.

---

## 8. Управление Exit-серверами

### Добавление нового Exit

1. Добавьте запись в `infra.json`:
```json
"exits": [
  { "name": "exit-1", "host": "5.6.7.8" },
  { "name": "exit-2", "host": "9.10.11.12" },
  { "name": "exit-3", "host": "11.12.13.14" }  ← новый
]
```

2. Установите SSH-ключ на новый сервер (см. раздел 4.3)

3. Запустите apply:
```powershell
.\orchestrator.ps1 .\infra.json -Mode apply
```

Оркестратор автоматически:
- Найдёт первый свободный индекс awgX
- Сгенерирует новую пару ключей
- Выберет свободный UDP-порт
- Задеплоит только новый Exit (Gateway обновится с новым awg-интерфейсом)

### Удаление Exit

1. Удалите запись из `infra.json`
2. Запустите apply:
```powershell
.\orchestrator.ps1 .\infra.json -Mode apply
```

На Gateway автоматически:
- Остановится `awg-quick@awgX`
- Отключится автозапуск сервиса
- Конфиг переименуется в `awgX.conf.removed.TIMESTAMP`
- Индекс awgX освободится для будущего использования

> **Примечание:** На самом Exit-сервере сервис `awg-quick@awgX` и NAT остаются — они не удаляются автоматически. Можно оставить как есть или почистить вручную.

### Переиспользование индексов

Если был exit с awg1, он удалён, а потом добавляется новый exit — он получит индекс awg1 (первый свободный). Это нормальное поведение, адресация восстанавливается без дыр.

---

## 9. Failover

### Принцип работы

`gw-failover` работает на Gateway как systemd-сервис (`Type=simple`, всегда работает).

Каждые `HEALTH_INTERVAL_SEC` (10 сек по умолчанию):
1. Для каждого awgX получает возраст последнего handshake
2. Если `ENABLE_PING_CHECK=1` — дополнительно пингует Exit через туннель
3. Обновляет счётчики `fail_cnt` / `ok_cnt` для каждого интерфейса
4. Если `fail_cnt[active] >= FAIL_THRESHOLD` (3) → переключается на лучший

**Non-preemptive**: обратного переключения нет. Если был awg0, упал, переключился на awg1 — awg1 остаётся активным даже после восстановления awg0. Это правильное поведение для production.

### Параметры

| Параметр | По умолчанию | Описание |
|----------|-------------|---------|
| `HEALTH_INTERVAL_SEC` | 10 | Интервал проверки |
| `FAIL_THRESHOLD` | 3 | Неудач подряд до переключения (= 30 сек) |
| `RECOVERY_THRESHOLD` | 2 | Успехов подряд для "живого" статуса (= 20 сек) |
| `HANDSHAKE_MAX_AGE_SEC` | 180 | Макс. возраст handshake (3 мин) |
| `ENABLE_PING_CHECK` | 0 | Ping-проверка через туннель (0=выкл, 1=вкл) |

### Включение ping-проверки

В `infra.json` ping-проверка выключена по умолчанию. Для включения — измените в `/etc/default/gw-failover` на сервере (или добавьте параметр в infra.json и пересоздайте инфраструктуру):

```bash
ENABLE_PING_CHECK=1
# Адреса уже записаны:
# PEER_TUN_IP_awg0=172.30.255.2
# PEER_TUN_IP_awg1=172.30.255.6
```

### Мониторинг failover

```bash
# Live лог переключений
journalctl -u gw-failover -f

# Текущий активный интерфейс
cat /run/gw-failover.state

# Текущее состояние маршрутизации
ip route show table awg-out
nft list table inet awg-gateway
```

### Ручное переключение

Failover не поддерживает ручное переключение напрямую. Для принудительного переключения на awg1:

```bash
# Остановить awg0 (failover сам переключится через ~30 сек)
systemctl stop awg-quick@awg0

# Или изменить маршрут вручную (failover перезапишет при следующей проверке)
ip route replace default dev awg1 table 200
nft flush table inet awg-gateway
nft -f /etc/nftables.d/gw-awg-nat.nft  # предварительно отредактировать awg1
```

---

## 10. Health-проверки

Health-режим проверяет следующие параметры:

### Gateway (13 проверок при 2 exits)

| Проверка | Метод | FAIL если |
|----------|-------|-----------|
| svc: wg-quick@wg-core | `systemctl is-active` | не `active` |
| svc: awg-routing | `systemctl is-active` | не `active` |
| svc: gw-failover | `systemctl is-active` | не `active` |
| svc: awg-quick@awg0..N | `systemctl is-active` | не `active` |
| ip rule priority 1000 | `ip rule show` | правило отсутствует |
| ip route table awg-out | `ip route show table 200` | нет default route |
| nft awg-gateway | `nft list table` | нет masquerade |
| wg-core handshake | `wg show latest-handshakes` | >180с → WARN, нет данных → FAIL |
| awgX handshake (× N) | `awg show latest-handshakes` | >180с → WARN, нет данных → FAIL |
| ping awgX → exit_tun_ip (× N) | `ping -I awgX` | потери пакетов |

### Каждый Exit (4 проверки)

| Проверка | Метод | FAIL если |
|----------|-------|-----------|
| svc: awg-quick@awgX | `systemctl is-active` | не `active` |
| nft exit-nat | `nft list table` | нет masquerade |
| awgX handshake | `awg show latest-handshakes` | >180с → WARN, нет данных → FAIL |
| ping awgX → gw_tun_ip | `ping -I awgX` | потери пакетов |

### Интеграция с мониторингом

Health возвращает exit code `1` при любом FAIL — удобно для автоматизации:

```powershell
# В cron / Task Scheduler:
.\orchestrator.ps1 .\infra.json -Mode health
if ($LASTEXITCODE -ne 0) {
    # отправить уведомление
}
```

---

## 11. Диагностика

### Общая диагностика Gateway

```bash
# Все сервисы одной командой
systemctl status wg-quick@wg-core awg-quick@awg0 awg-quick@awg1 \
  awg-routing gw-failover --no-pager -l

# Туннели и handshake
wg show wg-core
awg show awg0
awg show awg1

# Routing
ip rule show
ip route show table awg-out
nft list table inet awg-gateway

# Лог failover
journalctl -u gw-failover --no-pager -l
```

### Диагностика Exit

```bash
# Туннель
awg show awg0   # или awg1 — зависит от exit

# NAT
nft list table inet exit-nat

# Сервис
systemctl status awg-quick@awg0 nftables --no-pager
```

### Проблема: handshake не устанавливается

```bash
# На Gateway — проверить endpoint доступен ли с сервера
nc -zu <IP Exit> <PORT awg>

# На Exit — проверить порт слушается
ss -ulnp | grep <PORT>

# Проверить firewall на Exit
nft list ruleset
iptables -L -n  # если используется iptables

# Типичная причина: UDP-порт закрыт на firewall
ufw allow <PORT>/udp
```

### Проблема: трафик клиентов не проходит

```bash
# 1. Проверить ip_forward
sysctl net.ipv4.ip_forward  # должно быть 1

# 2. Проверить ip rule
ip rule show  # должна быть строка: 1000: from all iif wg-core lookup awg-out

# 3. Проверить маршрут в таблице awg-out
ip route show table awg-out  # должно быть: default dev awg0 ...

# 4. Проверить NAT на Gateway
nft list table inet awg-gateway  # masquerade iif wg-core oif awg0

# 5. Проверить NAT на Exit
nft list table inet exit-nat  # masquerade oif eth0
```

### Проблема: `awg-routing.env: line N: awgX: command not found`

Это означает что `FAILOVER_AWG_IFACES` записан без кавычек. Значение `awg0 awg1` при source воспринимается как команда `awg1`.

**Решение:** обновить `orchestrator.ps1` до актуальной версии и запустить `apply` заново.

### Проблема: после удаления exit старый туннель остаётся

```bash
# На Gateway — проверить что cleanup_stale_awg отработал
ip link show type amneziawg  # не должно быть удалённого awgX
ls /etc/amnezia/amneziawg/   # конфиг должен быть переименован в .removed.*

# Если не отработал — запустить apply заново
# Или вручную:
systemctl stop awg-quick@awg1
systemctl disable awg-quick@awg1
awg-quick down awg1
```

### Просмотр логов конкретного apply

```powershell
# Найти последний RunId
ls .\out\ | Sort-Object LastWriteTime | Select-Object -Last 3

# Посмотреть лог Gateway
Get-Content ".\out\20260228-120000Z\ssh_gw_apply.log"

# Посмотреть лог Exit
Get-Content ".\out\20260228-120000Z\ssh_exit-1_apply.log"
```

---

## 12. Безопасность

### state.json

Содержит **приватные ключи** всех AWG-туннелей. Обращайтесь с ним как с секретом:

```powershell
# Защита прав доступа на Windows
icacls ".\out" /inheritance:r /grant:r "$env:USERNAME:(OI)(CI)F"

# Добавить в .gitignore:
echo "out/" >> .gitignore
echo "ssh/" >> .gitignore
```

### SSH-ключ

- Используйте отдельный SSH-ключ только для оркестратора (не личный)
- Храните в `.\ssh\` рядом со скриптами
- Не включайте в репозиторий

OpenSSH требует строгих прав на приватный ключ. При копировании файла в Windows права наследуются от папки назначения и становятся "слишком открытыми" — SSH откажется использовать такой ключ с ошибкой `UNPROTECTED PRIVATE KEY FILE`.

**Исправление прав после копирования ключа:**

```powershell
$keyPath = ".\ssh\orchestrator_ed25519"

# Убираем наследование и оставляем права только текущему пользователю
icacls $keyPath /inheritance:r /grant:r "$env:USERNAME:F"

# Проверяем результат — должен быть только текущий пользователь
icacls $keyPath
```

Это необходимо выполнять **каждый раз при копировании ключа** в новую папку.

### Приватные ключи на серверах

| Файл | Права | Содержимое |
|------|-------|-----------|
| `/etc/wireguard/wg-core.key` | 600 | Приватный ключ wg-core |
| `/etc/amnezia/amneziawg/awgX.conf` | 600 | Конфиг с приватным ключом AWG |
| `/etc/default/gw-failover` | 600 | Конфигурация failover |

### Передача ключей при деплое

- Приватный ключ `wg-core` передаётся через временный файл (не переменную окружения)
- Приватные ключи AWG передаются через env-переменные в рамках SSH-сессии
- Все конфиги имеют права 600 немедленно при создании

---

## 13. Справочник файлов на серверах

### Gateway

```
/etc/wireguard/
├── wg-core.conf              WireGuard конфиг (chmod 600)
├── wg-core.key               Приватный ключ (chmod 600)
└── wg-core.pub               Публичный ключ (chmod 644)

/etc/amnezia/amneziawg/
├── awg0.conf                 AWG конфиг туннеля к exit-1 (chmod 600)
├── awg1.conf                 AWG конфиг туннеля к exit-2 (chmod 600)
└── awgX.conf.removed.*       Конфиги удалённых exits (архив)

/etc/nftables.d/
└── gw-awg-nat.nft            NAT правило (управляется gw-failover)

/etc/iproute2/rt_tables       Содержит запись "200 awg-out"

/usr/local/sbin/
├── awg-routing-up.sh         Восстановление routing после reboot
└── gw-failover.sh            Демон мониторинга

/etc/systemd/system/
├── awg-routing.service       Сервис восстановления routing
└── gw-failover.service       Сервис failover-демона

/etc/default/
└── gw-failover               Конфигурация failover (chmod 600)

/run/
└── gw-failover.state         Текущий активный интерфейс (runtime)

/etc/sysctl.d/
└── 99-awg-gateway.conf       net.ipv4.ip_forward=1
```

### Exit

```
/etc/amnezia/amneziawg/
└── awgX.conf                 AWG конфиг туннеля к Gateway (chmod 600)

/etc/nftables.d/
└── exit-nat.nft              NAT правило (masquerade через WAN)

/etc/sysctl.d/
└── 99-awg-exit.conf          net.ipv4.ip_forward=1
```

---

## 14. Перенос проекта в другую папку

При копировании или переносе папки проекта необходимо выполнить два шага, иначе оркестратор сгенерирует новые ключи и потеряет связь с задеплоенной инфраструктурой.

### Симптомы неправильного переноса

```
[keygen] Генерирую ключи wg-core...
[keygen] Генерирую ключи AWG Gateway для 'exit-1'...
```

Это означает что `out\state.json` не найден — оркестратор создаёт новый state с новыми ключами. Деплой с такими ключами перезапишет конфиги на серверах.

```
WARNING: UNPROTECTED PRIVATE KEY FILE!
Permissions for '...\ssh\orchestrator_ed25519' are too open.
```

SSH-ключ скопирован с широкими правами — OpenSSH отказывается его использовать.

### Правильный порядок переноса

**1. Скопируйте папку проекта целиком** (включая `out\` и `ssh\`):

```powershell
Copy-Item -Path "D:\OldPath\VPS_Deploy" -Destination "D:\NewPath\VPS_Deploy" -Recurse
cd "D:\NewPath\VPS_Deploy"
```

**2. Исправьте права на SSH-ключ** (обязательно после любого копирования):

```powershell
$keyPath = ".\ssh\orchestrator_ed25519"
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
icacls $keyPath /inheritance:r /grant:r "${user}:F"
```

**3. Исправьте права на папку `out\`:**

```powershell
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
icacls ".\out" /inheritance:r /grant:r "${user}:(OI)(CI)F"
```

**4. Проверьте что state.json на месте:**

```powershell
Test-Path ".\out\state.json"  # должно быть True
```

**5. Проверьте здоровье:**

```powershell
.\orchestrator.ps1 .\infra.json -Mode health
```

Если `health` запустился без сообщений `[keygen]` — перенос выполнен правильно.

### Если state.json был утерян

Если `state.json` утерян, а серверы уже задеплоены — новые ключи из нового state не совпадут с конфигурацией на серверах. Решение:

**Вариант А — восстановить state.json из бэкапа** (предпочтительно).

**Вариант Б — извлечь ключи с серверов вручную:**

```bash
# На Gateway — ключи wg-core
cat /etc/wireguard/wg-core.key        # приватный ключ
cat /etc/wireguard/wg-core.pub        # публичный ключ

# На Gateway — ключи awgX (Gateway-сторона)
grep PrivateKey /etc/amnezia/amneziawg/awg0.conf
grep -A5 "\[Peer\]" /etc/amnezia/amneziawg/awg0.conf | grep PublicKey

# На Exit — ключи awgX (Exit-сторона)
grep PrivateKey /etc/amnezia/amneziawg/awg0.conf
grep -A5 "\[Peer\]" /etc/amnezia/amneziawg/awg0.conf | grep PublicKey
```

**Вариант В — полное пересоздание.** Удалить state.json, запустить `apply` — на серверах будут установлены новые ключи. Туннели пересоздадутся с нуля.

---

## 15. Частые вопросы

**Q: Нужно ли запускать apply при изменении параметров awg_profile (обфускация)?**  
A: Да. Параметры обфускации (Jc, Jmin и т.д.) записываются в конфиг при каждом apply. После apply сервисы awg-quick перезапускаются с новыми параметрами.

**Q: Что произойдёт если запустить apply во время активного трафика?**  
A: Блоки 1-3 перезапускают туннели — трафик прерывается на ~1 секунду для каждого туннеля. Блок 4 обновляет routing и NAT атомарно (без разрыва). Блок 5 перезапускает failover-демон.

**Q: Можно ли изменить IP-план (base_cidr) после деплоя?**  
A: Нет без полного пересоздания. IP-план жёстко привязан к state.json через индексы awgX. При изменении base_cidr нужно удалить state.json и заново задеплоить всё с нуля.

**Q: Как посмотреть публичный ключ Gateway для настройки MikroTik?**  
A: После `plan` или `apply` он выводится в плане. Также доступен в `out\state.json` (`wg_core.public_key`) или в файле `out\<RunId>\rendered\gateway\wg-core.pubkey`.

**Q: Что значит `state UNKNOWN` у интерфейса awgX?**  
A: Это нормально для WireGuard/AmneziaWG. Ядро Linux показывает `UNKNOWN` для point-to-point интерфейсов без carrier в традиционном смысле. Флаги `UP,LOWER_UP` означают что интерфейс действительно поднят.

**Q: Failover переключился на awg1, awg0 восстановился — почему не переключается обратно?**  
A: Это правильное поведение (non-preemptive failover). Обратное автопереключение не реализовано намеренно — оно создаёт лишние переключения при нестабильном awg0. awg0 перейдёт в статус "живой" и будет использован при следующем сбое awg1.

**Q: Как добавить более 10 Exit-серверов?**  
A: Увеличьте `ip_plan.max_exits` в `infra.json`. Убедитесь что `base_cidr` имеет достаточно адресного пространства (каждый exit = /30 = 4 адреса).

**Q: Нужно ли пересоздавать инфраструктуру при смене IP сервера?**  
A: Нет. Просто обновите `host` в `infra.json` для нужного узла и запустите `apply`. Оркестратор задеплоит конфиги на новый IP, ключи останутся прежними.
