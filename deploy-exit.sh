#!/usr/bin/env bash
# =============================================================================
# deploy-exit.sh — развёртывание и обновление Exit-узла
# =============================================================================
#
# НАЗНАЧЕНИЕ
#   Устанавливает и конфигурирует Exit-сервер VPN-инфраструктуры:
#   AmneziaWG (awgX) туннель к Gateway и nftables NAT для выхода
#   клиентского трафика в интернет через WAN-интерфейс этого сервера.
#
# АРХИТЕКТУРА
#   Скрипт разбит на 3 независимых блока, выполняемых последовательно.
#   В отличие от Gateway, все блоки вызываются за один запуск скрипта —
#   переменная GATEWAY_STAGE не используется.
#
#   Блок 1  Установка пакетов: amneziawg, nftables
#           Включение ip_forward, запуск nftables
#   Блок 2  Туннель awgX к Gateway (конфиг + сервис awg-quick@awgX)
#           Сравнивает ключи: если изменились — предупреждает и заменяет
#   Блок 3  NAT через WAN (определяется автоматически по default route)
#
# ВЫЗОВ
#   Не вызывается напрямую. Вызывается из apply-exit.sh (генерируется
#   оркестратором orchestrator.ps1) который source-ит awgX.params.env
#   перед вызовом скрипта:
#
#     set -a; source awg0.params.env; set +a
#     bash deploy-exit.sh
#
#   Прямой вызов для отладки:
#     set -a; source /root/awg-deploy/<RunId>/rendered/exits/exit-1/awg0.params.env; set +a
#     bash deploy-exit.sh
#
# ТРЕБОВАНИЯ
#   ОС:       Ubuntu 22.04 / 24.04 (Debian-based)
#   Права:    root (проверяется в начале)
#   Сеть:     доступ к apt, PPA amnezia/ppa
#   Команды:  ip, systemctl, sysctl (до блока 1)
#             awg, nft (после блока 1 — устанавливаются в нём)
#
# ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ (из awgX.params.env)
#   AWG_IFNAME                — имя интерфейса (awg0, awg1, ...)
#   AWG_LISTEN_PORT           — UDP-порт туннеля
#   AWG_MTU                   — MTU (обычно 1380)
#   AWG_LOCAL_TUN_IP          — IP Exit в /30 подсети туннеля
#   AWG_GATEWAY_TUN_IP        — IP Gateway в /30 подсети туннеля
#   AWG_PRIVATE_KEY           — приватный ключ Exit (из state.json)
#   AWG_GATEWAY_PUBLIC_KEY    — публичный ключ Gateway для этого туннеля
#   AWG_GATEWAY_ENDPOINT      — host:port Gateway для подключения
#   AWG_JC/JMIN/JMAX/S1..S4  — параметры обфускации AmneziaWG
#   AWG_H1..H4                — параметры заголовков AmneziaWG
#   AWG_ADVANCED_SECURITY     — on/off
#   AWG_PERSISTENT_KEEPALIVE  — секунды (обычно 25)
#
# ИДЕМПОТЕНТНОСТЬ
#   Безопасен для повторного применения:
#   - Приватный ключ сравнивается с текущим в конфиге; замена только при расхождении
#   - nft таблица exit-nat пересоздаётся при каждом apply (WAN-if мог измениться)
#   - systemctl restart — интерфейс пересоздаётся, трафик прерывается на ~1 сек
#
# ФАЙЛЫ НА СЕРВЕРЕ (после деплоя)
#   /etc/amnezia/amneziawg/awgX.conf     — конфиг туннеля (chmod 600)
#   /etc/nftables.d/exit-nat.nft         — NAT правило
#   /etc/sysctl.d/99-awg-exit.conf       — ip_forward=1
#
# АВТОР / ВЕРСИЯ
#   Версия:  v1.0
#   Проект:  AWG VPN Infrastructure
# =============================================================================

set -euo pipefail

log()      { echo "[deploy-exit] $*"; }
warn()     { echo "[deploy-exit][внимание] $*"; }
die()      { echo "[deploy-exit][ошибка] $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Скрипт должен выполняться от root."
}

need_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Не задана переменная окружения: $name"
}

detect_wan_if() {
  local wan
  wan="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1 || true)"
  [[ -n "$wan" ]] || die "Не удалось определить WAN-интерфейс."
  echo "$wan"
}

# Извлечь значение PrivateKey из секции [Interface] конфига awg
extract_privkey_from_conf() {
  local conf="$1"
  awk -F' *= *' '
    /^\[Interface\]/ { in_iface=1; next }
    /^\[/            { in_iface=0 }
    in_iface && $1 == "PrivateKey" { gsub(/[[:space:]]/, "", $2); print $2; exit }
  ' "$conf"
}

# -----------------------------------------------------------------------------
# Блок 1
# -----------------------------------------------------------------------------

install_packages() {
  log "Обновляю индексы пакетов..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y

  log "Устанавливаю базовые пакеты..."
  apt-get install -y \
    ca-certificates curl gnupg lsb-release software-properties-common nftables

  if ! grep -R "ppa:amnezia/ppa" /etc/apt/sources.list /etc/apt/sources.list.d/* >/dev/null 2>&1; then
    log "Добавляю PPA AmneziaWG..."
    add-apt-repository -y ppa:amnezia/ppa
    apt-get update -y
  else
    log "PPA AmneziaWG уже добавлен."
  fi

  log "Устанавливаю amneziawg..."
  apt-get install -y amneziawg
  log "Установка завершена."
}

prepare_dirs() {
  mkdir -p /etc/amnezia/amneziawg && chmod 700 /etc/amnezia/amneziawg
  mkdir -p /etc/nftables.d
}

enable_ip_forward() {
  log "Включаю net.ipv4.ip_forward=1..."
  cat > /etc/sysctl.d/99-awg-exit.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl -p /etc/sysctl.d/99-awg-exit.conf >/dev/null
}

enable_nft_service() {
  systemctl enable nftables >/dev/null
  systemctl restart nftables
}

run_block1() {
  install_packages
  prepare_dirs
  enable_ip_forward
  enable_nft_service
  log "Готово (блок 1)."
}

# -----------------------------------------------------------------------------
# Блок 2: awgX
# Если конфиг уже существует — сравниваем PrivateKey с тем что пришёл из env.
# Если не совпадает — предупреждаем, останавливаем сервис, перезаписываем.
# -----------------------------------------------------------------------------

awg_require_env() {
  need_env AWG_IFNAME
  need_env AWG_LISTEN_PORT
  need_env AWG_MTU
  need_env AWG_LOCAL_TUN_IP
  need_env AWG_GATEWAY_TUN_IP
  need_env AWG_PRIVATE_KEY
  need_env AWG_GATEWAY_PUBLIC_KEY
  need_env AWG_GATEWAY_ENDPOINT
  need_env AWG_PERSISTENT_KEEPALIVE
  need_env AWG_JC
  need_env AWG_JMIN
  need_env AWG_JMAX
  need_env AWG_S1
  need_env AWG_S2
  need_env AWG_S3
  need_env AWG_S4
  need_env AWG_H1
  need_env AWG_H2
  need_env AWG_H3
  need_env AWG_H4
  need_env AWG_ADVANCED_SECURITY
}

awg_check_and_write_config() {
  local ifname="$1"
  local dir="/etc/amnezia/amneziawg"
  local conf="${dir}/${ifname}.conf"

  mkdir -p "$dir" && chmod 700 "$dir"

  if [[ -f "$conf" ]]; then
    local current_priv
    current_priv="$(extract_privkey_from_conf "$conf")"

    if [[ "$current_priv" == "$AWG_PRIVATE_KEY" ]]; then
      log "Ключ ${ifname} совпадает с оркестратором — обновляю конфиг (параметры могли измениться)."
    else
      # Вычисляем публичные ключи для наглядности в логе
      local current_pub expected_pub
      current_pub="$(printf '%s' "$current_priv" | awg pubkey 2>/dev/null || echo '<не удалось вычислить>')"
      expected_pub="$(printf '%s' "$AWG_PRIVATE_KEY" | awg pubkey 2>/dev/null || echo '<не удалось вычислить>')"

      warn "Ключ ${ifname} на сервере отличается от ключа в state.json!"
      warn "  Текущий pubkey:   ${current_pub}"
      warn "  Ожидаемый pubkey: ${expected_pub}"
      warn "Останавливаю awg-quick@${ifname} и заменяю конфиг..."
      systemctl stop "awg-quick@${ifname}" 2>/dev/null || true
    fi
  else
    log "Конфиг ${ifname} отсутствует — создаю."
  fi

  log "Пишу конфиг ${ifname}: $conf"
  cat > "$conf" <<EOF
[Interface]
PrivateKey = ${AWG_PRIVATE_KEY}
Address = ${AWG_LOCAL_TUN_IP}/30
ListenPort = ${AWG_LISTEN_PORT}
MTU = ${AWG_MTU}

Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}

[Peer]
PublicKey = ${AWG_GATEWAY_PUBLIC_KEY}
Endpoint = ${AWG_GATEWAY_ENDPOINT}
AllowedIPs = ${AWG_GATEWAY_TUN_IP}/32
PersistentKeepalive = ${AWG_PERSISTENT_KEEPALIVE}
AdvancedSecurity = ${AWG_ADVANCED_SECURITY}
EOF
  chmod 600 "$conf"
  log "Конфиг записан."
}

awg_enable_service() {
  local ifname="$1"
  log "Запускаю awg-quick@${ifname}..."
  systemctl enable "awg-quick@${ifname}" >/dev/null
  systemctl restart "awg-quick@${ifname}"
  ip link show "$ifname" >/dev/null 2>&1 || die "Интерфейс ${ifname} не поднялся."
  log "Интерфейс ${ifname} поднят."
}

run_block2() {
  awg_require_env
  local ifname="$AWG_IFNAME"
  awg_check_and_write_config "$ifname"
  awg_enable_service "$ifname"
  log "Готово (блок 2)."
}

# -----------------------------------------------------------------------------
# Блок 3: NAT через WAN
# -----------------------------------------------------------------------------

ensure_nft_include() {
  local main_conf="/etc/nftables.conf" dir="/etc/nftables.d"
  mkdir -p "$dir"
  if [[ ! -f "$main_conf" ]]; then
    printf '#!/usr/sbin/nft -f\ninclude "%s/*.nft"\n' "$dir" > "$main_conf"
  elif ! grep -qE "include[[:space:]]+\"${dir}/\*\.nft\"" "$main_conf"; then
    printf '\ninclude "%s/*.nft"\n' "$dir" >> "$main_conf"
  fi
}

configure_nat() {
  local wan
  wan="$(detect_wan_if)"
  log "WAN интерфейс: $wan"

  ensure_nft_include

  cat > /etc/nftables.d/exit-nat.nft <<EOF
# NAT для Exit-сервера
# WAN интерфейс: ${wan}
# Генерируется deploy-exit.sh — не редактировать вручную

table inet exit-nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    policy accept;
    oifname "${wan}" masquerade
  }
}
EOF

  systemctl restart nftables
  nft list table inet exit-nat >/dev/null 2>&1 || die "Не удалось применить nft таблицу exit-nat."
  log "NAT настроен: oif $wan masquerade"
}

run_block3() {
  configure_nat
  log "Готово (блок 3)."
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------

main() {
  require_root
  # ip, systemctl, sysctl должны быть до установки пакетов
  need_cmd ip
  need_cmd systemctl
  need_cmd sysctl

  run_block1  # устанавливает awg, nft

  # awg и nft проверяем после блока 1 — они устанавливаются в нём
  need_cmd awg
  need_cmd nft

  run_block2
  run_block3

  log "Deploy Exit завершён."
}

main "$@"
