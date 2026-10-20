#!/usr/bin/env bash
# fix4.sh — make /app writable so SQLite WAL can create -wal / -shm files
# Run: bash fix4.sh
(
set +e
trap 'echo "Interrupted — re-run bash fix4.sh"; exit 2' INT

if [ -n "${BASH_SOURCE[0]}" ]; then
  _d="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  [ -n "$_d" ] && cd "$_d"
fi

echo "==> cwd: $(pwd)"

# ---- 1. Stop and clean volumes ----
echo ""
echo "==> Stopping container and removing volumes"
docker compose down -v 2>&1 | tail -4

# ---- 2. Remove remaining root-owned files ----
echo ""
echo "==> Removing root-owned files"
for f in config/brand.json; do
  if [ -e "$f" ] && [ "$(stat -c '%u' "$f" 2>/dev/null)" = "0" ]; then
    rm -f "$f" && echo "    removed $f"
  fi
done
if [ -d static ]; then
  find static -maxdepth 2 -type f 2>/dev/null | while read -r f; do
    if [ "$(stat -c '%u' "$f" 2>/dev/null)" = "0" ]; then
      rm -f "$f" && echo "    removed $f"
    fi
  done
fi

# ---- 3. Reset writable dirs ----
echo ""
echo "==> Resetting writable paths"
mkdir -p config static/brand
chmod 0777 config static/brand
[ -f saas_shop.db ] || touch saas_shop.db
chmod 0666 saas_shop.db
stat -c '    %n owner=%u:%g mode=%a' saas_shop.db config static/brand

# ---- 4. Rewrite Dockerfile: /app writable ----
echo ""
echo "==> Rewriting Dockerfile to make /app writable"
cat > Dockerfile <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=5000 HOST=0.0.0.0
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY pyproject.toml ./
RUN pip install --no-cache-dir flask paypal-server-sdk python-dotenv requests Werkzeug cryptography
COPY --chown=1000:1000 . .
RUN chmod 0777 /app \
    && mkdir -p /app/config /app/static/brand \
    && chmod 0777 /app/config /app/static/brand
EXPOSE 5000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD curl -f http://localhost:${PORT:-5000}/health || exit 2
CMD ["python", "app.py"]
DOCKER

# ---- 5. Build ----
echo ""
echo "==> Building image"
docker compose build web 2>&1 | tail -6

# ---- 6. Pre-flight: does WAL work in the built image? ----
echo ""
echo "==> Pre-flight: WAL write as uid 1000 inside the new image"
docker run --rm --user 1000:1000 \
  -v "$(pwd)/saas_shop.db:/app/saas_shop.db" \
  paypal-saas-mvp_fail-web \
  python3 -c 'import sqlite3; c=sqlite3.connect("/app/saas_shop.db"); c.execute("PRAGMA journal_mode=WAL"); c.execute("CREATE TABLE IF NOT EXISTS _probe(x)"); c.commit(); c.close(); print("WAL OK")' 2>&1

# ---- 7. Start ----
echo ""
echo "==> Starting container"
docker compose up -d

# ---- 8. Readiness ----
echo ""
echo "==> Readiness (up to 60s)"
READY=0
for i in $(seq 1 30); do
  CODE=$(curl -s -o /tmp/_f4_$$ -w '%{http_code}' http://localhost:5000/health)
  echo "  probe $i: HTTP $CODE"
  if [ "$CODE" = "200" ]; then READY=1; break; fi
  sleep 2
done
rm -f /tmp/_f4_$$

if [ "$READY" -ne 1 ]; then
  echo ""
  echo "ERROR: backend not ready"
  docker compose logs --tail=30 web
  exit 2
fi

# ---- 9. Verify ----
echo ""
echo "==> Container user"
docker compose exec -T web id 2>&1

echo ""
echo "==> /app writable by container user"
docker compose exec -T web sh -c 'touch /app/_w && rm /app/_w && echo "yes: /app is writable"' 2>&1

echo ""
echo "==> /app ownership"
docker compose exec -T web ls -ld /app /app/saas_shop.db 2>&1

echo ""
echo "==> Health payload"
curl -s http://localhost:5000/health
echo ""

# ---- 10. Tests ----
echo ""
echo "==> extended_test.sh"
bash extended_test.sh
EXT_RC=$?

echo ""
echo "==> setup_test.sh"
if [ -f setup_test.sh ]; then
  bash setup_test.sh
  SETUP_RC=$?
else
  SETUP_RC="absent"
fi

echo ""
echo "DONE."
echo "  extended_test.sh exit: $EXT_RC"
echo "  setup_test.sh exit:    $SETUP_RC"
exit 0
)
