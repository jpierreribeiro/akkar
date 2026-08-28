--[[
Teal type declarations for akkar.

The strongest criticism of Lua for anything with real responsibility on it is
that there is no compiler checking your intent before the program runs. That
criticism is correct and akkar does not answer it by being written carefully.

What it can do is let people who want types have them. Teal is a typed dialect
that compiles to plain Lua, and the ecosystem already has the pattern: a
`-tl-type` package carrying declarations for a library written in ordinary
Lua. akkar is not rewritten; a handler written in Teal simply gets checked.

    -- handlers/users.tl
    local akkar = require("akkar")

    local app = akkar.new()

    app:get("/users/:id", function(req: akkar.Request): akkar.Response
      local id = req.params.id            -- string, checked
      return req.db:one("select ...", id)
    end)

What the compiler then catches, before anything runs:

  * a handler returning a value akkar cannot serialise
  * `req.parms` instead of `req.params`
  * a capability that is not in the closed set
  * a status helper called with the wrong shape
  * an option name `app:run` does not accept

What it still cannot catch, stated so nobody assumes otherwise: whether a
schema matches the table a handler actually returns. `body` and `response`
schemas are values built at runtime, and their agreement with the data is what
validation checks at request time. Types narrow the gap; they do not close it.
]]

local record akkar

   -- ================================================================ request
   record Request
      method: string
      path: string
      -- The route PATTERN that matched, not the request path -- `/users/:id`,
      -- never `/users/42`.  Metrics label by this to keep cardinality bounded.
      route: string
      -- Correlation id: taken from `x-request-id` when the client sends one,
      -- generated otherwise.
      id: string

      -- Path parameters, percent-decoded.  Values arrive as strings and are
      -- coerced by a `params` schema when the route declares one.
      params: {string: any}
      query: {string: any}
      -- Decoded from JSON, form-urlencoded or multipart.  A file part is a
      -- table with filename, content_type, data and size.
      body: any
      -- Always a plain table with lowercase keys, whether the request came
      -- off a socket or from the in-process test client.
      headers: {string: string}

      -- Capabilities, from the closed set.  Acquired on first read, so a
      -- route that never queries takes no connection.  Reading one that was
      -- not configured raises a message naming it.
      db: Db
      cache: Cache
      -- Already bound to this request's id, so `req.log:info(...)` correlates
      -- without the call site doing anything.
      log: Logger
      clock: any

      -- Set by authentication middleware.  Reading it without that middleware
      -- raises rather than returning nil.
      user: any
   end

   -- =============================================================== response
   record Response
      status: integer
      body: any
      headers: {string: string}
      -- Set by `akkar.raw` for a body that is not JSON.
      raw: string
      content_type: string
   end

   -- A handler returns a table (200), nil (204), or a Response.  Returning
   -- anything else is an error naming the type.
   type Handler = function(Request): any

   -- `next` takes the request and RETURNS the response, which is what allows
   -- post-processing: logging a status, measuring latency, wrapping an error.
   type Middleware = function(Request, function(Request): Response): Response

   -- ============================================================= validation
   record Rule
      kind: string
      optional: boolean
      min: number
      max: number
      match: string
      one_of: {string}
      default: any
      -- `object` and `array` recurse through these two fields.
      fields: {string: any}
      items: any
   end

   -- A schema field is either a Rule or the shorthand string form:
   -- "string", "integer", "number", "boolean", "table", each with an optional
   -- trailing "?" meaning the same as `optional = true`.
   type Schema = {string: Rule | string}

   record RouteOptions
      params: Schema
      query: Schema
      body: Schema
      -- Filters undeclared fields out of the response and validates the rest.
      -- A mismatch is a 500: a response breaking its own contract is a server
      -- bug, not the client's fault.
      response: Schema
      responses: {integer: any}
      before: {Middleware}
   end

   record Validators
      string: function({string: any}): Rule
      integer: function({string: any}): Rule
      number: function({string: any}): Rule
      boolean: function({string: any}): Rule
      table: function({string: any}): Rule
      object: function({string: any}): Rule
      array: function({string: any}): Rule
   end

   -- ================================================================ adapters
   record Db
      one: function(Db, string, ...: any): {string: any}
      many: function(Db, string, ...: any): {{string: any}}
      exec: function(Db, string, ...: any): any
      -- Commit at the end, rollback on any error -- including a response
      -- thrown from inside.  No path leaves a BEGIN open.
      transaction: function(Db, function(Db): any): any
      release: function(Db)
      close: function(Db)
   end

   record Cache
      get: function(Cache, string): string
      set: function(Cache, string, string, ?integer): any
      del: function(Cache, ...: string): integer
      incr: function(Cache, string): integer
      expire: function(Cache, string, integer): integer
      ttl: function(Cache, string): integer
      command: function(Cache, string, ...: any): any
      release: function(Cache)
   end

   record Logger
      debug: function(Logger, string, ?{string: any})
      info: function(Logger, string, ?{string: any})
      warn: function(Logger, string, ?{string: any})
      error: function(Logger, string, ?{string: any})
      -- Returns a logger carrying these fields on every line it writes.
      with: function(Logger, {string: any}): Logger
   end

   -- =================================================================== jobs
   -- Semantics live in `akkar.jobs`; a store only persists.  Three methods is
   -- the whole store contract, so a new backend is small.
   record JobStore
      enqueue: function(JobStore, string, string): integer
      dequeue: function(JobStore, string, ?number): string
      depth: function(JobStore, string): integer
   end

   record Job
      kind: string
      payload: any
      queued_at: integer
   end

   record ConsumeOptions
      timeout: number
      log: Logger
      should_stop: function(): boolean
   end

   record Queue
      push: function(Queue, string, any): integer
      pop: function(Queue, ?number): Job, string
      depth: function(Queue): integer
      -- A failing job is logged and dropped.  A retry policy nobody chose
      -- hides the failure and repeats the side effects already committed.
      consume: function(Queue, {string: function(any, ?Job)}, ?ConsumeOptions): {string: integer}
   end

   -- ================================================================== server
   record RunOptions
      host: string
      port: integer
      tls: boolean
      ctx: any
      -- Defaults that make a bare `app:run()` production-shaped.
      body_limit: integer          -- 1 MB
      timeout: number              -- 30 s, wall clock, per request
      shutdown_grace: number       -- 10 s before the drain says it is stalled
      -- Several processes sharing one port.  One Lua VM is one core, so
      -- capacity is processes.
      reuseport: boolean
      -- Refuse to start when a configured capability does not answer its
      -- contract.  On by default.
      check_capabilities: boolean
      -- Turn an undeclared global into an error.
      strict: boolean

      db: any
      cache: any
      log: Logger
      clock: any
   end

   record App
      get: function(App, string, RouteOptions | Handler, ?Handler): App
      post: function(App, string, RouteOptions | Handler, ?Handler): App
      put: function(App, string, RouteOptions | Handler, ?Handler): App
      patch: function(App, string, RouteOptions | Handler, ?Handler): App
      delete: function(App, string, RouteOptions | Handler, ?Handler): App

      use: function(App, Middleware): App
      -- A sub-app is an ordinary app mounted under a prefix, and stays
      -- testable on its own without knowing where it lives.
      mount: function(App, string, App): App

      run: function(App, ?RunOptions)
      -- Stops accepting, drains what is in flight, then closes.  A stalled
      -- drain warns and keeps waiting; it never forces a connection closed.
      stop: function(App, ?number): string
      handle_signals: function(App, ?{integer}): App

      -- No socket, no port, no database, but the same middleware, validation
      -- and dispatch chain a real request travels.
      test: function(App, ?RunOptions): TestClient

      match: function(App, string, string): any, {string: any}
      methods_for: function(App, string): {string}
   end

   record TestResponse
      status: integer
      body: any
      raw: string
      headers: {string: string}
   end

   record TestRequestOptions
      body: any
      headers: {string: string}
      timeout: number
   end

   record TestClient
      get: function(TestClient, string, ?TestRequestOptions): TestResponse
      post: function(TestClient, string, ?TestRequestOptions): TestResponse
      put: function(TestClient, string, ?TestRequestOptions): TestResponse
      patch: function(TestClient, string, ?TestRequestOptions): TestResponse
      delete: function(TestClient, string, ?TestRequestOptions): TestResponse
      head: function(TestClient, string, ?TestRequestOptions): TestResponse
      options: function(TestClient, string, ?TestRequestOptions): TestResponse
   end

   -- ================================================================= module
   new: function(): App

   v: Validators

   -- Status helpers.  A handler returns one of these, or a plain table, or
   -- nil -- it never mutates a context, which is what makes writing the
   -- response twice impossible.
   ok: function(?any): Response
   created: function(?any): Response
   no_content: function(): Response
   bad_request: function(?string): Response
   unauthorized: function(?string): Response
   forbidden: function(?string): Response
   not_found: function(?string): Response
   conflict: function(?string): Response
   too_large: function(?string): Response
   unavailable: function(?string): Response
   method_not_allowed: function({string}): Response
   response: function(integer, ?any, ?{string: string}): Response
   -- A body that is not JSON: Prometheus text, a CSV export, an SVG.
   raw: function(string, ?string, ?integer): Response

   cors: function(?{string: any}): Middleware

   -- The cjson null sentinel, exposed so a test can express JSON null without
   -- going through the wire.
   null: any

   defaults: {string: any}
end

return akkar
