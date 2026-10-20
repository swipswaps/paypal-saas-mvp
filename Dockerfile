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
