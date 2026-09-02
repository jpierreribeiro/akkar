# Registre com utilidade

> **Português (Brasil)** | [Original em inglês](../../recipes/log-usefully.md)

Uma linha por requisição (request) com campos que uma busca de log consegue filtrar, e toda linha carregando o id de requisição que a liga às demais.

## O arquivo inteiro

```lua
local akkar   = require "akkar"
local logging = require "akkar.log"
local time    = require "akkar.time"

local log = logging.new { level = "info", format = "json" }

local app = akkar.new()

-- Uma linha por requisição, com os campos que algo poderá buscar depois.
app:use(function(req, next)
  local started = time.monotime()
  local res = next(req)
  req.log:info("request", {
    method = req.method,
    path   = req.path,
    status = res.status,
    ms     = math.floor((time.monotime() - started) * 1000),
  })
  return res
end)

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  if req.params.id ~= 1 then
    -- req.log já carrega o id da requisição, então esta linha e a de cima
    -- podem ser encontradas juntas.
    req.log:warn("task not found", { task_id = req.params.id })
    return akkar.not_found "no task with that id"
  end
  return { id = 1, title = "buy milk", done = false }
end)

app:run { port = 3000, log = log }
```

Passar `log` para `app:run{}` substitui também a voz própria do akkar, então o processo inteiro escreve um único fluxo em um único formato. Dentro de um handler use `req.log`, que o akkar já vinculou ao id da requisição.

## Experimente

```sh
lua5.4 app.lua
```

```sh
curl http://127.0.0.1:3000/tasks/1
curl http://127.0.0.1:3000/tasks/7
```

```
{"id":1,"done":false,"title":"buy milk"}
{"error":"no task with that id"}
```

O primeiro terminal:

```
{"url":"http:\/\/127.0.0.1:3000","message":"listening","time":1786892056,"level":"info"}
{"request_id":"fb09c5ac000001","status":200,"method":"GET","ms":0,"path":"\/tasks\/1","message":"request","time":1786892058,"level":"info"}
{"request_id":"fb09c5ac000002","task_id":7,"message":"task not found","time":1786892058,"level":"warn"}
{"request_id":"fb09c5ac000002","status":404,"method":"GET","ms":0,"path":"\/tasks\/7","message":"request","time":1786892058,"level":"info"}
```

Duas linhas compartilham `fb09c5ac000002`. Isso é uma requisição, e o mesmo id voltou para quem chamou no cabeçalho `x-request-id`, então uma mensagem de suporte que o cite encontra as duas.

Remova `format = "json"` durante o desenvolvimento e as mesmas linhas se leem como
`INFO  request method=GET ms=0 path=/tasks/1 request_id=... status=200`.

## Por que campos e não frases

`log:warn("task not found", { task_id = 7 })` e
`log:warn("task 7 not found")` parecem iguais para uma pessoa e são completamente diferentes para uma máquina. A primeira tem uma mensagem idêntica em toda ocorrência, então pode ser contada, e um campo que pode ser filtrado, então as requisições de um cliente podem ser isoladas. A segunda é uma string que precisa ser casada com um padrão por quem estiver de plantão. Registre os identificadores pelos quais você gostaria de buscar, nunca os valores que você não gostaria de ler em um arquivo de log vazado: uma senha, um token, um cookie de sessão, um corpo de requisição inteiro. Se um valor merece ser escondido, deixe-o de fora em vez de confiar em um redator.
