--[[
akkar.email — sending mail over an HTTP API.

## This is not SMTP, deliberately

SMTP is a protocol implementation and a different-sized job. Doing it properly
means ESMTP negotiation, STARTTLS, AUTH in three mechanisms, line-ending
canonicalisation, dot-stuffing, MIME multipart assembly with correct
boundaries and transfer encodings, address parsing to RFC 5322, and a retry
policy for a queue with its own state -- and none of that gets an email
delivered on its own, because a message sent straight from an application
server without SPF, DKIM and a warmed sending IP lands in spam or is refused
outright. That is the whole reason the providers exist and the reason almost
nobody in this position should speak SMTP at all.

What this file does instead is the ten lines of HTTP those providers offer,
behind an interface that does not name any of them. If SMTP is ever wanted, it
belongs in `akkar/smtp.lua` as a transport this module can be handed -- the
seam is already here.

## A FAILED SEND IS A RETURNED VALUE. ALWAYS.

This is the only rule in this file that matters, and it is the reason the
module is shaped the way it is.

Email is simultaneously the thing most likely to be down -- a third-party API
over the public internet, on somebody else's incident schedule -- and the
thing least worth failing a request over. A user finished signing up. The row
is committed. If the welcome email cannot be sent, the correct outcome is a
logged failure and a 201, not a 500 that tells the user their account was not
created when it plainly was.

So nothing here raises. Not on a bad argument, not on a transport that throws,
not on a provider returning a document nobody expected. `send` returns
`id, nil` or `nil, reason, details`, and the transport is called inside a
`pcall` so that a third-party function that raises -- which is not this
module's to promise anything about -- comes back as the same returned error as
everything else.

The corollary is that ignoring the result is silent. `send` is therefore worth
wrapping at the call site in whatever the application does with a failure,
which for most applications is a log line and a retry queue -- `akkar.jobs`
being the obvious home for the second.

## Retries are the caller's, on purpose

`akkar.http` will not retry a POST unless it is told to, because a retried
POST is a second charge or a second email, and this is the module the second
half of that sentence is about. A send that times out MAY have been delivered;
there is no way to tell from here. So this module does not retry, and a caller
that wants to has to say so with the provider's own idempotency key, which is
the only mechanism that can actually make it safe.

## The shape

    local mailer = akkar.email.new {
      transport = akkar.email.json_api {
        url = "https://api.resend.com/emails",
        token = os.getenv "RESEND_API_KEY",
      },
      from = "hello@example.com",
    }

    local id, why = mailer:send {
      to = "ada@example.com",
      subject = "Welcome",
      text = "Glad you are here.",
      html = "<p>Glad you are here.</p>",
    }
    if not id then log:warn("email failed", { reason = why }) end
]]

local http = require "akkar.http"

local M = {}

-- ================================================================ addresses

--- One address or many, always returned as a list of strings.
---
--- Accepting both is not sugar. `to = "a@b.c"` is what a caller writes nine
--- times in ten, and a module that demands a list for the single case gets a
--- bare string passed to it anyway on the tenth day by somebody in a hurry.
local function address_list(value)
  if value == nil then return nil end
  if type(value) == "string" then return { value } end
  if type(value) ~= "table" then return nil end
  local out = {}
  for _, entry in ipairs(value) do
    if type(entry) ~= "string" then return nil end
    out[#out + 1] = entry
  end
  if #out == 0 then return nil end
  return out
end

M.address_list = address_list

--- A very loose sanity check, and loose ON PURPOSE.
---
--- Validating an address properly means RFC 5322, which permits quoted local
--- parts, comments, and domain literals, and which every "email regex" on the
--- internet gets wrong in the direction of REJECTING valid addresses. Being
--- wrong in that direction means a real user cannot sign up, which is far
--- worse than sending one message that bounces. So this only catches the
--- shapes that cannot possibly be an address, and the provider decides the
--- rest.
local function plausible(address)
  local at = address:find("@", 2, true)
  return at ~= nil and at < #address and not address:find "%s"
end

M.plausible = plausible

-- ================================================================== the message

--- Checks a message and returns it normalised, or nil and a reason.
---
--- A RETURNED reason, like everything else here. A malformed message is the
--- single most likely failure in this file -- it comes from application code,
--- often from a template -- and turning it into a raise would mean the one
--- error a caller can actually fix is the one that takes the request down.
function M.validate(message, defaults)
  defaults = defaults or {}
  if type(message) ~= "table" then
    return nil, "a message must be a table"
  end

  local to = address_list(message.to)
  if not to then return nil, "a message needs at least one `to` address" end
  for _, address in ipairs(to) do
    if not plausible(address) then
      return nil, "not an email address: " .. address
    end
  end

  local from = message.from or defaults.from
  if type(from) ~= "string" or from == "" then
    return nil, "a message needs a `from` address"
  end

  if type(message.subject) ~= "string" or message.subject == "" then
    return nil, "a message needs a `subject`"
  end

  -- One of the two, and either alone is fine. A message with neither is an
  -- empty email, which is never what anybody meant and which some providers
  -- accept silently -- so it is refused here rather than delivered.
  if message.text == nil and message.html == nil then
    return nil, "a message needs `text`, `html`, or both"
  end

  return {
    to = to,
    cc = address_list(message.cc),
    bcc = address_list(message.bcc),
    from = from,
    reply_to = message.reply_to or defaults.reply_to,
    subject = message.subject,
    text = message.text,
    html = message.html,
    headers = message.headers,
    tags = message.tags,
    idempotency_key = message.idempotency_key,
  }
end

-- ================================================================ a transport

--- A transport for the shape most JSON email APIs already have.
---
--- Resend, Postmark, Loops, Plunk and several others are all the same request:
--- POST a JSON object to one URL with a bearer token, get an object with an id
--- back. This covers that shape and lets the two things that actually differ
--- -- the field names and the header the token goes in -- be configured,
--- rather than shipping five transports that are one string apart.
---
--- A provider that does not fit is not a problem this needs to solve: the
--- transport is a function, so an unusual one is fifteen lines in the
--- application and needs nothing from this file.
function M.json_api(config)
  assert(config and config.url, "akkar.email: a transport needs a url")

  -- ASSERTING HERE IS CORRECT AND `send` STILL MAY NOT RAISE. This runs once,
  -- at construction, from configuration code -- a missing url is a deployment
  -- that should refuse to start, not a request that fails at three in the
  -- morning. `send` is the hot path and the one that must never raise; wiring
  -- is not.
  local client = config.http or http.connect {
    timeout = config.timeout or 15,
    -- Zero on purpose. akkar.http already refuses to retry a POST, and this
    -- states the intent at the one call site where a duplicate is a duplicate
    -- email in somebody's inbox.
    retries = 0,
  }()

  local fields = config.fields or {}
  local field = function(name) return fields[name] or name end

  return function(message)
    local body = {
      [field "from"] = message.from,
      [field "to"] = message.to,
      [field "subject"] = message.subject,
    }
    if message.text then body[field "text"] = message.text end
    if message.html then body[field "html"] = message.html end
    if message.cc then body[field "cc"] = message.cc end
    if message.bcc then body[field "bcc"] = message.bcc end
    if message.reply_to then body[field "reply_to"] = message.reply_to end
    if message.headers then body[field "headers"] = message.headers end
    if message.tags then body[field "tags"] = message.tags end

    for name, value in pairs(config.extra or {}) do body[name] = value end

    local headers = {}
    for name, value in pairs(config.headers or {}) do headers[name] = value end
    if config.token then
      headers[config.token_header or "authorization"] =
        (config.token_prefix or "Bearer ") .. config.token
    end
    -- The provider's own idempotency key, passed through untouched. It is the
    -- ONLY thing that makes a retry safe, and it is the caller's to choose
    -- because only the caller knows what "the same email" means.
    if message.idempotency_key then
      headers[config.idempotency_header or "idempotency-key"] =
        message.idempotency_key
    end

    local res, why = client:post(config.url, { headers = headers, body = body })
    if not res then return nil, why end

    local decoded
    if res.body and res.body ~= "" then
      local ok, value = pcall(require("akkar.json").decode, res.body)
      if ok then decoded = value end
    end

    if res.status < 200 or res.status >= 300 then
      -- The provider's own message where there is one, since it is far more
      -- useful than "status 422" -- and the whole response alongside, because
      -- no two of these providers agree on where they put it.
      local said = type(decoded) == "table"
                   and (decoded.message or decoded.error or decoded.Message)
      return nil, ("the email provider refused it (%d): %s")
                  :format(res.status, tostring(said or res.body or "")),
             { status = res.status, body = res.body, decoded = decoded }
    end

    local id = type(decoded) == "table"
               and (decoded.id or decoded.MessageID or decoded.message_id)
    -- `true` rather than nil when a provider answers 200 with no id: the send
    -- SUCCEEDED, and returning nil would make a success indistinguishable
    -- from a failure at the call site, which is the one thing the caller
    -- checks.
    return id or true, nil, { status = res.status, decoded = decoded }
  end
end

--- Resend, pre-wired. One concrete provider so the interface has a worked
--- example and nobody has to guess the field names.
function M.resend(config)
  config = config or {}
  assert(config.api_key, "akkar.email: resend needs an api_key")
  return M.json_api {
    url = config.url or "https://api.resend.com/emails",
    token = config.api_key,
    http = config.http,
    timeout = config.timeout,
  }
end

-- ================================================================== the mailer

local Mailer = {}
Mailer.__index = Mailer

--- Sends a message. Returns `id, nil, details` or `nil, reason, details`.
---
--- NEVER RAISES. Read the header for why; the short version is that a welcome
--- email failing must not un-create the account.
function Mailer:send(message)
  local valid, why = M.validate(message, self.defaults)
  if not valid then return nil, why end

  -- The transport is a function somebody else wrote, and it is under no
  -- obligation to this module's contract. A provider SDK that raises on a
  -- socket error would otherwise reach the handler as an error, which is
  -- precisely the outcome this file exists to prevent -- so it is called
  -- inside a pcall and a raise becomes the same returned error as a refusal.
  local ok, result, reason, details = pcall(self.transport, valid)
  if not ok then
    return nil, "the email transport raised: " .. tostring(result)
  end
  if not result then
    return nil, reason or "the email was not sent", details
  end
  return result, nil, details
end

--- The same send, with the failure already logged.
---
--- Exists because "log it and carry on" is what almost every caller does, and
--- a convenience that does it correctly is better than fifty call sites that
--- each forget in a different way. Returns the id or nil, so a caller who
--- does care still can.
function Mailer:send_or_log(message, log)
  local id, why, details = self:send(message)
  if not id and log then
    log:warn("email failed", { reason = why, to = message and message.to,
                               status = details and details.status })
  end
  return id, why
end

--- Returns a factory, matching the other adapters.
function M.new(config)
  config = config or {}
  assert(type(config.transport) == "function",
         "akkar.email: a transport function is required")
  local mailer = setmetatable({
    transport = config.transport,
    defaults = { from = config.from, reply_to = config.reply_to },
  }, Mailer)
  return mailer
end

--- `connect`, so this reads the same as `db.connect` and `http.connect` where
--- it is wired as a capability.
function M.connect(config)
  local mailer = M.new(config)
  return function() return mailer end
end

M.Mailer = Mailer

return M
