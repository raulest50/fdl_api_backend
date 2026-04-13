#!/usr/bin/env bash
set -euo pipefail

QUESTDB_CONTAINER_NAME="questdb"
QUESTDB_VOLUME_NAME="questdb-data"
QUESTDB_HTTP_PORT="9000"
QUESTDB_PG_PORT="8812"
QUESTDB_IMAGE="questdb/questdb:latest"
QUESTDB_BASE_URL=""

usage() {
  cat <<'EOF'
Uso:
  sudo bash setup_questdb.sh [--http-port 9000] [--pg-port 8812] [--container questdb] [--volume questdb-data]

Ejemplo:
  sudo bash setup_questdb.sh

Opciones:
  --http-port   Puerto HTTP/REST y Web Console de QuestDB. Default: 9000
  --pg-port     Puerto PostgreSQL wire protocol. Default: 8812
  --container   Nombre del contenedor Docker. Default: questdb
  --volume      Nombre del volumen persistente. Default: questdb-data
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
    --container)
      QUESTDB_CONTAINER_NAME="${2:-}"
      shift 2
      ;;
    --volume)
      QUESTDB_VOLUME_NAME="${2:-}"
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

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker no esta instalado o no esta en PATH."
  exit 1
fi

echo "Creando volumen persistente ${QUESTDB_VOLUME_NAME} si no existe..."
docker volume create "${QUESTDB_VOLUME_NAME}" >/dev/null

echo "Descargando imagen de QuestDB..."
docker pull "${QUESTDB_IMAGE}"

if docker ps -a --format '{{.Names}}' | grep -Fxq "${QUESTDB_CONTAINER_NAME}"; then
  echo "Eliminando contenedor previo ${QUESTDB_CONTAINER_NAME} para recrearlo con la configuracion esperada..."
  docker rm -f "${QUESTDB_CONTAINER_NAME}" >/dev/null
fi

echo "Levantando QuestDB..."
docker run -d \
  --name "${QUESTDB_CONTAINER_NAME}" \
  --restart unless-stopped \
  -p "${QUESTDB_HTTP_PORT}:9000" \
  -p "${QUESTDB_PG_PORT}:8812" \
  -v "${QUESTDB_VOLUME_NAME}:/var/lib/questdb" \
  "${QUESTDB_IMAGE}" >/dev/null

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

run_query() {
  local query="$1"
  curl -fsS "${QUESTDB_BASE_URL}/exec" --get --data-urlencode "query=${query}" >/dev/null
}

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
echo "Contenedor: ${QUESTDB_CONTAINER_NAME}"
echo "Volumen: ${QUESTDB_VOLUME_NAME}"
echo "Web Console / REST: ${QUESTDB_BASE_URL}"
echo "PostgreSQL wire protocol: 127.0.0.1:${QUESTDB_PG_PORT}"
echo
echo "Verificaciones sugeridas:"
echo "docker ps"
echo "curl ${QUESTDB_BASE_URL}"
echo "curl --get ${QUESTDB_BASE_URL}/exec --data-urlencode 'query=SHOW TABLES;'"
echo
echo "Para conectar la API FastAPI despues:"
echo "QUESTDB_BASE_URL=${QUESTDB_BASE_URL}"
