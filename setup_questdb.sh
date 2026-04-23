#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
cd "${SCRIPT_DIR}"

QUESTDB_HTTP_PORT="${QUESTDB_HTTP_PORT:-9000}"
QUESTDB_PG_PORT="${QUESTDB_PG_PORT:-8812}"
QUESTDB_IMAGE="${QUESTDB_IMAGE:-questdb/questdb:9.3.5}"
QUESTDB_CONTAINER_NAME="${QUESTDB_CONTAINER_NAME:-questdb}"
QUESTDB_LOOP_FILE="${QUESTDB_LOOP_FILE:-/srv/questdb-data.img}"
QUESTDB_MOUNT_POINT="${QUESTDB_MOUNT_POINT:-/srv/questdb-data}"
QUESTDB_DATA_DIR="${QUESTDB_DATA_DIR:-${QUESTDB_MOUNT_POINT}/data}"
QUESTDB_LOOP_SIZE_BYTES=$((4 * 1024 * 1024 * 1024))
MIN_ROOT_HEADROOM_BYTES=$((512 * 1024 * 1024))
QUESTDB_RECOMMENDED_FILE_MAX=2097152
QUESTDB_SYSCTL_FILE="/etc/sysctl.d/60-questdb.conf"
QDB_HTTP_USER="${QDB_HTTP_USER:-}"
QDB_HTTP_PASSWORD="${QDB_HTTP_PASSWORD:-}"
QUESTDB_BASE_URL=""
READINESS_QUERY="SELECT 1;"
CURL_AUTH_ARGS=()

usage() {
  cat <<'EOF'
Uso:
  sudo bash setup_questdb.sh [--http-port 9000] [--pg-port 8812] [--image questdb/questdb:9.3.5] [--loop-file /srv/questdb-data.img] [--mount-point /srv/questdb-data] [--data-dir /srv/questdb-data/data]

Ejemplo:
  sudo bash setup_questdb.sh

Opciones:
  --http-port    Puerto HTTP/REST y Web Console de QuestDB. Default: 9000
  --pg-port      Puerto PostgreSQL wire protocol. Default: 8812
  --image        Imagen fija de QuestDB para Compose. Default: questdb/questdb:9.3.5
  --loop-file    Archivo loopback de 4 GB para encapsular el storage. Default: /srv/questdb-data.img
  --mount-point  Punto de montaje del filesystem loopback. Default: /srv/questdb-data
  --data-dir     Directorio persistente de QuestDB dentro del mount. Default: /srv/questdb-data/data
EOF
}

get_dotenv_value() {
  local key="$1"
  local line=""

  if [[ ! -f "${ENV_FILE}" ]]; then
    return 1
  fi

  line="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 || true)"
  if [[ -z "${line}" ]]; then
    return 1
  fi

  printf '%s\n' "${line#*=}"
}

load_env_file_values() {
  local value=""

  if value="$(get_dotenv_value QUESTDB_HTTP_PORT)"; then
    QUESTDB_HTTP_PORT="${value}"
  fi
  if value="$(get_dotenv_value QUESTDB_PG_PORT)"; then
    QUESTDB_PG_PORT="${value}"
  fi
  if value="$(get_dotenv_value QUESTDB_IMAGE)"; then
    QUESTDB_IMAGE="${value}"
  fi
  if value="$(get_dotenv_value QUESTDB_DATA_DIR)"; then
    QUESTDB_DATA_DIR="${value}"
  fi
  if value="$(get_dotenv_value QDB_HTTP_USER)"; then
    QDB_HTTP_USER="${value}"
  fi
  if value="$(get_dotenv_value QDB_HTTP_PASSWORD)"; then
    QDB_HTTP_PASSWORD="${value}"
  fi
}

load_env_file_values

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

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "No existe ${ENV_FILE}. Copia .env.example a .env y completa las variables antes de ejecutar el setup."
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

for required_command in docker curl mountpoint mkfs.ext4 blkid grep; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "Falta el comando requerido: ${required_command}"
    exit 1
  fi
done

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 no esta disponible."
  exit 1
fi

validate_http_credentials() {
  if [[ -z "${QDB_HTTP_USER}" || -z "${QDB_HTTP_PASSWORD}" ]]; then
    echo "QDB_HTTP_USER y QDB_HTTP_PASSWORD son obligatorios para proteger QuestDB HTTP/Web Console."
    echo "Configuralos en ${ENV_FILE} antes de ejecutar el setup."
    exit 1
  fi

  CURL_AUTH_ARGS=(-u "${QDB_HTTP_USER}:${QDB_HTTP_PASSWORD}")
}

ensure_open_file_limits() {
  local current_file_max
  current_file_max="$(sysctl -n fs.file-max 2>/dev/null || echo 0)"

  if ! [[ "${current_file_max}" =~ ^[0-9]+$ ]]; then
    current_file_max=0
  fi

  if (( current_file_max >= QUESTDB_RECOMMENDED_FILE_MAX )); then
    echo "fs.file-max ya cumple la recomendacion reforzada de QuestDB (${current_file_max})."
    return
  fi

  echo "Ajustando fs.file-max de ${current_file_max} a ${QUESTDB_RECOMMENDED_FILE_MAX}..."
  cat > "${QUESTDB_SYSCTL_FILE}" <<EOF
fs.file-max = ${QUESTDB_RECOMMENDED_FILE_MAX}
EOF
  sysctl -q -p "${QUESTDB_SYSCTL_FILE}" >/dev/null
}

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
  curl --max-time 5 -fsS "${CURL_AUTH_ARGS[@]}" "${QUESTDB_BASE_URL}/exec" --get --data-urlencode "query=${query}"
}

wait_for_questdb() {
  local output=""

  echo "Esperando a que QuestDB responda en ${QUESTDB_BASE_URL}/exec..."
  for attempt in $(seq 1 30); do
    if output="$(run_query "${READINESS_QUERY}" 2>/dev/null)"; then
      if [[ "${output}" == *'"dataset"'* ]]; then
        return 0
      fi
    fi

    sleep 2
  done

  echo "QuestDB no respondio correctamente a /exec despues de varios intentos."
  echo "Prueba manual sugerida:"
  echo "curl --max-time 5 -u '${QDB_HTTP_USER}:***' --get ${QUESTDB_BASE_URL}/exec --data-urlencode 'query=${READINESS_QUERY}'"
  return 1
}

validate_required_tables() {
  local tables_output=""

  if ! tables_output="$(run_query "SHOW TABLES;" 2>/dev/null)"; then
    echo "No fue posible consultar SHOW TABLES; en QuestDB."
    return 1
  fi

  for table_name in devices deployments telemetria_datos; do
    if [[ "${tables_output}" != *"\"${table_name}\""* ]]; then
      echo "Falta la tabla requerida: ${table_name}"
      echo "Salida de SHOW TABLES;: ${tables_output}"
      return 1
    fi
  done

  return 0
}

get_existing_container_image() {
  if ! docker container inspect "${QUESTDB_CONTAINER_NAME}" >/dev/null 2>&1; then
    return 1
  fi

  docker inspect "${QUESTDB_CONTAINER_NAME}" --format '{{.Config.Image}}'
}

get_existing_container_image_id() {
  if ! docker container inspect "${QUESTDB_CONTAINER_NAME}" >/dev/null 2>&1; then
    return 1
  fi

  docker inspect "${QUESTDB_CONTAINER_NAME}" --format '{{.Image}}'
}

reconcile_existing_container() {
  local existing_image=""
  local existing_image_id=""

  if ! existing_image="$(get_existing_container_image)"; then
    echo "No existe un contenedor previo de QuestDB; se creara uno nuevo."
    return
  fi

  existing_image_id="$(get_existing_container_image_id || true)"

  if [[ "${existing_image}" == "${QUESTDB_IMAGE}" ]]; then
    echo "QuestDB ya usa la imagen objetivo (${existing_image}). Se reutilizara el contenedor."
    return
  fi

  echo "QuestDB usa una imagen distinta a la esperada."
  echo "Imagen actual: ${existing_image}"
  echo "Image ID actual: ${existing_image_id:-desconocido}"
  echo "Imagen objetivo: ${QUESTDB_IMAGE}"
  echo "Se recreara el contenedor preservando el almacenamiento persistente."

  docker rm -f "${QUESTDB_CONTAINER_NAME}" >/dev/null
}

validate_http_credentials
ensure_mount
ensure_open_file_limits
mkdir -p "${QUESTDB_DATA_DIR}"

export QUESTDB_HTTP_PORT
export QUESTDB_PG_PORT
export QUESTDB_IMAGE
export QUESTDB_DATA_DIR
export QDB_HTTP_USER
export QDB_HTTP_PASSWORD

echo "Descargando imagen objetivo de QuestDB..."
docker pull "${QUESTDB_IMAGE}" >/dev/null

reconcile_existing_container

echo "Levantando QuestDB con Docker Compose..."
docker compose up -d questdb
docker update --cpus 0.50 --memory 768m --memory-swap 768m --pids-limit 256 questdb >/dev/null

QUESTDB_BASE_URL="http://127.0.0.1:${QUESTDB_HTTP_PORT}"

wait_for_questdb

echo "Inicializando tablas base..."
run_query "CREATE TABLE IF NOT EXISTS devices (
  board_id SYMBOL CAPACITY 256 CACHE,
  sensor_type SYMBOL CAPACITY 16 CACHE,
  registered_at TIMESTAMP
) TIMESTAMP(registered_at) PARTITION BY MONTH;" >/dev/null

run_query "CREATE TABLE IF NOT EXISTS deployments (
  deployment_id SYMBOL CAPACITY 1024 CACHE,
  board_id SYMBOL CAPACITY 256 CACHE,
  latitude DOUBLE,
  longitude DOUBLE,
  location_name STRING,
  deployed_at TIMESTAMP
) TIMESTAMP(deployed_at) PARTITION BY MONTH;" >/dev/null

run_query "CREATE TABLE IF NOT EXISTS telemetria_datos (
  deployment_id SYMBOL CAPACITY 1024 CACHE,
  co2 DOUBLE,
  temp DOUBLE,
  rh DOUBLE,
  errors INT,
  ts TIMESTAMP
) TIMESTAMP(ts) PARTITION BY DAY;" >/dev/null

echo "Validando tablas base..."
if ! validate_required_tables; then
  echo "La inicializacion de QuestDB no dejo todas las tablas requeridas."
  exit 1
fi

echo
echo "Listo."
echo "Imagen fija solicitada: ${QUESTDB_IMAGE}"
echo "Imagen efectiva del contenedor: $(docker inspect "${QUESTDB_CONTAINER_NAME}" --format '{{.Config.Image}}')"
echo "Image ID efectivo: $(docker inspect "${QUESTDB_CONTAINER_NAME}" --format '{{.Image}}')"
echo "Auth HTTP QuestDB: habilitada para el usuario ${QDB_HTTP_USER}"
echo "Loopback: ${QUESTDB_LOOP_FILE}"
echo "Mount point: ${QUESTDB_MOUNT_POINT}"
echo "Directorio de datos: ${QUESTDB_DATA_DIR}"
echo "fs.file-max efectivo: $(sysctl -n fs.file-max)"
echo "Web Console / REST local: ${QUESTDB_BASE_URL}"
echo "PostgreSQL wire protocol local: 127.0.0.1:${QUESTDB_PG_PORT}"
echo
echo "Verificaciones sugeridas:"
echo "df -h / ${QUESTDB_MOUNT_POINT}"
echo "docker inspect ${QUESTDB_CONTAINER_NAME} --format '{{.Config.Image}}'"
echo "docker inspect ${QUESTDB_CONTAINER_NAME} --format '{{.Image}}'"
echo "docker inspect ${QUESTDB_CONTAINER_NAME} --format '{{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}}'"
echo "docker inspect ${QUESTDB_CONTAINER_NAME} --format '{{json .HostConfig.Ulimits}}'"
echo "curl --max-time 5 -u '${QDB_HTTP_USER}:***' --get ${QUESTDB_BASE_URL}/exec --data-urlencode 'query=SELECT 1;'"
echo "curl --max-time 5 -u '${QDB_HTTP_USER}:***' --get ${QUESTDB_BASE_URL}/exec --data-urlencode 'query=SHOW TABLES;'"
