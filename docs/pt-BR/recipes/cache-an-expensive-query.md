# Fazer cache de uma query cara

> **Português (Brasil)** | [Original em inglês](../../recipes/cache-an-expensive-query.md)

Calcula uma resposta uma vez, guarda ela por um minuto e atende todo mundo que chamar nesse minuto a partir da memória em vez do banco de dados.

Você vai precisar da tabela `tasks` da [página 5](../guide/05-a-database.md) do guia, e do Redis:

```sh
docker run -d --name akkar-redis -p 6379:6379 redis:7-alpine
```

## O arquivo inteiro

```lua
local akkar = require "akkar"
local db    = require "akkar.db"
local redis = require "akkar.redis"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}

local KEY = "stats:tasks"
local TTL = 60

local app = akkar.new()

app:get("/stats", function(req)
  local cached = req.cache:get(KEY)
  if cached then return akkar.json.decode(cached) end

  local row = req.db:one [[
    select count(*)::int                          as total,
           count(*) filter (where done)::int      as done
    from tasks
  ]]

  req.cache:set(KEY, akkar.json.encode(row), TTL)
  req.log:info("stats computed", { ttl_s = TTL })
  return row
end)

app:run {
  port = 3000,
  db = open,
  cache = redis.connect { host = "127.0.0.1", port = 6379 },
}
```

O cache guarda strings, então a linha entra como JSON e sai de volta com `akkar.json.decode`. O terceiro argumento de `set` é o tempo de vida em segundos. Depois dele, a chave desaparece e o próximo requisitante paga o preço da query.

## Testando

```sh
lua5.4 app.lua
```

Em um segundo terminal, pergunte duas vezes:

```sh
curl http://127.0.0.1:3000/stats
curl http://127.0.0.1:3000/stats
```

```
{"total":5,"done":0}
{"total":5,"done":0}
```

Duas respostas idênticas, e no primeiro terminal uma linha:

```
INFO  listening url=http://127.0.0.1:3000
INFO  stats computed request_id=ab82d0de000001 ttl_s=60
```

A query rodou uma vez só. A segunda requisição nunca chegou ao banco de dados.

## Por que tempo de vida e não invalidação na escrita

Apagar a chave sempre que as linhas subjacentes mudam é mais exato e bem mais difícil de manter certo: toda escrita em qualquer lugar da aplicação precisa lembrar de todas as chaves que ela afeta, e a que esquecer serve uma resposta errada para sempre. Um tempo de vida está errado por no máximo `TTL` segundos e depois se corrige sozinho sem ninguém precisar lembrar de nada, o que é a troca certa para um número de painel e a errada para um saldo bancário. Adicione `req.cache:del(KEY)` nas escritas que você controla se quiser as duas coisas. Use o Redis em vez de `akkar.cache.memory` para isso assim que houver mais de um processo: cache em memória é por processo, então com quatro workers você tem quatro cópias e quatro vezes mais misses.
