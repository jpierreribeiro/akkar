/* THE FLOOR.
 *
 * The same one-row query libpq can do with no Lua, no cqueues and no polling
 * loop -- just blocking PQexecParams in a tight C loop. Whatever this costs is
 * the price of Postgres plus libpq on this machine; everything above it is
 * ours.
 *
 * If this is ~50 us and the Lua driver is ~380 us, the remaining 330 us is the
 * event loop and the driver was never the thing to fix.
 */
#include <stdio.h>
#include <time.h>
#include "libpq-fe.h"

static double now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

int main(int argc, char **argv) {
  int iters = argc > 1 ? atoi(argv[1]) : 2000;
  const char *sql = argc > 2 ? argv[2]
                             : "select 42 as id, 'ada'::text as name";

  PGconn *c = PQconnectdb("host=127.0.0.1 port=55432 dbname=akkar "
                          "user=postgres password=akkar");
  if (PQstatus(c) != CONNECTION_OK) {
    printf("connect failed: %s\n", PQerrorMessage(c));
    return 1;
  }

  /* Warmup, discarded for the same reason the Lua benchmark discards one. */
  for (int i = 0; i < 100; i++) PQclear(PQexec(c, sql));

  double started = now_us();
  int rows = 0;
  for (int i = 0; i < iters; i++) {
    PGresult *r = PQexecParams(c, sql, 0, NULL, NULL, NULL, NULL, 0);
    rows = PQntuples(r);
    PQclear(r);
  }
  double elapsed = now_us() - started;

  printf("blocking libpq: %.2f us/query  (%d rows, %d iterations)\n",
         elapsed / iters, rows, iters);
  PQfinish(c);
  return 0;
}
