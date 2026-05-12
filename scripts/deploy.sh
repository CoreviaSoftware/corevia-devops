#!/usr/bin/env bash
# Pull latest images and (re)start the stack.
# Run from the repo root on the server:  bash scripts/deploy.sh
# Pin a specific build:  IMAGE_TAG_BE=sha-abc1234 IMAGE_TAG_FE=sha-abc1234 bash scripts/deploy.sh

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo ".env missing. Copy .env.production.example to .env and edit it." >&2
  exit 1
fi

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.prod.yml)

echo "==> Pulling images"
"${COMPOSE[@]}" pull

echo "==> Starting / updating stack"
"${COMPOSE[@]}" up -d --remove-orphans

echo "==> Stack status"
"${COMPOSE[@]}" ps

echo
echo "Tail logs with:    ${COMPOSE[*]} logs -f"
echo "Backend health:    ${COMPOSE[*]} exec backend wget -qO- http://localhost:3001/actuator/health"
