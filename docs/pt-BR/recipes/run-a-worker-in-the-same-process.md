# Rode um worker no mesmo processo

> **Português (Brasil)** | [Original em inglês](../../recipes/run-a-worker-in-the-same-process.md)

Responde a requisição (request) imediatamente e faz a parte lenta depois, no
mesmo processo, sem Redis e sem um segundo terminal.

## O arquivo inteiro

```lua
local akkar   = require "akkar"
local cqueues = require "cqueues"
local logging = require "akkar.log"
local memory  = require "akkar.jobs.memory"

local log   = logging.new()
local queue = memory.new "emails"

local app = akkar.new()

app:post("/signup", { body = { email = "string" } }, function(req)
  queue:push("welcome", { to = req.body.email })
  return akkar.created { queued = true }
end)

app:get("/queue", function() return { depth = queue:depth() } end)

app:task("emails", function(task)
  while not task.stopping() do
    -- Drena o que estiver esperando e retorna. `consume` não dorme, então
    -- o poll abaixo é o que dá ao servidor a sua vez.
    queue:consume({
      welcome = function(payload)
        log:info("welcome email sent", { to = payload.to })
      end,
    }, {
      timeout = 0,
      should_stop = function() return task.stopping() or queue:depth() == 0 end,
      log = log,
    })

    cqueues.poll(0.05)
  end
end)

app:run { port = 3000, log = log }
```

`app:task(name, fn)` roda uma função no próprio event loop do servidor durante
toda a vida do processo. O akkar supervisiona essa tarefa: uma tarefa que
lança um erro é registrada em log e reiniciada com backoff, e uma tarefa recebe
o pedido para terminar depois que o servidor tiver drenado, para que o trabalho
enfileirado pela última requisição ainda seja consumido.

## Experimente

```sh
lua5.4 app.lua
```

Em um segundo terminal:

```sh
curl -X POST http://127.0.0.1:3000/signup \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com"}'
curl http://127.0.0.1:3000/queue
```

```
{"queued":true}
{"depth":0}
```

O signup respondeu imediatamente, e o primeiro terminal mostra o trabalho
sendo feito logo depois:

```
INFO  listening url=http://127.0.0.1:3000
INFO  task started task=emails
INFO  welcome email sent to=grace@example.com
```

## Por que o loop e o poll, em vez de só usar `consume`

Um único estado Lua roda uma coroutine por vez e só troca quando algo
libera o controle (yield). O armazenamento em memória nunca bloqueia, então
`queue:consume` sem trabalho para fazer é um loop que nunca libera o controle:
o processo vai a 100% de um núcleo e o servidor para de responder por
completo, que é justamente a falha que esse formato evita. O poll é o que
devolve o controle. Isso também define para que serve uma tarefa. Ela serve
para trabalho que espera, como uma fila, um timer ou um poll. Trabalho que
consome CPU continua pertencendo a outro processo, porque enquanto ele roda,
nada mais nesse processo roda junto. Assim que houver mais de um processo,
troque a fila em memória pela `akkar.jobs.redis` para que o trabalho seja
compartilhado em vez de duplicado: a [página 10](../guide/10-background-work.md)
do guia cobre essa fila.
