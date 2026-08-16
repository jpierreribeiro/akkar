# The documentation, planned before it is written

> Nothing here is written yet. This is the plan, and it exists because
> documentation written without one becomes forty pages that each assume the
> reader has read the other thirty-nine.

## Who this is for, stated first because it changes everything

The reader we are writing for **has not built a backend before**. They may not
know Lua. They may not know what a JSON API is, why a database connection pool
exists, or what a reverse proxy does. They are also probably reading at
11pm on a laptop with six other tabs open.

That reader is not the same person as "an experienced backend developer
evaluating akkar", and **the mistake to avoid is writing one set of pages that
tries to serve both**. Everything below is organised around serving them
separately, on purpose, with signposts between.

### What "hold their hand" actually means, concretely

Not a friendlier tone. These, specifically:

- **One idea per screen.** If a section needs scrolling, it is two sections.
- **Every page starts with what you will have at the end**, in one sentence,
  and ends with a checkpoint confirming you have it.
- **Every code block is complete and runnable.** No `-- ...` in the middle, no
  "add this to your app" without showing where. A beginner cannot infer the
  surrounding context, because inferring it is the skill they do not have yet.
- **The error you will hit is shown next to the code that causes it.** Most
  documentation shows only the happy path, so the first divergence from it is
  where the reader is alone. akkar's error messages are unusually good — they
  name the mistake and the fix — and the docs should show them as *expected
  output*, not hide them.
- **Nothing is left implicit because it is obvious.** "Obvious" is a property
  of the writer, not the text.
- **No forward references.** If a page needs a concept, it either teaches it
  or links to a page that does. A tutorial that says "we will explain
  middleware later" has lost the reader now.

## The five kinds of page, and why they cannot be mixed

Borrowed from Diátaxis, which exists because these four modes conflict — text
that teaches badly explains, and text that explains badly instructs. A fifth
is added for this project.

| Kind | Answers | Reader is | Voice |
|---|---|---|---|
| **Quickstart** | "does this work at all" | impatient, evaluating | zero prose, one file, one command |
| **Tutorial** | "teach me by building" | learning | we-do-this-together, ordered, no choices |
| **Recipe** | "how do I do X" | working, knows the goal | task-first, self-contained, copyable |
| **Reference** | "what does this do exactly" | looking something up | complete, dry, alphabetical |
| **Explanation** | "why is it like this" | curious or sceptical | argumentative, honest about trade-offs |

**A recipe that teaches is a bad recipe. A tutorial that offers choices is a
bad tutorial.** The reader arrives in a mode; the page must be in the same one.

## The spine: what gets written, in order

### 0. Quickstart — five minutes, one file

The whole thing on one page: install, a file, a command, a `curl` that answers.
No explanation at all, and a line at the bottom saying where explanation lives.

This page exists for the person deciding whether to keep reading. It is written
first and rewritten last.

### 1. The beginner track — a spine, not footnotes

Ten to twelve short pages that build ONE application end to end. Not a toy:
something with a database, authentication and a frontend calling it, because
those are the three things a first real backend has and every tutorial skips
at least one.

The application: **a task list with accounts.** Chosen because it needs
exactly the concepts that matter and nothing else — users, a table, ownership
(which is what tenant scope teaches), and a frontend that logs in.

Planned pages, each one screen or two:

1. What a backend even is — request, response, JSON, and why a browser cannot
   talk to Postgres directly
2. Your first route — return a table, get JSON
3. Reading input — path params, query, body, and why validation is not optional
4. Errors that are not crashes — 400 versus 500, and who is at fault
5. A database, from zero — Docker, a table, a migration
6. Storing and reading rows — the query builder, and why not string
   concatenation (SQL injection shown, then prevented)
7. Accounts — password hashing, why not to invent it, sessions
8. Only your own tasks — ownership and tenant scope
9. Talking to it from a frontend — CORS, fetch, cookies, credentials
10. Background work — a job that runs after the response
11. Making it not fall over — deadlines, limits, health checks
12. Putting it on the internet — build, deploy, environment variables, secrets

Each page ends with a working application, not a fragment. **The reader can
stop after any page and have something that runs.**

### 2. Recipes — the cookbook

Short, independent, task-titled. Each is one page, one problem, one complete
solution, and a "why this way" section of at most a paragraph with a link to
the explanation page for anyone who wants more.

Written in the order people actually need them:

- Upload a file · Paginate a list · Cache an expensive query · Send email
- Call another API and handle failure · Retry safely · Rate limit an endpoint
- Accept a webhook (and verify its signature) · Schedule a recurring job
- Return a CSV · Stream a large response · Serve a frontend from the same server
- Run migrations on deploy · Read config from the environment
- Test a route · Test something that hits the database
- Log usefully · See what is slow

### 3. Reference — every symbol

Generated where possible. The modules already carry `---` docstrings in a
consistent shape, so a generator can produce the skeleton and the prose gets
hand-edited. Generating it is not a nicety: reference documentation drifts,
and hand-written reference is drifted reference.

Per module: what it is, when you need it, every public function with
signature, arguments, return values, errors it raises, and a minimal example.

### 4. Explanation — the arguments

This is where akkar's actual character lives, and where the material already
exists: this repository is full of decisions with reasons and retractions
attached. These pages are mostly editing, not writing.

- Why handlers return instead of writing a response
- Why every I/O goes through an adapter (and the driver swap that proved it)
- Why sessions and not JWTs
- Why one process per core instead of threads
- What the runtime is for, and what it is not (it is not speed)
- What akkar deliberately does not do, and what to use instead

## THE RULE THAT MAKES THIS DIFFERENT: every example runs

**Documentation that has rotted is worse than no documentation**, because a
beginner cannot tell the difference between "I made a mistake" and "this page
is from three versions ago". They will assume it is them, and they will stop.

So: a spec extracts every fenced Lua block from every documentation page and
runs it. A block that is not meant to run is marked as such explicitly, and
the marker is what makes it deliberate rather than accidental.

This is the same discipline the rest of the project already has — no claim
without a running proof — applied to prose. It is also the single highest
maintenance-cost item here, and it is worth it.

## Format, and the one thing to decide

Markdown in the repository is the source of truth either way. What is open:
whether it renders as a static site now or later.

**Recommendation: write the Markdown first, ship the site after the beginner
track exists.** A documentation site with three pages in it is worse than a
README, and choosing a generator is the kind of decision that eats a day and
teaches nothing about akkar.

## Size, honestly

| | pages | rough effort |
|---|---|---|
| Quickstart | 1 | half a session |
| Beginner track | 12 | 4–6 sessions — the bulk, and where the value is |
| Recipes | ~18 | 3–4 sessions, parallelisable |
| Reference | ~30 | 2 sessions with a generator, more without |
| Explanation | 6 | 1–2 sessions, mostly editing what exists |
| The runner that executes examples | — | half a session, and it pays for itself |

Ten to fourteen focused sessions. The beginner track is the half that matters
and should be written first and slowest.

## What would make this fail

Written down now, while it is cheap to avoid:

- **Writing reference first.** It is the easiest to write and the least
  useful, and finishing it creates the feeling of being done.
- **Letting the tutorial become a feature tour.** The application decides
  what appears; anything the task list does not need goes in a recipe.
- **Explaining while instructing.** The moment a tutorial page starts
  justifying a design decision, the reader who wanted to build something has
  been handed an essay.
- **Examples that are fragments.** The single most common way documentation
  fails a beginner, and the reason for the runner above.
