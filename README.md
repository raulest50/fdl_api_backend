# Frontera Data Labs API

API Python de solo lectura para consultar QuestDB y servir datos listos para el dashboard.

## Stack

- FastAPI
- httpx
- Docker Compose
- Nginx + Let's Encrypt en la VPS

## Estructura

```text
frontera-data-labs-api/
  app/
    main.py
    config.py
    models.py
    questdb.py
    routes/
  Dockerfile
  docker-compose.yml
  .env.example
  deploy.sh
  setup_questdb.sh
  setup_https_proxy.sh
```

## Endpoints

- `GET /health`
- `GET /api/deployments`
- `GET /api/deployments/{deployment_id}`
- `GET /api/deployments/{deployment_id}/telemetry?hours=24`

## Despliegue rapido en la VPS

```bash
git clone <tu-repo>
cd FronteraDataLabs/frontera-data-labs-api
sudo bash setup_questdb.sh
cp .env.example .env
nano .env
chmod +x deploy.sh
./deploy.sh
```

La API quedara escuchando en `127.0.0.1:8000`.

QuestDB quedara disponible en `http://127.0.0.1:9000`.

## Workflow recomendado

1. Hacer `git pull` en la VPS cuando subas cambios nuevos al repo.
2. Entrar a `FronteraDataLabs/frontera-data-labs-api`.
3. Ejecutar `sudo bash setup_questdb.sh` si la VPS es nueva o si QuestDB no existe.
4. Ejecutar `./deploy.sh`.
5. Verificar con `curl http://127.0.0.1:8000/health`.
6. Confirmar la politica de logs del contenedor con la salida de `docker inspect` que imprime el script.
7. Si todo responde bien, el frontend en Render solo necesita apuntar `VITE_API_BASE_URL` al dominio HTTPS de esta API.

## Setup de QuestDB

Para reconstruir QuestDB desde cero en una VPS limpia:

```bash
sudo bash setup_questdb.sh
```

El script:

- crea un volumen persistente Docker para QuestDB
- descarga y levanta `questdb/questdb`
- publica:
  - `9000` para Web Console y REST API
  - `8812` para PostgreSQL wire protocol
- crea automaticamente las tablas base:
  - `devices`
  - `deployments`
  - `telemetria_datos`

Verificaciones rapidas:

```bash
docker ps
curl http://127.0.0.1:9000
curl --get http://127.0.0.1:9000/exec --data-urlencode "query=SHOW TABLES;"
```

## Proxy HTTPS sin comprar dominio

Si no quieres comprar dominio, puedes usar un hostname gratis basado en tu IP con `sslip.io`.

Ejemplo para esta VPS:

```bash
sudo bash setup_https_proxy.sh --host 187.124.90.77.sslip.io
```

Opcionalmente puedes pasar email a Certbot:

```bash
sudo bash setup_https_proxy.sh --host 187.124.90.77.sslip.io --email tu-correo@ejemplo.com
```

Cuando termine, la API quedara disponible en:

```text
https://187.124.90.77.sslip.io
```

Y en Render deberias configurar:

```env
VITE_API_BASE_URL=https://187.124.90.77.sslip.io
```

## Variables de entorno

- `QUESTDB_BASE_URL=http://127.0.0.1:9000`
- `API_PORT=8000`
- `API_CORS_ORIGINS=http://localhost:5174,https://tu-frontend.onrender.com`

## Logging de produccion

Por defecto, el backend queda en modo silencioso de produccion:

- `uvicorn --log-level error --no-access-log`
- Docker con rotacion `json-file`
- `max-size=50m`
- `max-file=3`
- Nginx con `access_log off`

Esto busca evitar que stdout/stderr del contenedor vuelva a crecer sin limite y que el disco de la VPS se llene por logs de acceso normales.

## Variable del frontend

En el dashboard Vite, configura:

```env
VITE_API_BASE_URL=https://api.tudominio.com
```

## Nginx recomendado

Ejemplo de server block:

```nginx
server {
    server_name api.tudominio.com;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Luego emite TLS con Certbot:

```bash
sudo certbot --nginx -d api.tudominio.com
```

Despues de eso, ya no hace falta exponer QuestDB al navegador. El flujo queda:

- dashboard en Render -> `https://api.tudominio.com`
- API FastAPI en la VPS -> `http://127.0.0.1:9000/exec`
- QuestDB sigue privado detras de la API

## Pruebas

```bash
curl http://127.0.0.1:8000/health
curl http://127.0.0.1:8000/api/deployments
```

## Verificacion de logs

```bash
docker inspect frontera-data-labs-api --format '{{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}}'
docker logs --tail 50 frontera-data-labs-api
```

La primera linea debe mostrar `json-file` con `max-size` y `max-file`. La segunda no deberia llenarse con un log por cada request normal.

## Tech Stack Actual

- Frontend: React 19 + TypeScript 6 + Vite 8 + Cesium + Resium, desplegado como Static Site en Render.
- Backend API: FastAPI + httpx + uvicorn, empaquetado con Docker sobre `python:3.12-slim`.
- Orquestacion local en VPS: Docker Compose con un contenedor para la API.
- Base de datos: QuestDB en Docker, expuesto en la VPS y consumido por la API via HTTP `/exec`.
- Sistema operativo VPS: Ubuntu 24.04.
- Proxy reverso: Nginx en la VPS, apuntando a `127.0.0.1:8000`.
- HTTPS sin comprar dominio: hostname gratuito basado en IP con `sslip.io`, mas Certbot + Let's Encrypt para TLS.
- Publicacion del frontend: Render consume la API por HTTPS mediante `VITE_API_BASE_URL`.

## Posibles focos de ineficiencia

- QuestDB puede elevar CPU si recibe consultas frecuentes, sin filtros eficientes, o muchas lecturas repetidas del mismo nodo.
- La API FastAPI puede gastar CPU si se redepliega seguido, si hay polling agresivo desde el frontend, o si cada request dispara varias consultas seriales.
- Docker por si solo no suele ser el cuello de botella principal aqui, pero si el disco esta lleno puede degradar mucho todo el stack.
- Nginx y Certbot normalmente no deberian ser la causa principal de CPU alta en este montaje.
- `sslip.io` aporta resolucion de nombre, pero no deberia explicar CPU alta sostenida en la VPS.
