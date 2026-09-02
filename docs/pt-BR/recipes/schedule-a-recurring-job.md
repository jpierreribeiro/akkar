# Agende uma tarefa recorrente

> **Português (Brasil)** | [Original em inglês](../../recipes/schedule-a-recurring-job.md)

Roda algo a cada minuto dentro do servidor, e para de rodar quando o servidor
para.

Você vai precisar da tabela `tasks` da [página 5](../guide/05-a-database.md)
do guia.

## O arquivo inteiro

```lua
local akkar   = require "akkar"
local logging = require "akkar.log"
local db      = require "akkar.db"
local time    = require "akkar.time"

local log = logging.new()

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
  pool_size = 2,
}

local EVERY = 60

local app = akkar.new()

app:get("/health", function() return { ok = true } end)

app:task("task-report", function(task)
  while not task.stopping() do
    -- Aqui não existe `req`, então a capability é pega e devolvida na mão.
    -- Não liberar vaza um slot do pool a cada tick.
    local ok, why = pcall(function()
      local conn = open()
      local row = conn:one "select count(*)::int as total from tasks"
      conn:release()
      log:info("task report", { total = row.total })
    end)
    if not ok then log:error("task report failed", { detail = tostring(why) }) end

    -- Dormido em fatias, para que um shutdown não espere o intervalo inteiro passar.
    local due = time.monotime() + EVERY
    while time.monotime() < due and not task.stopping() do
      time.sleep(0.5)
    end
  end
end)

app:handle_signals()
app:run { port = 3000, db = open, log = log }
```

O `pcall` importa. Um tick que lança um erro encerraria a task, e o akkar a
reiniciaria com backoff, então um banco de dados fora do ar por um minuto vira
um erro registrado em log, em vez de um loop de reinicializações.

## Experimente

```sh
lua5.4 app.lua
```

O primeiro tick roda imediatamente e o próximo, um minuto depois:

```
INFO  listening url=http://127.0.0.1:3000
INFO  task started task=task-report
INFO  task report total=5
INFO  task report total=5
```

O servidor responde normalmente o tempo todo:

```sh
curl http://127.0.0.1:3000/health
```

```
{"ok":true}
```

Pare com `Ctrl-C`, ou envie um `SIGTERM` do jeito que um container faz, e o
timer recebe o pedido para terminar, em vez de ser morto:

```
INFO  signal received
INFO  shutdown: no longer accepting connections
INFO  shutdown: asking tasks to finish tasks=1
INFO  shutdown: tasks finished
INFO  shutdown: stopped cleanly
```

## Por que não existe cron no akkar

O akkar não tem agendador (scheduler), e o loop acima é tudo o que um deles
seria. Essa é uma decisão real, não uma lacuna: um timer dentro do processo do
servidor roda uma vez por processo, então dois processos significam duas
execuções por minuto e oito processos significam oito, e qualquer agendador
que o akkar oferecesse teria que responder a essa questão com um lock que
ninguém pediu. Rode isso em um único processo, ou cuide do lock você mesmo,
ou deixe o agendamento para o que já é dono dele, como uma entrada de cron ou
o agendador da sua plataforma chamando uma rota. O que o akkar oferece é que
a task vive e morre com o servidor: pede-se a ela que termine depois que a
última requisição (request) escoa, e nunca no meio de uma execução.
