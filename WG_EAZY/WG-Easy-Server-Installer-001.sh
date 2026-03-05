#!/usr/bin/env bash
set -euo pipefail

# ===== Настройки по умолчанию =====
WG_IMAGE_DEFAULT="weejewel/wg-easy:latest"     # твой привычный образ
WG_PORT_UDP_DEFAULT="51820"
WG_PORT_UI_DEFAULT="51821"

# ===== Использование =====
usage() {
  cat <<'EOF'
Использование:
  bash master.sh --password 'PASS' [--count 30] [--country RU] [--host auto] [--image weejewel/wg-easy:latest] [--no-clients]

Примеры:
  bash master.sh --password 'Qwerty123!' --count 30 --country RU
  bash master.sh --password 'Qwerty123!' --count 10            # страну определит сам
  bash master.sh --password 'Qwerty123!' --no-clients          # только установка wg-easy

Параметры:
  --password   Пароль для web-панели wg-easy (обязательно)
  --count      Сколько клиентов создать (по умолчанию 0)
  --country    Код страны (RU/PL/NL/DE...). Если не задан — попробует определить по IP.
  --host       WG_HOST (auto или конкретный IP/домен). По умолчанию auto.
  --image      Docker image wg-easy (по умолчанию weejewel/wg-easy:latest)
  --no-clients Не создавать клиентов (равносильно --count 0)
EOF
}

PASSWORD=""
COUNT=0
COUNTRY=""
WG_HOST="auto"
WG_IMAGE="$WG_IMAGE_DEFAULT"
NO_CLIENTS=0
ADD=0
MAKE_ZIP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password) PASSWORD="${2:-}"; shift 2;;
    --count) COUNT="${2:-0}"; shift 2;;
    --country) COUNTRY="${2:-}"; shift 2;;
    --host) WG_HOST="${2:-auto}"; shift 2;;
    --image) WG_IMAGE="${2:-$WG_IMAGE_DEFAULT}"; shift 2;;
    --no-clients) NO_CLIENTS=1; shift 1;;
    --add) ADD="${2:-0}"; shift 2;;
    --zip) MAKE_ZIP=1; shift 1;;
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

get_public_ip() {
  # Несколько источников (если один недоступен)
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
  # По IP (может не всегда работать, но как авто-попытка — ок)
  local cc=""
  cc="$(curl -fsS https://ipapi.co/country 2>/dev/null | tr -d '\n' || true)"
  # иногда возвращает пусто/мусор
  if [[ ! "$cc" =~ ^[A-Z]{2}$ ]]; then
    cc=""
  fi
  echo "$cc"
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
  log "Ставлю утилиты (curl/jq)..."
  apt update -y
  apt install -y curl ca-certificates jq zip
}

run_wg_easy() {
  local udp_port="$WG_PORT_UDP_DEFAULT"
  local ui_port="$WG_PORT_UI_DEFAULT"

  log "Поднимаю wg-easy контейнер: $WG_IMAGE"

  # если контейнер уже есть — обновим
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

api_login_cookie() {
  # Пытаемся создать сессию через /api/session (часто так в wg-easy)
  # Если не получится — всё равно продолжим, но создание клиентов может не сработать.
  local jar="$1"
  rm -f "$jar"

  # Попытка логина
  curl -fsS -c "$jar" -b "$jar" \
    -H "Content-Type: application/json" \
    -X POST "http://127.0.0.1:51821/api/session" \
    -d "{\"password\":\"$PASSWORD\"}" >/dev/null 2>&1 || true
}

api_create_client() {
  local jar="$1"
  local name="$2"

  # создаём клиента
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

  # На разных версиях endpoint конфигов мог называться по-разному.
  # Пробуем несколько вариантов.
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

wg_easy_exists() {
  docker ps --format '{{.Names}}' | grep -qx 'wg-easy'
}

get_next_index() {
  local jar="$1"
  local prefix="$2"   # например RU_91_142_72_112-
  local json max

  json="$(api_list_clients "$jar")"
  echo "$json" | jq -e . >/dev/null 2>&1 || { echo 1; return; }

  # вытащим номера из имён вида PREFIX + число
  max="$(echo "$json" | jq -r --arg p "$prefix" '
      [.[] | select(.name|startswith($p)) | .name] 
      | map(sub("^" + ($p|gsub("\\."; "\\\\.")) ; "")) 
      | map(try tonumber catch empty)
      | max // 0
    ' 2>/dev/null || echo 0)"

  if [[ -z "$max" || "$max" == "null" ]]; then
    max=0
  fi

  echo $((max + 1))
}

make_zip() {
  local zip_name="$1"
  local folder_name="$2"
  cd /root/wg-configs
  zip -r "$zip_name" "$folder_name" >/dev/null
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
"

# Если попросили догенерировать (ADD>0) — не переустанавливаем wg-easy
if [[ "$ADD" -gt 0 ]]; then
  if ! wg_easy_exists; then
    echo "wg-easy не запущен (контейнер wg-easy не найден). Запусти установку без --add."
    exit 1
  fi

  wait_ui

  JAR="/tmp/wg-easy.cookie"
  api_login_cookie "$JAR"

  OUTDIR="/root/wg-configs/${COUNTRY}_${WG_HOST//./_}"
  mkdir -p "$OUTDIR"

  PREFIX="${COUNTRY}_${WG_HOST//./_}-"
  START="$(get_next_index "$JAR" "$PREFIX")"
  END=$((START + ADD - 1))

  log "Догенерация клиентов: добавляю $ADD шт.
  Диапазон: ${START}..${END}
  Папка: $OUTDIR
  "

  for ((i=START;i<=END;i++)); do
    NAME="${PREFIX}${i}"
    echo "[+] create: $NAME"
    api_create_client "$JAR" "$NAME" || {
      echo "Не получилось создать клиента через API."
      exit 1
    }
  done

  JSON="$(api_list_clients "$JAR")"

  for ((i=START;i<=END;i++)); do
    NAME="${PREFIX}${i}"
    ID="$(echo "$JSON" | jq -r --arg n "$NAME" '.[] | select(.name==$n) | .id' | head -n1)"
    [[ -z "$ID" || "$ID" == "null" ]] && { echo "[!] нет id для $NAME"; continue; }

    OUTFILE="${OUTDIR}/${NAME}.conf"
    if download_client_config "$JAR" "$ID" "$OUTFILE"; then
      echo "[✓] saved: $OUTFILE"
    else
      echo "[!] не удалось скачать конфиг для $NAME (id=$ID)"
    fi
  done

  ZIP_NAME="${COUNTRY}_${WG_HOST//./_}.zip"
  make_zip "$ZIP_NAME" "${COUNTRY}_${WG_HOST//./_}"

  log "Готово (добавление).
  Папка конфигов: $OUTDIR
  ZIP готов: /root/wg-configs/$ZIP_NAME
  WG UI: http://${WG_HOST}:51821
  "
  exit 0
fi

run_wg_easy
wait_ui

if [[ "$COUNT" -le 0 ]]; then
  log "Генерация клиентов выключена (COUNT=0). Готово."
  echo "WG UI: http://${WG_HOST}:51821"
  exit 0
fi

log "Создаю $COUNT клиентов и скачиваю конфиги..."

JAR="/tmp/wg-easy.cookie"
api_login_cookie "$JAR"

OUTDIR="/root/wg-configs/${COUNTRY}_${WG_HOST//./_}"
mkdir -p "$OUTDIR"

# Создаём клиентов
for ((i=1;i<=COUNT;i++)); do
  NAME="${COUNTRY}_${WG_HOST//./_}-${i}"
  echo "[+] create: $NAME"
  api_create_client "$JAR" "$NAME" || {
    echo "Не получилось создать клиента через API. Проверь версию wg-easy / авторизацию."
    echo "Логи: docker logs wg-easy"
    exit 1
  }
done

# Получаем список клиентов и скачиваем конфиги по id
JSON="$(api_list_clients "$JAR")"
# Ожидаем массив объектов с полями id и name (обычно так)
echo "$JSON" | jq -e . >/dev/null 2>&1 || {
  echo "API вернул не-JSON. Проверь авторизацию/версию wg-easy."
  exit 1
}

# Скачиваем конфиги только для наших созданных имён
for ((i=1;i<=COUNT;i++)); do
  NAME="${COUNTRY}_${WG_HOST//./_}-${i}"
  ID="$(echo "$JSON" | jq -r --arg n "$NAME" '.[] | select(.name==$n) | .id' | head -n1)"
  if [[ -z "$ID" || "$ID" == "null" ]]; then
    echo "Не нашёл id для $NAME в списке клиентов."
    continue
  fi

  OUTFILE="${OUTDIR}/${NAME}.conf"
  if download_client_config "$JAR" "$ID" "$OUTFILE"; then
    echo "[✓] saved: $OUTFILE"
  else
    echo "[!] не удалось скачать конфиг для $NAME (id=$ID). Возможно другой endpoint в твоей версии."
  fi
done
ZIP_NAME="${COUNTRY}_${WG_HOST//./_}.zip"
cd /root/wg-configs
zip -r "$ZIP_NAME" "${COUNTRY}_${WG_HOST//./_}" >/dev/null

log "Готово.
Папка конфигов: $OUTDIR
WG UI: http://${WG_HOST}:51821
ZIP готов: /root/wg-configs/$ZIP_NAME
"
