# Limite de taxa em um endpoint

> **Português (Brasil)** | [Original em inglês](../../recipes/rate-limit-one-endpoint.md)

Coloca um limite em um caminho caro e deixa todos os outros caminhos em paz.

Você precisa do Redis:

```sh
docker run -d --name akkar-redis -p 6379:6379 redis:7-alpine
```

## O arquivo inteiro

```lua
local akkar = require "akkar"
local redis = require "akkar.redis"

local app = akkar.new()

-- O limitador é middleware, e middleware roda para toda requisição. Esse portão
-- é o que faz com que ele se aplique a um caminho e a nenhum outro.
local search_limit = akkar.limit.rate { per_second = 1, burst = 5 }

app:use(function(req, next)
  if req.path ~= "/search" then return next(req) end
  return search_limit(req, next)
end)

app:get("/search", function(req)
  return { query = req.query.q, results = akkar.empty_array }
end)

app:get("/health", function() return { ok = true } end)

app:run {
  port = 3000,
  cache = redis.connect { host = "127.0.0.1", port = 6379 },
}
```

`per_second` é a velocidade com que a cota é reabastecida e `burst` é o quanto
dela um chamador pode gastar de uma vez. O limitador conta por chamador: por
conta quando o middleware de autenticação já definiu `req.user`, e por
endereço IP caso contrário.

## Experimente

```sh
lua5.4 app.lua
```

Em um segundo terminal, a primeira requisição:

```sh
curl -i "http://127.0.0.1:3000/search?q=milk"
```

```
HTTP/1.1 200 OK
ratelimit-limit: 5
ratelimit-remaining: 4
ratelimit-reset: 1
x-request-id: 90ed2034000001
content-type: application/json
content-length: 29

{"results":[],"query":"milk"}
```

Execute seis vezes dentro de um segundo e a sexta é recusada:

```
HTTP/1.1 429 Too Many Requests
ratelimit-reset: 5
ratelimit-limit: 5
ratelimit-remaining: 0
retry-after: 1
x-request-id: 90ed2034000007
content-type: application/json
content-length: 45

{"retry_after":1,"error":"too many requests"}
```

O `/health` continua respondendo não importa quantas vezes você pergunte,
porque o portão o mandou direto por cima do limitador.

## Por que um portão e não a lista `before` da rota

Uma rota pode ter sua própria lista de middleware, e `app:get("/search", {
before = { search_limit } }, handler)` parece ser a grafia mais organizada.
Ela tem uma pegadinha: o middleware em uma lista `before` vê exatamente o que
o handler retornou, e o limitador adiciona seus cabeçalhos copiando uma
resposta, então um handler que retorna uma tabela simples acaba sendo copiado
para uma resposta sem status e o chamador recebe um 503 vazio. O middleware
de rota ali precisa retornar `akkar.ok { ... }` em vez de `{ ... }`. O portão
acima não tem essa regra, e é por isso que é ele que está escrito aqui. Para
o argumento sobre limites em geral, e a diferença entre contar por segundo e
contar em trânsito, veja [a página 11](../guide/11-not-falling-over.md) do
guia.
