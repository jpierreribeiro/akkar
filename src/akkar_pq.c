/*
 * akkar.pq -- Postgres over libpq, asynchronous, for cqueues.
 *
 * WHY THIS EXISTS, with the number that justifies it.
 *
 * `bench/compare/RESULTS.md`: the same query against the same Postgres on the
 * same box costs 32 us through pgx, 82 us through asyncpg and 330 us through
 * pgmoon. `docs/PERFORMANCE-STUDY.md` decomposes the akkar side and finds
 * that pgmoon's fetch and row decoding is 85-99% of the request at every
 * payload size, while cjson.encode never exceeds 10.6%. Per row, pgmoon costs
 * 10.2 us against cjson's 1.28 us.
 *
 * Half of that is the socket layer -- pgmoon reads a five byte header and
 * then a body, once per protocol message, and Postgres sends one message per
 * row, so a thousand rows cost 2,006 socket reads averaging 22 bytes. The
 * other half is building one Lua table per row in the interpreter.
 *
 * Both halves are what libpq does in C and what this module borrows.
 *
 * WHAT IS NOT BORROWED, deliberately: the waiting.
 *
 * A C function cannot yield into a cqueues controller without reaching into
 * the scheduler, and a driver that blocks the event loop would trade the 330
 * us for something far more expensive -- `docs/PLAN.md` records that pgmoon
 * yielding is worth 7.56x out of a possible 8x, and that property is not for
 * sale. So this module never waits. It exposes libpq's socket and its
 * non-blocking primitives, and `akkar/pq.lua` does every wait with
 * `cqueues.poll`, in Lua, where it can be read.
 *
 * The connection userdata answers `pollfd`, `events` and `timeout`, which is
 * the protocol cqueues polls by, so `cqueues.poll(conn)` works on it directly
 * with no wrapper object in between.
 */

#include <string.h>
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>

#include "libpq-fe.h"

#define AKKAR_PQ_CONN "akkar.pq.conn"

/* Postgres type OIDs. Only the ones worth converting; everything else comes
 * back as the text libpq gives us, which is what pgmoon does for exotic types
 * as well. */
#define OID_BOOL        16
#define OID_INT8        20
#define OID_INT2        21
#define OID_INT4        23
#define OID_TEXT        25
#define OID_JSON       114
#define OID_FLOAT4     700
#define OID_FLOAT8     701
#define OID_VARCHAR   1043
#define OID_NUMERIC   1700
#define OID_JSONB     3802

typedef struct {
  PGconn *conn;
  int     closed;
} akkar_conn;

/* Module-wide rather than per connection: it is a decoding policy, and a
 * process that wants exact numerics wants them on every connection it holds.
 * See the NUMERIC branch of `push_field`. */
static int numeric_as_string = 0;

static akkar_conn *check_conn(lua_State *L, int index) {
  akkar_conn *c = (akkar_conn *)luaL_checkudata(L, index, AKKAR_PQ_CONN);
  if (c->closed || c->conn == NULL)
    luaL_error(L, "akkar.pq: connection is closed");
  return c;
}

/* ------------------------------------------------------------- connecting */

/* Starts a connection and returns immediately. The caller polls it. */
static int pq_connect_start(lua_State *L) {
  const char *conninfo = luaL_checkstring(L, 1);

  akkar_conn *c = (akkar_conn *)lua_newuserdata(L, sizeof(akkar_conn));
  c->conn = NULL;
  c->closed = 0;
  luaL_getmetatable(L, AKKAR_PQ_CONN);
  lua_setmetatable(L, -2);

  c->conn = PQconnectStart(conninfo);
  if (c->conn == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, "akkar.pq: out of memory starting connection");
    return 2;
  }
  if (PQstatus(c->conn) == CONNECTION_BAD) {
    lua_pushnil(L);
    lua_pushstring(L, PQerrorMessage(c->conn));
    return 2;
  }
  /* Non-blocking from the first byte: every send after this returns rather
   * than parking the OS thread, which is the whole premise. */
  if (PQsetnonblocking(c->conn, 1) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, PQerrorMessage(c->conn));
    return 2;
  }
  return 1;
}

/* One step of the connect handshake. Returns what to wait for next. */
static int pq_connect_poll(lua_State *L) {
  akkar_conn *c = check_conn(L, 1);
  switch (PQconnectPoll(c->conn)) {
    case PGRES_POLLING_READING: lua_pushstring(L, "r");    return 1;
    case PGRES_POLLING_WRITING: lua_pushstring(L, "w");    return 1;
    case PGRES_POLLING_OK:      lua_pushstring(L, "ok");   return 1;
    case PGRES_POLLING_FAILED:
    default:
      lua_pushstring(L, "failed");
      lua_pushstring(L, PQerrorMessage(c->conn));
      return 2;
  }
}

/* ------------------------------------------------------- the poll protocol */

static int pq_pollfd(lua_State *L) {
  akkar_conn *c = check_conn(L, 1);
  lua_pushinteger(L, PQsocket(c->conn));
  return 1;
}

/* What the connection is currently waiting for. Set by the Lua side before
 * each poll, because only the caller knows whether it is mid-send or
 * mid-receive; defaulting to read is right for every state but flushing. */
static int pq_events(lua_State *L) {
  akkar_conn *c = check_conn(L, 1);
  lua_getuservalue(L, 1);
  if (lua_istable(L, -1)) {
    lua_getfield(L, -1, "events");
    if (lua_isstring(L, -1)) return 1;
    lua_pop(L, 2);
  } else {
    lua_pop(L, 1);
  }
  (void)c;
  lua_pushstring(L, "r");
  return 1;
}

static int pq_set_events(lua_State *L) {
  check_conn(L, 1);
  luaL_checkstring(L, 2);
  lua_getuservalue(L, 1);
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushvalue(L, -1);
    lua_setuservalue(L, 1);
  }
  lua_pushvalue(L, 2);
  lua_setfield(L, -2, "events");
  return 0;
}

/* cqueues asks for this; a connection has no deadline of its own, and the
 * caller's deadline is applied by whoever calls poll. */
static int pq_timeout(lua_State *L) {
  lua_pushnil(L);
  return 1;
}

/* ---------------------------------------------------------------- querying */

/* Sends a parameterised query without waiting for it to drain.
 *
 * PARAMETERS CARRY THEIR TYPE, and getting that wrong is the single most
 * expensive mistake this project has measured: pgmoon declared every Lua
 * number `numeric`, which against an integer column is a cross-type
 * comparison Postgres cannot answer from the index -- 3.287 ms and a
 * sequential scan against 0.153 ms and an index scan, on ten thousand rows.
 * `akkar/db.lua` documents it in full. The same rule is applied here at the
 * source: a Lua integer is int8, a float is float8, and neither is numeric.
 */
static int pq_send_query(lua_State *L) {
  akkar_conn *c = check_conn(L, 1);
  const char *sql = luaL_checkstring(L, 2);
  int n = 0;

  if (!lua_isnoneornil(L, 3)) {
    luaL_checktype(L, 3, LUA_TTABLE);
    /* `n` WINS OVER THE LENGTH OPERATOR, and the reason is the only value
     * that cannot be counted: nil.
     *
     * `table.pack(nil)` produces `{n = 1}` with no element at index 1, so
     * `lua_rawlen` answers 0 and the parameter vanishes -- which is exactly
     * the case where a caller means SQL NULL. Postgres then rejects the bind
     * with "supplies 0 parameters, but prepared statement requires 1", which
     * is the polite version; the impolite version is a trailing nil silently
     * dropped from a longer list and a query that binds the wrong columns. */
    lua_getfield(L, 3, "n");
    if (lua_isinteger(L, -1)) n = (int)lua_tointeger(L, -1);
    else n = (int)lua_rawlen(L, 3);
    lua_pop(L, 1);
  }
  if (n > 65535) return luaL_error(L, "akkar.pq: too many parameters");

  Oid         *types  = NULL;
  const char **values = NULL;
  int         *lengths = NULL;
  int         *formats = NULL;

  if (n > 0) {
    types   = (Oid *)calloc((size_t)n, sizeof(Oid));
    values  = (const char **)calloc((size_t)n, sizeof(char *));
    lengths = (int *)calloc((size_t)n, sizeof(int));
    formats = (int *)calloc((size_t)n, sizeof(int));
    if (!types || !values || !lengths || !formats) {
      free(types); free((void *)values); free(lengths); free(formats);
      return luaL_error(L, "akkar.pq: out of memory binding parameters");
    }
  }

  /* The converted strings are pushed onto the stack and stay there until
   * PQsendQueryParams has copied them, so nothing here outlives its buffer.
   *
   * WHICH IS WHY THE STACK HAS TO BE GROWN FIRST. The C API guarantees only
   * LUA_MINSTACK (20) free slots on entry, and the check above admits n up to
   * 65535. Past the guarantee, lua_rawgeti and lua_pushstring write beyond the
   * frame: api_check compiles out under NDEBUG, so it is silent heap
   * corruption rather than an error. Measured with this exact push pattern and
   * no other change: n=28 clean, n=40 and n=200 hang, n=1000 dumps core. The
   * threshold moves with the Lua stack depth at the call site, so in a server
   * the same query can corrupt quietly on one path and crash on another --
   * worse than a crash, because it is silent.
   *
   * Reachable from ordinary code: `Query:where_in(column, values)` in
   * akkar/sql.lua emits one placeholder per element with no bound on the
   * array, so a handler doing `where_in("id", body.ids)` over a client-supplied
   * list is enough. */
  if (!lua_checkstack(L, n + 4))
    return luaL_error(L, "akkar.pq: %d parameters do not fit on the Lua stack", n);

  int base = lua_gettop(L);
  for (int i = 0; i < n; i++) {
    lua_rawgeti(L, 3, i + 1);
    int t = lua_type(L, -1);

    if (t == LUA_TNIL) {
      types[i] = 0;
      values[i] = NULL;                       /* a real SQL NULL */
    } else if (t == LUA_TBOOLEAN) {
      types[i] = OID_BOOL;
      lua_pushstring(L, lua_toboolean(L, -1) ? "t" : "f");
      values[i] = lua_tostring(L, -1);
      lua_remove(L, -2);
    } else if (t == LUA_TNUMBER) {
      if (lua_isinteger(L, -1)) {
        types[i] = OID_INT8;
        lua_pushfstring(L, "%I", (LUAI_UACINT)lua_tointeger(L, -1));
      } else {
        types[i] = OID_FLOAT8;
        lua_pushfstring(L, "%f", (LUAI_UACNUMBER)lua_tonumber(L, -1));
      }
      values[i] = lua_tostring(L, -1);
      lua_remove(L, -2);
    } else if (t == LUA_TSTRING) {
      types[i] = OID_TEXT;
      values[i] = lua_tostring(L, -1);
    } else {
      lua_settop(L, base);
      free(types); free((void *)values); free(lengths); free(formats);
      return luaL_error(L, "akkar.pq: parameter %d is a %s, which has no "
                           "Postgres type", i + 1, lua_typename(L, t));
    }
    lengths[i] = 0;
    formats[i] = 0;                            /* text format, as pgmoon does */
  }

  int sent = PQsendQueryParams(c->conn, sql, n, types, values,
                               lengths, formats, 0);
  lua_settop(L, base);
  free(types); free((void *)values); free(lengths); free(formats);

  if (!sent) {
    lua_pushnil(L);
    lua_pushstring(L, PQerrorMessage(c->conn));
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* Pushes whatever is buffered. 0 means done, 1 means poll for write. */
static int pq_flush(lua_State *L) {
  akkar_conn *c = check_conn(L, 1);
  int r = PQflush(c->conn);
  if (r < 0) {
    lua_pushnil(L);
    lua_pushstring(L, PQerrorMessage(c->conn));
    return 2;
  }
  lua_pushinteger(L, r);
  return 1;
}

static int pq_consume(lua_State *L) {
  akkar_conn *c = check_conn(L, 1);
  if (!PQconsumeInput(c->conn)) {
    lua_pushnil(L);
    lua_pushstring(L, PQerrorMessage(c->conn));
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int pq_busy(lua_State *L) {
  akkar_conn *c = check_conn(L, 1);
  lua_pushboolean(L, PQisBusy(c->conn));
  return 1;
}

/* ----------------------------------------------------------------- results */

/* One field, converted by its Postgres type.
 *
 * A SQL NULL becomes nil, which means the key is ABSENT from the row rather
 * than present-and-null. That is what pgmoon does and what `akkar/db.lua`
 * relies on -- `docs/PERFORMANCE-STUDY.md` records an earlier version of that
 * file walking every field of every row to replace a `pgmoon.null` sentinel
 * that does not exist, which cost 12% of the database path for nothing.
 */
static void push_field(lua_State *L, PGresult *res, int row, int col) {
  if (PQgetisnull(res, row, col)) { lua_pushnil(L); return; }

  const char *v = PQgetvalue(res, row, col);
  int len = PQgetlength(res, row, col);

  switch (PQftype(res, col)) {
    case OID_BOOL:
      lua_pushboolean(L, v[0] == 't');
      return;
    case OID_INT2:
    case OID_INT4:
    case OID_INT8: {
      /* strtoll rather than lua_stringtonumber: an integer column must come
       * back as a Lua integer, not a float that happens to be whole, or
       * `math.type` lies to every caller downstream and the int8 binding
       * above stops matching what was read. */
      char *end = NULL;
      long long n = strtoll(v, &end, 10);
      if (end && *end == '\0') lua_pushinteger(L, (lua_Integer)n);
      else lua_pushlstring(L, v, (size_t)len);
      return;
    }
    case OID_FLOAT4:
    case OID_FLOAT8: {
      char *end = NULL;
      double d = strtod(v, &end);
      if (end && *end == '\0') lua_pushnumber(L, (lua_Number)d);
      else lua_pushlstring(L, v, (size_t)len);
      return;
    }
    case OID_NUMERIC: {
      /* NUMERIC IS ARBITRARY PRECISION AND A DOUBLE IS NOT, and this is the
       * one place where being a drop-in replacement and being correct point
       * in different directions.
       *
       * pgmoon decodes OID 1700 as `number` (pgmoon/init.lua:110), so it
       * loses digits on exactly the columns -- money, quantities -- where
       * nobody forgives that. Returning the exact string instead would be
       * correct and would break every caller doing arithmetic on a price,
       * which is not a trade this driver gets to make on their behalf while
       * its whole value proposition is that swapping it changes one file.
       *
       * So: pgmoon's behaviour by default, exact digits on request, and the
       * loss written down here rather than discovered in an invoice.
       */
      if (numeric_as_string) { lua_pushlstring(L, v, (size_t)len); return; }
      char *end = NULL;
      double d = strtod(v, &end);
      if (end && *end == '\0') lua_pushnumber(L, (lua_Number)d);
      else lua_pushlstring(L, v, (size_t)len);
      return;
    }
    default:
      lua_pushlstring(L, v, (size_t)len);
      return;
  }
}

/* Collects one result: rows as an array of tables, or the command tag. */
static int push_result(lua_State *L, akkar_conn *c, PGresult *res) {
  ExecStatusType status = PQresultStatus(res);

  if (status == PGRES_TUPLES_OK || status == PGRES_SINGLE_TUPLE) {
    int rows = PQntuples(res), cols = PQnfields(res);
    /* `affected_rows` is set for a write that also returned rows -- INSERT
     * ... RETURNING -- and NOT for a SELECT, which is precisely what pgmoon
     * does (pgmoon/init.lua:853). The shape has to match or swapping the
     * driver becomes a rewrite of every caller that reads it, and the whole
     * claim being tested is that swapping changes one file. */
    const char *tag = PQcmdStatus(res);
    int is_select = tag && strncmp(tag, "SELECT", 6) == 0;

    /* Field names once, not once per row: a thousand rows of five columns is
     * five thousand strings interned for no reason otherwise. */
    lua_createtable(L, cols, 0);
    for (int col = 0; col < cols; col++) {
      lua_pushstring(L, PQfname(res, col));
      lua_rawseti(L, -2, col + 1);
    }
    int names = lua_gettop(L);

    lua_createtable(L, rows, 0);
    for (int row = 0; row < rows; row++) {
      lua_createtable(L, 0, cols);
      for (int col = 0; col < cols; col++) {
        lua_rawgeti(L, names, col + 1);
        push_field(L, res, row, col);
        if (lua_isnil(L, -1)) lua_pop(L, 2);   /* NULL: leave the key absent */
        else lua_rawset(L, -3);
      }
      lua_rawseti(L, -2, row + 1);
    }
    lua_remove(L, names);
    if (!is_select) {
      const char *n = PQcmdTuples(res);
      if (n && *n) {
        lua_pushinteger(L, (lua_Integer)strtoll(n, NULL, 10));
        lua_setfield(L, -2, "affected_rows");
      }
    }
    PQclear(res);
    return 1;
  }

  if (status == PGRES_COMMAND_OK) {
    /* A write with nothing to return. pgmoon answers `{affected_rows = n}`
     * and so does this; a `begin` or a `set` answers an empty table, because
     * `PQcmdTuples` is empty for them and inventing a zero would make
     * "changed nothing" indistinguishable from "not a write". */
    lua_newtable(L);
    const char *n = PQcmdTuples(res);
    if (n && *n) {
      lua_pushinteger(L, (lua_Integer)strtoll(n, NULL, 10));
      lua_setfield(L, -2, "affected_rows");
    }
    PQclear(res);
    return 1;
  }

  /* An error result. The message is what a handler will see, so it carries
   * the fields that make a Postgres error actionable rather than only its
   * prose: SQLSTATE is what distinguishes a unique violation from a deadlock,
   * and a caller that cannot tell them apart cannot retry correctly. */
  lua_pushnil(L);
  lua_newtable(L);
  const char *msg   = PQresultErrorMessage(res);
  const char *state = PQresultErrorField(res, PG_DIAG_SQLSTATE);
  const char *detail = PQresultErrorField(res, PG_DIAG_MESSAGE_DETAIL);
  const char *constraint = PQresultErrorField(res, PG_DIAG_CONSTRAINT_NAME);
  lua_pushstring(L, msg ? msg : PQerrorMessage(c->conn));
  lua_setfield(L, -2, "message");
  if (state)      { lua_pushstring(L, state);      lua_setfield(L, -2, "sqlstate"); }
  if (detail)     { lua_pushstring(L, detail);     lua_setfield(L, -2, "detail"); }
  if (constraint) { lua_pushstring(L, constraint); lua_setfield(L, -2, "constraint"); }
  PQclear(res);
  return 2;
}

/* Takes one result if one is ready. nil with no error means the query is
 * finished and every result has been collected. */
static int pq_get_result(lua_State *L) {
  akkar_conn *c = check_conn(L, 1);
  PGresult *res = PQgetResult(c->conn);
  if (res == NULL) { lua_pushnil(L); return 1; }
  return push_result(L, c, res);
}

/* ------------------------------------------------------------ housekeeping */

static int pq_status(lua_State *L) {
  akkar_conn *c = (akkar_conn *)luaL_checkudata(L, 1, AKKAR_PQ_CONN);
  if (c->closed || c->conn == NULL) { lua_pushstring(L, "closed"); return 1; }
  switch (PQstatus(c->conn)) {
    case CONNECTION_OK:  lua_pushstring(L, "ok");  break;
    case CONNECTION_BAD: lua_pushstring(L, "bad"); break;
    default:             lua_pushstring(L, "connecting"); break;
  }
  return 1;
}

static int pq_error(lua_State *L) {
  akkar_conn *c = (akkar_conn *)luaL_checkudata(L, 1, AKKAR_PQ_CONN);
  if (c->closed || c->conn == NULL) { lua_pushstring(L, "closed"); return 1; }
  lua_pushstring(L, PQerrorMessage(c->conn));
  return 1;
}

/* True while the server is inside a transaction block. `akkar/db.lua` needs
 * it to refuse returning a connection to the pool mid-transaction, which is
 * the defect class this project has already paid for twice. */
static int pq_in_transaction(lua_State *L) {
  akkar_conn *c = check_conn(L, 1);
  PGTransactionStatusType t = PQtransactionStatus(c->conn);
  lua_pushboolean(L, t == PQTRANS_INTRANS || t == PQTRANS_INERROR
                     || t == PQTRANS_ACTIVE);
  return 1;
}

static int pq_close(lua_State *L) {
  akkar_conn *c = (akkar_conn *)luaL_checkudata(L, 1, AKKAR_PQ_CONN);
  if (!c->closed && c->conn != NULL) {
    PQfinish(c->conn);
    c->conn = NULL;
    c->closed = 1;
  }
  return 0;
}

static int pq_gc(lua_State *L) {
  return pq_close(L);
}

static int pq_tostring(lua_State *L) {
  akkar_conn *c = (akkar_conn *)luaL_checkudata(L, 1, AKKAR_PQ_CONN);
  lua_pushfstring(L, "akkar.pq.conn(%s)",
                  (c->closed || !c->conn) ? "closed" : "open");
  return 1;
}

static const luaL_Reg conn_methods[] = {
  { "connect_poll",   pq_connect_poll },
  { "pollfd",         pq_pollfd },
  { "events",         pq_events },
  { "set_events",     pq_set_events },
  { "timeout",        pq_timeout },
  { "send_query",     pq_send_query },
  { "flush",          pq_flush },
  { "consume",        pq_consume },
  { "busy",           pq_busy },
  { "get_result",     pq_get_result },
  { "status",         pq_status },
  { "error",          pq_error },
  { "in_transaction", pq_in_transaction },
  { "close",          pq_close },
  { NULL, NULL }
};

/* Chooses how NUMERIC comes back: false (the default) matches pgmoon and
 * returns a Lua number; true returns the exact digits as a string. */
static int pq_numeric_as_string(lua_State *L) {
  if (lua_gettop(L) >= 1) numeric_as_string = lua_toboolean(L, 1);
  lua_pushboolean(L, numeric_as_string);
  return 1;
}

static const luaL_Reg pq_functions[] = {
  { "connect_start",     pq_connect_start },
  { "numeric_as_string", pq_numeric_as_string },
  { NULL, NULL }
};

int luaopen_akkar_pq_native(lua_State *L) {
  luaL_newmetatable(L, AKKAR_PQ_CONN);

  lua_newtable(L);
  luaL_setfuncs(L, conn_methods, 0);
  lua_setfield(L, -2, "__index");

  lua_pushcfunction(L, pq_gc);
  lua_setfield(L, -2, "__gc");
  lua_pushcfunction(L, pq_tostring);
  lua_setfield(L, -2, "__tostring");
  lua_pop(L, 1);

  lua_newtable(L);
  luaL_setfuncs(L, pq_functions, 0);
  lua_pushstring(L, "akkar.pq 0.1");
  lua_setfield(L, -2, "VERSION");

  /* The Lua this was COMPILED against, so the Lua half can refuse a mismatch.
   *
   * Loading a C module built for a different Lua is not a clean failure. A
   * module built for 5.4 loads into 5.5 without complaint -- the symbol
   * `luaopen_akkar_pq_native` resolves, the table comes back, its fields read
   * correctly -- and then the first real call dumps core, because the two
   * versions do not lay out a lua_State the same way.
   *
   * Found porting akkar to Lua 5.5: `spec/db_spec.lua` adds `./?.so` to
   * cpath, picked up the 5.4 build sitting in the tree, and segfaulted the
   * whole suite before printing a single line. Three sessions of that would
   * look like "Lua 5.5 is unstable" and it is nothing of the kind.
   */
  lua_pushinteger(L, LUA_VERSION_NUM);
  lua_setfield(L, -2, "LUA_VERSION_NUM");
  return 1;
}
