#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

QUESTDB_HTTP_PORT="${QUESTDB_HTTP_PORT:-9000}"
QUESTDB_PG_PORT="${QUESTDB_PG_PORT:-8812}"
QUESTDB_IMAGE="${QUESTDB_IMAGE:-questdb/questdb:8.2.2}"
QUESTDB_LOOP_FILE="${QUESTDB_LOOP_FILE:-/srv/questdb-data.img}"
QUESTDB_MOUNT_POINT="${QUESTDB_MOUNT_POINT:-/srv/questdb-data}"
QUESTDB_DATA_DIR="${QUESTDB_DATA_DIR:-${QUESTDB_MOUNT_POINT}/data}"
QUESTDB_LOOP_SIZE_BYTES=$((4 * 1024 * 1024 * 1024))
MIN_ROOT_HEADROOM_BYTES=$((512 * 1024 * 1024))
QUESTDB_BASE_URL=""

usage() {
  cat <<'EOF'
Uso:
  sudo bash setup_questdb.sh [--http-port 9000] [--pg-port 8812] [--image questdb/questdb:8.2.2] [--loop-file /srv/questdb-data.img] [--mount-point /srv/questdb-data] [--data-dir /srv/questdb-data/data]

Ejemplo:
  sudo bash setup_questdb.sh

Opciones:
  --http-port    Puerto HTTP/REST y Web Console de QuestDB. Default: 9000
  --pg-port      Puerto PostgreSQL wire protocol. Default: 8812
  --image        Imagen fija de QuestDB para Compose. Default: questdb/questdb:8.2.2
  --loop-file    Archivo loopback de 4 GB para encapsular el storage. Default: /srv/questdb-data.img
  --mount-point  Punto de montaje del filesystem loopback. Default: /srv/questdb-data
  --data-dir     Directorio persistente de QuestDB dentro del mount. Default: /srv/questdb-data/data
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --http-port)
      QUESTDB_HTTP_PORT="${2:-}"
      shift 2
      ;;
    --pg-port)
      QUESTDB_PG_PORT="${2:-}"
      shift 2
      ;;
    --image)
      QUESTDB_IMAGE="${2:-}"
      shift 2
      ;;
    --loop-file)
      QUESTDB_LOOP_FILE="${2:-}"
      shift 2
      ;;
    --mount-point)
      QUESTDB_MOUNT_POINT="${2:-}"
      shift 2
      ;;
    --data-dir)
      QUESTDB_DATA_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Opcion no reconocida: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Este script debe ejecutarse con sudo o como root."
  exit 1
fi

for port in "${QUESTDB_HTTP_PORT}" "${QUESTDB_PG_PORT}"; do
  if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
    echo "Los puertos deben ser numericos."
    exit 1
  fi
done

case "${QUESTDB_DATA_DIR}" in
  "${QUESTDB_MOUNT_POINT}"/*) ;;
  *)
    echo "QUESTDB_DATA_DIR debe vivir dentro de ${QUESTDB_MOUNT_POINT} para que la barrera de disco sea efectiva."
    exit 1
    ;;
esac

for required_command in docker curl mountpoint mkfs.ext4 blkid; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "Falta el comando requerido: ${required_command}"
    exit 1
  fi
done

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 no esta disponible."
  exit 1
fi

ensure_root_headroom() {
  local available_bytes
  available_bytes=$(df --output=avail -B1 / | tail -n 1 | tr -d '[:space:]')

  if [[ -f "${QUESTDB_LOOP_FILE}" ]]; then
    return
  fi

  if (( available_bytes < QUESTDB_LOOP_SIZE_BYTES + MIN_ROOT_HEADROOM_BYTES )); then
    echo "No hay espacio suficiente en / para reservar 4 GB a QuestDB y dejar headroom operativo."
    echo "Espacio requerido minimo: $((QUESTDB_LOOP_SIZE_BYTES + MIN_ROOT_HEADROOM_BYTES)) bytes"
    echo "Espacio disponible: ${available_bytes} bytes"
    exit 1
  fi
}

ensure_loop_file() {
  if [[ -f "${QUESTDB_LOOP_FILE}" ]]; then
    echo "Loopback existente en ${QUESTDB_LOOP_FILE}."
    return
  fi

  ensure_root_headroom
  mkdir -p "$(dirname "${QUESTDB_LOOP_FILE}")"

  echo "Reservando archivo loopback de 4 GB en ${QUESTDB_LOOP_FILE}..."
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${QUESTDB_LOOP_SIZE_BYTES}" "${QUESTDB_LOOP_FILE}"
  else
    dd if=/dev/zero of="${QUESTDB_LOOP_FILE}" bs=1M count=4096 status=progress
  fi
}

ensure_loop_filesystem() {
  if blkid -p -s TYPE -o value "${QUESTDB_LOOP_FILE}" >/dev/null 2>&1; then
    return
  fi

  echo "Formateando ${QUESTDB_LOOP_FILE} como ext4..."
  mkfs.ext4 -F "${QUESTDB_LOOP_FILE}" >/dev/null
}

ensure_fstab_entry() {
  local fstab_line
  fstab_line="${QUESTDB_LOOP_FILE} ${QUESTDB_MOUNT_POINT} ext4 loop,noatime,defaults 0 0"

  if ! grep -Fqx "${fstab_line}" /etc/fstab; then
    echo "Registrando mount persistente en /etc/fstab..."
    echo "${fstab_line}" >> /etc/fstab
  fi
}

ensure_mount() {
  mkdir -p "${QUESTDB_MOUNT_POINT}"

  if mountpoint -q "${QUESTDB_MOUNT_POINT}"; then
    echo "El mount point ${QUESTDB_MOUNT_POINT} ya esta activo."
    return
  fi

  ensure_loop_file
  ensure_loop_filesystem
  ensure_fstab_entry

  echo "Montando filesystem loopback en ${QUESTDB_MOUNT_POINT}..."
  mount "${QUESTDB_MOUNT_POINT}"
}

run_query() {
  local query="$1"
  curl -fsS "${QUESTDB_BASE_URL}/exec" --get --data-urlencode "query=${query}" >/dev/null
}

ensure_mount
mkdir -p "${QUESTDB_DATA_DIR}"

export QUESTDB_HTTP_PORT
export QUESTDB_PG_PORT
export QUESTDB_IMAGE
export QUESTDB_DATA_DIR

echo "Levantando QuestDB con Docker Compose..."
docker compose up -d questdb
docker update --cpus 0.50 --memory 768m --memory-swap 768m --pids-limit 256 questdb >/dev/null

QUESTDB_BASE_URL="http://127.0.0.1:${QUESTDB_HTTP_PORT}"

echo "Esperando a que QuestDB responda en ${QUESTDB_BASE_URL}..."
for attempt in $(seq 1 30); do
  if curl -fsS "${QUESTDB_BASE_URL}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
  if [[ "${attempt}" -eq 30 ]]; then
    echo "QuestDB no respondio a tiempo."
    exit 1
  fi
done

echo "Inicializando tablas base..."
run_query "CREATE TABLE IF NOT EXISTS devices (
  board_id SYMBOL CAPACITY 256 CACHE,
  sensor_type SYMBOL CAPACITY 16 CACHE,
  registered_at TIMESTAMP
) TIMESTAMP(registered_at) PARTITION BY MONTH;"

run_query "CREATE TABLE IF NOT EXISTS deployments (
  deployment_id SYMBOL CAPACITY 1024 CACHE,
  board_id SYMBOL CAPACITY 256 CACHE,
  latitude DOUBLE,
  longitude DOUBLE,
  location_name STRING,
  deployed_at TIMESTAMP
) TIMESTAMP(deployed_at) PARTITION BY MONTH;"

run_query "CREATE TABLE IF NOT EXISTS telemetria_datos (
  deployment_id SYMBOL CAPACITY 1024 CACHE,
  co2 DOUBLE,
  temp DOUBLE,
  rh DOUBLE,
  errors INT,
  ts TIMESTAMP
) TIMESTAMP(ts) PARTITION BY DAY;"

echo
echo "Listo."
echo "Imagen fija: ${QUESTDB_IMAGE}"
echo "Loopback: ${QUESTDB_LOOP_FILE}"
echo "Mount point: ${QUESTDB_MOUNT_POINT}"
echo "Directorio de datos: ${QUESTDB_DATA_DIR}"
echo "Web Console / REST: ${QUESTDB_BASE_URL}"
echo "PostgreSQL wire protocol: 127.0.0.1:${QUESTDB_PG_PORT}"
echo
echo "Verificaciones sugeridas:"
echo "df -h / ${QUESTDB_MOUNT_POINT}"
echo "docker inspect questdb --format '{{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}}'"
echo "curl ${QUESTDB_BASE_URL}"
echo "curl --get ${QUESTDB_BASE_URL}/exec --data-urlencode 'query=SHOW TABLES;'"
