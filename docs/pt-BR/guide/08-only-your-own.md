# 8. Somente as próprias tarefas

> **Português (Brasil)** | [Original em inglês](../../guide/08-only-your-own.md)

Ao final desta página, cada tarefa vai pertencer a uma conta, e nenhuma conta
vai conseguir ver ou mexer nas tarefas de outra.

Você precisa que a [página 7](07-accounts.md) esteja funcionando: você consegue
se cadastrar, fazer login e chamar `/me`.

Esta página começa com o bug de propósito. É o bug mais caro desse tipo de
software, tem uma linha de tamanho, e ninguém o escreve deliberadamente.

## Primeiro, tarefas precisam de um dono

A tabela `tasks` não tem a menor ideia de quem é ninguém. Adicionar uma coluna
`user_id` a ela é uma migração, a terceira:

```sql
alter table tasks add column user_id integer references accounts (id);
delete from tasks where user_id is null;
alter table tasks alter column user_id set not null
```

Três instruções, e a do meio merece um aviso.

**Ela apaga as tarefas que você criou antes de existirem contas.** Toda tarefa
da página 6 não tem dono, e não existe forma honesta de adivinhar um. Uma
tarefa que não pertence a ninguém nunca pode ser mostrada a ninguém, então ela
é peso morto na tabela. Isso a apaga e depois torna a coluna obrigatória, para
que nenhuma linha futura fique sem dono.

Esse delete também é o exemplo mais claro de por que a [página 5](05-a-database.md)
disse que não existe desfazer. Rodar essa migração destrói essas linhas.
Nenhuma migração posterior consegue trazê-las de volta, porque nada em lugar
nenhum sabe o que elas eram. Quando uma migração apaga, leia-a duas vezes antes
de rodá-la em qualquer coisa que importe.

`references accounts (id)` é o banco de dados mantendo o vínculo honesto:
`user_id` tem que ser o id de uma linha real em `accounts`. Tente guardar uma
tarefa para a conta 999 e o Postgres recusa.

## Agora o bug

Aqui está a aplicação com tarefas que têm donos. Ela está completa e roda.
Leia as duas rotas de tarefas com atenção antes de rodá-la.

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local migrate = require "akkar.migrate"
local crypto  = require "akkar.crypto"
local session = require "akkar.session"
local auth    = require "akkar.auth"
local memory  = require "akkar.cache.memory"
local v       = akkar.v

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  statement_timeout = 30,
}

local conn = open()
local runner = migrate.new(conn, {
  files = {
    { name = "003_tasks_belong_to_accounts.sql", sql = [[
      alter table tasks add column user_id integer references accounts (id);
      delete from tasks where user_id is null;
      alter table tasks alter column user_id set not null
    ]] },
  },
})
for _, name in ipairs(runner:apply()) do print("applied " .. name) end
conn:release()

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
}

local app = akkar.new()

app:use(auth.middleware { sessions = sessions, optional = true })

local function require_login(req, next)
  if not req.auth then
    return akkar.unauthorized "log in first"
  end
  return next(req)
end

app:post("/accounts", {
  body = {
    email    = v.string { min = 3, max = 200, match = "^[^@]+@[^@]+$" },
    password = v.string { min = 8, max = 200 },
  },
}, function(req)
  local hash = crypto.hash_password(req.body.password)
  local account = req.db:one(
    "insert into accounts (email, password_hash) values ($1, $2) " ..
    "on conflict (email) do nothing returning id, email",
    req.body.email, hash)

  if not account then
    return akkar.conflict "that email already has an account"
  end
  return akkar.created(account)
end)

app:post("/login", {
  body = { email = "string", password = "string" },
}, function(req)
  local account = req.db:one(
    "select id, email, password_hash from accounts where email = $1",
    req.body.email)

  if not account or not crypto.verify_password(req.body.password,
                                               account.password_hash) then
    return akkar.unauthorized "wrong email or password"
  end

  auth.login(req, account.id)
  return { logged_in_as = account.email }
end)

app:get("/tasks", { before = { require_login } }, function(req)
  local rows = req.db:many "select id, title, done from tasks order by id"
  return { tasks = akkar.array(rows) }
end)

app:post("/tasks", {
  before = { require_login },
  body   = { title = "string" },
}, function(req)
  local task = req.db:one(
    "insert into tasks (title, user_id) values ($1, $2) " ..
    "returning id, title, done",
    req.body.title, req.auth.user_id)
  return akkar.created(task)
end)

app:run { port = 3000, db = open, cache = memory.factory() }
```

```sh
lua5.4 app.lua
```

```
applied 003_tasks_belong_to_accounts.sql
INFO  listening url=http://127.0.0.1:3000
```

Você vai precisar de uma segunda conta para isso. Cadastre uma, a não ser que
você já tenha criado uma na página 7:

```sh
curl -s -X POST http://127.0.0.1:3000/accounts \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"correct horse battery"}'
```

Depois faça login com as duas, cada uma em seu próprio arquivo de cookies:

```sh
curl -s -o /dev/null -X POST http://127.0.0.1:3000/login \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com","password":"correct horse battery"}' -c ada.txt

curl -s -o /dev/null -X POST http://127.0.0.1:3000/login \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"correct horse battery"}' -c grace.txt
```

Cada uma cria uma tarefa:

```sh
curl -s -X POST http://127.0.0.1:3000/tasks -b ada.txt \
  -H "content-type: application/json" -d '{"title":"buy milk"}'
```

```
{"title":"buy milk","done":false,"id":8}
```

```sh
curl -s -X POST http://127.0.0.1:3000/tasks -b grace.txt \
  -H "content-type: application/json" -d '{"title":"call the bank"}'
```

```
{"title":"call the bank","done":false,"id":9}
```

(Seus ids vão ser números diferentes. Eles dependem de quantas tarefas seu
banco de dados já viu.)

Agora Ada pede suas tarefas:

```sh
curl -s http://127.0.0.1:3000/tasks -b ada.txt
```

```
{"tasks":[{"title":"buy milk","done":false,"id":8},{"title":"call the bank","done":false,"id":9}]}
```

**Ela está lendo a tarefa da Grace.** E a Grace consegue ler a da Ada:

```sh
curl -s http://127.0.0.1:3000/tasks -b grace.txt
```

```
{"tasks":[{"title":"buy milk","done":false,"id":8},{"title":"call the bank","done":false,"id":9}]}
```

Nada quebrou. Nada foi registrado em log. As duas requisições (request) estavam
autenticadas, as duas foram respondidas com `200 OK`, e as duas entregaram a
uma pessoa os dados de outra.

Aqui está a linha responsável por isso:

```lua no-run
req.db:many "select id, title, done from tasks order by id"
```

E aqui está a linha que ela deveria ter sido:

```lua no-run
req.db:many("select id, title, done from tasks where user_id = $1 order by id",
            req.auth.user_id)
```

Cinco palavras. Essa é toda a diferença entre uma lista de tarefas funcionando
e um vazamento de dados, e a versão errada se lê perfeitamente bem. Em um
arquivo com vinte consultas, todas parecidas com essa, você não vai conseguir
identificar a única que está sem elas. Nem quem estiver revisando seu código.
É assim que acontece de verdade: não por malícia, mas por causa de uma rota em
duzentas, escrita com pressa, numa quinta-feira.

Então o conserto não é "lembrar do filtro". O conserto é tornar impossível
enviar a consulta que esqueceu dele.

## O handle com escopo

`req.db:scope(coluna, valor)` devolve um handle de banco de dados que carrega
uma condição consigo:

```lua no-run
local mine = req.db:scope("user_id", req.auth.user_id)
```

Toda consulta que passa por `mine` recebe `user_id = <aquela conta>`
adicionado antes de rodar. Não como um lembrete. A instrução sem escopo nunca
chega a ser construída, então não existe um momento em que ela poderia ser
enviada.

Leituras, atualizações, exclusões e inserções, todas passam por ele, o que
importa: uma escrita sem escopo é pior do que uma leitura sem escopo.

### Por que ele recusa SQL puro

Tente passar uma string simples e ele não vai aceitar:

```lua
local db = require "akkar.db"

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  pool_size = 0,
}

local conn = open()
local mine = conn:scope("user_id", 1)

local ok, why = pcall(function()
  return mine:many "select id, title from tasks"
end)

print("did it run?", ok)
print(why)

conn:close()
```

```
did it run?	false
db: this handle is scoped to user_id, so it takes an akkar.sql query rather than raw SQL -- a string cannot be scoped without parsing it. Use db:unscoped() if the query genuinely covers every tenant.
```

O motivo está na mensagem. Para adicionar uma condição a uma instrução, você
precisa entender a instrução, e uma string é só letras. Onde entra o `where`?
Já existe um? Isso é um `select` dentro de um `select`? Responder a isso
significa escrever um parser de SQL dentro do akkar, e um parser de SQL que
discorda do Postgres sobre o que uma consulta significa é pior do que nenhum
escopo, porque estaria errado silenciosamente.

Então o handle com escopo usa o construtor de consultas da [página 6](06-storing-and-reading.md)
e nada além disso. O construtor sabe onde ficam suas próprias condições, então
adicionar uma é exato. Não existe a opção de passar uma string com a promessa
de que você mesmo adicionou o filtro, porque é exatamente nessa opção que o
filtro esquecido se esconde.

### Ele prevalece sobre o que quem chamou enviou

Em uma inserção, o escopo não apenas adiciona a coluna. Ele **sobrescreve** ela:

```lua
local sql = require "akkar.sql"

-- A row that arrived from a caller, with someone else's user_id in it.
local row = { title = "buy milk", user_id = 5 }

local insert = sql.insert_into("tasks", row, { "title", "user_id" })
insert:scope("user_id", 1)

print(insert:to_string())
for _, value in ipairs(insert:values()) do
  print("value: " .. tostring(value))
end
```

```
insert into tasks (title, user_id) values ($1, $2)
value: buy milk
value: 1
```

A linha dizia conta 5. A instrução guarda a conta 1, aquela que detém a
sessão. Quem chama não consegue escrever na conta de outra pessoa colocando um
id no corpo da requisição.

### A válvula de escape, e por que ela é feia de propósito

Algumas consultas realmente cobrem todo mundo: uma contagem noturna, um
relatório administrativo. Para essas existe `req.db:unscoped()`, que devolve o
handle simples.

É um nome longo no ponto de chamada, e essa é a funcionalidade.
`grep -rn ':unscoped()'` te dá a lista completa de toda consulta na sua
aplicação que atravessa entre contas. Uma lista curta que alguém consegue ler
vence uma regra que ninguém consegue verificar.

## A aplicação inteira

Toda rota de tarefas agora passa pelo escopo. Este é o `app.lua`, completo.

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local migrate = require "akkar.migrate"
local crypto  = require "akkar.crypto"
local session = require "akkar.session"
local auth    = require "akkar.auth"
local memory  = require "akkar.cache.memory"
local sql     = require "akkar.sql"
local v       = akkar.v

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  statement_timeout = 30,
}

local conn = open()
local runner = migrate.new(conn, {
  files = {
    { name = "003_tasks_belong_to_accounts.sql", sql = [[
      alter table tasks add column user_id integer references accounts (id);
      delete from tasks where user_id is null;
      alter table tasks alter column user_id set not null
    ]] },
  },
})
for _, name in ipairs(runner:apply()) do print("applied " .. name) end
conn:release()

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
}

local app = akkar.new()

app:use(auth.middleware { sessions = sessions, optional = true })

local function require_login(req, next)
  if not req.auth then
    return akkar.unauthorized "log in first"
  end
  return next(req)
end

app:post("/accounts", {
  body = {
    email    = v.string { min = 3, max = 200, match = "^[^@]+@[^@]+$" },
    password = v.string { min = 8, max = 200 },
  },
}, function(req)
  local hash = crypto.hash_password(req.body.password)
  local account = req.db:one(
    "insert into accounts (email, password_hash) values ($1, $2) " ..
    "on conflict (email) do nothing returning id, email",
    req.body.email, hash)

  if not account then
    return akkar.conflict "that email already has an account"
  end
  return akkar.created(account)
end)

app:post("/login", {
  body = { email = "string", password = "string" },
}, function(req)
  local account = req.db:one(
    "select id, email, password_hash from accounts where email = $1",
    req.body.email)

  if not account or not crypto.verify_password(req.body.password,
                                               account.password_hash) then
    return akkar.unauthorized "wrong email or password"
  end

  auth.login(req, account.id)
  return { logged_in_as = account.email }
end)

app:post("/logout", function(req)
  auth.logout(req)
  return { logged_out = true }
end)

app:get("/tasks", { before = { require_login } }, function(req)
  local mine = req.db:scope("user_id", req.auth.user_id)
  local query = sql.select("id, title, done"):from "tasks"
  query:order_by("id", { "id", "title" })
  return { tasks = akkar.array(mine:many(query)) }
end)

app:get("/tasks/:id", {
  before = { require_login },
  params = { id = "integer" },
}, function(req)
  local mine = req.db:scope("user_id", req.auth.user_id)
  local query = sql.select("id, title, done"):from "tasks"
  query:where("id = ?", req.params.id)
  local task = mine:one(query)
  return task or akkar.not_found "no task with that id"
end)

app:post("/tasks", {
  before = { require_login },
  body   = { title = "string" },
}, function(req)
  local mine = req.db:scope("user_id", req.auth.user_id)
  local insert = sql.insert_into("tasks", { title = req.body.title }, { "title" })
  insert:returning "id, title, done"
  return akkar.created(mine:one(insert))
end)

app:delete("/tasks/:id", {
  before = { require_login },
  params = { id = "integer" },
}, function(req)
  local mine = req.db:scope("user_id", req.auth.user_id)
  local delete = sql.delete_from "tasks"
  delete:where("id = ?", req.params.id)
  if mine:exec(delete).affected_rows == 0 then
    return akkar.not_found "no task with that id"
  end
  return nil
end)

app:run { port = 3000, db = open, cache = memory.factory() }
```

Repare no que os quatro manipuladores (handlers) de tarefas têm em comum. Cada
um começa restringindo o handle, e depois dessa linha não sobra nada para
lembrar. Nenhum handler menciona `user_id` de novo. A inserção não o define e a
exclusão não o verifica, porque o handle faz as duas coisas.

A rota de listagem ainda envolve suas linhas com `akkar.array`, pelo motivo que
a [página 6](06-storing-and-reading.md) explica, e o escopo torna esse motivo
mais nítido, não mais fraco: uma conta sem tarefas ainda é agora um caso
comum e cotidiano, e ela tem que responder `[]` como qualquer outra.

Reiniciar o servidor esvazia o cache de sessões, então faça login com as duas
contas de novo antes de testar isto.

**Ada vê uma tarefa. Grace vê a outra:**

```sh
curl -s http://127.0.0.1:3000/tasks -b ada.txt
```

```
{"tasks":[{"id":8,"done":false,"title":"buy milk"}]}
```

```sh
curl -s http://127.0.0.1:3000/tasks -b grace.txt
```

```
{"tasks":[{"id":9,"done":false,"title":"call the bank"}]}
```

**Ada pede a tarefa da Grace pelo id, que ela consegue adivinhar facilmente:**

```sh
curl -s -i http://127.0.0.1:3000/tasks/9 -b ada.txt
```

```
HTTP/1.1 404 Not Found
x-request-id: 959171d7000009
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

**A dela própria está ali:**

```sh
curl -s http://127.0.0.1:3000/tasks/8 -b ada.txt
```

```
{"id":8,"done":false,"title":"buy milk"}
```

**Ela tenta apagar a da Grace:**

```sh
curl -s -i -X DELETE http://127.0.0.1:3000/tasks/9 -b ada.txt
```

```
HTTP/1.1 404 Not Found
x-request-id: 959171d700000b
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

```sh
curl -s http://127.0.0.1:3000/tasks -b grace.txt
```

```
{"tasks":[{"id":9,"done":false,"title":"call the bank"}]}
```

Continua lá. A exclusão não encontrou nenhuma linha correspondente, porque o
escopo adicionou `user_id = 1` e a tarefa 9 pertence à conta 5.

**E uma tarefa que Ada cria recebe o id dela sem o handler dizer isso:**

```sh
curl -s -X POST http://127.0.0.1:3000/tasks -b ada.txt \
  -H "content-type: application/json" -d '{"title":"read the guide"}'
```

```
{"id":10,"done":false,"title":"read the guide"}
```

```sh
docker exec akkar-pg psql -U postgres -d akkar -c 'select id, title, user_id from tasks order by id'
```

```
 id |     title      | user_id 
----+----------------+---------
  8 | buy milk       |       1
  9 | call the bank  |       5
 10 | read the guide |       1
(3 rows)
```

## Por que `404` e não `403`

Ada pediu a tarefa 9. Ela existe, e não é dela. O akkar respondeu `404 Not
Found`, que é o que "não existe essa tarefa" significa, em vez de `403
Forbidden`, que significa "isso existe e você não pode ter".

`403` é honesto e vaza informação. Ele confirma que a tarefa existe, e fazer
isso para os ids de 1 a 1000 conta a um estranho exatamente quantas tarefas o
seu serviço guarda e quais ids são reais. Para algo que alguém não tem direito
de ver, `404` é a melhor resposta, porque é a resposta que essa pessoa
receberia se a tarefa de fato não existisse.

Use `403` quando quem chama já sabe que a coisa existe e a recusa é o ponto em
questão: um membro tentando alterar uma configuração que só um proprietário
pode alterar.

Repare que nenhum handler escolheu isso. O escopo removeu a linha, `mine:one`
devolveu `nil`, e o caminho comum de "não encontrado" da
[página 4](04-errors.md) fez o resto.

## O que você tem agora

Uma lista de tarefas onde:

- uma pessoa se cadastra, faz login e faz logout
- senhas são guardadas como hashes PBKDF2 e nunca como texto
- uma sessão pode ser revogada no servidor
- toda tarefa pertence a uma conta
- ler, escrever e apagar a tarefa de outra conta não é um erro que você
  consegue cometer em um handler, porque o handle recusa a construir a
  consulta

## Ponto de verificação

Você tem isso se:

- duas contas cada uma vê apenas suas próprias tarefas
- pedir a tarefa de outra conta pelo id retorna `404`
- apagar a tarefa de outra conta retorna `404` e deixa a tarefa intacta
- uma tarefa nova recebe seu dono sem nenhum handler mencionar `user_id`

E você consegue explicar por que `scope` recusa uma string de SQL puro em uma
frase: porque adicionar uma condição a uma string significa fazer o parsing do
SQL, e um parser que discorda do Postgres estaria errado silenciosamente,
então o construtor é a única porta de entrada.

Próximo no guia: conversando com tudo isso a partir de uma página no navegador.
