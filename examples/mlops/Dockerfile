FROM python:3.13-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN groupadd --gid 65532 app \
 && useradd --create-home --uid 65532 --gid 65532 app \
 && pip install --no-cache-dir uv==0.8.22

WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY ml_service ./ml_service
COPY schema.sql bootstrap.py smoke.py ./

USER 65532:65532
EXPOSE 8000
ENTRYPOINT ["/app/.venv/bin/uvicorn"]
CMD ["ml_service.app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2", "--no-access-log"]
