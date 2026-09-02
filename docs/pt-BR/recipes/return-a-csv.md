# Retornar um CSV

> **Português (Brasil)** | [Original em inglês](../../recipes/return-a-csv.md)

Responde com um arquivo de planilha em vez de JSON, e faz o navegador salvá-lo
com um nome que você escolhe.

Você vai precisar da tabela `tasks` da [página 5](../guide/05-a-database.md)
do guia.

## O arquivo inteiro

```lua
local akkar = require "akkar"
local db    = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}

-- Um campo que contém vírgula, aspas ou quebra de linha precisa ser
-- colocado entre aspas, e uma aspa dentro dele precisa ser dobrada. Tudo o
-- mais sai como está.
local function cell(value)
  local text = tostring(value)
  if text:find '["\n\r,]' then
    return '"' .. text:gsub('"', '""') .. '"'
  end
  return text
end

local function csv(header, rows, columns)
  local lines = { table.concat(header, ",") }
  for _, row in ipairs(rows) do
    local out = {}
    for i, column in ipairs(columns) do out[i] = cell(row[column]) end
    lines[#lines + 1] = table.concat(out, ",")
  end
  return table.concat(lines, "\r\n") .. "\r\n"
end

local app = akkar.new()

app:get("/tasks.csv", function(req)
  local rows = req.db:many "select id, title, done from tasks order by id"

  local body = csv({ "id", "title", "done" }, rows, { "id", "title", "done" })

  local res = akkar.raw(body, "text/csv; charset=utf-8")
  res.headers = { ["content-disposition"] = 'attachment; filename="tasks.csv"' }
  return res
end)

app:run { port = 3000, db = open }
```

`akkar.raw(body, content_type)` é a resposta certa quando o conteúdo não é
JSON. O corpo sai exatamente como foi dado.

## Testando

```sh
lua5.4 app.lua
```

Em um segundo terminal:

```sh
curl -i http://127.0.0.1:3000/tasks.csv
```

```
HTTP/1.1 200 OK
content-disposition: attachment; filename="tasks.csv"
x-request-id: 8dbcaf87000001
content-type: text/csv; charset=utf-8
content-length: 141

id,title,done
8,buy milk,false
9,call the bank,false
10,read the guide,false
11,buy a birthday card,false
12,buy a birthday card,false
```

## Por que o escape vale as seis linhas

Uma exportação em CSV é o único endpoint cuja saída é lida por um programa
que ninguém aqui escreveu, e um título contendo uma vírgula transforma uma
coluna em duas em todas as linhas seguintes. A função `cell` acima é a regra
inteira: colocar entre aspas quando o valor contém uma vírgula, uma aspa ou
uma quebra de linha, e dobrar qualquer aspa interna. As quebras de linha são
`\r\n` porque é isso que o formato exige e o que o Excel espera. Se a
exportação for grande o suficiente para que mantê-la em memória vire um
problema, produza-a conforme ela é escrita: veja
[Transmitir uma resposta grande](stream-a-large-response.md).
