# 11. Fazendo o servidor não cair

> **Português (Brasil)** | [Original em inglês](../../guide/11-not-falling-over.md)

Ao final desta página, seu servidor vai recusar trabalho que não consegue fazer em vez de aceitá-lo e ficar mais lento, e vai conseguir dizer a um host a diferença entre "me reinicie" e "não me mande tráfego ainda".

Três ideias, uma tela cada. Elas são independentes, então leia na ordem que preferir.

## 1. Prazos, e a metade que você não controla

Toda requisição (request) que o akkar trata tem um prazo. Ele é de 30 segundos por padrão, e você viu isso na página 4: um handler que demora demais recebe `503` e quem chamou recebe uma resposta em vez de uma conexão pendurada.

Aqui está a parte que a página 4 não disse. **O prazo faz o akkar parar de esperar. Ele não faz o Postgres parar de trabalhar.**

Quando o prazo estoura, o akkar desiste do handler e responde. A query que aquele handler estava executando continua rodando, numa conexão do banco de dados, dentro do Postgres. O Postgres só percebe que ninguém está mais ouvindo na próxima vez que tentar escrever algo de volta, e uma query que não produz saída até terminar pode não tentar por minutos.

Então sob carga, um timeout pode deixar seu banco de dados **mais ocupado** do que nenhum timeout. Requisições desistem, quem chamou tenta de novo, cada nova tentativa inicia outra query, e as abandonadas continuam em andamento.

O akkar avisa sobre isso na inicialização. Você provavelmente vem vendo isso desde a página 5:

```
WARN  db has no statement_timeout, so a request deadline does not stop the query consequence=an abandoned query keeps a backend busy after the 503 fix=db.connect { statement_timeout = <seconds> }, matching the deadline request_deadline_s=30
```

Leia isso em três partes: o que está faltando, o que dá errado por causa disso, e a linha exata que resolve.

A correção é dar ao Postgres seu próprio prazo, e fazer os dois números concordarem:

```lua no-run
local connect = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}
```

```lua no-run
app:run {
  port = 3000,
  timeout = 5,
  db = connect,
}
```

Agora os dois lados desistem no mesmo momento. O akkar para de esperar, e o Postgres cancela a query em vez de terminar um trabalho que ninguém vai ler.

Reinicie, e o aviso desaparece.

Por que cinco e não trinta? Porque um número em que você nunca pensa é um número que está errado. Escolha a coisa mais lenta que uma requisição sua legitimamente faz, adicione uma margem, e use esse valor. Cinco segundos é generoso para uma lista de tarefas.

Um aviso sobre o executor de migrações: passe a ele uma conexão **sem** `statement_timeout`. Uma migração longa deve mesmo demorar, e essa configuração a cancelaria no meio do caminho. A página 12 abre uma conexão separada exatamente por esse motivo.

## 2. Limites de taxa, ou recusar rápido em vez de aceitar devagar

Um servidor além da sua capacidade não fica mais rápido aceitando mais trabalho. Ele fica mais lento no trabalho que já assumiu. As próprias medições do akkar são diretas sobre isso: dobrar o número de clientes contra um pool de banco de dados fixo mudou o throughput quase nada e deixou o um por cento mais lento das requisições sessenta vezes mais lento.

Então a resposta honesta para mais carga do que você consegue atender é dizer não imediatamente.

```lua no-run
local limiter = akkar.limit.rate { per_second = 5, burst = 10 }
```

Dois números, e eles formam um par. Pense num balde com `burst` tokens. Cada requisição consome um. O balde se reabastece a `per_second` tokens por segundo. Então quem chama pode fazer uma sequência curta de 10 requisições, e depois disso recebe 5 por segundo pelo tempo que quiser.

Instale como middleware e ele se aplica a tudo:

```lua no-run
app:use(limiter)
```

Envie onze requisições rapidamente e a décima primeira é recusada:

```sh
curl -s -i http://127.0.0.1:3000/tasks
```

```
HTTP/1.1 429 Too Many Requests
access-control-allow-credentials: true
access-control-allow-origin: http://127.0.0.1:5173
ratelimit-reset: 2
ratelimit-limit: 10
retry-after: 1
ratelimit-remaining: 0
x-request-id: 35e8f1a2000026
content-type: application/json
content-length: 45

{"error":"too many requests","retry_after":1}
```

`429` significa "requisições demais". Os quatro cabeçalhos não são decoração:

| cabeçalho | significa |
|---|---|
| `ratelimit-limit` | o tamanho do balde |
| `ratelimit-remaining` | tokens restantes após esta requisição |
| `ratelimit-reset` | segundos até o balde encher de novo |
| `retry-after` | espere esse tempo antes de tentar de novo |

Eles são enviados em requisições bem-sucedidas também, então um cliente bem-comportado pode se autolimitar antes de ser recusado. Um limite que um cliente não consegue ver é um limite que ele só descobre tropeçando nele.

**Quem é contado.** Por padrão o balde é por usuário autenticado, e por endereço IP quando não há usuário. Nunca por caminho (path), porque quem é limitado por caminho pode simplesmente ir passando pelos seus caminhos um por um.

### A armadilha: você acabou de limitar a taxa dos seus próprios health checks

Deixe o limitador como `app:use(limiter)` e envie doze requisições ao endpoint de liveness, que é o que um host faz numa programação regular:

```sh
for i in $(seq 1 12); do
  curl -s -o /dev/null -w "%{http_code} " http://127.0.0.1:3000/health/live
done
```

```
200 200 200 200 200 200 200 200 200 200 429 429
```

Leia o que isso significa. Seu host pergunta "você está vivo?", seu servidor responde "requisições demais", e o host interpreta um código diferente de 200 como falha. Um limitador de taxa instalado para manter o serviço no ar acabou de dizer ao orquestrador para reiniciá-lo.

Isente as sondagens (probes). Middleware é uma função comum, então isso são quatro linhas:

```lua no-run
app:use(function(req, next)
  if req.path:find("/health/", 1, true) == 1 then
    return next(req)
  end
  return limiter(req, next)
end)
```

`req.path:find("/health/", 1, true) == 1` significa "o caminho começa com `/health/`". O `true` desliga o casamento de padrões, então o texto é comparado literalmente.

As mesmas doze requisições:

```
200 200 200 200 200 200 200 200 200 200 200 200
```

E uma rota de verdade ainda recusa, que é o objetivo:

```sh
for i in $(seq 1 12); do
  curl -s -o /dev/null -w "%{http_code} " -X POST http://127.0.0.1:3000/login \
    -H "content-type: application/json" \
    -d '{"email":"nobody@example.com","password":"wrong"}'
done
```

```
401 401 401 401 401 401 401 401 401 401 429 429
```

### O limitador precisa de um lugar compartilhado para contar

A contagem acontece em `req.cache`. Qual cache você passou para `app:run` decide se você tem um limite de verdade:

- **`akkar.cache.memory`** conta dentro de um processo só. Rode quatro processos e sua frota permite quatro vezes o que você configurou. Isso é um bom padrão enquanto você está aprendendo, e não é limite de taxa.
- **Redis** conta num único lugar que todo processo compartilha. Isso é um limite de verdade.

Você já iniciou o Redis na página 10 para a fila de jobs, então trocar significa mudar a linha `cache` de `app:run` e nada mais:

```lua no-run
app:run {
  port = 3000,
  timeout = 5,
  db = connect,
  cache = redis.connect { port = 6379 },
}
```

Isso tem um segundo efeito que você vai gostar: sessões vivem em `req.cache` também, então agora elas sobrevivem a um reinício do servidor. Desde a página 7, todo reinício deslogava todo mundo. Isso para agora.

## 3. Liveness e readiness, que não são a mesma pergunta

Um host faz duas perguntas ao seu processo, e confundi-las causa quedas de serviço (outages).

**Liveness: esse processo ainda está funcionando?** Se a resposta é não, o host **mata e reinicia** o contêiner (container).

**Readiness: esse processo deveria receber tráfego agora?** Se a resposta é não, o host **para de rotear** para ele e o deixa em paz.

Perguntas diferentes, consequências diferentes, então dois endpoints:

```lua no-run
local probe = health.new {
  checks = {
    db = function()
      local conn = connect()
      local answer = conn:one "select 1 as ok"
      conn:release()
      return answer ~= nil
    end,
  },
  timeout = 2,
  cache   = 5,
}

app:get("/health/live", function()
  return probe:live()
end)

app:get("/health/ready", function()
  local result = probe:ready()
  if result.status == "fail" then
    error(akkar.unavailable(result))
  end
  return result
end)
```

Uma checagem retorna `true` para passar, ou `false` mais um motivo para falhar. `timeout` é quanto tempo uma checagem pode levar. `cache` é por quanto tempo um resultado é reaproveitado: um endpoint de readiness consultado uma vez por segundo por vinte instâncias não pode transformar um banco de dados com dificuldades num banco de dados espancado, então a resposta é lembrada por cinco segundos, falhas incluídas.

Ambos funcionam enquanto está tudo bem:

```sh
curl -s http://127.0.0.1:3000/health/live
```

```
{"status":"pass","uptime":9.7806364339995,"checks":{}}
```

```sh
curl -s http://127.0.0.1:3000/health/ready
```

```
{"status":"pass","uptime":9.7931252540002,"cached":false,"checks":{"db":{"status":"pass","took_ms":1}}}
```

Repare em `"checks":{}` na resposta de liveness. Ela não rodou nada, e essa é a próxima seção.

### Por que liveness não deve tocar o banco de dados

**`live()` não checa nada.** Não abre conexão, não roda query, e não chama nenhuma das funções na sua tabela `checks`. Ela responde a partir de dois números que a sonda guarda desde que foi criada.

Isso soa preguiçoso. É a linha mais importante desta página, então aqui está o raciocínio completo.

Suponha que sua sonda de liveness rodasse `select 1`. Agora seu banco de dados fica lento. Não fora do ar, só lento, do jeito que um banco de dados fica quando uma query está sem um índice.

1. A sonda de liveness de cada instância expira o tempo, **no mesmo momento**, porque todas dependem do mesmo banco de dados.
2. O host interpreta isso como "esses processos estão quebrados" e reinicia **todos de uma vez**.
3. Cada instância reiniciando abre conexões novas com o banco de dados que já estava com dificuldades.
4. Nada está servindo tráfego. As instâncias que poderiam ter respondido a partir de cache, ou servido rotas que nunca tocam o banco de dados, foram mortas também.

**Uma dependência lenta virou uma frota sem nada rodando nela, e os reinícios pioraram a dependência.** Reiniciar um processo não conserta um banco de dados lento, e fazer isso com todo processo ao mesmo tempo é como um problema pequeno vira uma queda de serviço.

Readiness é o lugar de uma dependência. Uma checagem de readiness que falha tira uma instância do balanceador de carga e deixa o processo vivo, para que ele possa voltar assim que o banco de dados voltar, sem um reinício.

Também não há nada útil que liveness pudesse checar. Um processo cujo laço de eventos (event loop) parou não consegue responder à sonda de jeito nenhum: a conexão fica pendurada e a sonda expira. Esse é o sinal. Qualquer coisa mais engenhosa é uma checagem se fazendo passar por prova.

### Como fica quando o banco de dados está fora do ar

Você pode ver isso sem quebrar nada de verdade. Mude duas linhas em `app.lua`: aponte o banco de dados para uma porta sem nada nela, e deixe o app iniciar mesmo assim.

```lua no-run
local connect = db.connect {
  host = "127.0.0.1", port = 55499, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}
```

```lua no-run
app:run {
  port = 3000,
  timeout = 5,
  check_capabilities = false,
  db = connect,
  cache = redis.connect { port = 6379 },
}
```

`check_capabilities = false` é o que permite o processo iniciar com uma dependência que não está respondendo. Sem isso, o akkar se recusa a inicializar, o que é o padrão correto: num dia comum um banco de dados ausente é um erro na sua configuração, e falhar ruidosamente na inicialização é melhor do que descobrir isso na primeira requisição. Desligar isso é como você obtém um processo que sobe degradado e ainda consegue dizer isso.

Liveness, sem banco de dados nenhum:

```sh
curl -s -i http://127.0.0.1:3000/health/live
```

```
HTTP/1.1 200 OK
access-control-allow-credentials: true
access-control-allow-origin: http://127.0.0.1:5173
x-request-id: db2ef11b000001
content-type: application/json
content-length: 54

{"checks":{},"status":"pass","uptime":8.5785176360005}
```

Readiness, mesmo servidor, mesmo momento:

```sh
curl -s -i http://127.0.0.1:3000/health/ready
```

```
HTTP/1.1 503 Service Unavailable
access-control-allow-credentials: true
access-control-allow-origin: http://127.0.0.1:5173
x-request-id: db2ef11b000002
content-type: application/json
content-length: 307

{"error":{"uptime":8.5937886770043,"checks":{"db":{"took_ms":1,"status":"fail","reason":"db: could not connect to 127.0.0.1:55499 (database \"akkar\", user \"postgres\") -- \/home\/jp\/.luarocks\/share\/lua\/5.4\/pgmoon\/cqueues.lua:18: socket:connect: Connection refused"}},"status":"fail","cached":false}}
```

`200` e `503`, de um processo só, no mesmo instante, e ambos estão corretos. O processo está bem, então não o reinicie. O banco de dados dele não está, então não mande tráfego para ele. O `reason` nomeia a checagem que falhou, que é o que você quer às 3 da manhã, e o caminho nele vai parecer diferente na sua máquina.

Devolva a porta para `55432` e remova `check_capabilities = false` antes de seguir em frente.

**Quando você implantar, aponte a política de reinício do host para `/health/live` e o roteamento de tráfego dele para `/health/ready`.** Nunca o contrário. A página 12 faz isso por você.

## A aplicação completa

`app.lua`, com tudo desta página nele. `worker.lua` da página 10 está inalterado.

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local redis   = require "akkar.redis"
local jobs    = require "akkar.jobs.redis"
local health  = require "akkar.health"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local sql     = require "akkar.sql"
local crypto  = require "akkar.crypto"

local app = akkar.new()

local connect = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}

local queue = jobs.new(redis.connect { port = 6379 }(), "email")

local probe = health.new {
  checks = {
    db = function()
      local conn = connect()
      local answer = conn:one "select 1 as ok"
      conn:release()
      return answer ~= nil
    end,
  },
  timeout = 2,
  cache   = 5,
}

app:get("/health/live", function()
  return probe:live()
end)

app:get("/health/ready", function()
  local result = probe:ready()
  if result.status == "fail" then
    error(akkar.unavailable(result))
  end
  return result
end)

app:use(akkar.cors {
  origin = "http://127.0.0.1:5173",
  credentials = true,
})

local limiter = akkar.limit.rate { per_second = 5, burst = 10 }

app:use(function(req, next)
  if req.path:find("/health/", 1, true) == 1 then
    return next(req)
  end
  return limiter(req, next)
end)

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

app:handle_signals()

app:run {
  port = 3000,
  timeout = 5,
  db = connect,
  cache = redis.connect { port = 6379 },
}
```

Duas linhas perto do final ainda não foram explicadas.

**`app:handle_signals()`** faz `Ctrl-C` e uma parada de contêiner terminarem as requisições já em andamento antes do processo encerrar, em vez de cortá-las abruptamente. O akkar não instala manipuladores de sinal por conta própria, porque uma biblioteca que faz isso pelas suas costas entra em conflito com o que mais seu processo estiver fazendo. Num contêiner isso não é opcional, e a página 12 explica por quê.

**`timeout = 5`** é o prazo de requisição da primeira seção, agora coincidindo com o `statement_timeout` da conexão.

## Checkpoint

Você conseguiu isso se:

- o aviso de `statement_timeout` sumiu da sua saída de inicialização
- doze requisições rápidas a `/tasks` terminam em `429`, e doze a
  `/health/live` não
- `/health/live` e `/health/ready` respondem `200` neste exato momento
- você consegue dizer, numa frase, o que acontece a uma frota cuja sonda de liveness consulta o banco de dados quando esse banco de dados fica lento

A seguir no guia: colocando tudo isso em algum lugar além do seu laptop.
