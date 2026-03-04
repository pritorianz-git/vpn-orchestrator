#!/usr/bin/env bash
# =============================================================================
# deploy-gateway.sh — развёртывание и обновление Gateway-узла
# =============================================================================
#
# НАЗНАЧЕНИЕ
#   Устанавливает и конфигурирует Gateway-сервер VPN-инфраструктуры:
#   WireGuard (wg-core), AmneziaWG (awgX), policy routing, nftables NAT,
#   сервис мониторинга и автоматического failover.
#
# АРХИТЕКТУРА
#   Скрипт разбит на 5 независимых блоков, каждый вызывается отдельно
#   через переменную GATEWAY_STAGE. Это позволяет:
#   - передавать secrets (приватные ключи) только в нужный блок
#   - повторно применять только изменившиеся части конфигурации
#   - диагностировать проблемы на конкретном этапе
#
#   Блок 1  Установка пакетов: wireguard, amneziawg, nftables
#   Блок 2  Туннель wg-core к корневому маршрутизатору (MikroTik/RouterOS)
#   Блок 3  Туннели awgX к Exit-серверам (один вызов на каждый exit)
#   Блок 4  Policy routing (ip rule + ip route table awg-out) + nft NAT +
#           сервис awg-routing.service (персистентность после reboot)
#   Блок 5  Failover-демон gw-failover.sh (мониторинг + автопереключение)
#
# ВЫЗОВ
#   Не вызывается напрямую. Вызывается из apply-gateway.sh (генерируется
#   оркестратором orchestrator.ps1) который source-ит нужные env-файлы
#   и передаёт GATEWAY_STAGE перед каждым вызовом.
#
#   Прямой вызов для отладки (пример блока 4):
#     set -a; source awg-routing.env; set +a
#     GATEWAY_STAGE=4 bash deploy-gateway.sh
#
# ТРЕБОВАНИЯ
#   ОС:       Ubuntu 22.04 / 24.04 (Debian-based)
#   Права:    root (проверяется в начале)
#   Сеть:     доступ к apt, PPA amnezia/ppa
#   Команды:  ip, awk, systemctl, sysctl (до блока 1)
#             wg (блок 2), awg (блок 3), nft (блок 4)
#
# ИДЕМПОТЕНТНОСТЬ
#   Все блоки безопасны для повторного применения (apply = re-apply):
#   - Ключи сравниваются с текущими; замена только при расхождении
#   - ip rule: del+add (надёжнее grep по ip rule show)
#   - ip route: replace (всегда идемпотентен)
#   - nft: flush+load атомарно (без разрыва трафика)
#   - Устаревшие awgX: автоматически останавливаются и удаляются в блоке 4
#
# БЕЗОПАСНОСТЬ
#   - Приватный ключ wg-core передаётся через файл (WG_CORE_PRIVATE_KEY_FILE),
#     а не через переменную окружения
#   - Приватные ключи AWG хранятся в /etc/amnezia/amneziawg/*.conf (chmod 600)
#   - /etc/default/gw-failover (содержит FAILOVER_AWG_IFACES) — chmod 600
#
# ФАЙЛЫ НА СЕРВЕРЕ (после деплоя)
#   /etc/wireguard/wg-core.conf          — конфиг wg-core (chmod 600)
#   /etc/wireguard/wg-core.key           — приватный ключ (chmod 600)
#   /etc/amnezia/amneziawg/awgX.conf     — конфиги туннелей к exits (chmod 600)
#   /etc/nftables.d/gw-awg-nat.nft       — NAT правило Gateway
#   /etc/iproute2/rt_tables              — таблица awg-out (id 200)
#   /usr/local/sbin/awg-routing-up.sh    — скрипт восстановления routing
#   /etc/systemd/system/awg-routing.service
#   /usr/local/sbin/gw-failover.sh       — демон failover
#   /etc/systemd/system/gw-failover.service
#   /etc/default/gw-failover             — конфигурация failover (chmod 600)
#   /run/gw-failover.state               — текущий активный интерфейс
#
# АВТОР / ВЕРСИЯ
#   Версия:  v1.0
#   Проект:  AWG VPN Infrastructure
# =============================================================================

set -euo pipefail

log()      { echo "[deploy-gateway] $*"; }
warn()     { echo "[deploy-gateway][внимание] $*"; }
die()      { echo "[deploy-gateway][ошибка] $*" >&2; exit 1; }
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
  [[ -n "$wan" ]] || die "Не удалось определить WAN-интерфейс по default route."
  echo "$wan"
}

# Извлечь PrivateKey из секции [Interface] конфига wg/awg
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

  log "Устанавливаю базовые утилиты..."
  apt-get install -y \
    ca-certificates curl gnupg lsb-release software-properties-common

  log "Устанавливаю WireGuard..."
  apt-get install -y wireguard

  log "Устанавливаю nftables..."
  apt-get install -y nftables

  if ! grep -R "ppa:amnezia/ppa" /etc/apt/sources.list /etc/apt/sources.list.d/* >/dev/null 2>&1; then
    log "Добавляю PPA AmneziaWG..."
    add-apt-repository -y ppa:amnezia/ppa
    apt-get update -y
  else
    log "PPA AmneziaWG уже добавлен."
  fi

  log "Устанавливаю amneziawg..."
  apt-get install -y amneziawg
  log "Установка пакетов завершена."
}

prepare_dirs() {
  mkdir -p /etc/wireguard         && chmod 700 /etc/wireguard
  mkdir -p /etc/amnezia/amneziawg && chmod 700 /etc/amnezia/amneziawg
  mkdir -p /etc/nftables.d
}

enable_ip_forward() {
  log "Включаю net.ipv4.ip_forward=1..."
  cat > /etc/sysctl.d/99-awg-gateway.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl -p /etc/sysctl.d/99-awg-gateway.conf >/dev/null
}

enable_services_block1() {
  systemctl enable nftables >/dev/null
  systemctl restart nftables
}

show_status_block1() {
  log "Проверка блок 1:"

  # FIX: if/else вместо `cmd && log || die`
  # Паттерн `A && B || C` вызывает C если B вернул ненулевой код, даже если A успешен.
  if command -v wg  >/dev/null 2>&1; then log "  wg: OK";  else die "wg не найден";  fi
  if command -v awg >/dev/null 2>&1; then log "  awg: OK"; else die "awg не найден"; fi
  if command -v nft >/dev/null 2>&1; then log "  nft: OK"; else die "nft не найден"; fi

  local ipf
  ipf="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)"
  if [[ "$ipf" == "1" ]]; then
    log "  ip_forward=1: OK"
  else
    die "ip_forward не равен 1 (текущее значение: '${ipf}')"
  fi

  log "Готово (блок 1)."
}

run_block1() {
  install_packages
  prepare_dirs
  enable_ip_forward
  enable_services_block1
  show_status_block1
}

# -----------------------------------------------------------------------------
# Блок 2: wg-core
# -----------------------------------------------------------------------------

wgcore_require_env() {
  need_env WG_CORE_IFNAME
  need_env WG_CORE_ADDRESS_CIDR
  need_env WG_CORE_LISTEN_PORT
  need_env WG_CORE_MTU
  need_env WG_CORE_PEER_PUBLIC_KEY
  need_env WG_CORE_PEER_ENDPOINT
  need_env WG_CORE_PEER_ALLOWED_IPS
  need_env WG_CORE_PEER_PERSISTENT_KEEPALIVE
  need_env WG_CORE_PRIVATE_KEY_FILE
}

wgcore_install_key() {
  local ifname="$1"
  local src_file="${WG_CORE_PRIVATE_KEY_FILE}"
  local priv="/etc/wireguard/${ifname}.key"
  local pub="/etc/wireguard/${ifname}.pub"

  [[ -f "$src_file" ]] || die "Файл приватного ключа не найден: $src_file"

  local expected_pub
  expected_pub="$(wg pubkey < "$src_file")"

  if [[ -f "$priv" ]]; then
    local current_pub
    current_pub="$(wg pubkey < "$priv" 2>/dev/null || true)"

    if [[ "$current_pub" == "$expected_pub" ]]; then
      log "Ключ wg-core совпадает с оркестратором — пропускаю установку."
      return 0
    fi

    warn "Ключ wg-core на сервере отличается от ключа в state.json!"
    warn "  Текущий pubkey:   ${current_pub:-<не удалось прочитать>}"
    warn "  Ожидаемый pubkey: ${expected_pub}"
    warn "Останавливаю wg-quick@${ifname} и заменяю ключ..."
    systemctl stop "wg-quick@${ifname}" 2>/dev/null || true
  else
    log "Ключ wg-core отсутствует — устанавливаю."
  fi

  install -m 0600 "$src_file" "$priv"
  wg pubkey < "$priv" > "$pub"
  chmod 644 "$pub"
  log "Установлен публичный ключ wg-core: $(cat "$pub")"
}

wgcore_write_config() {
  local ifname="$1"
  local conf="/etc/wireguard/${ifname}.conf"
  local priv="/etc/wireguard/${ifname}.key"
  [[ -f "$priv" ]] || die "Не найден приватный ключ: $priv"

  local allowed
  allowed="$(echo "$WG_CORE_PEER_ALLOWED_IPS" | tr ' ' ',' | sed 's/,,*/,/g;s/^,//;s/,$//')"
  [[ -n "$allowed" ]] || die "WG_CORE_PEER_ALLOWED_IPS пустой."

  log "Пишу конфиг wg-core: $conf"
  cat > "$conf" <<EOF
[Interface]
PrivateKey = $(cat "$priv")
Address = ${WG_CORE_ADDRESS_CIDR}
ListenPort = ${WG_CORE_LISTEN_PORT}
MTU = ${WG_CORE_MTU}

[Peer]
PublicKey = ${WG_CORE_PEER_PUBLIC_KEY}
Endpoint = ${WG_CORE_PEER_ENDPOINT}
AllowedIPs = ${allowed}
PersistentKeepalive = ${WG_CORE_PEER_PERSISTENT_KEEPALIVE}
EOF
  chmod 600 "$conf"
}

wgcore_enable_service() {
  local ifname="$1"
  log "Включаю wg-quick@${ifname}..."
  systemctl enable "wg-quick@${ifname}" >/dev/null
  systemctl restart "wg-quick@${ifname}"
  ip link show "$ifname" >/dev/null 2>&1 || die "Интерфейс ${ifname} не поднялся."
  log "Интерфейс ${ifname} поднят."
}

run_block2() {
  wgcore_require_env
  local ifname="$WG_CORE_IFNAME"
  wgcore_install_key "$ifname"
  wgcore_write_config "$ifname"
  wgcore_enable_service "$ifname"
  log "Готово (блок 2)."
}

# -----------------------------------------------------------------------------
# Блок 3: awgX на Gateway
# -----------------------------------------------------------------------------

awg_require_env() {
  need_env AWG_IFNAME
  need_env AWG_LISTEN_PORT
  need_env AWG_MTU
  need_env AWG_LOCAL_TUN_IP
  need_env AWG_PRIVATE_KEY
  need_env AWG_PEER_PUBLIC_KEY
  need_env AWG_PEER_ENDPOINT
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
      log "Ключ ${ifname} совпадает с оркестратором — обновляю конфиг."
    else
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
Table = off

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
PublicKey = ${AWG_PEER_PUBLIC_KEY}
Endpoint = ${AWG_PEER_ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = ${AWG_PERSISTENT_KEEPALIVE}
AdvancedSecurity = ${AWG_ADVANCED_SECURITY}
EOF
  chmod 600 "$conf"
}

awg_enable_service() {
  local ifname="$1"
  log "Включаю awg-quick@${ifname}..."
  systemctl enable "awg-quick@${ifname}" >/dev/null
  systemctl restart "awg-quick@${ifname}"
  ip link show "$ifname" >/dev/null 2>&1 || die "Интерфейс ${ifname} не поднялся."
  log "Интерфейс ${ifname} поднят."
}

run_block3() {
  awg_require_env
  local ifname="$AWG_IFNAME"
  awg_check_and_write_config "$ifname"
  awg_enable_service "$ifname"
  log "Готово (блок 3)."
}

# -----------------------------------------------------------------------------
# Блок 4: routing table + ip rule + nft NAT + awg-routing.service
# -----------------------------------------------------------------------------

block4_require_env() {
  need_env ROUTING_TABLE_NAME
  need_env ROUTING_TABLE_ID
  need_env ROUTING_RULE_PRIORITY
  need_env WG_CORE_IFNAME
  need_env ACTIVE_AWG_IFNAME
  need_env FAILOVER_AWG_IFACES
}

ensure_rt_table() {
  local name="$1" id="$2"
  local file="/etc/iproute2/rt_tables"

  if grep -Eq "^[[:space:]]*${id}[[:space:]]+${name}[[:space:]]*$" "$file"; then
    log "Таблица '$name' (id=$id) уже существует."
    return 0
  fi
  if grep -Eq "^[[:space:]]*${id}[[:space:]]+" "$file"; then
    die "ID ${id} уже занят в $file другим именем. Нужна ручная проверка."
  fi
  echo "${id} ${name}" >> "$file"
  log "Добавлена таблица: $id $name"
}

ensure_ip_rule() {
  local prio="$1" iif="$2" table_id="$3"

  # del+add вместо grep: формат вывода ip rule show различается в версиях iproute2
  # (lookup может выводиться как имя таблицы или числовой id — grep ненадёжен).
  while ip rule del priority "$prio" 2>/dev/null; do :; done
  ip rule add priority "$prio" iif "$iif" lookup "$table_id"
  log "Установлен ip rule: priority $prio iif $iif lookup $table_id"
}

set_awg_out_default() {
  local table_id="$1" awg_if="$2"
  ip route replace default dev "$awg_if" table "$table_id"
  log "Установлен default route: dev $awg_if table $table_id"
}

ensure_nft_include() {
  local main_conf="/etc/nftables.conf" dir="/etc/nftables.d"
  mkdir -p "$dir"
  if [[ ! -f "$main_conf" ]]; then
    printf '#!/usr/sbin/nft -f\ninclude "%s/*.nft"\n' "$dir" > "$main_conf"
  elif ! grep -qE "include[[:space:]]+\"${dir}/\*\.nft\"" "$main_conf"; then
    printf '\ninclude "%s/*.nft"\n' "$dir" >> "$main_conf"
  fi
}

configure_gateway_nat() {
  local wg_if="$1" awg_if="$2"

  ensure_nft_include

  # FIX: убран `systemctl restart nftables` — он сбрасывает ВСЕ правила и рвёт трафик.
  # Вместо этого: атомарный `nft -f` с flush+add внутри файла.
  # nft применяет файл транзакционно: старые правила таблицы сбрасываются и
  # заменяются новыми без момента "таблицы нет вообще".
  cat > /etc/nftables.d/gw-awg-nat.nft <<EOF
# NAT Gateway: трафик из wg-core → активный awgX
# Управляется gw-failover при переключении

table inet awg-gateway {
  chain postrouting {
    type nat hook postrouting priority 100;
    policy accept;
    iifname "${wg_if}" oifname "${awg_if}" masquerade
  }
}
EOF

  # Удаляем старую таблицу если есть, затем загружаем файл
  nft delete table inet awg-gateway 2>/dev/null || true
  nft -f /etc/nftables.d/gw-awg-nat.nft

  nft list table inet awg-gateway >/dev/null 2>&1 \
    || die "Не удалось применить nft таблицу inet awg-gateway."
  log "nft NAT настроен: iif $wg_if oif $awg_if masquerade"
}

install_awg_routing_service() {
  local prio="$1" iif="$2" table_id="$3" table_name="$4" awg_if="$5"
  local awg_ifaces="$6"   # список всех awgX через пробел для After=

  log "Устанавливаю awg-routing.service..."

  cat > /usr/local/sbin/awg-routing-up.sh <<EOF
#!/usr/bin/env bash
# Восстанавливает policy routing для awg-out после reboot
# Генерируется deploy-gateway.sh — не редактировать вручную
set -euo pipefail

PRIO="${prio}"
IIF="${iif}"
TABLE_ID="${table_id}"
TABLE_NAME="${table_name}"
AWG_IF="${awg_if}"

# Ждём появления интерфейсов (максимум 30 сек — запасной вариант)
for i in \$(seq 1 30); do
  ip link show "\$IIF"    >/dev/null 2>&1 && \
  ip link show "\$AWG_IF" >/dev/null 2>&1 && break
  sleep 1
done

ip link show "\$IIF"    >/dev/null 2>&1 || { echo "Нет интерфейса \$IIF";    exit 1; }
ip link show "\$AWG_IF" >/dev/null 2>&1 || { echo "Нет интерфейса \$AWG_IF"; exit 1; }

# del+add — надёжная идемпотентность (grep по ip rule show ненадёжен)
while ip rule del priority "\$PRIO" 2>/dev/null; do :; done
ip rule add priority "\$PRIO" iif "\$IIF" lookup "\$TABLE_ID"

# replace — всегда идемпотентен
ip route replace default dev "\$AWG_IF" table "\$TABLE_ID"

echo "[awg-routing] ip rule priority \$PRIO + ip route table \$TABLE_NAME восстановлены."
EOF
  chmod 755 /usr/local/sbin/awg-routing-up.sh

  # FIX: добавляем After= для каждого awg-quick@awgX чтобы routing поднимался
  # строго после туннелей, а не надеяться только на 30-сек цикл ожидания.
  local after_units="network-online.target wg-quick@${iif}.service"
  for awg_if_item in $awg_ifaces; do
    after_units+=" awg-quick@${awg_if_item}.service"
  done

  cat > /etc/systemd/system/awg-routing.service <<EOF
[Unit]
Description=AWG policy routing (ip rule + ip route table awg-out)
After=${after_units}
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/awg-routing-up.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable awg-routing >/dev/null
  systemctl restart awg-routing
  log "awg-routing.service установлен и запущен."
}

# Удаляем awg-интерфейсы которых больше нет в конфигурации.
# Вызывается из блока 4 — после того как все нужные awgX уже установлены.
cleanup_stale_awg() {
  local keep_ifaces="$1"  # пробел-разделённый список нужных (напр. "awg0 awg1")

  # Смотрим все существующие awgX-интерфейсы в системе
  local existing
  existing=$(ip link show type amneziawg 2>/dev/null     | grep -oP '^\d+:\s+\Kawg\d+' || true)

  for ifname in $existing; do
    # Проверяем входит ли интерфейс в список нужных
    local needed=0
    for keep in $keep_ifaces; do
      [[ "$ifname" == "$keep" ]] && needed=1 && break
    done

    if [[ $needed -eq 0 ]]; then
      warn "Удаляю устаревший интерфейс $ifname (отсутствует в конфигурации)..."
      systemctl stop  "awg-quick@${ifname}" 2>/dev/null || true
      systemctl disable "awg-quick@${ifname}" 2>/dev/null || true
      awg-quick down "$ifname" 2>/dev/null || true
      local conf="/etc/amnezia/amneziawg/${ifname}.conf"
      if [[ -f "$conf" ]]; then
        mv "$conf" "${conf}.removed.$(date +%Y%m%d%H%M%S)"
        log "  Конфиг перемещён: ${conf}.removed.*"
      fi
      log "  $ifname удалён."
    fi
  done
}

run_block4() {
  block4_require_env

  local tname="$ROUTING_TABLE_NAME" tid="$ROUTING_TABLE_ID"
  local prio="$ROUTING_RULE_PRIORITY"
  local wg_if="$WG_CORE_IFNAME" awg_if="$ACTIVE_AWG_IFNAME"
  local awg_ifaces="$FAILOVER_AWG_IFACES"

  ip link show "$wg_if"  >/dev/null 2>&1 || die "Интерфейс wg-core не найден: $wg_if"
  ip link show "$awg_if" >/dev/null 2>&1 || die "Интерфейс active awg не найден: $awg_if"

  # Удаляем устаревшие awg-интерфейсы которых нет в новой конфигурации
  cleanup_stale_awg "$awg_ifaces"

  ensure_rt_table "$tname" "$tid"
  ensure_ip_rule "$prio" "$wg_if" "$tid"
  set_awg_out_default "$tid" "$awg_if"
  configure_gateway_nat "$wg_if" "$awg_if"
  install_awg_routing_service "$prio" "$wg_if" "$tid" "$tname" "$awg_if" "$awg_ifaces"

  log "Готово (блок 4)."
}

# -----------------------------------------------------------------------------
# Блок 5: failover
# -----------------------------------------------------------------------------

block5_require_env() {
  need_env ROUTING_TABLE_NAME
  need_env ROUTING_TABLE_ID
  need_env WG_CORE_IFNAME
  need_env FAILOVER_AWG_IFACES
  need_env HEALTH_INTERVAL_SEC
  need_env FAIL_THRESHOLD
  need_env RECOVERY_THRESHOLD
  need_env HANDSHAKE_MAX_AGE_SEC
  need_env FAILOVER_SCRIPT
}

install_failover_files() {
  log "Устанавливаю gw-failover.sh из $FAILOVER_SCRIPT..."
  [[ -f "$FAILOVER_SCRIPT" ]] || die "Файл не найден: $FAILOVER_SCRIPT"
  install -m 0755 "$FAILOVER_SCRIPT" /usr/local/sbin/gw-failover.sh
  log "gw-failover.sh установлен."

  install -m 0644 /dev/stdin /etc/systemd/system/gw-failover.service <<'EOF'
[Unit]
Description=Gateway AWG failover (switch awg-out default route + nft NAT)
After=network-online.target wg-quick@wg-core.service nftables.service awg-routing.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/default/gw-failover
ExecStart=/usr/local/sbin/gw-failover.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  log "gw-failover.service установлен."
}

write_failover_env() {
  log "Пишу /etc/default/gw-failover..."

  local peer_ips=""
  for var in $(compgen -v | grep "^PEER_TUN_IP_"); do
    peer_ips+="${var}=${!var}"$'\n'
  done

  cat > /etc/default/gw-failover <<EOF
# Конфигурация gw-failover
# Генерируется deploy-gateway.sh — не редактировать вручную

ROUTING_TABLE_NAME=${ROUTING_TABLE_NAME}
ROUTING_TABLE_ID=${ROUTING_TABLE_ID}
WG_CORE_IFNAME=${WG_CORE_IFNAME}

FAILOVER_AWG_IFACES="${FAILOVER_AWG_IFACES}"

HEALTH_INTERVAL_SEC=${HEALTH_INTERVAL_SEC}
FAIL_THRESHOLD=${FAIL_THRESHOLD}
RECOVERY_THRESHOLD=${RECOVERY_THRESHOLD}
HANDSHAKE_MAX_AGE_SEC=${HANDSHAKE_MAX_AGE_SEC}

ENABLE_PING_CHECK=0

${peer_ips}
EOF
  chmod 600 /etc/default/gw-failover
}

enable_failover_service() {
  log "Включаю gw-failover..."
  systemctl daemon-reload
  systemctl enable gw-failover >/dev/null
  systemctl restart gw-failover
  systemctl status gw-failover --no-pager | sed -n '1,12p' || true
}

run_block5() {
  block5_require_env
  install_failover_files
  write_failover_env
  enable_failover_service
  log "Готово (блок 5)."
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------

main() {
  require_root
  # Базовые утилиты — должны быть до установки пакетов
  need_cmd ip
  need_cmd awk
  need_cmd systemctl
  need_cmd sysctl

  local stage="${GATEWAY_STAGE:-1}"
  case "$stage" in
    1) run_block1 ;;                              # устанавливает wg, awg, nft
    2) need_cmd wg;  run_block2 ;;               # wg нужен в блоке 2
    3) need_cmd awg; run_block3 ;;               # awg нужен в блоке 3
    4) need_cmd nft; run_block4 ;;               # nft нужен в блоке 4
    5) run_block5 ;;
    *) die "Неизвестный GATEWAY_STAGE: $stage (доступно: 1..5)" ;;
  esac
}

main "$@"
