# Lesson 13 — Containers for AI

Containerizing the RAG FAQ service: a naive baseline image vs an optimized,
production-style image, plus a full `docker-compose` stack (app + Qdrant + Redis
+ Langfuse).

## Metrics: naive vs multi-stage

| Metric | Naive (`Dockerfile.naive`) | Multi-stage (`Dockerfile`) |
|---|---|---|
| **Image size** | 1.81 GB | **351 MB** (−81%) |
| **Build time** (no-cache, base image cached) | 77 s | 70 s |
| **Rebuild after code change** | 84 s | **4 s** (~20× faster) |
| **Cold start** (`docker run` → `/health=ok`) | 3.2 s | 6.2 s* |

\* Cold start is dominated by the one-time startup work of embedding the 20 FAQ
docs via the OpenAI API (a network call), **not** by the image — a local
container starts from an already-present image regardless of its size, so the
~3 s gap here is OpenAI API-latency noise between runs, not an image effect.

### Why the optimized image wins

- **Size (1.81 GB → 351 MB):** `python:3.11` (full, ~1 GB) → `python:3.11-slim`,
  and a **multi-stage** build — dependencies are installed in a builder stage and
  only the resulting packages are copied into the slim runtime (no pip cache, no
  build toolchain, no `tests/`/docs — see `.dockerignore`). No heavy ML libs are
  needed because embeddings are done via the OpenAI API.
- **Rebuild (84 s → 4 s):** the naive image does `COPY . .` *then*
  `RUN pip install`, so **any** code change busts the dependency layer and
  reinstalls everything. The optimized image copies `requirements.txt` and
  installs deps **before** copying app code, so a code change only rebuilds the
  tiny app-copy layer — deps stay cached.

## Production hardening (optimized image)

- **Multi-stage build** — builder stage compiles/installs deps; runtime stage
  carries only the installed packages + app code.
- **Non-root** — runs as `appuser` (uid 1000). Verified: `docker exec <c> whoami`
  → `appuser`.
- **HEALTHCHECK** — polls `/health` with stdlib `urllib` (no `curl` installed)
  and is healthy only when the service reports `{"status":"ok"}` (i.e. after the
  RAG index has loaded). Verified: `docker inspect --format '{{.State.Health.Status}}'`
  → `healthy`.
- **No secrets in the image** — `.env` is `.dockerignore`'d; `OPENAI_API_KEY` is
  passed at runtime (`--env-file .env` / compose `env_file`).

## docker-compose stack

`docker-compose.yml` brings up the full local stack on one network:

| Service | Image | Port | Role |
|---|---|---|---|
| `app` | built from `Dockerfile` | 8000 | the RAG FAQ service |
| `qdrant` | `qdrant/qdrant:v1.12.4` | 6333 | vector DB |
| `redis` | `redis:7-alpine` | 6379 | cache |
| `langfuse` | `langfuse/langfuse:2` | 3000 | observability UI |
| `langfuse-db` | `postgres:16-alpine` | — | Langfuse's database |

## How to run

```bash
# 1. configure
cp .env.example .env          # then put your real OPENAI_API_KEY in .env

# 2a. single optimized container
docker build -t rag-faq:optimized .
docker run -d --env-file .env -p 8000:8000 rag-faq:optimized

# 2b. or the full stack
docker compose up -d
docker compose ps

# 3. query it
curl -s http://localhost:8000/health
curl -s -X POST http://localhost:8000/ask \
  -H "Content-Type: application/json" \
  -d '{"question":"What is RAG?"}'
```

### Example `/ask` response

```json
{
  "answer": "RAG stands for Retrieval-Augmented Generation, ... grounded on external documents fetched at query time ...",
  "sources": [
    {"score": 0.65, "question": "What is RAG?", "answer": "..."},
    {"score": 0.55, "question": "What is chunking in RAG?", "answer": "..."},
    {"score": 0.31, "question": "What is hallucination?", "answer": "..."}
  ]
}
```

## Screenshots

See `screenshots/`:
- `docker_images.txt` — both images with sizes (1.81 GB vs 351 MB)
- `curl_ask.txt` — live `/ask` request + grounded response
- `compose_ps.txt` — `docker compose ps` with the full stack running
