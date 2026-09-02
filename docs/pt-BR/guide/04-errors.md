# 4. Erros que não são falhas críticas

> **Português (Brasil)** | [Original em inglês](../../guide/04-errors.md)

Ao final desta página, sua lista de tarefas vai responder corretamente quando algo
der errado: `404` para uma tarefa que não existe, `400` para uma requisição (request) que
quebra uma regra, e `500` somente quando a falha for realmente sua.

Mesma configuração de antes: `app.lua` na pasta `akkar`, um terminal rodando o
servidor, outro para o `curl`. Veja a [página 2](02-your-first-route.md) se precisar.

## Uma pergunta decide o código de status

De quem é a culpa?

- **A culpa é de quem chamou** recebe um status que começa com `4`. A mensagem é direcionada
  a quem chamou, e deve ser específica, porque essa pessoa pode corrigir o problema.
- **A culpa é sua** recebe um status que começa com `5`. A mensagem é direcionada
  a você, e quem chamou recebe quase nada, porque não há nada que essa pessoa possa fazer.

É essa a ideia inteira. Todo status abaixo é um desses dois casos.

Errar isso não é só uma questão estética. Um `5` significa "eu estou quebrado", e um servidor que
retorna `500` para uma entrada inválida comum vai acionar alguém às 3 da manhã por causa de quem chamou
digitou uma palavra errada. Um `4` significa "você está errado", e um servidor que retorna
`400` para um bug próprio esconde esse bug para sempre, porque ninguém investiga um
erro de cliente.

## Os que o akkar trata sem você precisar fazer nada

Você já viu alguns destes. Aqui estão todos juntos. A menos que uma seção
mostre seu próprio arquivo, a saída veio da aplicação finalizada no final
desta página, então você pode rodar cada um destes assim que tiver esse arquivo.

**Nenhuma rota corresponde ao caminho.** `404`.

```sh
curl -i http://127.0.0.1:3000/nope
```

```
HTTP/1.1 404 Not Found
x-request-id: fe230c25000005
content-type: application/json
content-length: 35

{"error":"no route for GET \/nope"}
```

**O caminho existe, o método não.** `405`, e ele diz o que funcionaria.

```sh
curl -i -X PUT http://127.0.0.1:3000/tasks/1
```

```
HTTP/1.1 405 Method Not Allowed
allow: DELETE, GET
x-request-id: fe230c25000004
content-type: application/json
content-length: 57

{"allowed":["DELETE","GET"],"error":"method not allowed"}
```

**O corpo não é um JSON válido.** `400`.

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{oops}'
```

```
HTTP/1.1 400 Bad Request
x-request-id: fe230c25000001
content-type: application/json
content-length: 29

{"error":"invalid JSON body"}
```

**O corpo é de um tipo que o servidor não lê.** `415`, não `400`. O corpo pode
estar perfeitamente bem formado e simplesmente ser algo que este servidor não entende,
e `400` culparia quem chamou pela coisa errada.

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: text/plain" -d 'hello'
```

```
HTTP/1.1 415 Unsupported Media Type
x-request-id: fe230c25000002
content-type: application/json
content-length: 149

{"error":"unsupported content type 'text\/plain'; this endpoint reads application\/json, application\/x-www-form-urlencoded or multipart\/form-data"}
```

**O corpo é enorme.** `413`. O akkar o recusa antes de lê-lo para a
memória, então quem chamou não pode usar um upload grande para esgotar o seu servidor. O
limite padrão é 1 MB.

```sh
head -c 2000000 /dev/zero | tr '\0' 'a' > big.txt
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" --data-binary @big.txt
```

```
HTTP/1.1 413 Request Entity Too Large
x-request-id: fe230c25000003
content-type: application/json
content-length: 46

{"error":"request body exceeds 1048576 bytes"}
```

**A entrada não corresponde ao esquema.** `422`, com os campos que falharam nomeados. Isso
foi tudo o que vimos na [página 3](03-reading-input.md).

**A requisição demorou demais.** `503`. Toda requisição tem um prazo, 30 segundos
por padrão. Aqui está uma com o prazo definido para 1 segundo e um handler que
demora 3:

```lua
local akkar   = require "akkar"
local cqueues = require "cqueues"

local app = akkar.new()

app:get("/slow", function()
  cqueues.sleep(3)
  return { done = true }
end)

app:run { port = 3000, timeout = 1 }
```

```sh
curl -i http://127.0.0.1:3000/slow
```

```
HTTP/1.1 503 Service Unavailable
x-request-id: 30e8581a000001
content-type: application/json
content-length: 37

{"error":"request deadline exceeded"}
```

E no terminal do servidor:

```
WARN  request deadline exceeded method=GET path=/slow request_id=30e8581a000001 timeout_s=1
```

Sete comportamentos, nenhum código. Você os ganha só por usar o akkar.

## O 500 que você causa, e o que quem chamou recebe como informação

Aqui está um handler com um bug nele. Ele busca uma tarefa e a usa sem
verificar se ela foi encontrada.

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
  local task = find_task(req.params.id)
  return { id = task.id, title = task.title }
end)

app:run { port = 3000 }
```

A tarefa 1 funciona:

```sh
curl -i http://127.0.0.1:3000/tasks/1
```

```
HTTP/1.1 200 OK
x-request-id: 193d86bb000002
content-type: application/json
content-length: 27

{"id":1,"title":"buy milk"}
```

A tarefa 99 não:

```sh
curl -i http://127.0.0.1:3000/tasks/99
```

```
HTTP/1.1 500 Internal Server Error
x-request-id: 193d86bb000003
content-type: application/json
content-length: 33

{"error":"internal server error"}
```

`find_task` não retornou nada, então `task` era `nil`, então `task.id` quebrou.

**Duas coisas aconteceram aqui e ambas valem a pena entender.**

**Primeiro, o servidor não morreu.** Um handler gerou um erro e o akkar
respondeu `500` para essa requisição. O processo continuou rodando e a próxima
requisição foi atendida normalmente. Uma falha dentro de um handler é contida.

**Segundo, quem chamou não recebeu nenhuma informação útil.** Isso é proposital. Veja
o que o servidor imprimiu em vez disso:

```
ERROR handler raised at=app.lua:16 detail=app.lua:18: attempt to index a nil value (local 'task') request_id=193d86bb000003
```

A mensagem real, o arquivo e os dois números de linha: `app.lua:16` é onde a
rota é declarada, `app.lua:18` é onde ela quebrou. Nada disso foi para
quem chamou, porque uma mensagem de erro do Lua pode conter caminhos de arquivos, nomes de
variáveis internas e às vezes fragmentos de SQL. Entregar isso para quem
enviou a requisição diz a um atacante como o seu servidor é construído.

O `request_id` está nos dois lugares. Quem chamou o tem no cabeçalho
`x-request-id`, você o tem no log. Alguém pode reportar "recebi um
erro, o id era 193d86bb000003" e você pode encontrar exatamente essa requisição.

## Dizendo "não encontrado" de propósito

O `500` acima não é realmente sobre uma verificação de nil ausente. **Pedir uma tarefa
que não existe é algo normal para quem chamou fazer, e a resposta correta
é `404`.** O bug foi responder isso como uma falha do servidor.

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
  local task = find_task(req.params.id)
  if not task then
    return akkar.not_found "no task with that id"
  end
  return { id = task.id, title = task.title }
end)

app:run { port = 3000 }
```

```sh
curl -i http://127.0.0.1:3000/tasks/99
```

```
HTTP/1.1 404 Not Found
x-request-id: 27532103000002
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

`akkar.not_found "..."` constrói uma resposta com status `404` e um corpo de
`{"error": "..."}`. Você a retorna exatamente da mesma forma que retorna uma tabela, porque
é apenas mais um valor. Não existe um "caminho de erro" separado para aprender.

## Os helpers, todos eles

Cada um recebe uma mensagem opcional e retorna uma resposta que você pode devolver com `return`.

| Helper | Status | Use quando |
|---|---|---|
| `akkar.ok(body)` | 200 | você quer `200` com um corpo explícito |
| `akkar.created(body)` | 201 | você acabou de criar algo |
| `akkar.no_content()` | 204 | funcionou e não há nada para enviar |
| `akkar.bad_request(msg)` | 400 | a requisição quebra uma regra que um esquema não consegue expressar |
| `akkar.unauthorized(msg)` | 401 | quem chamou não provou quem é |
| `akkar.forbidden(msg)` | 403 | você sabe quem é a pessoa e ela não pode fazer isso |
| `akkar.not_found(msg)` | 404 | a coisa que ela pediu não existe |
| `akkar.conflict(msg)` | 409 | isso colide com algo que já existe |
| `akkar.too_large(msg)` | 413 | o que ela enviou é grande demais |
| `akkar.unavailable(msg)` | 503 | você não pode atender isso agora |

Para qualquer outra coisa, `akkar.response(status, body)` aceita qualquer status e qualquer
corpo.

Retornar `nil` de um handler é o mesmo que `akkar.no_content()`. Você viu
isso na página 3, quando `find_task` não encontrava nada e quem chamou recebia `204`.

## 400 ou 422?

Eles são próximos e vale a pena declarar a diferença uma vez.

**`422` é o que o akkar envia quando a entrada não corresponde ao esquema.** Tipo
errado, campo ausente, string longa demais. Você nunca o escreve você mesmo.

**`400` é o que você envia quando a entrada corresponde ao esquema e ainda assim está
errada.** A regra é uma que um esquema não consegue expressar.

```lua
local akkar = require "akkar"

local app = akkar.new()

app:post("/tasks", { body = { title = "string" } }, function(req)
  if req.body.title:match "^%s*$" then
    return akkar.bad_request "title cannot be blank"
  end
  return akkar.created { id = 1, title = req.body.title, done = false }
end)

app:run { port = 3000 }
```

`"   "` é uma string, então o esquema é satisfeito. O akkar não tem nenhuma reclamação. Ainda
não é um título, e apenas o seu código sabe disso:

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"   "}'
```

```
HTTP/1.1 400 Bad Request
x-request-id: da26a49f000001
content-type: application/json
content-length: 33

{"error":"title cannot be blank"}
```

Deixe o título de fora completamente e o esquema o pega primeiro, então o seu `if`
nunca roda:

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{}'
```

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: da26a49f000002
content-type: application/json
content-length: 64

{"error":"validation failed","fields":{"body.title":"required"}}
```

Se você estiver em dúvida sobre qual usar, quase não importa. Ambos são `4`, ambos dizem "quem
chamou enviou algo errado". O que importa é que nenhum dos dois é `500`.

## Levantando um erro de dentro do seu código

Aqui está um problema que você vai encontrar assim que seu código tiver mais de uma camada.

`find_task` é a função que sabe que a tarefa está ausente. Mas `find_task` não
é um handler, então ela não pode retornar uma resposta. Hoje ela retorna `nil`, e
cada chamador precisa lembrar de verificar `nil` e transformá-lo em um
`404`. Um que esquece produz o `500` de antes.

A resposta do akkar: **uma resposta funciona também como um erro lançado.** A última linha de
`find_task` é a única mudança neste arquivo.

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
  error(akkar.not_found "no task with that id")
end

local app = akkar.new()

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  return find_task(req.params.id)
end)

app:run { port = 3000 }
```

`error(...)` é a forma do Lua de lançar um erro. Normalmente, lançar dentro de um handler dá
ao chamador um `500`, como você viu. Mas o akkar verifica primeiro o que foi lançado: se
for uma de suas próprias respostas, essa resposta é enviada como está escrita.

```sh
curl -i http://127.0.0.1:3000/tasks/99
```

```
HTTP/1.1 404 Not Found
x-request-id: 7c0c87ef000001
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

E o caso de sucesso permanece intacto:

```sh
curl -i http://127.0.0.1:3000/tasks/1
```

```
HTTP/1.1 200 OK
x-request-id: 7c0c87ef000002
content-type: application/json
content-length: 40

{"done":false,"id":1,"title":"buy milk"}
```

O handler tem uma linha e nada nele verifica `nil`. Todo handler que
chama `find_task` agora ganha o `404` de graça, e esquecer de verificar não é
mais possível, porque `find_task` nunca retorna `nil`.

Use isso com moderação. Uma resposta retornada é mais fácil de acompanhar do que uma lançada,
então lance apenas onde retornar significaria passar um valor de volta através de
funções que não têm nenhum motivo para saber sobre HTTP.

## A aplicação inteira

Tudo das páginas 2, 3 e 4:

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
  error(akkar.not_found "no task with that id")
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
  if req.body.title:match "^%s*$" then
    return akkar.bad_request "title cannot be blank"
  end

  for _, task in ipairs(tasks) do
    if task.title == req.body.title then
      return akkar.conflict "a task with that title already exists"
    end
  end

  local task = { id = next_id, title = req.body.title, done = false }
  tasks[#tasks + 1] = task
  next_id = next_id + 1
  return akkar.created(task)
end)

app:delete("/tasks/:id", { params = { id = "integer" } }, function(req)
  local task = find_task(req.params.id)
  for i, candidate in ipairs(tasks) do
    if candidate.id == task.id then
      table.remove(tasks, i)
      break
    end
  end
  return nil
end)

app:run { port = 3000 }
```

Seis respostas de um servidor. Rode-as nesta ordem.

**Uma tarefa que não existe:**

```sh
curl -s -i http://127.0.0.1:3000/tasks/99
```

```
HTTP/1.1 404 Not Found
x-request-id: 35851af7000001
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

**Um título que é só espaços:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"   "}'
```

```
HTTP/1.1 400 Bad Request
x-request-id: 35851af7000002
content-type: application/json
content-length: 33

{"error":"title cannot be blank"}
```

**Um título que já existe:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"buy milk"}'
```

```
HTTP/1.1 409 Conflict
x-request-id: 35851af7000003
content-type: application/json
content-length: 49

{"error":"a task with that title already exists"}
```

**Um título que está tudo bem:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"walk the dog"}'
```

```
HTTP/1.1 201 Created
x-request-id: 35851af7000004
content-type: application/json
content-length: 44

{"title":"walk the dog","id":3,"done":false}
```

**Excluindo-o:**

```sh
curl -s -i -X DELETE http://127.0.0.1:3000/tasks/3
```

```
HTTP/1.1 204 No Content
x-request-id: 35851af7000005
content-length: 0

```

**Excluindo-o novamente:**

```sh
curl -s -i -X DELETE http://127.0.0.1:3000/tasks/3
```

```
HTTP/1.1 404 Not Found
x-request-id: 35851af7000006
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

Cada um desses é um `4` ou um `2`. Nenhum é um `500`, e essa é a
medida desta página: **um `500` no seu log deveria significar que você tem um bug para corrigir.**
Se erros comuns de quem chamou produzem `500`, o log deixa de significar qualquer coisa e você
vai parar de lê-lo.

## Ponto de checagem

Você conseguiu isso se:

- `curl http://127.0.0.1:3000/tasks/99` retorna `404`, não `204` e não `500`
- publicar um título em branco retorna `400` com sua mensagem
- publicar um título duplicado retorna `409`
- você consegue dizer, para qualquer status que seu servidor envie, de quem é a culpa

Agora você tem uma API de lista de tarefas completa que se comporta corretamente quando as coisas dão
errado. Tudo o que ela sabe desaparece quando você para o servidor, porque as tarefas
vivem em uma variável Lua.

Próximo no guia: um banco de dados de verdade.
