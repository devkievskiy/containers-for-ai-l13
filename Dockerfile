# Optimized, production-style image: multi-stage, slim base, non-root, HEALTHCHECK.
# Target: < 800 MB (we land far below — no heavy ML libs, embeddings are via the
# OpenAI API, so the runtime only needs fastapi/uvicorn/httpx/numpy/pydantic).

# ---- Stage 1: build dependencies into an isolated prefix ----
FROM python:3.11-slim AS builder
WORKDIR /build
COPY app/requirements.txt .
# Build/install wheels into /install so the runtime stage can copy just that.
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- Stage 2: slim runtime ----
FROM python:3.11-slim
# Run as a non-root user.
RUN useradd --create-home --uid 1000 appuser
WORKDIR /app

# Bring in only the installed packages (no build tooling, no pip cache).
COPY --from=builder /install /usr/local
# App code + data only (see .dockerignore for what's excluded).
COPY app ./app
COPY data ./data

USER appuser
EXPOSE 8000

# Healthcheck passes only when the RAG service has finished loading and the app
# reports {"status": "ok"} — uses stdlib so no curl needs to be installed.
HEALTHCHECK --interval=10s --timeout=3s --start-period=40s --retries=5 \
  CMD python -c "import json,sys,urllib.request; \
r=json.load(urllib.request.urlopen('http://localhost:8000/health')); \
sys.exit(0 if r.get('status')=='ok' else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
