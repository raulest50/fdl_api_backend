#!/usr/bin/env bash
set -euo pipefail

HOSTNAME_VALUE=""
API_PORT="8000"
SITE_NAME="frontera-data-labs-api"
EMAIL=""

usage() {
  cat <<'EOF'
Uso:
  sudo bash setup_https_proxy.sh --host 187.124.90.77.sslip.io [--port 8000] [--site frontera-data-labs-api] [--email you@example.com]

Ejemplo sin dominio propio:
  sudo bash setup_https_proxy.sh --host 187.124.90.77.sslip.io

Opciones:
  --host    Hostname publico que apunte a esta VPS. Recomendado: <IP>.sslip.io
  --port    Puerto local donde escucha la API FastAPI. Default: 8000
  --site    Nombre del archivo de sitio Nginx. Default: frontera-data-labs-api
  --email   Email para Let's Encrypt. Si se omite, Certbot se registra sin email.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOSTNAME_VALUE="${2:-}"
      shift 2
      ;;
    --port)
      API_PORT="${2:-}"
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

if [[ -z "${HOSTNAME_VALUE}" ]]; then
  echo "Debes indicar --host."
  usage
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Este script debe ejecutarse con sudo o como root."
  exit 1
fi

if ! [[ "${API_PORT}" =~ ^[0-9]+$ ]]; then
  echo "El puerto debe ser numerico."
  exit 1
fi

echo "Instalando dependencias del proxy HTTPS..."
apt-get update
apt-get install -y nginx certbot python3-certbot-nginx

NGINX_CONF="/etc/nginx/sites-available/${SITE_NAME}.conf"
NGINX_LINK="/etc/nginx/sites-enabled/${SITE_NAME}.conf"

echo "Escribiendo configuracion Nginx en ${NGINX_CONF}..."
cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${HOSTNAME_VALUE};

    location / {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf "${NGINX_CONF}" "${NGINX_LINK}"

echo "Validando configuracion Nginx..."
nginx -t
systemctl reload nginx || systemctl restart nginx

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
echo "URL publica de la API: https://${HOSTNAME_VALUE}"
echo "En Render configura:"
echo "VITE_API_BASE_URL=https://${HOSTNAME_VALUE}"
