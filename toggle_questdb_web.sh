#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
PRIVATE_MAPPING='      - "127.0.0.1:${QUESTDB_HTTP_PORT:-9000}:9000"'
PUBLIC_MAPPING='      - "${QUESTDB_HTTP_PORT:-9000}:9000"'

if [[ "${EUID}" -ne 0 ]]; then
  echo "Este script debe ejecutarse con sudo o como root."
  exit 1
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "No se encontro docker-compose.yml en ${SCRIPT_DIR}."
  exit 1
fi

current_mode="unknown"
if grep -Fq "${PRIVATE_MAPPING}" "${COMPOSE_FILE}"; then
  current_mode="private"
elif grep -Fq "${PUBLIC_MAPPING}" "${COMPOSE_FILE}"; then
  current_mode="public"
fi

echo "Modo actual de la consola web de QuestDB: ${current_mode}"
echo "Escribe 'enable' para exponerla publicamente o 'disable' para volverla privada."
read -r action

case "${action}" in
  enable)
    target_mode="public"
    ;;
  disable)
    target_mode="private"
    ;;
  *)
    echo "Accion no valida. Usa 'enable' o 'disable'."
    exit 1
    ;;
esac

if [[ "${current_mode}" == "${target_mode}" ]]; then
  echo "QuestDB ya esta en modo ${target_mode}."
  exit 0
fi

echo "Vas a cambiar la consola web de QuestDB a modo ${target_mode}."
echo "Confirma escribiendo 'yes'."
read -r confirmation

if [[ "${confirmation}" != "yes" ]]; then
  echo "Operacion cancelada."
  exit 0
fi

tmp_file="$(mktemp)"
cp "${COMPOSE_FILE}" "${tmp_file}"

if [[ "${target_mode}" == "public" ]]; then
  sed 's#127\.0\.0\.1:\${QUESTDB_HTTP_PORT:-9000}:9000#\${QUESTDB_HTTP_PORT:-9000}:9000#' "${COMPOSE_FILE}" > "${tmp_file}"
else
  sed 's#"\${QUESTDB_HTTP_PORT:-9000}:9000"#"127.0.0.1:\${QUESTDB_HTTP_PORT:-9000}:9000"#' "${COMPOSE_FILE}" > "${tmp_file}"
fi

mv "${tmp_file}" "${COMPOSE_FILE}"

cd "${SCRIPT_DIR}"
docker compose up -d questdb

if [[ "${target_mode}" == "public" ]]; then
  echo "Modo actual: publico"
  echo "URL esperada en desarrollo: http://<IP-DE-TU-VPS>:9000"
else
  echo "Modo actual: privado"
  echo "URL esperada en desarrollo: http://127.0.0.1:9000 solo desde la VPS"
fi

echo "Recordatorio: esto es solo para desarrollo. Antes de produccion vuelve a modo privado."
