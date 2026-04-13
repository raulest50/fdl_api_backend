# Frontera Data Labs API

API Python de solo lectura para consultar QuestDB y servir datos listos para el dashboard, ahora endurecida para demos en VPS con limites pequenos de logs, CPU, memoria y almacenamiento persistente.

## Stack

- FastAPI + httpx
- QuestDB en Docker Compose
- Nginx + Certbot en la VPS
- Storage loopback ext4 de 4 GB para aislar el crecimiento de QuestDB

## Arquitectura de despliegue

- `questdb` y `frontera-data-labs-api` viven en el mismo `docker-compose.yml`
- ambos contenedores rotan logs con `json-file` en `1m x 2`
- QuestDB usa una imagen fija configurable por `QUESTDB_IMAGE`
- el backend consulta QuestDB por red interna de Compose en `http://questdb:9000`
- QuestDB persiste datos dentro de `QUESTDB_DATA_DIR`, que debe vivir en el mount loopback de 4 GB
- Nginx mantiene `access_log off`, limita `/health` y `/api/` a `5r/s` por IP con `burst 20`, y rota su error log a `1 MB x 2`

## Endpoints

- `GET /health`
- `GET /api/deployments`
- `GET /api/deployments/{deployment_id}`
- `GET /api/deployments/{deployment_id}/telemetry?hours=24`

## Cambios operativos relevantes

- el backend reutiliza un solo `httpx.AsyncClient`
- `GET /api/deployments` ahora deduplica en SQL y cachea 30 segundos
- `GET /api/deployments/{deployment_id}` cachea 15 segundos
- `GET /api/deployments/{deployment_id}/telemetry` solo acepta hasta `24` horas y agrega la serie en buckets de 5 minutos
- el `Dockerfile` y Compose arrancan `uvicorn` con `--log-level error --no-access-log`

## Variables de entorno

Ejemplo base:

```env
APP_NAME=Frontera Data Labs API
APP_VERSION=0.1.0
API_HOST=0.0.0.0
API_PORT=8000
QUESTDB_BASE_URL=http://questdb:9000
API_CORS_ORIGINS=http://localhost:5174,https://your-frontend.onrender.com
QUERY_TIMEOUT_SECONDS=10
QUESTDB_IMAGE=questdb/questdb:8.2.2
QUESTDB_HTTP_PORT=9000
QUESTDB_PG_PORT=8812
QUESTDB_DATA_DIR=/srv/questdb-data/data
```

## Despliegue recomendado en la VPS

```bash
git clone <tu-repo>
cd FronteraDataLabs/frontera-data-labs-api
cp .env.example .env
nano .env
sudo bash setup_questdb.sh
sudo bash setup_https_proxy.sh --host <TU_HOST>
chmod +x deploy.sh
./deploy.sh
```

## Que hace `setup_questdb.sh`

- reserva un archivo loopback de 4 GB en `/srv/questdb-data.img`
- lo formatea como ext4
- lo monta en `/srv/questdb-data`
- persiste el mount en `/etc/fstab`
- crea `QUESTDB_DATA_DIR` dentro de ese filesystem acotado
- levanta el servicio `questdb` por Compose
- aplica limites de CPU, memoria y `pids`
- crea las tablas `devices`, `deployments` y `telemetria_datos`

## Que hace `deploy.sh`

- levanta `questdb` y `frontera-data-labs-api` con `docker compose up -d --build`
- reaplica limites duros de CPU, memoria y `pids` via `docker update`
- imprime el estado del stack y la politica de logs de ambos contenedores

## Verificaciones rapidas

```bash
curl http://127.0.0.1:8000/health
curl http://127.0.0.1:8000/api/deployments
curl --get http://127.0.0.1:8000/api/deployments/<DEPLOYMENT_ID>/telemetry --data-urlencode "hours=24"
docker inspect frontera-data-labs-api --format '{{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}}'
docker inspect questdb --format '{{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}}'
docker stats --no-stream
df -h / /srv/questdb-data
```

## Comportamiento esperado bajo presion

- si un contenedor se vuelve ruidoso, sus logs quedan acotados a unos pocos MB
- si hay trafico anormal, Nginx puede responder `429` en `/health` y `/api/`
- si QuestDB crece demasiado, llenara su filesystem loopback antes de dejar sin espacio la raiz de la VPS
- si la carga sube demasiado, los topes de CPU y memoria deben degradar el servicio antes de tumbar toda la maquina

## Notas para el frontend

- en el dashboard Vite configura `VITE_API_BASE_URL=https://<TU_HOST>`
- el endpoint de telemetria mantiene el mismo shape, pero ahora devuelve una serie agregada y acotada
