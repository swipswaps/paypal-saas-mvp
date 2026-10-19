#!/usr/bin/env bash
if [ ! -f .env ]; then
  echo "[entrypoint] .env missing; copying .env.example"
  cp .env.example .env
fi
echo "[entrypoint] starting Flask on 0.0.0.0:5000"
exec python app.py
