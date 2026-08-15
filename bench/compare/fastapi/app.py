"""FastAPI, matching the other two exactly.

Pydantic does the validation the other two do explicitly, and the response
model emits the same three fields.  Access logging is off: writing a line per
request measures the terminal.
"""
import os

import asyncpg
from fastapi import FastAPI, Path
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
pool: asyncpg.Pool | None = None

POOL_SIZE = int(os.environ.get("POOL", "10"))


@app.on_event("startup")
async def startup() -> None:
    global pool
    pool = await asyncpg.create_pool(
        host="127.0.0.1", port=55432, database="akkar",
        user="postgres", password="akkar",
        min_size=POOL_SIZE, max_size=POOL_SIZE,
    )


@app.exception_handler(RequestValidationError)
async def validation_error(_request, exc: RequestValidationError) -> JSONResponse:
    # The same shape AND the same distinction the other two make: 0 is an
    # integer that fails the minimum, not a type failure.  Pydantic already
    # knows which; this just reports it the way the others do.
    kind = exc.errors()[0].get("type", "") if exc.errors() else ""
    message = "min is 1" if "greater_than" in kind else "expected integer"
    return JSONResponse(
        status_code=422,
        content={"error": "validation failed", "fields": {"params.id": message}},
    )


@app.get("/ping")
async def ping() -> dict:
    return {"pong": True}


@app.get("/users/{id}")
async def get_user(id: int = Path(ge=1)) -> JSONResponse:
    row = await pool.fetchrow(
        "select id, name, email from users where id = $1", id)
    if row is None:
        return JSONResponse(status_code=404, content={"error": "user not found"})
    return JSONResponse(
        content={"id": row["id"], "name": row["name"], "email": row["email"]})


@app.get("/rows/{n}")
async def rows(n: int = Path(ge=1, le=5000)) -> JSONResponse:
    """Variable payload, to find where serialisation starts to dominate."""
    result = await pool.fetch(
        "select id, name, email from users order by id limit $1", n)
    return JSONResponse(content={"users": [
        {"id": r["id"], "name": r["name"], "email": r["email"]} for r in result]})
