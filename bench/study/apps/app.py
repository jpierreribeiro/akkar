"""The FastAPI side, configured the way its own community would configure it.

The first run of the old comparison had FastAPI at 2,433 req/s because
`uvicorn` was installed instead of `uvicorn[standard]` -- asyncio and h11
rather than uvloop and httptools. It would have made akkar look 11.8x faster
than a framework that is actually faster than akkar. So: uvloop, httptools,
and ORJSONResponse, which is what `orjson` was installed for and never used.
"""
import os

import asyncpg
from fastapi import FastAPI
from fastapi.responses import ORJSONResponse

app = FastAPI(default_response_class=ORJSONResponse)
pool = None


@app.on_event("startup")
async def startup():
    global pool
    size = int(os.environ.get("POOL_SIZE", "10"))
    pool = await asyncpg.create_pool(
        host="127.0.0.1", port=55432, database="akkar",
        user="postgres", password="akkar",
        min_size=size, max_size=size,
    )


@app.get("/ping")
async def ping():
    return {"pong": True}


@app.get("/users/{user_id}")
async def user(user_id: int):
    row = await pool.fetchrow(
        "select id, name, email from users where id = $1", user_id)
    if row is None:
        return ORJSONResponse({"error": "user not found"}, status_code=404)
    return dict(row)


@app.get("/rows/{n}")
async def rows(n: int):
    records = await pool.fetch(
        "select id, name, email, note from bench_rows order by id limit $1", n)
    return {"rows": [dict(r) for r in records]}
