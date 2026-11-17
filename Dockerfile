# syntax=docker/dockerfile:1.7
# ---------- Stage 1: build dependencies ----------
# Python minor version matches the distroless runtime (3.11, Debian 12) so compiled wheels are ABI-compatible.
FROM python:3.11-slim-bookworm@sha256:a83ba18aef0f865b1a4a611c2cf460fe446f2795673bbb9fe43be570439e3b39 AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build
COPY requirements.txt .
# Install into an isolated prefix that is copied wholesale into the runtime image.
RUN pip install --no-compile --target /deps -r requirements.txt \
    && find /deps -type d -name "__pycache__" -prune -exec rm -rf {} + \
    && rm -rf /deps/*.dist-info/RECORD

# ---------- Stage 2: minimal runtime ----------
# Distroless: no shell, no package manager, runs as UID 65532 ("nonroot").
FROM gcr.io/distroless/python3-debian12:nonroot@sha256:7d1042ce588ab97019fe95c24ffca7bc5a82ccdac572511d5e09bda4435c89c5

ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="devops-task" \
      org.opencontainers.image.description="Small FastAPI service for the DevOps assessment" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/nayan9744-web/devops-assessment" \
      org.opencontainers.image.licenses="MIT"

ENV PYTHONPATH=/deps \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080 \
    APP_VERSION=${APP_VERSION}

WORKDIR /app
COPY --from=builder --chown=65532:65532 /deps /deps
COPY --chown=65532:65532 app/ ./app/

USER 65532:65532
EXPOSE 8080

# No curl/wget in distroless, so the healthcheck uses the bundled Python interpreter.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python3", "-c", "import os,urllib.request,sys; urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"PORT\",\"8080\")}/health', timeout=2); sys.exit(0)"]

# Exec form => python is PID 1 and receives SIGTERM directly for graceful shutdown.
ENTRYPOINT ["python3", "-m", "app"]
