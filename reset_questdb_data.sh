#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
cd "${SCRIPT_DIR}"

QUESTDB_HTTP_PORT="${QUESTDB_HTTP_PORT:-9000}"
QDB_HTTP_USER="${QDB_HTTP_USER:-}"
QDB_HTTP_PASSWORD="${QDB_HTTP_PASSWORD:-}"
QUESTDB_BASE_URL=""
CURL_AUTH_ARGS=()
FORCE_RESET=false

usage() {
  cat <<'EOF'
Uso:
  sudo bash reset_questdb_data.sh --force

Descripcion:
  Borra por completo las tablas telemetria_datos, deployments y devices,
  y las vuelve a crear con el esquema base actual.

Notas:
  - Este script es destructivo.
  - Requiere el flag --force para ejecutarse.
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
  if value="$(get_dotenv_value QDB_HTTP_USER)"; then
    QDB_HTTP_USER="${value}"
  fi
  if value="$(get_dotenv_value QDB_HTTP_PASSWORD)"; then
    QDB_HTTP_PASSWORD="${value}"
  fi
}

run_query() {
  local query="$1"
  curl --max-time 5 -fsS "${CURL_AUTH_ARGS[@]}" "${QUESTDB_BASE_URL}/exec" --get --data-urlencode "query=${query}"
}

validate_required_tables() {
  local tables_output=""
  tables_output="$(run_query "SHOW TABLES;")"

  for table_name in devices deployments telemetria_datos; do
    if [[ "${tables_output}" != *"\"${table_name}\""* ]]; then
      echo "Falta la tabla requerida tras el reset: ${table_name}"
      echo "Salida de SHOW TABLES;: ${tables_output}"
      return 1
    fi
  done

  return 0
}

load_env_file_values

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE_RESET=true
      shift
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

if [[ "${FORCE_RESET}" != true ]]; then
  echo "Reset abortado. Debes pasar --force para confirmar el borrado total."
  usage
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "No existe ${ENV_FILE}. Copia .env.example a .env y completa las variables antes de ejecutar el reset."
  exit 1
fi

if [[ -z "${QDB_HTTP_USER}" || -z "${QDB_HTTP_PASSWORD}" ]]; then
  echo "QDB_HTTP_USER y QDB_HTTP_PASSWORD son obligatorios para autenticar el reset."
  exit 1
fi

for required_command in curl grep; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "Falta el comando requerido: ${required_command}"
    exit 1
  fi
done

CURL_AUTH_ARGS=(-u "${QDB_HTTP_USER}:${QDB_HTTP_PASSWORD}")
QUESTDB_BASE_URL="http://127.0.0.1:${QUESTDB_HTTP_PORT}"

echo "Validando conectividad con QuestDB..."
run_query "SELECT 1;" >/dev/null

echo "Borrando tablas actuales..."
run_query "DROP TABLE IF EXISTS telemetria_datos;" >/dev/null
run_query "DROP TABLE IF EXISTS deployments;" >/dev/null
run_query "DROP TABLE IF EXISTS devices;" >/dev/null

echo "Recreando tablas base..."
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

echo "Validando tablas recreadas..."
validate_required_tables

echo
echo "Reset total completado."
echo "Tablas recreadas: devices, deployments, telemetria_datos"
echo "Recuerda que el dashboard publico puede mostrar datos cacheados por unos segundos mientras expira la TTL actual de deployments."
