#!/usr/bin/env bash
set -euo pipefail

# ===== Настройки по умолчанию =====
WG_IMAGE_DEFAULT="weejewel/wg-easy:latest"
WG_PORT_UDP_DEFAULT="51820"
WG_PORT_UI_DEFAULT="51821"

# ===== Использование =====
usage() {
  cat <<'EOF'
Использование:
  bash master.sh --password 'PASS' [--count 30] [--country RU] [--host auto] [--image weejewel/wg-easy:latest] [--no-clients] [--refresh-endpoints]

Примеры:
  bash master.sh --password 'Qwerty123!' --count 30 --country RU
  bash master.sh --password 'Qwerty123!' --count 10
  bash master.sh --password 'Qwerty123!' --no-clients
  bash master.sh --password 'Qwerty123!' --country PL --refresh-endpoints --count 3

Параметры:
  --password           Пароль для web-панели wg-easy (обязательно)
  --count              Сколько клиентов создать (по умолчанию 0)
  --country            Код страны (RU/PL/NL/DE...). Если не задан — попробует определить по IP
  --host               WG_HOST (auto или конкретный IP/домен). По умолчанию auto
  --image              Docker image wg-easy (по умолчанию weejewel/wg-easy:latest)
  --no-clients         Не создавать клиентов (равносильно --count 0)
  --refresh-endpoints  Полный сброс wg-easy и создание новых клиентов под новый WG_HOST
EOF
}

PASSWORD=""
COUNT=0
COUNTRY=""
WG_HOST="auto"
WG_IMAGE="$WG_IMAGE_DEFAULT"
NO_CLIENTS=0
REFRESH_ENDPOINTS=0

STATE_DIR="/root/.wg-easy-meta"
STATE_FILE="$STATE_DIR/wg_host.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password) PASSWORD="${2:-}"; shift 2;;
    --count) COUNT="${2:-0}"; shift 2;;
    --country) COUNTRY="${2:-}"; shift 2;;
    --host) WG_HOST="${2:-auto}"; shift 2;;
    --image) WG_IMAGE="${2:-$WG_IMAGE_DEFAULT}"; shift 2;;
    --no-clients) NO_CLIENTS=1; shift 1;;
    --refresh-endpoints) REFRESH_ENDPOINTS=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Неизвестный параметр: $1"; usage; exit 1;;
  esac
done

if [[ -z "$PASSWORD" ]]; then
  echo "Ошибка: --password обязателен"
  usage
  exit 1
fi

if [[ "$NO_CLIENTS" == "1" ]]; then
  COUNT=0
fi

# ===== Функции =====
log() { echo -e "\n[master] $*\n"; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Запусти от root (или через sudo)."
    exit 1
  fi
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

get_saved_host() {
  [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || true
}

save_host() {
  ensure_state_dir
  printf '%s\n' "$WG_HOST" > "$STATE_FILE"
}

get_public_ip() {
  local ip=""
  ip="$(curl -fsS https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -fsS https://icanhazip.com 2>/dev/null | tr -d '\n' || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(curl -fsS https://ifconfig.me 2>/dev/null || true)"
  fi
  echo "$ip"
}

get_country_code() {
  local cc=""
  cc="$(curl -fsS https://ipapi.co/country 2>/dev/null | tr -d '\n' || true)"
  if [[ ! "$cc" =~ ^[A-Z]{2}$ ]]; then
    cc=""
  fi
  echo "$cc"
}

get_next_index() {
  local jar="$1"
  local json
  local max=0
  local name
  local num

  json="$(api_list_clients "$jar")"

  while IFS= read -r name; do
    num="${name##*-}"
    if [[ "$num" =~ ^[0-9]+$ ]]; then
      if (( num > max )); then
        max=$num
      fi
    fi
  done < <(echo "$json" | jq -r '.[].name')

  echo $((max + 1))
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker уже установлен: $(docker --version)"
    return
  fi

  log "Ставлю Docker (get.docker.com)..."
  curl -fsSL https://get.docker.com | sh

  systemctl enable docker
  systemctl start docker
  log "Docker установлен: $(docker --version)"
}

install_tools() {
  log "Проверяю утилиты..."

  need_install=()

  command -v curl >/dev/null 2>&1 || need_install+=("curl")
  command -v jq >/dev/null 2>&1 || need_install+=("jq")
  command -v zip >/dev/null 2>&1 || need_install+=("zip")

  if [ ${#need_install[@]} -eq 0 ]; then
    log "Все утилиты уже установлены."
    return
  fi

  log "Ставлю: ${need_install[*]}"
  apt update -y
  apt install -y "${need_install[@]}"
}

wipe_wg_easy_data() {
  log "Полностью очищаю данные wg-easy..."
  docker rm -f wg-easy >/dev/null 2>&1 || true
  rm -rf /root/.wg-easy
  mkdir -p /root/.wg-easy
}

run_wg_easy() {
  local udp_port="$WG_PORT_UDP_DEFAULT"
  local ui_port="$WG_PORT_UI_DEFAULT"

  log "Поднимаю wg-easy контейнер: $WG_IMAGE"

  if docker ps -a --format '{{.Names}}' | grep -qx 'wg-easy'; then
    log "Контейнер wg-easy уже существует — пересоздаю..."
    docker rm -f wg-easy >/dev/null 2>&1 || true
  fi

  mkdir -p /root/.wg-easy

  docker run -d \
    --name=wg-easy \
    -e WG_HOST="$WG_HOST" \
    -e PASSWORD="$PASSWORD" \
    -v /root/.wg-easy:/etc/wireguard \
    -p "${udp_port}:51820/udp" \
    -p "${ui_port}:51821/tcp" \
    --cap-add=NET_ADMIN \
    --cap-add=SYS_MODULE \
    --sysctl="net.ipv4.conf.all.src_valid_mark=1" \
    --sysctl="net.ipv4.ip_forward=1" \
    --restart unless-stopped \
    "$WG_IMAGE"

  log "wg-easy запущен. UI: http://${WG_HOST}:${ui_port}"
}

wait_ui() {
  log "Жду доступности wg-easy UI на localhost:51821 ..."
  for i in {1..60}; do
    if curl -fsS "http://127.0.0.1:51821" >/dev/null 2>&1; then
      log "UI доступен."
      return
    fi
    sleep 1
  done
  echo "UI так и не поднялся за 60 секунд. Проверь: docker logs wg-easy"
  exit 1
}

recreate_wg_easy_if_needed() {
  local old_host=""
  old_host="$(get_saved_host)"

  if [[ "$REFRESH_ENDPOINTS" == "1" ]]; then
    log "Запрошен полный refresh endpoint'ов.
  Старый WG_HOST: ${old_host:-<empty>}
  Новый WG_HOST:  $WG_HOST"
    return
  fi

  if [[ -z "$old_host" || "$old_host" != "$WG_HOST" ]]; then
    log "WG_HOST изменился.
  Старый: ${old_host:-<empty>}
  Новый:  $WG_HOST"
    run_wg_easy
    wait_ui
    save_host
  else
    log "WG_HOST не изменился: $WG_HOST"
    if ! curl -fsS "http://127.0.0.1:51821" >/dev/null 2>&1; then
      log "UI недоступен, пересоздаю контейнер wg-easy..."
      run_wg_easy
      wait_ui
    fi
  fi
}

api_login_cookie() {
  local jar="$1"
  rm -f "$jar"

  curl -fsS -c "$jar" -b "$jar" \
    -H "Content-Type: application/json" \
    -X POST "http://127.0.0.1:51821/api/session" \
    -d "{\"password\":\"$PASSWORD\"}" >/dev/null
}

api_create_client() {
  local jar="$1"
  local name="$2"

  curl -fsS -c "$jar" -b "$jar" \
    -H "Content-Type: application/json" \
    -X POST "http://127.0.0.1:51821/api/wireguard/client" \
    -d "{\"name\":\"$name\"}" >/dev/null
}

api_list_clients() {
  local jar="$1"
  curl -fsS -c "$jar" -b "$jar" \
    "http://127.0.0.1:51821/api/wireguard/client"
}

download_client_config() {
  local jar="$1"
  local id="$2"
  local out="$3"

  local urls=(
    "http://127.0.0.1:51821/api/wireguard/client/${id}/configuration"
    "http://127.0.0.1:51821/api/wireguard/client/${id}/config"
    "http://127.0.0.1:51821/api/wireguard/client/${id}/config-file"
  )

  for u in "${urls[@]}"; do
    if curl -fsS -c "$jar" -b "$jar" "$u" -o "$out" >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

create_clients_and_download() {
  local jar="$1"
  local outdir="$2"

  mkdir -p "$outdir"
  find "$outdir" -maxdepth 1 -type f -name "*.conf" -delete

  log "Создаю $COUNT клиентов и скачиваю конфиги..."

  local start_index
  start_index="$(get_next_index "$jar")"

  local created_names=()

  for ((i=0; i<COUNT; i++)); do
    local idx name
    idx=$((start_index + i))
    name="${COUNTRY}_${WG_HOST//./_}-${idx}"
    created_names+=("$name")

    echo "[+] create: $name"
    api_create_client "$jar" "$name" || {
      echo "Не получилось создать клиента через API. Проверь версию wg-easy / авторизацию."
      echo "Логи: docker logs wg-easy"
      exit 1
    }
  done

  local json
  json="$(api_list_clients "$jar")"
  echo "$json" | jq -e . >/dev/null 2>&1 || {
    echo "API вернул не-JSON. Проверь авторизацию/версию wg-easy."
    exit 1
  }

  local name id outfile
  for name in "${created_names[@]}"; do
    id="$(echo "$json" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -n1)"

    if [[ -z "$id" || "$id" == "null" ]]; then
      echo "Не нашёл id для $name в списке клиентов."
      exit 1
    fi

    outfile="${outdir}/${name}.conf"
    if download_client_config "$jar" "$id" "$outfile"; then
      echo "[✓] saved: $outfile"
    else
      echo "[!] не удалось скачать конфиг для $name (id=$id). Возможно другой endpoint в твоей версии."
      exit 1
    fi
  done
}

  local json
  json="$(api_list_clients "$jar")"
  echo "$json" | jq -e . >/dev/null 2>&1 || {
    echo "API вернул не-JSON. Проверь авторизацию/версию wg-easy."
    exit 1
  }

  for ((i=1;i<=COUNT;i++)); do
    local name id outfile
    name="${COUNTRY}_${WG_HOST//./_}-${i}"
    id="$(echo "$json" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -n1)"

    if [[ -z "$id" || "$id" == "null" ]]; then
      echo "Не нашёл id для $name в списке клиентов."
      exit 1
    fi

    outfile="${outdir}/${name}.conf"
    if download_client_config "$jar" "$id" "$outfile"; then
      echo "[✓] saved: $outfile"
    else
      echo "[!] не удалось скачать конфиг для $name (id=$id). Возможно другой endpoint в твоей версии."
      exit 1
    fi
  done
}

make_zip() {
  local outdir="$1"
  local zip_name="$2"

  mkdir -p /root/wg-configs
  cd /root/wg-configs
  rm -f "$zip_name"
  zip -r "$zip_name" "$(basename "$outdir")" >/dev/null
  log "ZIP готов: /root/wg-configs/$zip_name"
}

# ===== Выполнение =====
need_root
install_tools
install_docker

if [[ "$WG_HOST" == "auto" ]]; then
  log "Определяю внешний IP..."
  WG_HOST="$(get_public_ip)"
  if [[ -z "$WG_HOST" ]]; then
    echo "Не удалось определить внешний IP. Укажи вручную: --host X.X.X.X"
    exit 1
  fi
fi

if [[ -z "$COUNTRY" ]]; then
  log "Пробую определить страну по IP..."
  COUNTRY="$(get_country_code)"
  if [[ -z "$COUNTRY" ]]; then
    COUNTRY="XX"
  fi
fi

log "Параметры:
  WG_HOST  = $WG_HOST
  COUNTRY  = $COUNTRY
  COUNT    = $COUNT
  IMAGE    = $WG_IMAGE
  REFRESH  = $REFRESH_ENDPOINTS
"

recreate_wg_easy_if_needed

if [[ "$REFRESH_ENDPOINTS" == "1" ]]; then
  if [[ "$COUNT" -le 0 ]]; then
    echo "Для --refresh-endpoints нужно указать --count > 0"
    exit 1
  fi

  wipe_wg_easy_data
  run_wg_easy
  wait_ui
  save_host

  JAR="/tmp/wg-easy.cookie"
  api_login_cookie "$JAR"

  OUTDIR="/root/wg-configs/${COUNTRY}_${WG_HOST//./_}"
  ZIP_NAME="${COUNTRY}_${WG_HOST//./_}.zip"

  create_clients_and_download "$JAR" "$OUTDIR"
  make_zip "$OUTDIR" "$ZIP_NAME"

  log "Endpoint'ы обновлены: старые клиенты полностью удалены, новые созданы.
Папка конфигов: $OUTDIR
WG UI: http://${WG_HOST}:51821
ZIP готов: /root/wg-configs/$ZIP_NAME
"
  exit 0
fi

if [[ "$COUNT" -le 0 ]]; then
  log "Генерация клиентов выключена (COUNT=0). Готово."
  echo "WG UI: http://${WG_HOST}:51821"
  exit 0
fi

JAR="/tmp/wg-easy.cookie"
api_login_cookie "$JAR"

OUTDIR="/root/wg-configs/${COUNTRY}_${WG_HOST//./_}"
ZIP_NAME="${COUNTRY}_${WG_HOST//./_}.zip"

create_clients_and_download "$JAR" "$OUTDIR"
make_zip "$OUTDIR" "$ZIP_NAME"

save_host

log "Готово.
Папка конфигов: $OUTDIR
WG UI: http://${WG_HOST}:51821
ZIP готов: /root/wg-configs/$ZIP_NAME
"
