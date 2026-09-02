# Why akkar is like this

Seven arguments. Each one takes a decision that shows up in the API, says what it
makes impossible, says what it costs, and points at the measurement or the
retraction behind it.

These pages are for a reader who is curious or sceptical, and being sceptical
is the correct posture. They are **not** the place to learn akkar: if you want
to build something, start at `docs/guide/00-quickstart.md` and come back here
when a page makes you ask "why on earth is it like that".

| Page | The question |
|---|---|
| [handlers-return.md](handlers-return.md) | Why does a handler return a value instead of writing a response? |
| [adapters.md](adapters.md) | Why does every piece of I/O go through an adapter akkar owns? |
| [sessions-not-jwt.md](sessions-not-jwt.md) | Why are sessions kept on the server, and why can akkar not sign a JWT? |
| [one-process-per-core.md](one-process-per-core.md) | Why processes and `SO_REUSEPORT` rather than threads? |
| [what-the-runtime-is-for.md](what-the-runtime-is-for.md) | What does `akkar build` buy, and why is speed not on the list? |
| [what-akkar-does-not-do.md](what-akkar-does-not-do.md) | What is deliberately excluded, and what should you use instead? |
| [slower-than-openresty.md](slower-than-openresty.md) | Why is akkar slower than OpenResty, where does the time go, and what can be done? |

## How to read a number on these pages

Every figure here is traceable to a file in the repository, and the file is
named next to it. That is a deliberate constraint, because this project has
published wrong numbers more than once and each time the correction is still on
the page next to the claim.

Four of those corrections are load-bearing enough that you will meet them here:

- **A whole comparison retracted.** `bench/compare/RESULTS.md` measured akkar
  against Gin and FastAPI with four asymmetries running at the same time,
  including Gin silently using twice the CPU. The re-run,
  `bench/study/RESULTS.md`, reversed the conclusion: akkar is at parity with
  FastAPI on the framework path and ahead of it on every route that touches the
  database.
- **A benchmark taken on a dirty machine.** The first driver comparison ran
  with twenty two wedged servers spinning on the box, and the contamination
  **inflated** the result being sold, from 3.01x to 3.91x.
- **A table labelled median that was a maximum.** The saturation sweep in
  `bench/study/RESULTS.md` section 8 kept the best of three runs under a
  comment saying it took the median. The retraction works out which of its
  conclusions survive.
- **A benchmark that measured one process while reporting eight.** Seven died
  with `EADDRINUSE` and the harness never checked, which is how akkar found out
  it had never passed `reuseport` through to lua-http.

If a claim on these pages has no file beside it, treat it as an opinion.

## What is missing from this section

Stated so it is not mistaken for completeness. There is no page on the tenant
scope design, on the blocking watchdog, or on the job queue, and all three
carry arguments of the same kind. For now those live in
`akkar/scope.lua`, `README.md` and `akkar/jobs.lua`.
