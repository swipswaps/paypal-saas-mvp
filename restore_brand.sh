#!/usr/bin/env bash
# restore_brand.sh — restore config/brand.json from a snapshot
# Usage: bash restore_brand.sh [snapshot.json] [service]
(
set +e
SNAP="${1:-}"
SERVICE="${2:-web}"

if [ -z "$SNAP" ]; then
  for candidate in config/brand.json.bak /tmp/brand_snapshot.json /tmp/_brand_snapshot.json; do
    if [ -f "$candidate" ]; then SNAP="$candidate"; break; fi
  done
fi

if [ -z "$SNAP" ] || [ ! -f "$SNAP" ]; then
  echo "restore_brand.sh: no snapshot found"
  echo "  Usage: bash restore_brand.sh <snapshot.json> [service]"
  exit 2
fi

if cp "$SNAP" config/brand.json 2>&1; then
  echo "restore_brand.sh: restored $SNAP to config/brand.json (host)"
  exit 0
fi

CONT=$(docker compose ps -q "$SERVICE" 2>&1)
if [ -z "$CONT" ]; then
  echo "restore_brand.sh: host cp failed and no '$SERVICE' container running"
  exit 2
fi

docker cp "$SNAP" "$CONT:/tmp/_restore_brand.json" 2>&1 || { echo "restore_brand.sh: docker cp failed"; exit 2; }
docker exec -u root "$CONT" sh -c \
  'mkdir -p /app/config && cp /tmp/_restore_brand.json /app/config/brand.json && chmod 666 /app/config/brand.json && rm -f /tmp/_restore_brand.json' 2>&1 \
  || { echo "restore_brand.sh: docker exec failed"; exit 2; }
echo "restore_brand.sh: restored $SNAP via docker"
)
