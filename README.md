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
cp .env.example .env
nano .env
chmod +x deploy.sh
./deploy.sh
```

La API quedara escuchando en `127.0.0.1:8000`.

## Workflow recomendado

1. Hacer `git pull` en la VPS cuando subas cambios nuevos al repo.
2. Entrar a `FronteraDataLabs/frontera-data-labs-api`.
3. Ejecutar `./deploy.sh`.
4. Verificar con `curl http://127.0.0.1:8000/health`.
5. Si todo responde bien, el frontend en Render solo necesita apuntar `VITE_API_BASE_URL` al dominio HTTPS de esta API.

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
