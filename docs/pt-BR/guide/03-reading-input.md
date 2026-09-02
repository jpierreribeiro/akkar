# 3. Lendo a entrada

> **Português (Brasil)** | [Original em inglês](../../guide/03-reading-input.md)

Ao final desta página, sua lista de tarefas vai responder a três rotas: pedir
uma tarefa pelo id, filtrar a lista e criar uma nova tarefa. Você também vai
ver o que dá errado quando a entrada não é verificada, que é o motivo pelo
qual a verificação existe.

Tudo nesta página roda na pasta `akkar`, no arquivo `app.lua`, do mesmo jeito
que na [página 2](02-your-first-route.md). Deixe dois terminais abertos: um
rodando o servidor, outro para o `curl`.

## A entrada chega em três lugares

Uma requisição (request) pode carregar informação em três pontos diferentes,
e eles não são intercambiáveis.

| Onde | Se parece com | Usado para |
|---|---|---|
| O caminho | `/tasks/7` | qual coisa você quer dizer |
| A query string | `/tasks?done=true` | opções e filtros |
| O corpo | anexado a `POST`, `PUT`, `PATCH` | os dados sendo enviados |

O resto desta página é uma seção por ponto.

---

## Parte 1: o caminho

### Um pedaço do caminho que você não sabe de antemão

Você não pode escrever uma rota para cada id de tarefa. Você escreve uma rota
com um buraco nela, como `"/tasks/:id"`.

`:id` significa "qualquer pedaço único do caminho vai aqui, e chame ele de
`id`". Uma requisição para `/tasks/7` bate com a rota, e `7` é o valor.

Duas coisas novas aparecem. O handler agora recebe um argumento, geralmente
chamado de `req`, que é a requisição. E o pedaço capturado fica em
`req.params`, sob o nome que você escolheu.

### A versão que parece certa e está errada

Este é o arquivo completo. Tente antes de continuar lendo.

```lua
local akkar = require "akkar"

local tasks = {
  { id = 1, title = "buy milk",       done = false },
  { id = 2, title = "read the guide", done = true  },
}

local function find_task(id)
  for _, task in ipairs(tasks) do
    if task.id == id then return task end
  end
end

local app = akkar.new()

app:get("/tasks/:id", function(req)
  return find_task(req.params.id)
end)

app:run { port = 3000 }
```

```sh
curl -i http://127.0.0.1:3000/tasks/1
```

```
HTTP/1.1 204 No Content
x-request-id: 970f4cb2000002
content-length: 0

```

A tarefa 1 existe. Você pediu a tarefa 1. Você não recebeu nada.

**`204 No Content` é o que o akkar envia quando um handler não retorna nada.**
Esse é um status real e deliberado, e está correto aqui: `find_task` não
encontrou nada e não retornou nada, então não há conteúdo para enviar. O bug
não está no akkar. O bug é que `find_task` não encontrou a tarefa 1.

### Por que falhou

**Tudo em uma URL é texto.** Não existem números em um caminho, só
caracteres. Então `req.params.id` é a string `"1"`, não o número `1`.

E em Lua, `1 == "1"` é `false`. O número um e o texto "um" são valores
diferentes. Então o laço comparou `1 == "1"` duas vezes, obteve `false` duas
vezes, e não retornou nada.

Nada quebrou. Nenhum erro apareceu em lugar nenhum. A rota simplesmente disse
a todo chamador que nenhuma tarefa existe. Esse é o motivo inteiro da próxima
seção.

### A versão que funciona

Uma mudança. A rota agora declara o que espera.

```lua
local akkar = require "akkar"

local tasks = {
  { id = 1, title = "buy milk",       done = false },
  { id = 2, title = "read the guide", done = true  },
}

local function find_task(id)
  for _, task in ipairs(tasks) do
    if task.id == id then return task end
  end
end

local app = akkar.new()

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  return find_task(req.params.id)
end)

app:run { port = 3000 }
```

A parte nova é `{ params = { id = "integer" } }`, ficando entre o caminho e o
handler. Ela diz: esta rota tem um parâmetro de caminho, chamado `id`, e ele
precisa ser um número inteiro.

```sh
curl -i http://127.0.0.1:3000/tasks/1
```

```
HTTP/1.1 200 OK
x-request-id: aa5a8a75000002
content-type: application/json
content-length: 40

{"id":1,"title":"buy milk","done":false}
```

O akkar verificou que `"1"` é um número inteiro, converteu para o número `1`,
e colocou isso em `req.params.id`. A comparação agora funciona porque os dois
lados são números.

### E bobagem recebe uma resposta de verdade

```sh
curl -i http://127.0.0.1:3000/tasks/abc
```

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: aa5a8a75000003
content-type: application/json
content-length: 71

{"fields":{"params.id":"expected integer"},"error":"validation failed"}
```

`422` significa: eu entendi a requisição, mas os dados nela não são
aceitáveis. O corpo nomeia o campo exato e o problema exato. `params.id` diz
de qual dos três lugares veio, então um cliente que envia tanto um caminho
ruim quanto um corpo ruim consegue diferenciar os dois.

**Seu handler nunca rodou.** O akkar verificou primeiro. Esse é o ponto: um
handler com um schema pode assumir que sua entrada já está no formato certo,
então ele não precisa começar com cinco linhas de verificação.

### Mais uma, e não é um erro

```sh
curl -i http://127.0.0.1:3000/tasks/99
```

```
HTTP/1.1 204 No Content
x-request-id: aa5a8a75000004
content-length: 0

```

`99` é um número inteiro perfeitamente válido, então a validação passou. Só
não existe nenhuma tarefa com esse id, então `find_task` não retornou nada,
então o akkar enviou `204`.

Isso não é o que você quer. Pedir uma tarefa que não existe deveria ser um
`404`, não "aqui está o nada". Consertar isso é a [página 4](04-errors.md).

---

## Parte 2: a query string

Tudo depois do `?` em uma URL é a query string. É uma lista de pares
`nome=valor` unidos por `&`:

```
/tasks?done=true
/tasks?done=true&sort=title
```

Use ela para opções: filtros, ordenação, números de página. Coisas que mudam
como você responde, em vez do que você está pedindo.

O akkar coloca eles em `req.query`, e eles recebem um schema exatamente como
os parâmetros de caminho recebem.

```lua
local akkar = require "akkar"

local tasks = {
  { id = 1, title = "buy milk",       done = false },
  { id = 2, title = "read the guide", done = true  },
}

local app = akkar.new()

app:get("/tasks", { query = { done = "boolean?" } }, function(req)
  if req.query.done == nil then
    return { tasks = tasks }
  end

  local matching = {}
  for _, task in ipairs(tasks) do
    if task.done == req.query.done then
      matching[#matching + 1] = task
    end
  end
  return { tasks = matching }
end)

app:run { port = 3000 }
```

**O `?` no final de `"boolean?"` significa opcional.** Sem ele o campo seria
obrigatório, e `/tasks` sem filtro seria rejeitado. Com ele, `req.query.done`
é ou um booleano de verdade ou `nil`, e `nil` aqui significa "o chamador não
filtrou".

```sh
curl "http://127.0.0.1:3000/tasks"
```

```
{"tasks":[{"title":"buy milk","id":1,"done":false},{"title":"read the guide","id":2,"done":true}]}
```

```sh
curl "http://127.0.0.1:3000/tasks?done=true"
```

```
{"tasks":[{"title":"read the guide","id":2,"done":true}]}
```

```sh
curl "http://127.0.0.1:3000/tasks?done=false"
```

```
{"tasks":[{"title":"buy milk","id":1,"done":false}]}
```

Coloque a URL entre aspas no seu shell. Sem as aspas, o `&` diz ao shell para
rodar o comando em segundo plano, o que é confuso e não é o que você queria.

Assim como antes, a query string é texto. O akkar transformou `"true"` no
booleano `true` porque o schema dizia `boolean`. Envie algo que não é um
booleano e você recebe a mesma forma de resposta de antes:

```sh
curl -i "http://127.0.0.1:3000/tasks?done=yes"
```

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: 396ea19e000005
content-type: application/json
content-length: 72

{"error":"validation failed","fields":{"query.done":"expected boolean"}}
```

---

## Parte 3: o corpo

Para criar uma tarefa, o chamador precisa enviar a tarefa. Isso vai no corpo.

Aqui está o `curl` enviando uma:

```sh
curl -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" \
  -d '{"title":"buy milk"}'
```

Três flags, e todas as três são necessárias:

- `-X POST` define o método. Sem ele o `curl` envia `GET`.
- `-H "content-type: application/json"` diz ao servidor que o corpo é JSON.
  Sem ela o servidor não sabe como ler os bytes.
- `-d '...'` é o próprio corpo.

### Primeiro, sem verificar nada

```lua
local akkar = require "akkar"

local tasks = {}
local next_id = 1

local app = akkar.new()

app:post("/tasks", function(req)
  local task = { id = next_id, title = req.body.title, done = false }
  tasks[#tasks + 1] = task
  next_id = next_id + 1
  return akkar.created(task)
end)

app:run { port = 3000 }
```

`akkar.created(...)` envia o status `201 Created` em vez de `200 OK`. `201` é
a resposta certa para "eu criei uma coisa nova", e é a única ideia nova
naquele arquivo.

O caso bom funciona:

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" \
  -d '{"title":"buy milk"}'
```

```
HTTP/1.1 201 Created
x-request-id: e9429509000002
content-type: application/json
content-length: 40

{"done":false,"title":"buy milk","id":1}
```

Agora os dois casos ruins. Eles são o ponto desta página.

**Um chamador que esquece o título:**

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" \
  -d '{}'
```

```
HTTP/1.1 201 Created
x-request-id: e9429509000003
content-type: application/json
content-length: 21

{"done":false,"id":2}
```

`201 Created`. Seu servidor disse "pronto, criei". Ele armazenou uma tarefa
sem título. Ninguém foi avisado de que algo estava errado. Essa linha agora
está na sua lista para sempre, e todo trecho de código que lê uma tarefa e
espera um título está a um passo de quebrar com ela. Esse é o pior resultado
desta página, porque nada parece quebrado.

**Um chamador que não envia corpo nenhum:**

```sh
curl -i -X POST http://127.0.0.1:3000/tasks
```

```
HTTP/1.1 500 Internal Server Error
x-request-id: 6e579814000002
content-type: application/json
content-length: 33

{"error":"internal server error"}
```

E no terminal do servidor:

```
ERROR handler raised at=app.lua:8 detail=app.lua:9: attempt to index a nil value (field 'body') request_id=6e579814000002
```

Sem corpo enviado, `req.body` é `nil`, então `req.body.title` quebra. `500`
significa que o servidor quebrou. Mas o servidor não quebrou. **O chamador
enviou uma requisição ruim e o servidor levou a culpa por isso.** Esse é o
status errado, e a página 4 é sobre por que isso importa.

### Agora com o schema

```lua
local akkar = require "akkar"

local tasks = {}
local next_id = 1

local app = akkar.new()

app:post("/tasks", { body = { title = "string" } }, function(req)
  local task = { id = next_id, title = req.body.title, done = false }
  tasks[#tasks + 1] = task
  next_id = next_id + 1
  return akkar.created(task)
end)

app:run { port = 3000 }
```

As mesmas três requisições. A boa continua igual:

```
HTTP/1.1 201 Created
x-request-id: 04c9ad53000002
content-type: application/json
content-length: 40

{"done":false,"title":"buy milk","id":1}
```

Título ausente:

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: 04c9ad53000003
content-type: application/json
content-length: 64

{"fields":{"body.title":"required"},"error":"validation failed"}
```

Nenhum corpo:

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: 04c9ad53000004
content-type: application/json
content-length: 64

{"fields":{"body.title":"required"},"error":"validation failed"}
```

Tipo errado:

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" \
  -d '{"title": 42}'
```

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: 04c9ad53000005
content-type: application/json
content-length: 71

{"fields":{"body.title":"expected string"},"error":"validation failed"}
```

Nenhum `500`. Nenhuma tarefa silenciosamente quebrada. O handler não rodou em
nenhum dos três casos ruins, e o chamador foi avisado exatamente sobre qual
campo estava errado.

### Uma segunda coisa que o schema faz

Envie campos que o schema não menciona:

```sh
curl -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" \
  -d '{"title":"buy milk","done":true,"id":999}'
```

O handler vê só isto:

```
{"title":"buy milk"}
```

**Campos que você não declarou são removidos antes do seu handler rodar.**
Um chamador não pode definir `id`, e não pode marcar uma tarefa como feita na
criação, porque isso nunca chega ao seu código. Você não escreveu uma linha
para impedir isso. Declarar o que você aceita é o mesmo ato de rejeitar o que
você não aceita.

---

## Os tipos de schema que você tem agora

Um schema é uma tabela simples. O nome é o campo, o valor é a regra. (Este
bloco está marcado como `no-run` porque é um valor isolado, não um arquivo
inteiro.)

```lua no-run
{ title = "string", count = "integer", ratio = "number",
  done = "boolean", extra = "table" }
```

Cinco nomes de tipo: `string`, `integer`, `number`, `boolean`, `table`. Some
`?` ao final de qualquer um deles para tornar o campo opcional: `"string?"`.

Regras podem ser mais estritas que um tipo. Em vez de um nome, use `akkar.v`:

```lua
local akkar = require "akkar"
local v = akkar.v

local app = akkar.new()

app:post("/tasks", {
  body = {
    title    = v.string { min = 1, max = 100 },
    priority = v.string { optional = true, one_of = { "low", "high" } },
  },
}, function(req)
  return akkar.created { title = req.body.title, priority = req.body.priority }
end)

app:run { port = 3000 }
```

`v.string { min = 1, max = 100 }` é um título entre 1 e 100 caracteres.
`one_of` limita uma string a uma lista fixa. `v.integer { min = 1 }` faz o
mesmo para números. `"string?"` é só um atalho para
`v.string { optional = true }`.

```sh
curl -s -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"x","priority":"urgent"}'
```

```
{"error":"validation failed","fields":{"body.priority":"must be one of: low, high"}}
```

```sh
curl -s -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":""}'
```

```
{"error":"validation failed","fields":{"body.title":"min length 1"}}
```

A mensagem diz qual era a regra, não só que uma regra foi quebrada. Um
chamador consegue agir sobre isso sem ler seu código-fonte.

---

## A aplicação inteira

Tudo desta página em um único arquivo:

```lua
local akkar = require "akkar"

local tasks = {
  { id = 1, title = "buy milk",       done = false },
  { id = 2, title = "read the guide", done = true  },
}
local next_id = 3

local function find_task(id)
  for _, task in ipairs(tasks) do
    if task.id == id then return task end
  end
end

local app = akkar.new()

app:get("/tasks", { query = { done = "boolean?" } }, function(req)
  if req.query.done == nil then
    return { tasks = tasks }
  end

  local matching = {}
  for _, task in ipairs(tasks) do
    if task.done == req.query.done then
      matching[#matching + 1] = task
    end
  end
  return { tasks = matching }
end)

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  return find_task(req.params.id)
end)

app:post("/tasks", { body = { title = "string" } }, function(req)
  local task = { id = next_id, title = req.body.title, done = false }
  tasks[#tasks + 1] = task
  next_id = next_id + 1
  return akkar.created(task)
end)

app:run { port = 3000 }
```

Quatro comandos contra ele, em ordem:

```sh
curl -s http://127.0.0.1:3000/tasks
```

```
{"tasks":[{"id":1,"done":false,"title":"buy milk"},{"id":2,"done":true,"title":"read the guide"}]}
```

```sh
curl -s -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"walk the dog"}'
```

```
{"id":3,"done":false,"title":"walk the dog"}
```

```sh
curl -s http://127.0.0.1:3000/tasks/3
```

```
{"id":3,"done":false,"title":"walk the dog"}
```

```sh
curl -s "http://127.0.0.1:3000/tasks?done=false"
```

```
{"tasks":[{"id":1,"done":false,"title":"buy milk"},{"id":3,"done":false,"title":"walk the dog"}]}
```

A tarefa nova desaparece quando você para o servidor, porque a lista vive em
uma variável Lua. Um banco de dados vem mais adiante no guia.

## Checkpoint

Você tem isso se:

- `curl http://127.0.0.1:3000/tasks/1` retorna a tarefa 1, não `204`
- `curl http://127.0.0.1:3000/tasks/abc` retorna `422` nomeando `params.id`
- `curl -X POST .../tasks -H "content-type: application/json" -d '{}'` retorna
  `422` nomeando `body.title`, e não cria nada

E você consegue dizer por que a validação não é opcional em uma frase: sem
ela, entrada ruim ou quebra o handler como um `500` ou é armazenada como se
estivesse tudo bem, e a segunda é pior.

Uma coisa nesta página ainda está errada e teve um conserto prometido: pedir
`/tasks/99`, uma tarefa que não existe, responde `204 No Content` em vez de
`404 Not Found`. Isso, e a questão inteira de de quem é a culpa por um erro, é
o próximo assunto: [4. Erros que não são quebras](04-errors.md).
