# Frontera Data Labs API

Backend FastAPI de solo lectura para consultar QuestDB y servir datos al dashboard, preparado para una VPS nueva con dominio propio, TLS, rate limiting en la API y QuestDB protegido con autenticacion HTTP nativa.

## Arquitectura objetivo

- `api.fronteradatalabs.com` sirve FastAPI detras de Nginx y TLS
- `questdb.fronteradatalabs.com` sirve la Web Console y el HTTP API de QuestDB detras de Nginx y TLS
- QuestDB sigue escuchando solo en loopback del host (`127.0.0.1:9000`) y no se expone directamente a Internet
- la autenticacion de QuestDB se hace con `QDB_HTTP_USER` y `QDB_HTTP_PASSWORD`
- QuestDB usa una imagen fija `questdb/questdb:9.3.5`
- el host y el contenedor usan `nofile=2097152`, que es el doble del warning minimo recomendado visto anteriormente

## Servicios

- FastAPI + httpx
- QuestDB en Docker Compose
- Nginx + Certbot
- Storage loopback ext4 de 4 GB para encapsular el crecimiento de QuestDB

## Variables de entorno

Copia `.env.example` a `.env` y completa las credenciales reales:

```env
APP_NAME=Frontera Data Labs API
APP_VERSION=0.1.0
API_HOST=0.0.0.0
API_PORT=8000
QUESTDB_BASE_URL=http://questdb:9000
API_CORS_ORIGINS=https://fronteradatalabs.com,https://www.fronteradatalabs.com
QUERY_TIMEOUT_SECONDS=10
QUESTDB_IMAGE=questdb/questdb:9.3.5
QUESTDB_HTTP_PORT=9000
QUESTDB_PG_PORT=8812
QUESTDB_DATA_DIR=/srv/questdb-data/data
QDB_HTTP_USER=change-me
QDB_HTTP_PASSWORD=change-me-strong-password
```

## Flujo recomendado en la VPS

```bash
git pull
cp .env.example .env
nano .env
sudo bash setup_questdb.sh
./deploy.sh
sudo bash setup_https_proxy.sh --service api --host api.fronteradatalabs.com --email you@example.com
sudo bash setup_https_proxy.sh --service questdb --host questdb.fronteradatalabs.com --email you@example.com
```

## Que hace `setup_questdb.sh`

- exige que exista `.env`
- exige `QDB_HTTP_USER` y `QDB_HTTP_PASSWORD`
- reserva un archivo loopback de 4 GB en `/srv/questdb-data.img`
- lo formatea como ext4 y lo monta en `/srv/questdb-data`
- persiste el mount en `/etc/fstab`
- crea `QUESTDB_DATA_DIR` dentro del filesystem acotado
- ajusta `fs.file-max` del host a `2097152`
- descarga la imagen objetivo de QuestDB
- recrea el contenedor si encuentra una imagen vieja, sin tocar el storage persistente
- levanta QuestDB con `ulimits.nofile=2097152`
- verifica readiness con autenticacion HTTP
- crea las tablas base `devices`, `deployments` y `telemetria_datos`

## Que hace `setup_https_proxy.sh`

- soporta dos modos:
  - `--service api`
  - `--service questdb`
- valida que el dominio resuelva a la IP publica de la VPS antes de lanzar Certbot
- para `api`:
  - proxy a `127.0.0.1:8000`
  - rate limiting en `/health` y `/api/`
- para `questdb`:
  - proxy a `127.0.0.1:9000`
  - no duplica auth en Nginx; deja que QuestDB responda con su propia autenticacion HTTP
- en ambos casos:
  - emite TLS con Let's Encrypt
  - rota error logs de Nginx a `1 MB x 2`

## Hostinger: lo que debes hacer tu

En la zona DNS de `fronteradatalabs.com`, crea:

```text
A  api      -> 187.124.25.26
A  questdb  -> 187.124.25.26
```

Ademas:

- asegurate de que `80/tcp` y `443/tcp` esten permitidos en la VPS/firewall
- no abras `9000`, `8812` ni `8000` al exterior
- espera propagacion DNS antes de correr los scripts de TLS

## Verificaciones rapidas

QuestDB local autenticado:

```bash
docker inspect questdb --format '{{.Config.Image}}'
docker inspect questdb --format '{{.Image}}'
docker inspect questdb --format '{{json .HostConfig.Ulimits}}'
sysctl -n fs.file-max
curl --max-time 5 -u "$QDB_HTTP_USER:$QDB_HTTP_PASSWORD" --get http://127.0.0.1:9000/exec --data-urlencode "query=SELECT 1;"
curl --max-time 5 -u "$QDB_HTTP_USER:$QDB_HTTP_PASSWORD" --get http://127.0.0.1:9000/exec --data-urlencode "query=SHOW TABLES;"
```

API publica:

```bash
curl -vk https://api.fronteradatalabs.com/health
```

QuestDB publico via dominio:

```bash
curl -vk -u "$QDB_HTTP_USER:$QDB_HTTP_PASSWORD" https://questdb.fronteradatalabs.com/exec --get --data-urlencode "query=SHOW TABLES;"
```

## Notas importantes

- `questdb.fronteradatalabs.com` expone tanto la Web Console como el HTTP API de QuestDB, ambos protegidos por las credenciales nativas
- `toggle_questdb_web.sh` queda solo como herramienta legacy/desarrollo; no hace falta usarlo para esta arquitectura con dominio propio
- el frontend debera usar:

```env
VITE_API_BASE_URL=https://api.fronteradatalabs.com
```
