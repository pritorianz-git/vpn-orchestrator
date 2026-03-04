#!/usr/bin/env bash
# =============================================================================
# gw-failover.sh — демон мониторинга и автоматического failover AWG-туннелей
# =============================================================================
#
# НАЗНАЧЕНИЕ
#   Работает как постоянный systemd-сервис (Type=simple) на Gateway.
#   В цикле проверяет здоровье всех awgX-туннелей к Exit-серверам и при
#   деградации активного туннеля автоматически переключает трафик на
#   следующий живой туннель:
#     - меняет default route в таблице awg-out
#     - обновляет nft NAT правило (iif wg-core → oif awgX)
#     - записывает текущий активный интерфейс в /run/gw-failover.state
#
# ПРИНЦИП РАБОТЫ
#   Non-preemptive failover: переключение происходит только при деградации
#   активного интерфейса. Обратного автопереключения нет — стабильность
#   важнее симметрии.
#
#   Алгоритм проверки (каждые HEALTH_INTERVAL_SEC секунд):
#     1. Для каждого awgX получить возраст последнего handshake
#     2. Если ENABLE_PING_CHECK=1 — дополнительно пинговать PEER_TUN_IP_awgX
#     3. Накапливать счётчики fail_cnt / ok_cnt
#     4. fail_cnt[active] >= FAIL_THRESHOLD  → переключиться на best
#        (best = любой интерфейс с ok_cnt >= RECOVERY_THRESHOLD)
#
#   Состояния интерфейса: unknown → healthy / degraded
#   Логирование: только при смене состояния (не спамит при стабильной работе)
#
# КОНФИГУРАЦИЯ
#   Читается из EnvironmentFile=/etc/default/gw-failover (генерируется
#   deploy-gateway.sh блок 5). Переменные:
#
#   ROUTING_TABLE_NAME      — имя таблицы маршрутизации (awg-out)
#   ROUTING_TABLE_ID        — числовой ID таблицы (200)
#   WG_CORE_IFNAME          — входящий интерфейс от клиентов (wg-core)
#   FAILOVER_AWG_IFACES     — список туннелей через пробел ("awg0 awg1 ...")
#   HEALTH_INTERVAL_SEC     — интервал проверки в секундах (10)
#   FAIL_THRESHOLD          — порог срабатывания failover (3 подряд)
#   RECOVERY_THRESHOLD      — порог восстановления резервного (2 подряд)
#   HANDSHAKE_MAX_AGE_SEC   — максимальный возраст handshake (180)
#   ENABLE_PING_CHECK       — 0/1, дополнительный ping-тест (по умолчанию 0)
#   PEER_TUN_IP_awgX        — IP Exit в туннеле для ping (если ENABLE_PING_CHECK=1)
#
# ФАЙЛЫ
#   /etc/default/gw-failover        — конфигурация (читается при старте)
#   /etc/nftables.d/gw-awg-nat.nft  — NAT правило (перезаписывается при switch)
#   /run/gw-failover.state          — текущий активный интерфейс
#
# ДИАГНОСТИКА
#   journalctl -u gw-failover -f             — live лог
#   cat /run/gw-failover.state               — текущий активный awgX
#   systemctl status gw-failover             — статус сервиса
#
# ВАЖНЫЕ ОСОБЕННОСТИ
#   - При старте после reboot: первые ~2 мин handshake может быть "холодным"
#     (keepalive ещё не сработал). Failover не переключится если awg1 тоже
#     не прошёл RECOVERY_THRESHOLD проверок.
#   - Атомарное обновление nft: flush table + nft -f (без разрыва трафика)
#   - Ключи читаются из конфига awgX.conf через awk при каждом цикле
#
# АВТОР / ВЕРСИЯ
#   Версия:  v1.0
#   Проект:  AWG VPN Infrastructure
# =============================================================================

set -euo pipefail

log()      { echo "[gw-failover] $*"; }
die()      { echo "[gw-failover][ошибка] $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"; }

# Убираем завершающие '=' у base64 ключа для нормализации перед сравнением
normalize_key() {
  local k="${1:-}"
  k="${k#"${k%%[![:space:]]*}"}"   # ltrim
  k="${k%"${k##*[![:space:]]}"}"   # rtrim
  while [[ "$k" == *"=" ]]; do k="${k%=}"; done
  echo "$k"
}

# --- Загрузка конфигурации ---
CFG_FILE="${CFG_FILE:-/etc/default/gw-failover}"
if [[ -f "$CFG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CFG_FILE"
else
  die "Не найден файл конфигурации: $CFG_FILE"
fi

# --- Обязательные параметры ---
: "${ROUTING_TABLE_NAME:?}"
: "${ROUTING_TABLE_ID:?}"
: "${WG_CORE_IFNAME:?}"
: "${FAILOVER_AWG_IFACES:?}"
: "${HEALTH_INTERVAL_SEC:?}"
: "${FAIL_THRESHOLD:?}"
: "${RECOVERY_THRESHOLD:?}"
: "${HANDSHAKE_MAX_AGE_SEC:?}"

# --- Внутренние файлы ---
NFT_RULES_FILE="${NFT_RULES_FILE:-/etc/nftables.d/gw-awg-nat.nft}"
STATE_FILE="${STATE_FILE:-/run/gw-failover.state}"

need_cmd ip
need_cmd awk
need_cmd date
need_cmd ping
need_cmd nft
need_cmd awg

# --- Получаем peer public key из конфига awgX ---
# FIX: -F' *= *' вместо -F'=' — корректно парсит строки вида "PublicKey = base64key="
get_peer_pubkey_from_conf() {
  local ifname="$1"
  local conf="/etc/amnezia/amneziawg/${ifname}.conf"
  [[ -f "$conf" ]] || die "Нет конфига: $conf"

  awk -F' *= *' '
    /^\[Peer\]/  { inpeer=1; next }
    /^\[/        { inpeer=0 }
    inpeer && $1 == "PublicKey" { gsub(/[[:space:]]/, "", $2); print $2; exit }
  ' "$conf"
}

# --- Peer tunnel IP (опционально) ---
# Возвращает IP только если ENABLE_PING_CHECK=1, иначе пустую строку.
# PEER_TUN_IP_awgX задаёт адрес для ping, но без флага он игнорируется.
get_peer_tun_ip() {
  local ifname="$1"
  [[ "${ENABLE_PING_CHECK:-0}" == "1" ]] || { echo ""; return 0; }
  local var="PEER_TUN_IP_${ifname}"
  echo "${!var:-}"
}

# --- Возраст handshake в секундах (999999 если нет данных) ---
get_handshake_age_sec() {
  local ifname="$1"
  local peer_pub="$2"

  local want
  want="$(normalize_key "$peer_pub")"

  local out
  if ! out="$(awg show "$ifname" latest-handshakes 2>/dev/null)"; then
    echo 999999; return 0
  fi

  local epoch
  epoch="$(
    echo "$out" | awk -v want="$want" '
      {
        k = $1
        while (k ~ /=$/) sub(/=$/, "", k)
        if (k == want) { print $2; exit }
      }
    '
  )"

  if [[ -z "${epoch:-}" || "$epoch" == "0" ]]; then
    echo 999999; return 0
  fi

  local now
  now="$(date +%s)"
  (( now >= epoch )) && echo $(( now - epoch )) || echo 999999
}

# --- Проверка здоровья интерфейса ---
# Возвращает 0 (здоров) или 1 (нездоров).
# Записывает причину в глобальную переменную HEALTH_REASON.
HEALTH_REASON=""
check_iface_health() {
  local ifname="$1" peer_pub="$2" peer_tun_ip="$3"

  local age
  age="$(get_handshake_age_sec "$ifname" "$peer_pub")"

  if (( age > HANDSHAKE_MAX_AGE_SEC )); then
    HEALTH_REASON="handshake_age=${age}s (max=${HANDSHAKE_MAX_AGE_SEC}s)"
    return 1
  fi

  if [[ -n "$peer_tun_ip" ]]; then
    if ! ping -I "$ifname" -c 1 -W 1 "$peer_tun_ip" >/dev/null 2>&1; then
      HEALTH_REASON="ping_fail(peer=${peer_tun_ip})"
      return 1
    fi
  fi

  HEALTH_REASON="ok(handshake_age=${age}s)"
  return 0
}

# --- Текущий активный awgX из таблицы awg-out ---
get_active_iface_from_table() {
  ip route show table "$ROUTING_TABLE_ID" default 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

apply_default_route() {
  local ifname="$1"
  ip route replace default dev "$ifname" table "$ROUTING_TABLE_ID"
}

apply_nft_nat() {
  local ifname="$1"

  # FIX: атомарная замена через flush + add внутри одного nft -f.
  # Убран паттерн `nft delete table; nft -f` — между ними таблица отсутствует
  # и трафик проваливается (race condition).
  cat > "$NFT_RULES_FILE" <<EOF
# NAT Gateway: трафик из wg-core → активный awgX
# Управляется gw-failover — не редактировать вручную

table inet awg-gateway {
  chain postrouting {
    type nat hook postrouting priority 100;
    policy accept;
    iifname "${WG_CORE_IFNAME}" oifname "${ifname}" masquerade
  }
}
EOF

  # flush table удаляет правила внутри таблицы атомарно, затем add добавляет новые.
  # Если таблица не существует — создаём её без flush.
  if nft list table inet awg-gateway >/dev/null 2>&1; then
    nft flush table inet awg-gateway
  fi
  nft -f "$NFT_RULES_FILE"
}

switch_active() {
  local new_if="$1"
  log "Переключаю активный интерфейс на ${new_if}..."
  apply_default_route "$new_if"
  apply_nft_nat "$new_if"
  echo "active=${new_if}" > "$STATE_FILE"
  log "Активный интерфейс: ${new_if}"
}

pick_first_existing_iface() {
  local ifaces="$1"
  local ifname
  for ifname in $ifaces; do
    if ip link show "$ifname" >/dev/null 2>&1; then
      echo "$ifname"; return 0
    fi
  done
  echo ""; return 0
}

main_loop() {
  log "Старт."
  log "Таблица: ${ROUTING_TABLE_NAME} (${ROUTING_TABLE_ID}), iif: ${WG_CORE_IFNAME}"
  log "Интерфейсы: ${FAILOVER_AWG_IFACES}"
  log "Параметры: interval=${HEALTH_INTERVAL_SEC}s fail=${FAIL_THRESHOLD} recovery=${RECOVERY_THRESHOLD} handshake_max=${HANDSHAKE_MAX_AGE_SEC}s"

  ip link show "$WG_CORE_IFNAME" >/dev/null 2>&1 \
    || die "Не найден интерфейс wg-core: ${WG_CORE_IFNAME}"

  local active
  active="$(get_active_iface_from_table || true)"
  if [[ -z "${active:-}" ]]; then
    active="$(pick_first_existing_iface "$FAILOVER_AWG_IFACES")"
    [[ -n "$active" ]] || die "Не удалось выбрать стартовый awg-интерфейс."
    switch_active "$active"
  else
    log "Текущий активный интерфейс: ${active}"
    echo "active=${active}" > "$STATE_FILE"
  fi

  declare -A fail_cnt ok_cnt iface_state

  # FIX: инициализируем счётчики и state для всех интерфейсов.
  # state="unknown" — не "healthy" и не "degraded", чтобы не было
  # ложных логов "восстановился" при первом запуске.
  local ifname
  for ifname in $FAILOVER_AWG_IFACES; do
    fail_cnt["$ifname"]=0
    ok_cnt["$ifname"]=0
    iface_state["$ifname"]="unknown"
  done

  while true; do
    active="$(get_active_iface_from_table || true)"
    if [[ -z "${active:-}" && -f "$STATE_FILE" ]]; then
      active="$(awk -F'=' '/^active=/{print $2}' "$STATE_FILE" | tr -d ' ')"
    fi

    # FIX: local вынесен из тела цикла
    local best="" active_reason=""
    local peer_pub peer_tun_ip

    for ifname in $FAILOVER_AWG_IFACES; do
      if ! ip link show "$ifname" >/dev/null 2>&1; then
        # Интерфейс отсутствует — считаем failed только если он активный
        if [[ "$ifname" == "${active:-}" ]]; then
          fail_cnt["$ifname"]=$(( fail_cnt["$ifname"] + 1 ))
          ok_cnt["$ifname"]=0
        fi
        continue
      fi

      peer_pub="$(get_peer_pubkey_from_conf "$ifname")"
      peer_tun_ip="$(get_peer_tun_ip "$ifname")"

      if check_iface_health "$ifname" "$peer_pub" "$peer_tun_ip"; then
        ok_cnt["$ifname"]=$(( ok_cnt["$ifname"] + 1 ))
        fail_cnt["$ifname"]=0
      else
        fail_cnt["$ifname"]=$(( fail_cnt["$ifname"] + 1 ))
        ok_cnt["$ifname"]=0
      fi

      [[ "$ifname" == "${active:-}" ]] && active_reason="$HEALTH_REASON"

      if (( ok_cnt["$ifname"] >= RECOVERY_THRESHOLD )); then
        [[ -z "$best" ]] && best="$ifname"
      fi
    done

    if [[ -n "${active:-}" ]]; then
      if (( fail_cnt["$active"] >= FAIL_THRESHOLD )); then

        # FIX: логируем деградацию только при переходе из non-degraded состояния
        if [[ "${iface_state[$active]}" != "degraded" ]]; then
          log "Активный ${active} деградировал: ${active_reason}"
          iface_state["$active"]="degraded"
        fi

        if [[ -n "$best" && "$best" != "$active" ]]; then
          log "Переключаюсь на ${best}."
          switch_active "$best"
          iface_state["$best"]="healthy"
          fail_cnt["$best"]=0
          ok_cnt["$best"]=0
        fi

      else
        # FIX: логируем восстановление только если ранее был degraded (не unknown)
        if [[ "${iface_state[$active]}" == "degraded" ]]; then
          log "Активный ${active} восстановился: ${active_reason}"
          iface_state["$active"]="healthy"
        elif [[ "${iface_state[$active]}" == "unknown" ]]; then
          iface_state["$active"]="healthy"
        fi
      fi

    else
      # Нет активного — выбираем лучший или первый доступный
      if [[ -n "$best" ]]; then
        switch_active "$best"
      else
        local fallback
        fallback="$(pick_first_existing_iface "$FAILOVER_AWG_IFACES")"
        [[ -n "$fallback" ]] && switch_active "$fallback"
      fi
    fi

    sleep "$HEALTH_INTERVAL_SEC"
  done
}

main_loop
