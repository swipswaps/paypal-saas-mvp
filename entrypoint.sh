#!/usr/bin/env bash
[ -f .env ] || cp .env.example .env
exec python app.py
