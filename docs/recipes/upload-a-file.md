# Upload a file

Takes a file from an HTML form or a `curl -F`, checks what it is, and writes
it to disk under a name the server chose.

## The whole file

```lua
local akkar  = require "akkar"
local crypto = require "akkar.crypto"

local UPLOADS = os.getenv "UPLOAD_DIR" or "/tmp/akkar-uploads"
os.execute("mkdir -p " .. UPLOADS)

local EXTENSIONS = { ["image/png"] = "png", ["image/jpeg"] = "jpg" }

local app = akkar.new()

app:post("/avatars", { body = { avatar = "table" } }, function(req)
  local file = req.body.avatar

  local extension = EXTENSIONS[file.content_type]
  if not extension then
    return akkar.bad_request("avatar must be a PNG or a JPEG, not " ..
                             tostring(file.content_type))
  end

  -- The name is ours, never the client's. A filename arrives from the network
  -- and may contain ../ or a name that is already on disk.
  local name = crypto.token(16) .. "." .. extension

  local out, why = io.open(UPLOADS .. "/" .. name, "wb")
  if not out then
    req.log:error("could not write an upload", { detail = why })
    return akkar.unavailable "the file could not be stored"
  end
  out:write(file.data)
  out:close()

  return akkar.created { id = name, size = file.size, name = file.filename }
end)

app:run { port = 3000, body_limit = 5 * 1024 * 1024 }
```

akkar parses `multipart/form-data` before the handler runs. A file part reaches
you as a table with four fields: `filename`, `content_type`, `data` and `size`.
A plain text field in the same form reaches you as a string.

## Try it

```sh
lua5.4 app.lua
```

In a second terminal:

```sh
curl -F "avatar=@cat.png;type=image/png" http://127.0.0.1:3000/avatars
```

```
{"size":22,"id":"54f3a654004ef069b27fd49f5f3aa949.png","name":"cat.png"}
```

A text field where the file should be is refused before the handler runs,
because the route declares `avatar` as a table:

```sh
curl -F "avatar=hello" http://127.0.0.1:3000/avatars
```

```
{"fields":{"body.avatar":"expected table"},"error":"validation failed"}
```

A file of a type this route does not take:

```sh
curl -F "avatar=@cat.png;type=application/pdf" http://127.0.0.1:3000/avatars
```

```
{"error":"avatar must be a PNG or a JPEG, not application\/pdf"}
```

Anything larger than `body_limit` gets a `413` and never reaches the handler.
The default limit is 1 MB, which is why this file raises it to 5 MB.

## Why the body limit is the important line

akkar buffers the whole upload in memory before your handler sees it, so
`body_limit` is not a formality: it is the number that decides how much
memory one caller can make this process allocate. Five concurrent 5 MB
uploads is 25 MB of resident memory. Set the limit to the largest file you
actually accept and no higher, and remember that `content_type` is a string
the client chose, so it says what the client claims to have sent and not what
the bytes are. Check the bytes as well if the file goes anywhere it can be
served back.
