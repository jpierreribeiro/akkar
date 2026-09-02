# 6. Guardando e lendo linhas

> **Português (Brasil)** | [Original em inglês](../../guide/06-storing-and-reading.md)

Ao final desta página, sua lista de tarefas vai guardar suas tarefas no Postgres. Você vai conseguir parar o servidor, iniciá-lo de novo, e encontrar suas tarefas ainda lá.

Você precisa do banco de dados da [página 5](05-a-database.md): o container rodando, e a tabela `tasks` criada pela migration.

## Primeiro, o erro que acaba com empresas

Existe uma forma de escrever código de banco de dados que é fácil, óbvia e catastrófica. Vale a pena conhecê-la antes de qualquer outra coisa, porque depois que você a viu, vai reconhecê-la pelo resto da vida.

Aqui está um handler que salva uma tarefa. Ele monta o SQL colando o título no meio dele.

**Não execute este bloco.** Ele está aqui para ser lido e nada mais. Está marcado de forma que a própria suíte de testes do guia se recuse a executá-lo, porque rodar isso contra um banco de dados destrói esse banco de dados, que é exatamente o ponto sendo demonstrado.

```lua skip
app:post("/tasks", { body = { title = "string" } }, function(req)
  local task = req.db:one(
    "insert into tasks (title) values ('" .. req.body.title .. "') " ..
    "returning id, title, done")
  return akkar.created(task)
end)
```

Parece estar tudo certo. Funciona. Todo título que você testar volta correto.

Agora alguém envia isto como título:

```
'); drop table tasks; --
```

Cole isso na string e veja o que é entregue ao banco de dados:

```
insert into tasks (title) values (''); drop table tasks; --') returning id, title, done
```

Leia do jeito que o Postgres lê. Os dois primeiros caracteres de quem chamou, `')`, fecharam o valor e fecharam a instrução. Depois vem uma nova instrução: `drop table tasks`. Depois `--`, que significa "ignore o resto desta linha", então tudo que vem depois, incluindo toda a parte `returning` que você escreveu, é descartado antes mesmo de o Postgres olhar para isso.

**O Postgres executa as duas instruções. Sua tabela sumiu.**

Isso não é uma história. Aqui está o mesmo golpe executado contra um banco de dados descartável enquanto esta página era escrita. O pequeno script que rodou isso deixou a parte `returning` de fora, já que o `--` a apaga de qualquer forma:

```
rows before: 1
the SQL that gets sent:
insert into tasks (title) values (''); drop table tasks; --')
after: ok=false err=db: ERROR: relation "tasks" does not exist (32)
```

A tabela existia. Uma requisição depois, a tabela não existia mais.

Isso se chama **injeção de SQL** (SQL injection). O motivo de acontecer não é descuido. É que o banco de dados recebe um único pedaço longo de texto, e nesse ponto não há como saber quais partes foram escritas por você e quais partes chegaram de um estranho. As letras são iguais.

`drop table` é a versão barulhenta. A versão silenciosa lê todas as linhas de todos os outros usuários e as devolve para quem chamou. Você nem notaria.

## O conserto, e é um caractere por valor

Nunca coloque um valor dentro do texto de uma instrução. Escreva um **placeholder** em vez disso, e passe o valor separadamente:

```lua no-run
req.db:one("insert into tasks (title) values ($1) returning id, title, done",
           req.body.title)
```

`$1` significa "o primeiro valor que estou prestes a te dar". `$2` é o segundo, e assim por diante. A instrução vai para o Postgres, depois os valores vão para o Postgres, e eles viajam como duas coisas diferentes.

O Postgres planeja a instrução primeiro, antes de ter visto qualquer valor. No momento em que seu título chega, já não existe mais nenhum lugar nesse plano onde texto poderia virar comando. Um título contendo `drop table` é um título contendo `drop table`, da mesma forma que um título contendo `hello` é um título contendo `hello`.

Não existe uma versão disso que você precisa acertar. Ou você escreveu `$1`, ou não escreveu.

## Conectando o banco de dados à aplicação

Duas linhas conectam as duas metades.

```lua no-run
local open = db.connect { ... }     -- cria a função que abre conexões
app:run { port = 3000, db = open }  -- entrega essa função ao akkar
```

O akkar então coloca uma conexão em `req.db` para cada requisição que usa uma, e a recolhe depois. Seu handler nunca abre nada e nunca fecha nada.

Aqui está tudo, pequeno o suficiente para ver de uma vez. Crie como `app.lua`.

```lua
local akkar = require "akkar"
local db    = require "akkar.db"

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  statement_timeout = 30,
}

local app = akkar.new()

app:get("/tasks", function(req)
  local rows = req.db:many "select id, title, done from tasks order by id"
  return { tasks = akkar.array(rows) }
end)

app:post("/tasks", { body = { title = "string" } }, function(req)
  return akkar.created(req.db:one(
    "insert into tasks (title) values ($1) returning id, title, done",
    req.body.title))
end)

app:run { port = 3000, db = open }
```

```sh
lua5.4 app.lua
```

```
INFO  listening url=http://127.0.0.1:3000
```

Duas diferenças em relação à conexão da página 5.

**Não há `pool_size = 0`.** Sem isso, o akkar mantém um pool de dez conexões e as compartilha entre requisições. Abrir uma conexão leva tempo de verdade, então um servidor que abrisse uma por requisição passaria a maior parte da vida abrindo conexões.

**`statement_timeout = 30` é novo.** Ele diz ao Postgres para desistir de qualquer query única que rode por mais de 30 segundos. Deixe isso de fora e o akkar imprime isto ao iniciar:

```
WARN  db has no statement_timeout, so a request deadline does not stop the query consequence=an abandoned query keeps a backend busy after the 503 fix=db.connect { statement_timeout = <seconds> }, matching the deadline request_deadline_s=30
```

O akkar consegue parar de esperar por uma query lenta, mas só o Postgres consegue parar de executá-la. Sem essa configuração, uma query que ninguém mais está esperando continua trabalhando mesmo assim. A página 11 trata de deadlines de forma completa. Por enquanto, a linha está lá e o aviso não.

### O erro se você esquecer `db = open`

Este é um arquivo completo, e o erro nele é que `app:run` nunca foi informado sobre um banco de dados:

```lua
local akkar = require "akkar"

local app = akkar.new()

app:get("/tasks", function(req)
  return { tasks = akkar.array(req.db:many "select id, title, done from tasks") }
end)

app:run { port = 3000 }
```

```sh
curl -i http://127.0.0.1:3000/tasks
```

```
HTTP/1.1 500 Internal Server Error
x-request-id: e5f4904d000001
content-type: application/json
content-length: 33

{"error":"internal server error"}
```

E no terminal do servidor:

```
ERROR handler raised at=app.lua:5 detail=app.lua:6: req.db is not configured; pass db = ... to app:run{} request_id=e5f4904d000001
```

A mensagem diz o conserto. Vale saber que `req.db` se comporta assim de propósito: ler uma capability que nunca foi configurada te dá uma frase, não `attempt to index a nil value`.

## As quatro coisas que você pode fazer com `req.db`

| Chamada | Devolve | Use para |
|---|---|---|
| `db:one(sql, ...)` | a primeira linha, ou `nil` | uma coisa, por id |
| `db:many(sql, ...)` | uma lista de linhas | uma lista |
| `db:exec(sql, ...)` | um resultado que você geralmente ignora | insert, update, delete |
| `db:transaction(fn)` | o que `fn` devolver | várias instruções, tudo ou nada |

Uma linha é uma tabela Lua simples, com um campo por coluna: `row.id`, `row.title`, `row.done`. Não há mais nada a aprender sobre o formato.

`db:one` devolvendo `nil` quando nada corresponde é o motivo de `or akkar.not_found "..."` aparecer com tanta frequência. Esse padrão é da [página 4](04-errors.md) e não muda agora que o dado é real.

`db:exec` devolve uma tabela com `affected_rows` dentro, que é como você diferencia "apagou uma linha" de "não havia nada para apagar".

### Recuperando a linha depois de inserir

O Postgres tem um recurso que vale a pena conhecer no primeiro dia: `returning`.

```lua no-run
req.db:one("insert into tasks (title) values ($1) returning id, title, done",
           req.body.title)
```

Sem `returning` você inseriria, e depois teria que rodar uma segunda query para descobrir qual id o banco de dados deu para a linha. Com ele, o insert responde com a linha finalizada. Uma ida e volta em vez de duas, e nenhum chute.

### Por que a lista é envolvida em `akkar.array`

Aquele handler não devolve as linhas diretamente. Ele diz:

```lua no-run
return { tasks = akkar.array(rows) }
```

Aqui está para que isso serve. Lua tem um único tipo de tabela, então uma lista vazia e um objeto vazio são o mesmo valor, e o JSON precisa escolher. Ele escolhe `{}`:

```lua
local akkar = require "akkar"
local json  = require "akkar.json"

print(json.encode { tasks = akkar.array {} })
print(json.encode { tasks = {} })
print(json.encode { tasks = akkar.array { "a", "b" } })
```

```
{"tasks":[]}
{"tasks":{}}
{"tasks":["a","b"]}
```

Olhe a linha do meio, e depois imagine sua rota fazendo isso. Com linhas na tabela você responde `"tasks":[...]`, uma lista. Sem linhas você responde `"tasks":{}`, um objeto. **O tipo da sua resposta dependeria de quanto dado por acaso existe.**

Isso é uma coisa ruim de entregar para qualquer um. Quem chama sua API agora precisa de uma verificação para um caso que seu servidor nunca deveria ter produzido, e o jeito mais comum de descobrir isso é `tasks.map(...)` num navegador estourando no dia em que um usuário novo abre uma lista de tarefas vazia.

`akkar.array` marca a tabela como uma lista, então uma vazia continua sendo `[]`. Envolva toda coleção que você devolver. Custa uma chamada e remove uma classe inteira de "funciona até não funcionar".

## Várias instruções que precisam acontecer todas, ou nenhuma

Digamos que você queira adicionar três tarefas em uma requisição. Duas delas funcionam, a terceira tem um título em branco, e você a recusa. Sem ajuda, agora você tem duas tarefas guardadas de uma requisição que falhou, o que é uma bagunça que ninguém pediu.

`db:transaction` é a resposta. Tudo dentro da função ou acontece, ou não acontece:

```lua no-run
app:post("/tasks/bulk", { body = { titles = "table" } }, function(req)
  return req.db:transaction(function(tx)
    local created = {}
    for _, title in ipairs(req.body.titles) do
      if type(title) ~= "string" or title:match "^%s*$" then
        error(akkar.bad_request "every title must be text and not blank")
      end
      created[#created + 1] = tx:one(
        "insert into tasks (title) values ($1) returning id, title, done", title)
    end
    return akkar.created { tasks = akkar.array(created) }
  end)
end)
```

Dentro da função você usa `tx`, não `req.db`. `tx` é a mesma conexão com a transação aberta nela. Usar `req.db` ali seria uma segunda conexão fora da transação, e ela não seria desfeita.

O akkar envia `commit` quando a função retorna e `rollback` se ela levantar um erro. Não existe forma de deixar uma transação aberta por esquecimento, porque não existe linha para você esquecer.

### A parte que vai te pegar

Olhe a recusa de novo. É `error(akkar.bad_request "...")`, não `return akkar.bad_request "..."`.

**Retornar de dentro da função encerra a transação com sucesso.** O akkar não consegue diferenciar "aqui está sua resposta" de "aqui está sua recusa": ambos são valores voltando de uma função que não falhou. Então ele faz commit, e as linhas escritas antes da recusa permanecem.

Este é o truque da [página 4](04-errors.md) fazendo trabalho de verdade. Uma resposta lançada com `error(...)` chega a quem chamou exatamente como se tivesse sido retornada, e no caminho de saída ela desfaz a transação.

A diferença é fácil de ver. As listas abaixo vêm de um banco de dados que já tinha quatro tarefas nele, criadas pelos passos no final desta página, então as suas vão mostrar suas próprias tarefas em vez disso. O que importa é qual delas ganha uma linha.

Com `error(...)`:

```sh
curl -s -i -X POST http://127.0.0.1:3000/tasks/bulk \
  -H "content-type: application/json" -d '{"titles":["call the bank","   "]}'
```

```
HTTP/1.1 400 Bad Request
x-request-id: 3292fc5800000e
content-type: application/json
content-length: 50

{"error":"every title must be text and not blank"}
```

```sh
curl -s http://127.0.0.1:3000/tasks
```

```
{"tasks":[{"id":1,"title":"buy milk","done":false},{"id":2,"title":"walk the dog","done":false},{"id":4,"title":"read the guide","done":false},{"id":5,"title":"water the plants","done":false}]}
```

Nenhum "call the bank". Agora troque essa uma palavra para `return` e envie a mesma requisição. A resposta é idêntica:

```
HTTP/1.1 400 Bad Request
x-request-id: 0a51984b000001
content-type: application/json
content-length: 50

{"error":"every title must be text and not blank"}
```

Mas a lista não é:

```
{"tasks":[{"id":1,"done":false,"title":"buy milk"},{"id":2,"done":false,"title":"walk the dog"},{"id":4,"done":false,"title":"read the guide"},{"id":5,"done":false,"title":"water the plants"},{"id":7,"done":false,"title":"call the bank"}]}
```

Aí está, id 7, guardado por uma requisição que foi respondida com `400 Bad Request`. Nada quebrou e nada pareceu errado. **Dentro de uma transação, levante o erro para recusar.**

(Os ids pulam números, e isso é normal. O Postgres distribui o próximo número mesmo quando a linha é desfeita ou apagada, porque a alternativa seria fazer todo mundo esperar sua vez por um id.)

## Queries que não são as mesmas toda vez

Filtrar e ordenar são pontos onde SQL escrito à mão dá errado, porque a instrução agora depende do que quem chamou pediu. Essa é exatamente a forma que te tenta a voltar a colar strings.

`akkar.sql` monta a instrução a partir de pedaços em vez disso:

```lua
local sql = require "akkar.sql"

local query = sql.select("id, title, done"):from "tasks"
query:where("done = ?", false)
query:order_by("title", { "id", "title" })
query:limit(10)

print(query:to_string())
for _, value in ipairs(query:values()) do
  print("value: " .. tostring(value))
end
```

```sh
lua5.4 builder.lua
```

```
select id, title, done from tasks where done = $1 order by title asc limit $2
value: false
value: 10
```

Olhe o que isso produziu. O `?` na sua condição virou `$1`, e `false` foi para a lista de valores. **O builder não consegue colocar um valor dentro do texto mesmo que você queira.** Não existe método que aceite SQL bruto e não existe válvula de escape, porque uma válvula de escape é para onde vai a injeção.

Entregue a query diretamente ao `db:many`, sem nenhum passo `build()`:

```lua no-run
return { tasks = akkar.array(req.db:many(query)) }
```

### Nomes de coluna não são valores

`$1` funciona para um valor. Não funciona para um nome de coluna: o Postgres não consegue planejar `order by $1`, porque o plano depende de qual coluna é.

Então um nome de coluna vindo de quem chamou precisa ser verificado contra uma lista que você escreveu:

```lua no-run
query:order_by(req.query.sort, { "id", "title" })
```

Esse segundo argumento é a lista inteira de permitidos. Qualquer outra coisa é recusada:

```lua
local sql = require "akkar.sql"

local query = sql.select("id, title"):from "tasks"

local ok, why = pcall(function()
  query:order_by("password_hash", { "id", "title" })
end)

print("allowed?", ok)
print(why)
```

```
allowed?	false
akkar.sql: order column 'password_hash' is not in the allowed list (id, title)
```

(`pcall` executa uma função e captura o erro em vez de parar o programa, que é como o exemplo consegue imprimir a recusa em vez de quebrar por causa dela.)

Faça a mesma verificação no schema da rota, com `one_of`, e quem chamou recebe um `422` limpo em vez de um `500`:

```lua no-run
sort = v.string { optional = true, one_of = { "id", "title" }, default = "id" }
```

```sh
curl -s -i "http://127.0.0.1:3000/tasks?sort=password_hash"
```

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: 3292fc5800000a
content-type: application/json
content-length: 81

{"fields":{"query.sort":"must be one of: id, title"},"error":"validation failed"}
```

As duas verificações, por dois motivos diferentes. O schema está ali para dar a quem chamou uma boa resposta. A lista de permitidos está ali porque um schema que você esquece de escrever não deveria ser a única coisa entre um estranho e suas colunas.

## A aplicação inteira

Tudo acima em um único arquivo. Este é o `app.lua`.

```lua
local akkar = require "akkar"
local db    = require "akkar.db"
local sql   = require "akkar.sql"
local v     = akkar.v

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  statement_timeout = 30,
}

local app = akkar.new()

app:get("/tasks", {
  query = {
    done = "boolean?",
    sort = v.string { optional = true, one_of = { "id", "title" }, default = "id" },
  },
}, function(req)
  local query = sql.select("id, title, done"):from "tasks"
  if req.query.done ~= nil then
    query:where("done = ?", req.query.done)
  end
  query:order_by(req.query.sort, { "id", "title" })
  return { tasks = akkar.array(req.db:many(query)) }
end)

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  local task = req.db:one(
    "select id, title, done from tasks where id = $1", req.params.id)
  return task or akkar.not_found "no task with that id"
end)

app:post("/tasks", { body = { title = "string" } }, function(req)
  return akkar.created(req.db:one(
    "insert into tasks (title) values ($1) returning id, title, done",
    req.body.title))
end)

app:post("/tasks/bulk", { body = { titles = "table" } }, function(req)
  return req.db:transaction(function(tx)
    local created = {}
    for _, title in ipairs(req.body.titles) do
      if type(title) ~= "string" or title:match "^%s*$" then
        error(akkar.bad_request "every title must be text and not blank")
      end
      created[#created + 1] = tx:one(
        "insert into tasks (title) values ($1) returning id, title, done", title)
    end
    return akkar.created { tasks = akkar.array(created) }
  end)
end)

app:delete("/tasks/:id", { params = { id = "integer" } }, function(req)
  local gone = req.db:exec("delete from tasks where id = $1", req.params.id)
  if gone.affected_rows == 0 then
    return akkar.not_found "no task with that id"
  end
  return nil
end)

app:run { port = 3000, db = open }
```

Execute-o, e trabalhe nestes passos em ordem.

**Uma lista vazia, porque a tabela está vazia:**

```sh
curl -s http://127.0.0.1:3000/tasks
```

```
{"tasks":[]}
```

Uma lista vazia, e ainda assim uma lista, por causa de `akkar.array`.

**Crie uma:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"buy milk"}'
```

```
HTTP/1.1 201 Created
x-request-id: 3292fc58000002
content-type: application/json
content-length: 40

{"id":1,"title":"buy milk","done":false}
```

**E outra:**

```sh
curl -s -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"walk the dog"}'
```

```
{"id":2,"title":"walk the dog","done":false}
```

```sh
curl -s http://127.0.0.1:3000/tasks
```

```
{"tasks":[{"id":1,"title":"buy milk","done":false},{"id":2,"title":"walk the dog","done":false}]}
```

**Agora envie o ataque, de propósito:**

```sh
curl -s -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" \
  -d "{\"title\":\"'); drop table tasks; --\"}"
```

```
{"id":3,"title":"'); drop table tasks; --","done":false}
```

```sh
curl -s http://127.0.0.1:3000/tasks
```

```
{"tasks":[{"id":1,"title":"buy milk","done":false},{"id":2,"title":"walk the dog","done":false},{"id":3,"title":"'); drop table tasks; --","done":false}]}
```

É uma tarefa. Tem um id. A tabela ainda está lá. Aquela string agora é a linha mais entediante do seu banco de dados, e é exatamente isso que deveria acontecer com ela.

**Ordene por título, o que passa pela lista de permitidos:**

```sh
curl -s "http://127.0.0.1:3000/tasks?sort=title"
```

```
{"tasks":[{"id":3,"title":"'); drop table tasks; --","done":false},{"id":1,"title":"buy milk","done":false},{"id":2,"title":"walk the dog","done":false}]}
```

Ordenado por texto, então o título começando com apóstrofo vem primeiro.

**Apague, depois apague de novo:**

```sh
curl -s -i -X DELETE http://127.0.0.1:3000/tasks/3
```

```
HTTP/1.1 204 No Content
x-request-id: 3292fc5800000b
content-length: 0

```

```sh
curl -s -i -X DELETE http://127.0.0.1:3000/tasks/3
```

```
HTTP/1.1 404 Not Found
x-request-id: 3292fc5800000c
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

`affected_rows` foi 1 na primeira vez e 0 na segunda, que é como o handler sabe a diferença.

**Várias de uma vez:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/tasks/bulk \
  -H "content-type: application/json" \
  -d '{"titles":["read the guide","water the plants"]}'
```

```
HTTP/1.1 201 Created
x-request-id: 3292fc5800000d
content-type: application/json
content-length: 107

{"tasks":[{"id":4,"title":"read the guide","done":false},{"id":5,"title":"water the plants","done":false}]}
```

Agora pare o servidor com `Ctrl-C` e inicie-o de novo. Peça a lista mais uma vez. **As tarefas ainda estão lá.** Essa é a frase para a qual esta página inteira existiu.

## Checkpoint

Você tem isso se:

- postar uma tarefa e reiniciar o servidor deixa a tarefa no lugar
- `'); drop table tasks; --` é guardado como um título e sua tabela sobrevive
- `?sort=password_hash` dá `422`, não `500` e não um stack trace
- uma requisição bulk com um título em branco nela não cria nada

E você consegue dizer por que placeholders existem em uma frase: porque o valor nunca vira parte da instrução, então texto nunca pode virar comando.

Agora todo mundo que chama vê todas as tarefas, porque ainda não existe algo como um usuário. Isso é o próximo passo: [7. Contas](07-accounts.md).
