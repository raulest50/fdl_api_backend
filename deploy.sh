#!/usr/bin/env bash
set -euo pipefail

if [ ! -f .env ]; then
  echo "Missing .env file. Copy .env.example to .env first."
  exit 1
fi

docker compose up -d --build
docker update --cpus 0.25 --memory 256m --memory-swap 256m --pids-limit 128 frontera-data-labs-api >/dev/null
docker update --cpus 0.50 --memory 768m --memory-swap 768m --pids-limit 256 questdb >/dev/null
docker compose ps
docker inspect frontera-data-labs-api --format '{{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}}'
docker inspect questdb --format '{{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}}'
