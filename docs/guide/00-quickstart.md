# Quickstart

One file, one command, one answer. About five minutes.

## 1. Get akkar

You need Lua 5.4, LuaRocks, and the OpenSSL development headers.

```sh
git clone https://github.com/jpierreribeiro/akkar.git
cd akkar
luarocks install --local --only-deps akkar-dev-1.rockspec
eval "$(luarocks path --bin)"
```

Stay in the `akkar` folder for the rest of this page.

## 2. One file

Create `app.lua` in that folder:

```lua
local akkar = require "akkar"

local app = akkar.new()

app:get("/hello", function()
  return { hello = "world" }
end)

app:run { port = 3000 }
```

## 3. One command

```sh
lua5.4 app.lua
```

```
INFO  listening url=http://127.0.0.1:3000
```

The command does not return. That is correct. The server is running and waiting.

## 4. One answer

Open a **second terminal** and run:

```sh
curl http://127.0.0.1:3000/hello
```

```
{"hello":"world"}
```

Press `Ctrl-C` in the first terminal to stop the server.

## If it did not work

**`module 'akkar' not found`**

```
lua5.4: app.lua:1: module 'akkar' not found:
	no field package.preload['akkar']
	no file '/usr/local/share/lua/5.4/akkar.lua'
	no file '/usr/local/share/lua/5.4/akkar/init.lua'
	...
	no file './akkar.lua'
	no file './akkar/init.lua'
```

Lua looked for akkar and could not find it. You are in the wrong folder. `cd`
into the `akkar` folder you cloned and run `lua5.4 app.lua` from there.

**`Address already in use`**

```
lua5.4: akkar: port 3000 on 127.0.0.1 is already in use.
  Something else is listening there -- most often a server from a previous run
  that is still going.
  Stop it, or start this one on another port with app:run { port = 3001 }
```

Something is already listening on port 3000, usually a copy of this server you
forgot to stop. Stop it with `Ctrl-C`, or change `port = 3000` to another
number such as `3001`.

This message used to be a stack trace pointing inside akkar's own source, with
no port in it. It was rewritten because this page existed: writing down what a
beginner sees is what made it obvious that the message was useless to one.

---

That is the whole quickstart. It shows that akkar works, and nothing else.

**Want to understand what you just did?** Start at
[1. What a backend even is](01-what-is-a-backend.md).
