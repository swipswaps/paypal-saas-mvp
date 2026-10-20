#!/usr/bin/env bash
# fingerprint-port.sh — identify what is listening on PORT (default 5000)
PORT="${1:-5000}"
OUT="/tmp/_fprint_$$"
echo "=== Fingerprinting port $PORT ==="
echo ""
echo "--- lsof -i :$PORT ---"
lsof -i :$PORT > "$OUT" 2>&1
if [ -s "$OUT" ]; then cat "$OUT"; else echo "  (no match, or lsof needs sudo)"; fi
echo ""
echo "--- ss -tlnp | grep :$PORT ---"
ss -tlnp > "$OUT" 2>&1
if grep -q ":$PORT " "$OUT"; then grep ":$PORT " "$OUT"
else echo "  (nothing listening, or no permission to read process info)"; fi
echo ""
echo "--- HTTP headers from / ---"
curl -s -I "http://localhost:$PORT/" > "$OUT" 2>&1
if [ -s "$OUT" ]; then head -8 "$OUT"; else echo "  (no HTTP response)"; fi
echo ""
echo "--- HTTP headers from /health ---"
curl -s -I "http://localhost:$PORT/health" > "$OUT" 2>&1
if [ -s "$OUT" ]; then head -8 "$OUT"; else echo "  (no HTTP response)"; fi
echo ""
echo "=== Interpretations ==="
echo "  Server: Werkzeug/…            -> our Flask app (or another Flask)"
echo "  Server: AirTunes/… or 403     -> macOS AirPlay Receiver"
echo "  /v2/ returns JSON errors      -> Docker Registry"
echo "  Server: uvicorn               -> FastAPI/Uvicorn"
echo "  Server: nginx / Apache        -> reverse proxy in front of something"
echo ""
echo "=== Fixes ==="
echo "  Move our app to another port:"
echo "    add PORT=5001 to .env; docker compose up -d --build"
echo "  Stop our previous container:"
echo "    docker compose down"
echo "  Stop a stray local app:"
echo "    pkill -f 'python app.py'"
echo "  Disable macOS AirPlay Receiver:"
echo "    System Settings > General > AirDrop & Handoff > AirPlay Receiver"
rm -f "$OUT"
