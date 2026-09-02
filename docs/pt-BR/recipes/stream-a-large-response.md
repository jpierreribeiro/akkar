# Transmita uma resposta grande

> **Português (Brasil)** | [Original em inglês](../../recipes/stream-a-large-response.md)

Grava a resposta conforme ela é produzida, de modo que a exportação de qualquer tamanho custa a mesma memória que a exportação de uma única linha.

Você vai precisar da tabela `tasks` da [página 5](../guide/05-a-database.md) do guia.

## O arquivo inteiro

```lua
local akkar = require "akkar"
local db    = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}

local BATCH = 500

local app = akkar.new()

app:get("/tasks.ndjson", function(req)
  return akkar.stream(function(write)
    local after = 0
    while true do
      local rows = req.db:many(
        "select id, title, done from tasks where id > $1 order by id limit $2",
        after, BATCH)
      if #rows == 0 then break end

      for _, row in ipairs(rows) do
        write(akkar.json.encode(row) .. "\n")
      end
      after = rows[#rows].id
    end
  end, { content_type = "application/x-ndjson" })
end)

app:run { port = 3000, db = open }
```

O handler continua retornando um valor. O `akkar.stream` descreve um corpo que é produzido sob demanda, e o loop lê a tabela em lotes de 500, de modo que o processo mantém 500 linhas por vez, e não a tabela inteira.

## Experimente

```sh
lua5.4 app.lua
```

Em um segundo terminal:

```sh
curl -i http://127.0.0.1:3000/tasks.ndjson
```

```
HTTP/1.1 200 OK
x-request-id: 3638d95d000001
content-type: application/x-ndjson
transfer-encoding: chunked
connection: transfer-encoding

{"done":false,"id":8,"title":"buy milk"}
{"done":false,"id":9,"title":"call the bank"}
{"done":false,"id":10,"title":"read the guide"}
{"done":false,"id":11,"title":"buy a birthday card"}
{"done":false,"id":12,"title":"buy a birthday card"}
```

Não há `content-length`, porque o tamanho não é conhecido no momento em que os cabeçalhos são enviados. A resposta é fragmentada (chunked) em vez disso, que é o que significa fazer streaming no HTTP/1.1.

## Três coisas que mudam quando você faz streaming

O status sai junto com o primeiro byte, então um produtor que falha no meio do caminho não pode virar um 500. O akkar registra isso no log e derruba a conexão, e quem chamou vê uma resposta truncada em vez de uma mentira com aparência de completa. Faça toda verificação que possa recusar a requisição (request) antes do primeiro `write`, momento em que retornar um 404 ou um 400 ainda funciona. A conexão com o banco de dados permanece reservada até que o último byte seja escrito, então um leitor lento mantém um slot do pool ocupado pelo tempo que levar para ler. E o prazo da requisição cobre o handler, não o corpo, então uma exportação grande tem permissão para ultrapassar esse prazo. Formate uma linha por registro em vez de um array JSON único sempre que possível: assim o leitor pode começar a trabalhar na primeira linha sem esperar pelo colchete de fechamento.
