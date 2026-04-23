#!/usr/bin/env bash
set -euo pipefail

SERVICE_TYPE=""
HOSTNAME_VALUE=""
UPSTREAM_PORT=""
SITE_NAME=""
EMAIL=""
RATE_LIMIT_ZONE_NAME="frontera_api_limit"
RATE_LIMIT_RATE="5r/s"
RATE_LIMIT_BURST="20"

usage() {
  cat <<'EOF'
Uso:
  sudo bash setup_https_proxy.sh --service api --host api.fronteradatalabs.com [--port 8000] [--site frontera-data-labs-api] [--email you@example.com]
  sudo bash setup_https_proxy.sh --service questdb --host questdb.fronteradatalabs.com [--port 9000] [--site frontera-data-labs-questdb] [--email you@example.com]

Opciones:
  --service  Tipo de proxy a configurar. Valores validos: api, questdb
  --host     Hostname publico que apunte a esta VPS.
  --port     Puerto local del servicio de upstream. Default: 8000 para api, 9000 para questdb
  --site     Nombre base del sitio/configuracion de Nginx.
  --email    Email para Let's Encrypt. Si se omite, Certbot se registra sin email.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)
      SERVICE_TYPE="${2:-}"
      shift 2
      ;;
    --host)
      HOSTNAME_VALUE="${2:-}"
      shift 2
      ;;
    --port)
      UPSTREAM_PORT="${2:-}"
      shift 2
      ;;
    --site)
      SITE_NAME="${2:-}"
      shift 2
      ;;
    --email)
      EMAIL="${2:-}"
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

if [[ -z "${SERVICE_TYPE}" || -z "${HOSTNAME_VALUE}" ]]; then
  echo "Debes indicar --service y --host."
  usage
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Este script debe ejecutarse con sudo o como root."
  exit 1
fi

case "${SERVICE_TYPE}" in
  api)
    UPSTREAM_PORT="${UPSTREAM_PORT:-8000}"
    SITE_NAME="${SITE_NAME:-frontera-data-labs-api}"
    ;;
  questdb)
    UPSTREAM_PORT="${UPSTREAM_PORT:-9000}"
    SITE_NAME="${SITE_NAME:-frontera-data-labs-questdb}"
    ;;
  *)
    echo "Servicio invalido: ${SERVICE_TYPE}. Usa 'api' o 'questdb'."
    exit 1
    ;;
esac

if ! [[ "${UPSTREAM_PORT}" =~ ^[0-9]+$ ]]; then
  echo "El puerto debe ser numerico."
  exit 1
fi

detect_public_ip() {
  curl -4 -fsS https://api.ipify.org
}

validate_dns_points_to_vps() {
  local public_ip=""
  local resolved_ips=""

  public_ip="$(detect_public_ip)"
  if [[ -z "${public_ip}" ]]; then
    echo "No fue posible detectar la IP publica de la VPS."
    exit 1
  fi

  resolved_ips="$(getent ahostsv4 "${HOSTNAME_VALUE}" | awk '{print $1}' | sort -u || true)"
  if [[ -z "${resolved_ips}" ]]; then
    echo "El dominio ${HOSTNAME_VALUE} todavia no resuelve por DNS."
    echo "Crea el registro A en Hostinger y espera propagacion antes de correr Certbot."
    exit 1
  fi

  if ! grep -Fxq "${public_ip}" <<< "${resolved_ips}"; then
    echo "El dominio ${HOSTNAME_VALUE} no apunta a esta VPS."
    echo "IP publica detectada: ${public_ip}"
    echo "IPs resueltas por DNS:"
    echo "${resolved_ips}"
    echo "Corrige el registro DNS y espera propagacion antes de continuar."
    exit 1
  fi
}

echo "Instalando dependencias del proxy HTTPS..."
apt-get update
apt-get install -y nginx certbot python3-certbot-nginx logrotate

validate_dns_points_to_vps

NGINX_CONF="/etc/nginx/sites-available/${SITE_NAME}.conf"
NGINX_LINK="/etc/nginx/sites-enabled/${SITE_NAME}.conf"
LOGROTATE_CONF="/etc/logrotate.d/${SITE_NAME}"

write_api_config() {
  local rate_limit_conf="/etc/nginx/conf.d/${SITE_NAME}-rate-limit.conf"

  echo "Escribiendo zona de rate limiting en ${rate_limit_conf}..."
  cat > "${rate_limit_conf}" <<EOF
limit_req_zone \$binary_remote_addr zone=${RATE_LIMIT_ZONE_NAME}:10m rate=${RATE_LIMIT_RATE};
EOF

  cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${HOSTNAME_VALUE};

    access_log off;
    error_log /var/log/nginx/${SITE_NAME}.error.log warn;
    limit_req_status 429;

    location = /health {
        limit_req zone=${RATE_LIMIT_ZONE_NAME} burst=${RATE_LIMIT_BURST} nodelay;
        proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /api/ {
        limit_req zone=${RATE_LIMIT_ZONE_NAME} burst=${RATE_LIMIT_BURST} nodelay;
        proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
}

write_questdb_config() {
  cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${HOSTNAME_VALUE};

    access_log off;
    error_log /var/log/nginx/${SITE_NAME}.error.log warn;

    location / {
        proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Authorization \$http_authorization;
    }
}
EOF
}

echo "Escribiendo configuracion Nginx en ${NGINX_CONF}..."
case "${SERVICE_TYPE}" in
  api)
    write_api_config
    ;;
  questdb)
    write_questdb_config
    ;;
esac

echo "Escribiendo politica de rotacion para el error log de Nginx..."
cat > "${LOGROTATE_CONF}" <<EOF
/var/log/nginx/${SITE_NAME}.error.log {
    size 1M
    rotate 2
    compress
    missingok
    notifempty
    copytruncate
}
EOF

ln -sf "${NGINX_CONF}" "${NGINX_LINK}"

echo "Validando configuracion Nginx..."
nginx -t
systemctl reload nginx || systemctl restart nginx

if command -v logrotate >/dev/null 2>&1; then
  logrotate -d "${LOGROTATE_CONF}" >/dev/null
fi

CERTBOT_ARGS=(
  --nginx
  --non-interactive
  --agree-tos
  --redirect
  -d "${HOSTNAME_VALUE}"
)

if [[ -n "${EMAIL}" ]]; then
  CERTBOT_ARGS+=(-m "${EMAIL}")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi

echo "Solicitando certificado TLS con Certbot..."
certbot "${CERTBOT_ARGS[@]}"

echo
echo "Listo."
echo "Servicio configurado: ${SERVICE_TYPE}"
echo "URL publica: https://${HOSTNAME_VALUE}"
echo "Upstream local: http://127.0.0.1:${UPSTREAM_PORT}"
if [[ "${SERVICE_TYPE}" == "api" ]]; then
  echo "Rate limiting: ${RATE_LIMIT_RATE} con burst ${RATE_LIMIT_BURST} para /health y /api/"
  echo "En Render configura:"
  echo "VITE_API_BASE_URL=https://${HOSTNAME_VALUE}"
else
  echo "QuestDB queda expuesto solo via Nginx/TLS. La autenticacion HTTP la aplica QuestDB con QDB_HTTP_USER/QDB_HTTP_PASSWORD."
fi
echo "Rotacion de Nginx: 1 MB x 2 archivos para ${SITE_NAME}.error.log"
