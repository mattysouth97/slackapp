# syntax=docker/dockerfile:1.6
# kimbiseo Slack bot - production image for Fly.io
#
# Base: python:3.11-slim (Debian Bookworm slim). Korean-text-heavy bot.
# PDF *output* (services/pdf_writer.py via fpdf2) DOES render glyphs
# server-side and needs an embedded CJK font - fonts-noto-cjk is installed
# below. HWPX stays XML-first; PDF *intake* prefers the Anthropic native
# document path with pypdfium2 as the fallback. UTF-8 locale is set
# explicitly for subprocess inheritance (the Windows CP949 bug - Linux
# defaults differ but explicit beats implicit).
FROM python:3.11-slim AS runtime

# UTF-8 everywhere - defeats locale-inherited CP949 / ASCII-7 subprocess crashes.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONIOENCODING=utf-8 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Install OS deps. Kept minimal:
# - ca-certificates: HTTPS to api.anthropic.com / slack.com / notion.so
# - tzdata: APScheduler Friday-cycle cron needs Asia/Seoul timezone (added when KB ships)
# - fonts-noto-cjk: embedded CJK font for PDF output (services/pdf_writer.py).
#   Without it, format='pdf' raises PdfFontError on Linux (no malgun.ttf).
# Build tools intentionally omitted - every pinned wheel below has prebuilt
# manylinux distributions. If a future dep needs gcc, add `build-essential`
# in a multi-stage builder layer rather than the runtime image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/*

# Install Python deps before copying app code so layer caching survives
# code changes. Includes pyhwp (missing from requirements.txt today -
# needed by skills/propose/scripts/extract_hwp.py for binary HWP intake).
COPY requirements.txt .
RUN pip install -r requirements.txt \
    && pip install "pyhwp>=0.1.1"

# App code. .dockerignore strips: .venv, .git, .omc/state, .env, docs,
# tests, *.pyc, __pycache__. The bundled skills/ directory IS shipped
# (propose + hwpx-core are runtime deps, not just dev artifacts).
COPY . .

# Persistent state volume mount point. Empty at image-build time; populated
# by fly volume on first boot. The fly.toml mounts a Fly volume here.
# KIMBISEO_JOBS_DB_PATH=/data/kimbiseo_jobs.db is set via fly secrets.
RUN mkdir -p /data

# Slack Socket Mode uses an outbound WSS connection - no inbound HTTP port.
# Fly process-died restart is the only health check (per Q9 grilling).
# Slack Bolt's SocketModeHandler reconnects internally on WSS drops.
CMD ["python", "app.py"]