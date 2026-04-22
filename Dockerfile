# syntax=docker/dockerfile:1.7
# ── Stage 1: Build ──────────────────────────────────────────────────────
# Matches the postgres_rdkit_docker base (Debian 12 bookworm) so system
# library versions (libpq, libxml2, boost) stay aligned between the app
# and DB containers.
ARG PYTHON_VERSION=3.8
FROM python:${PYTHON_VERSION}-slim-bookworm AS builder

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Dev headers required by C extensions: psycopg2, freesasa, lxml, Cython, Pillow (reportlab).
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        libpq-dev \
        libxml2-dev \
        libxslt1-dev \
        libfreetype6-dev \
        libjpeg-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /build
COPY pyproject.toml README.md ./
COPY uv.lock* ./

RUN --mount=type=cache,target=/root/.cache/uv \
    if [ -f uv.lock ]; then \
        uv sync --frozen --no-dev --no-install-project; \
    else \
        uv sync --no-dev --no-install-project; \
    fi

# ── Stage 2: Runtime ────────────────────────────────────────────────────
FROM python:${PYTHON_VERSION}-slim-bookworm

LABEL org.opencontainers.image.title="protwis Django Runtime"
LABEL org.opencontainers.image.description="Python runtime for the protwis Django application (GPCRdb)"
LABEL org.opencontainers.image.source="https://github.com/protwis/protwis_django_docker"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# Runtime shared libraries only (no -dev packages).
# libxrender1 / libxext6 are required by rdkit.Chem.Draw (transitively pulled
# by datamol) — the Python wheel dlopens them at import time.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 \
        libxml2 \
        libxslt1.1 \
        libfreetype6 \
        libjpeg62-turbo \
        libxrender1 \
        libxext6 \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    VIRTUAL_ENV=/opt/venv

# protwis source is bind-mounted here at runtime; image is code-free.
WORKDIR /app/src
EXPOSE 8000

CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]
