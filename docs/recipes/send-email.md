# Send email

Sends a message through an email provider's API, and keeps the request
working when the provider does not.

Put your provider key in the environment before starting the server:

```sh
export RESEND_API_KEY=re_your_key_here
```

## The whole file

```lua
local akkar = require "akkar"
local email = require "akkar.email"

local mailer = email.new {
  from = "akkar recipes <onboarding@resend.dev>",
  transport = email.resend {
    api_key = os.getenv "RESEND_API_KEY" or "re_no_key_set",
  },
}

local app = akkar.new()

app:post("/signup", { body = { email = "string" } }, function(req)
  local id, why = mailer:send {
    to = req.body.email,
    subject = "Welcome to the task list",
    text = "Thanks for signing up. Your account is ready.",
  }

  if not id then
    -- The account was created either way. A welcome email that did not go out
    -- is not a reason to undo a signup.
    req.log:error("welcome email failed", { detail = why })
    return akkar.created { account = req.body.email, emailed = false }
  end

  return akkar.created { account = req.body.email, emailed = true, message_id = id }
end)

app:run { port = 3000 }
```

A mailer is not a capability, so it is not passed to `app:run{}`: it is built
once at the top of the file and the handler closes over it. `mailer:send`
never raises. It returns a message id, or `nil` and a reason.

akkar speaks provider HTTP APIs, not SMTP. `email.resend` is one provider
pre-wired; `email.json_api { url = ..., token = ..., fields = ... }` covers
the others, which differ only in field names and where the token goes.

## Try it

```sh
lua5.4 app.lua
```

```sh
curl -X POST http://127.0.0.1:3000/signup \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com"}'
```

With a key that the provider rejects, which is what you get if you forgot to
export one:

```
{"emailed":false,"account":"ada@example.com"}
```

```
ERROR welcome email failed detail=the email provider refused it (401): API key is invalid request_id=8f7e6cbe000001
```

The signup still answered 201. With a working key the same request answers
`"emailed":true` and carries the provider's `message_id`.

## Why the failure is not an error

An email provider is a third party over a network, so sending will fail
sometimes, and the interesting question is what that failure does to the
request it happened inside. Here it does nothing: the account exists, the
caller is told the email did not go out, and the reason is in the log next to
the request id. The other half of that argument is that the caller should not
be waiting for a provider at all. `mailer:send` makes an HTTP call, so it
holds the request for as long as the provider takes. For anything busier than
a demo, push a job and send it from a worker instead:
[Run a worker in the same process](run-a-worker-in-the-same-process.md).
