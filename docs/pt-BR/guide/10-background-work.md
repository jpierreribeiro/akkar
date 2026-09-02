# 10. Trabalho em segundo plano

> **Português (Brasil)** | [Original em inglês](../../guide/10-background-work.md)

Ao final desta página, cadastrar um usuário vai colocar um job "enviar o email de boas-vindas" numa fila e responder para quem chamou imediatamente. Um segundo programa vai pegar esse job e fazer a parte lenta no seu próprio ritmo.

## Por que não simplesmente enviar no handler

Digamos que você adicione o email ao `POST /signup`, logo depois que a linha é inserida. Enviar um email significa chamar o servidor de outra pessoa pela internet, então o handler agora fica assim:

1. escrever a linha da conta, um milissegundo
2. chamar o provedor de email, **de 200 milissegundos a um timeout**
3. responder ao navegador

O passo 2 não é seu. É uma chamada de rede para uma empresa que você não controla, e é ela quem decide quanto tempo seu cadastro vai levar. Três coisas dão errado, e todas as três são comuns:

**A pessoa espera por algo que não interessa a ela.** Ela apertou um botão para criar uma conta. Agora está olhando para um spinner enquanto um servidor de email em algum lugar pensa sobre o assunto.

**Um provedor lento vira um cadastro falho.** Toda requisição (request) tem um prazo. Quando o provedor demora mais que esse prazo, o akkar responde `503` e quem chamou vê um erro, mesmo que a conta tenha sido criada perfeitamente. Agora você tem uma conta cujo dono acredita que o cadastro falhou, e que vai apertar o botão de novo.

**Um provedor quebrado vira um cadastro quebrado.** Se a chamada de email lançar uma exceção, o handler lança também, e quem chamou recebe um `500` para algo que funcionou.

A correção é separar as duas coisas. **A requisição faz a parte pela qual quem chamou está esperando. Tudo o mais vai para uma fila.**

## Uma fila precisa de um lugar para existir

O job tem que sobreviver entre "a requisição o colocou ali" e "outra coisa o pegou", e esses são dois processos diferentes. Uma variável Lua não consegue fazer isso. O akkar guarda filas de jobs no Redis.

Se o Redis ainda não estiver rodando, um comando o inicia. É o mesmo formato do comando do Postgres da página 5:

```sh
docker run -d --name akkar-redis -p 6379:6379 redis:7-alpine
```

Ele imprime um id hexadecimal longo e retorna. Esse id é do container, e você não vai precisar dele. `docker ps` agora deve listar `akkar-redis`.

## A coluna que torna um job seguro para repetir

Antes do código, uma pequena mudança de schema. O motivo dela está na seção sobre "pelo menos uma vez" mais abaixo, e vai fazer mais sentido lá, mas é mais fácil aplicá-la agora do que parar no meio do caminho.

Crie `migrations/004_welcome_email_sent.sql`:

```sql
alter table accounts add column welcome_email_sent_at timestamptz
```

Aplique-a da mesma forma que você aplicou as três primeiras na página 5. Deve reportar um arquivo aplicado. Rode uma segunda vez e deve reportar nenhum, que é a ideia toda de um ledger de migrações.

## Colocando um job na fila

Duas mudanças em `app.lua`. Primeiro, perto do topo, construa a fila:

```lua no-run
local redis = require "akkar.redis"
local jobs  = require "akkar.jobs.redis"

local queue = jobs.new(redis.connect { port = 6379 }(), "email")
```

`"email"` é o nome da fila. Jobs enviados sob um nome só são pegos por workers lendo esse nome, então uma fila de email lenta não consegue travar uma fila rápida.

Repare no `()` extra depois de `redis.connect { ... }`. `redis.connect` devolve uma função que abre conexões, e a fila quer uma conexão, não a função.

Deixe o `()` de fora e nada reclama a princípio. A fila é construída, o servidor inicia, e o erro só aparece no primeiro push:

```
lua5.4: ./akkar/jobs/redis.lua:24: attempt to call a nil value (method 'command')
```

Essa mensagem nomeia um arquivo dentro do akkar, e não a linha no seu código, então parece um bug no framework. Não é. É o `()` faltando, e vale a pena reconhecer isso uma vez para que custe um minuto em vez de uma noite inteira.

Segundo, dentro do handler `/signup`, depois do insert e antes de responder:

```lua no-run
queue:push("welcome_email",
           { account_id = account.id, email = req.body.email },
           { id = "welcome:" .. account.id })
```

Três argumentos, e cada um merece uma frase.

**`"welcome_email"`** é o tipo do job. O worker procura o tipo numa tabela de handlers, então um worker pode atender vários tipos.

**O segundo argumento é o payload**, e é armazenado como JSON. Coloque nele o que o handler precisa e nada mais. Não coloque uma linha do banco de dados nele: quando o job rodar, a linha pode ter mudado, e um id buscado na hora sempre está correto.

**`id` é uma promessa de não enfileirar isso duas vezes.** O armazenamento recusa um segundo push com o mesmo id, e `push` retorna `false, "duplicate"` em vez disso. Dois cliques no botão de cadastro portanto enfileiram um email, não dois. Note que isso só protege o lado do *push*. Não impede que um job enfileirado uma vez *rode* duas vezes, que é o assunto da seção seguinte.

## Tirando um job da fila

O worker é um programa separado. Coloque isto em `worker.lua`, ao lado de `app.lua`:

```lua server
local cqueues = require "cqueues"
local db      = require "akkar.db"
local redis   = require "akkar.redis"
local jobs    = require "akkar.jobs.redis"
local logging = require "akkar.log"

local log = logging.new()

local connect = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
}

local queue = jobs.new(redis.connect { port = 6379 }(), "email")

local handlers = {
  welcome_email = function(payload)
    local conn = connect()
    local first = conn:one([[
      update accounts
         set welcome_email_sent_at = now()
       where id = $1
         and welcome_email_sent_at is null
      returning id ]], payload.account_id)
    conn:release()

    if not first then
      log:info("this welcome email was already sent, doing nothing",
               { account_id = payload.account_id })
      return
    end

    cqueues.sleep(3)
    log:info("welcome email sent", { to = payload.email })
  end,
}

log:info("worker waiting for jobs")
queue:consume(handlers, { log = log, timeout = 1 })
```

`cqueues.sleep(3)` faz o papel do provedor de email de verdade. Substitua pela chamada ao serviço que você usar. São três segundos para que o ponto desta página fique visível na saída abaixo.

`queue:consume` é um loop que não termina. Ele espera um job, chama o handler cujo nome bate com o tipo do job, e espera de novo. Assim como o servidor, ele continua rodando até você pará-lo com `Ctrl-C`.

## Observando funcionar

Agora você tem três coisas para rodar. Dê um terminal para cada uma:

```sh
lua5.4 app.lua
```

```sh
lua5.4 worker.lua
```

```
INFO  worker waiting for jobs
```

E um terminal para o `curl`:

```sh
time curl -s -i -X POST http://127.0.0.1:3000/signup \
  -H "content-type: application/json" \
  -d '{"email":"noether@example.com","password":"correct horse battery"}'
```

```
HTTP/1.1 201 Created
access-control-allow-origin: http://127.0.0.1:5173
set-cookie: akkar_session=d621d5985219d60fb67a9e8cb0c81ac7c9be544a13d2c626dc259743d2ee72da.ad449163adb6b63484c8aac280c1c093a97eac1624e6379f65708cf35a5f072c; Path=/; Max-Age=1209600; HttpOnly; SameSite=Lax
access-control-allow-credentials: true
x-request-id: d34903c6000001
content-type: application/json
content-length: 39

{"id":13,"email":"noether@example.com"}

real	0m0,777s
```

Menos de um segundo, e a maior parte desse segundo é o hash da senha, não o email.

Olhe o terminal do worker:

```
INFO  worker waiting for jobs
INFO  welcome email sent to=noether@example.com
```

Essa linha apareceu cerca de três segundos depois que o `curl` terminou. **Quem chamou nunca esperou por isso.** Essa é a funcionalidade inteira.

## Se ninguém está ouvindo, o job espera

Pare o worker com `Ctrl-C` e cadastre outra pessoa. O cadastro ainda responde `201`. O job fica no Redis até um worker voltar, o que pode ser depois do seu próximo deploy.

Esse é o comportamento correto, e vale a pena saber em vez de descobrir na prática: uma fila sem worker parece exatamente uma fila funcionando, do ponto de vista de quem chamou. Se emails de boas-vindas pararem de chegar, verifique se o processo worker está rodando antes de olhar qualquer outra coisa.

## Pelo menos uma vez, o que significa que um job pode rodar duas vezes

Esta é a parte para ler devagar, porque ela decide o que você pode colocar num handler.

A fila do akkar promete entrega **pelo menos uma vez** (at-least-once) quando o armazenamento oferece suporte a isso, e o Redis oferece. Eis o que isso significa na prática.

Quando um worker pega um job, o job não é apagado. Ele se move para uma lista "sendo trabalhado", e só é removido quando o handler terminar. Se o worker for morto no meio do caminho, o job ainda está sentado naquela lista em vez de ter sumido.

Um worker segura um job por `visibility` segundos, cinco minutos por padrão, e quando esse tempo se esgota o job volta para a fila para outra pessoa. **O worker que o devolve é apenas outro worker fazendo pop da mesma fila**, então não há um processo faxineiro para lembrar de implantar: o loop que você já tem recupera os jobs abandonados da frota enquanto trabalha.

O único número que você precisa escolher é `visibility`, e só você pode, porque só você sabe quanto tempo um handler seu pode legitimamente levar:

```lua no-run
local queue = jobs.new(redis.connect { port = 6379 }(), "email", {
  visibility = 300,      -- segundos que um worker pode segurar um job
})
```

Defina abaixo do seu handler mais lento e você vai entregar um job ainda ativo a um segundo worker enquanto o primeiro ainda está trabalhando nele, fazendo o mesmo job rodar duas vezes ao mesmo tempo, que é a falha que esse número existe para tornar rara em vez de impossível.

O design alternativo seria apagar o job no momento em que ele é entregue. Aí um worker que morre perde o job silenciosamente e para sempre, e ninguém fica sabendo.

**Então a troca é deliberada: um job que roda duas vezes é melhor que um job que desaparece.** Um é visível e corrigível. O outro é invisível.

O preço dessa escolha é seu. **Escreva cada handler de forma que rodá-lo duas vezes não cause dano.**

## Tornando o handler seguro para rodar duas vezes

Olhe de novo a primeira coisa que o handler faz:

```lua no-run
local first = conn:one([[
  update accounts
     set welcome_email_sent_at = now()
   where id = $1
     and welcome_email_sent_at is null
  returning id ]], payload.account_id)

if not first then
  return
end
```

O `update` define a coluna **somente se ela ainda estiver vazia**, e `returning id` nos diz se alguma linha mudou. Então:

- a primeira execução encontra uma coluna vazia, a toma para si e envia o email;
- qualquer execução posterior encontra um horário já preenchido nela, não muda nenhuma linha, recebe `nil` de volta, e não faz nada.

O banco de dados decide, numa única instrução, qual execução é a primeira. É isso que torna seguro: dois workers rodando o mesmo job no mesmo instante não podem os dois vencer, porque um único `update` é atômico.

Você pode ver isso acontecer. Pare o worker. Cadastre alguém, o que enfileira um job. Em seguida, enfileire o mesmo job uma segunda vez à mão, com isto em `twice.lua`:

```lua
local redis = require "akkar.redis"
local jobs  = require "akkar.jobs.redis"

local queue = jobs.new(redis.connect { port = 6379 }(), "email")

queue:push("welcome_email", { account_id = 14, email = "lamarr@example.com" })

print("jobs waiting: " .. queue:depth())
```

Use o id e o email que seu cadastro realmente retornou.

```sh
lua5.4 twice.lua
```

```
jobs waiting: 2
```

Agora inicie o worker de novo:

```sh
lua5.4 worker.lua
```

```
INFO  worker waiting for jobs
INFO  welcome email sent to=lamarr@example.com
INFO  this welcome email was already sent, doing nothing account_id=14
```

Dois jobs, um email. É assim que "seguro para rodar duas vezes" se parece, e são cinco linhas de SQL, não uma funcionalidade do framework.

**A forma geral.** Antes de fazer a coisa que não pode ser desfeita, reivindique-a no banco de dados de um jeito que só uma tentativa possa vencer. Uma coluna como essa, um índice único numa tabela "já fizemos isso", ou uma chave de idempotência que o próprio serviço externo entenda. Qual delas depende do que você está chamando.

**Quando não há coluna para reivindicar, reivindique o job.** Todo job carrega um `uid`, cunhado quando foi enviado e inalterado por toda retentativa e toda reentrega daquele job, então é a mesma string na segunda execução que na primeira, e é a chave sob a qual escrever aquela linha "já fizemos isso":

```lua no-run
local handlers = {
  charge = function(payload, job)
    local first = conn:one([[
      insert into processed_jobs (uid) values ($1)
      on conflict do nothing
      returning uid ]], job.uid)

    if not first then return end         -- alguma outra execução chegou primeiro
    charge_the_card(payload)
  end,
}
```

Repare no segundo argumento: `consume` chama um handler com `(payload, job)`, e `job.uid` está no segundo. Não recorra a `job.id`, esse é opcional, fornecido por quem enviou, e impede um PUSH duplicado em vez de uma EXECUÇÃO duplicada. E não recorra a `job.attempts`: ele muda a cada vez.

Escreva o marcador na mesma transação que o efeito colateral, ou você apenas moveu a corrida em vez de fechá-la.

## Duas outras coisas que a fila oferece

Você ainda não precisa delas. Estão aqui para você saber onde procurar.

**Retentativas.** Um handler que lança uma exceção é descartado por padrão. Peça retentativas e um job que falhou é recolocado mais tarde, esperando cada vez mais:

```lua no-run
local queue = jobs.new(redis.connect { port = 6379 }(), "email", {
  retries = 3,
  backoff = { base = 2, max = 300 },
  dead_letter = true,
})
```

As retentativas ficam desligadas a menos que você as peça, de propósito. Uma política de retentativa que ninguém escolheu repete o que quer que o handler já tenha feito, e só você sabe se isso é seguro.

**Dead letters.** Com `dead_letter = true`, um job que esgotou suas retentativas é mantido numa lista separada em vez de desaparecer. `queue:dead_depth()` os conta. Um número que está crescendo é algo a se observar.

## A aplicação inteira

`app.lua`:

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local redis   = require "akkar.redis"
local jobs    = require "akkar.jobs.redis"
local memory  = require "akkar.cache.memory"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local sql     = require "akkar.sql"
local crypto  = require "akkar.crypto"

local app = akkar.new()

local queue = jobs.new(redis.connect { port = 6379 }(), "email")

app:use(akkar.cors {
  origin = "http://127.0.0.1:5173",
  credentials = true,
})

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
  secure = false,
}

app:use(auth.middleware { sessions = sessions, optional = true })

local function signed_in(req)
  if not req.auth then
    error(akkar.unauthorized "please log in")
  end
  return req.auth.user_id
end

app:post("/signup", { body = { email = "string", password = "string" } },
function(req)
  local taken = req.db:one("select id from accounts where email = $1",
                           req.body.email)
  if taken then
    return akkar.conflict "that email already has an account"
  end

  local account = req.db:one(
    "insert into accounts (email, password_hash) values ($1, $2) returning id",
    req.body.email, crypto.hash_password(req.body.password))

  queue:push("welcome_email",
             { account_id = account.id, email = req.body.email },
             { id = "welcome:" .. account.id })

  auth.login(req, account.id)
  return akkar.created { id = account.id, email = req.body.email }
end)

app:post("/login", { body = { email = "string", password = "string" } },
function(req)
  local account = req.db:one(
    "select id, password_hash from accounts where email = $1", req.body.email)
  if not account
     or not crypto.verify_password(req.body.password, account.password_hash) then
    return akkar.unauthorized "wrong email or password"
  end
  auth.login(req, account.id)
  return { id = account.id, email = req.body.email }
end)

app:post("/logout", function(req)
  auth.logout(req)
  return akkar.no_content()
end)

app:get("/tasks", function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  local rows = mine:many(sql.select("id, title, done"):from "tasks")
  return { tasks = akkar.array(rows) }
end)

app:post("/tasks", { body = { title = "string" } }, function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  return akkar.created(mine:one(
    sql.insert_into("tasks", { title = req.body.title }, { "title" })
       :returning "id, title, done"))
end)

app:run {
  port = 3000,
  db = db.connect {
    host = "127.0.0.1", port = 55432, database = "akkar",
    user = "postgres", password = "akkar",
  },
  cache = memory.new(),
}
```

`worker.lua` é o arquivo de mais cedo nesta página, sem alterações.

## Checkpoint

Você conseguiu se:

- o cadastro responde em bem menos de um segundo enquanto o worker leva três
- parar o worker não impede o cadastro de funcionar
- você consegue dizer por que um job pode rodar duas vezes, e apontar a linha no seu handler que torna isso inofensivo
- `queue:depth()` conta o que está esperando

A seguir no guia: o que o seu servidor faz quando as coisas dão errado em escala.
