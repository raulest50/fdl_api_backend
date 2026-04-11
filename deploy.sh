#!/usr/bin/env bash
set -euo pipefail

if [ ! -f .env ]; then
  echo "Missing .env file. Copy .env.example to .env first."
  exit 1
fi

docker compose up -d --build
docker compose ps
