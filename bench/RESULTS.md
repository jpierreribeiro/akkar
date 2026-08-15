# Results

A number without the machine it came from is not a result. Record the instance
type, the date and the exact command.

## Template

```
date        :
machine     :
lua         : 5.4.x
akkar       : <git sha>
command     :
```

---

## Not yet run on real hardware

The benchmarks below have only been smoke-tested on a development laptop,
which shares its cores with a browser and cannot answer the question they were
written for. **Do not quote these as akkar's performance.** They are here to
show the targets work, not how fast anything is.

### Smoke test, development laptop

```
/ping                  1.5 ms
/expensive           234.8 ms     (~3M iteration loop, bcrypt-shaped)
/expensive-yielding 1073.5 ms     (same work, yielding every 2000)
```

The last two are the trade already measured in isolation, visible over HTTP:
yielding costs the task roughly 4.5x here and hands that time to everyone else.
The isolated measurement put it at 2.7x; a laptop under a browser is exactly
why this needs a real machine.

## What is worth knowing once it runs

Three questions, in order of how much they change:

1. **Where does N-process scaling stop?** Near-linear to 8 means "one process
   per core" is the whole deployment story. Flattening earlier means something
   shared is the limit, most likely Postgres `max_connections` against
   N × `pool_size`.
2. **How much of a real request is the framework?** Compare `/ping` against
   `/users/:id`. Every measurement in this project so far says the database
   dominates and the framework is noise; this either confirms that over HTTP
   or contradicts it.
3. **What does one blocking handler cost at N=1 versus N=8?** This is the
   honest answer to CPU-bound work in a single-threaded runtime — not a
   helper, but enough processes that one blocked worker is a fraction of
   capacity rather than all of it.
