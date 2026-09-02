# 12. Colocando no ar

> **Português (Brasil)** | [Original em inglês](../../guide/12-deploying.md)

Ao final desta página, sua lista de tarefas será uma imagem de contêiner de
6.58 MB que executa suas próprias migrações quando inicia, lê todos os
segredos do ambiente e para de forma limpa quando o host solicita.

Esta é a última página da trilha para iniciantes. Ela é mais longa que as
outras porque implantar é o momento em que cinco coisas separadas precisam
estar certas ao mesmo tempo.

## O que é uma implantação aqui

`akkar build` lê sua aplicação, descobre todo módulo Lua e todo módulo nativo
que ela precisa, e liga tudo isso em **um único executável**. Não uma pasta de
arquivos. Um arquivo.

Esse arquivo não precisa de Lua na máquina de destino, nem de LuaRocks, nem de
OpenSSL, nem de uma biblioteca C correspondente. Então a imagem em que ele é
embarcado pode ser `scratch`, o que significa uma imagem que não contém
absolutamente nada.

Você não vai executar `akkar build` manualmente. O `Dockerfile` no repositório
do akkar executa isso para você, e acertar seus vinte argumentos é exatamente
o trabalho que você não quer repetir.

## Dois arquivos que você já tem

Você está trabalhando dentro da pasta do akkar desde a página 0, então os dois
arquivos abaixo já estão ao lado do seu `app.lua`.

**`Dockerfile`** constrói a imagem. Ele tem dois alvos úteis:

| alvo | contém | tamanho |
|---|---|---|
| padrão | seu binário e um pacote de CAs | 6.58 MB para esta aplicação |
| `slim` | o mesmo binário, mais o busybox | cerca de 8 MB a mais |

Os tamanhos variam um pouco conforme o que sua aplicação incorpora.
`docs/DEPLOY.md` mediu 6.4 MB para um exemplo menor e 14.5 MB para sua versão
`slim`.

O padrão não tem shell nenhum. Isso é um recurso na maioria dos dias e uma
armadilha em um dia específico, que tem sua própria seção mais abaixo.

**`railway.json`** descreve a implantação para o Railway. Outros hosts usam
seus próprios arquivos, e as três configurações abaixo se aplicam a todos
eles:

```json
{
  "$schema": "https://railway.com/railway.schema.json",
  "build":  { "builder": "DOCKERFILE", "dockerfilePath": "Dockerfile" },
  "deploy": {
    "healthcheckPath": "/health/ready",
    "healthcheckTimeout": 30,
    "restartPolicyType": "ON_FAILURE",
    "restartPolicyMaxRetries": 10,
    "drainingSeconds": 15,
    "overlapSeconds": 15
  }
}
```

`healthcheckPath` é `/health/ready`, e não `/health/live`, pelo motivo que a
página 11 dedicou uma seção inteira a explicar. O host está perguntando "posso
enviar tráfego para essa nova implantação agora?", que é uma pergunta de
prontidão. Apontar isso para o endpoint de vivacidade encaminharia usuários
reais para uma instância cuja conexão com o banco de dados ainda não está
aberta.

`drainingSeconds` é o parâmetro que ninguém acerta de primeira. O Railway
envia `SIGTERM` e, por padrão, dá **zero segundos** ao processo antes de
matá-lo. Seu `shutdown_grace = 10` não vale nada contra um orçamento de zero
segundos, então é preciso avisar o host para esperar. Os dois números formam
um par, e o do host precisa ser o maior.

## Nada que seja segredo vai no arquivo

Até agora, `app.lua` teve uma senha de banco de dados escrita nele, e um
segredo de sessão com um valor padrão de reserva. Nenhum dos dois sobrevive a
uma implantação.

- Uma senha em um arquivo é uma senha no seu histórico do git, para sempre,
  inclusive depois que você a troca.
- Um segredo de sessão que muda a cada reinício desloga todo mundo a cada
  implantação.
- A origem do frontend é diferente em produção, e não é um segredo, mas ainda
  assim é configuração.

Tudo isso vai para o ambiente, e a aplicação lê no momento da inicialização:

```lua no-run
local function required(name)
  local value = os.getenv(name)
  if value == nil or value == "" then
    error("this app needs the environment variable " .. name ..
          " and it is not set", 0)
  end
  return value
end
```

**Repare no que ela não faz: não existe valor padrão.** Um segredo ausente
para o processo imediatamente, com o nome do que está faltando:

```
lua5.4: this app needs the environment variable SESSION_SECRET and it is not set
```

Essa é uma manhã melhor do que um servidor que inicia, atende por seis horas,
e então entrega a alguém uma sessão assinada com uma chave vazia.

Leia todos eles logo no início, antes de a aplicação abrir qualquer coisa:

```lua no-run
local SESSION_SECRET  = required "SESSION_SECRET"
local FRONTEND_ORIGIN = required "FRONTEND_ORIGIN"

local settings = {
  host     = required "PGHOST",
  port     = tonumber(os.getenv "PGPORT") or 5432,
  database = required "PGDATABASE",
  user     = required "PGUSER",
  password = required "PGPASSWORD",
}
```

Os nomes `PG*` não são inventados. São os que as ferramentas do Postgres usam
há décadas, e são o que um banco de dados gerenciado no Railway, Render ou Fly
fornece quando você anexa um.

`PGPORT` tem um valor padrão porque 5432 é o padrão da indústria e não é um
segredo. Nada mais tem.

**Gere o segredo de sessão uma vez e guarde-o.** Qualquer 32 bytes aleatórios
servem:

```sh
lua5.4 -e 'print(require("akkar.crypto").token(32))'
```

Configure como uma variável de ambiente no seu host, seja qual for a tela de
"variáveis" ou "segredos" que ele oferece. Não coloque no repositório.

## O host escolhe a porta, e o host não é localhost

Duas linhas em `app:run` mudam, e ambas são a diferença entre uma implantação
que responde e uma que não responde:

```lua no-run
app:run {
  host = os.getenv "HOST" or "0.0.0.0",
  port = tonumber(os.getenv "PORT") or 8080,
  timeout = 5,
  shutdown_grace = 10,
  db = connect,
  cache = redis.connect {
    host = os.getenv "REDIS_HOST" or "127.0.0.1",
    port = tonumber(os.getenv "REDIS_PORT") or 6379,
  },
}
```

**`0.0.0.0`, não `127.0.0.1`.** O akkar usa `127.0.0.1` como padrão, o que é
correto em um laptop e invisível dentro de um contêiner. O proxy na frente do
seu contêiner se conecta de fora do loopback do próprio contêiner, então um
servidor vinculado ao loopback não aceita nada e a plataforma reporta que sua
aplicação falhou ao responder. Todo o resto da implantação pode estar perfeito
e essa única palavra ainda assim quebra tudo.

**`PORT` vem do host.** Leia-o em vez de fixar um número. 8080 é, por acaso,
tanto o padrão do akkar quanto o que vários hosts injetam, o que é exatamente
por isso que fixar o valor é perigoso: funciona até o dia em que não funciona
mais.

## Migrações, e a armadilha que já tem um histórico escrito

Seu banco de dados do outro lado começa vazio. Alguma coisa precisa criar as
tabelas, e isso precisa acontecer a cada implantação, antes que o código novo
atenda uma requisição (request).

A abordagem óbvia é embarcar a pasta `migrations/` e deixar o `akkar.migrate`
lê-la. **A partir desta imagem, isso não funciona.** Alguém já passou por isso
antes de você e registrou em `docs/DEPLOY.md`, com o diretório montado e
legível:

```
akkar.migrate: could not list /migrations:
find "/migrations" -maxdepth 1 -type f -name '*.sql': No such file or directory
```

Leia isso com atenção. Diz "No such file or directory" sobre um diretório que
estava lá o tempo todo. O arquivo que falta não é o `/migrations`. É o
**`/bin/sh`**.

`akkar.migrate` lista um diretório executando `find`, porque o Lua não tem
como listar um diretório, e adicionar uma biblioteca C só para isso custaria
mais do que economiza. Executar `find` precisa de um shell. Esta imagem não
tem shell. Comprove na sua própria máquina assim que a imagem estiver
construída:

```sh
docker exec tasklist-api /bin/sh -c 'echo hi'
```

```
OCI runtime exec failed: exec failed: unable to start container process: exec: "/bin/sh": stat /bin/sh: no such file or directory: unknown
```

Então as migrações viajam como **dados**, em vez de como arquivos.
`migrate.new` recebe uma lista de pares `{ name, sql }`, e essa lista é
embutida no binário junto com tudo o mais:

```lua no-run
local MIGRATIONS = {
  { name = "001_create_tasks.sql", sql = [[
    create table tasks (
      id    serial primary key,
      title text    not null,
      done  boolean not null default false
    ) ]] },

  { name = "002_create_accounts.sql", sql = [[
    create table accounts (
      id            serial primary key,
      email         text not null unique,
      password_hash text not null
    ) ]] },

  { name = "003_tasks_belong_to_accounts.sql", sql = [[
    alter table tasks add column user_id integer references accounts (id);
    delete from tasks where user_id is null;
    alter table tasks alter column user_id set not null ]] },

  { name = "004_welcome_email_sent.sql", sql = [[
    alter table accounts add column welcome_email_sent_at timestamptz ]] },
}
```

Depois, execute-as na inicialização, antes do `app:run`:

```lua no-run
do
  local one_off = {}
  for key, value in pairs(settings) do one_off[key] = value end
  one_off.pool_size = 0

  local connection = db.connect(one_off)()
  local runner = migrate.new(connection, { files = MIGRATIONS })
  local applied = runner:apply()
  log:info("migrations applied", { count = #applied })
  for _, name in ipairs(applied) do log:info("migrated", { file = name }) end
  connection:close()
end
```

Três detalhes nesse trecho, e cada um deles é algo que deu errado com alguém
antes de ser documentado.

**`pool_size = 0`** dá uma conexão que não vem do pool. O executor de
migrações toma um lock em nível de banco de dados para que duas instâncias
iniciando ao mesmo tempo não possam migrar juntas, e esse lock pertence a uma
sessão. Uma conexão vinda do pool, que volta para ele no meio da execução,
levaria o lock junto.

**Nenhum `statement_timeout` nessa conexão.** `settings` ainda não recebeu um
neste ponto do arquivo, de propósito. Uma migração pode levar minutos; o
timeout de cinco segundos da página 11 a cancelaria no meio do caminho.

**É seguro executar a cada boot.** O executor mantém uma tabela de registro do
que já foi aplicado e pula essas migrações. Dez instâncias iniciando juntas
aplicam as migrações uma única vez, porque as outras nove esperam no lock e
depois não encontram nada para fazer.

Existe um custo honesto aqui. Essa lista precisa se manter sincronizada
manualmente com a sua pasta `migrations/`, e uma lista copiada à mão é uma
lista que diverge com o tempo. Mantenha os arquivos `.sql` como a coisa que
você edita, e trate isso como o mecanismo, não como o hábito diário.

Se você preferir manter a pasta, `docs/DEPLOY.md` descreve a outra forma:
construir o mesmo binário no alvo `slim`, que tem shell, e executar as
migrações a partir dessa imagem antes de a imagem `scratch` atender
requisições.

## Construindo a imagem

```sh
docker build --build-arg APP=app.lua -t mytasks .
```

A primeira construção leva cerca de três minutos, a maior parte compilando
bibliotecas C. Construções seguintes, depois de editar `app.lua`, levam cerca
de quinze segundos, porque tudo acima do seu arquivo já está em cache.

Perto do final você verá o que a construção de fato fez:

```
akkar build: 141 Lua modules, 47 native modules -> /build/akkar-app
```

```
akkar dev-1
static, and it starts
```

Essas duas últimas linhas são a própria construção testando sua saída antes de
embarcá-la. Um binário que não consegue iniciar deve falhar aqui, não no loop
de reinicialização do seu host.

```sh
docker images mytasks --format '{{.Repository}}:{{.Tag}} {{.Size}}'
```

```
mytasks:latest 6.58MB
```

Seis megabytes e meio, contendo sua aplicação, um interpretador Lua, um
servidor HTTP, um driver de Postgres e o OpenSSL.

## Executando a imagem

Contra o seu Postgres e Redis locais, para que você veja funcionar antes de um
host entrar na jogada. `--network host` permite que o contêiner alcance
serviços em `127.0.0.1` na sua máquina; em uma implantação real, os nomes de
host são reais.

```sh
docker run -d --name tasklist-api --network host \
  -e PORT=3003 -e HOST=0.0.0.0 \
  -e PGHOST=127.0.0.1 -e PGPORT=55432 -e PGDATABASE=tasklist_deploy \
  -e PGUSER=postgres -e PGPASSWORD=akkar \
  -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 \
  -e SESSION_SECRET=this-is-thirty-two-bytes-long-ok \
  -e FRONTEND_ORIGIN=http://127.0.0.1:5173 \
  -e INSECURE_COOKIES=1 \
  mytasks
```

`tasklist_deploy` é um banco de dados novo e vazio, sem nada dentro. Crie-o
primeiro com `createdb tasklist_deploy`, ou com o que quer que seu contêiner
de Postgres ofereça.

`INSECURE_COOKIES=1` serve apenas para este teste local. Os cookies de sessão
são marcados como `Secure` por padrão, o que significa que o navegador não vai
enviá-los por `http` puro. Em produção você tem HTTPS e deixa isso sem
definir.

```sh
docker logs tasklist-api
```

```
INFO  migrations applied count=4
INFO  migrated file=001_create_tasks.sql
INFO  migrated file=002_create_accounts.sql
INFO  migrated file=003_tasks_belong_to_accounts.sql
INFO  migrated file=004_welcome_email_sent.sql
INFO  listening url=http://0.0.0.0:3003
```

Um banco de dados vazio, migrado pelo próprio contêiner, no seu primeiro boot.

```sh
curl -s http://127.0.0.1:3003/health/ready
```

```
{"cached":false,"status":"pass","uptime":3.8247107550051,"checks":{"db":{"status":"pass","took_ms":1}}}
```

```sh
curl -s -X POST http://127.0.0.1:3003/signup \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com","password":"correct horse battery"}'
```

```
{"id":1,"email":"ada@example.com"}
```

Reinicie o contêiner e o log conta que não havia nada para fazer:

```
INFO  migrations applied count=0
INFO  listening url=http://0.0.0.0:3003
```

## O worker é uma segunda imagem

O `Dockerfile` constrói um arquivo de entrada em um binário, então o worker
ganha sua própria construção do mesmo repositório:

```sh
docker build --build-arg APP=worker.lua -t mytasks-worker .
```

É rápido, porque tudo, exceto as duas últimas camadas, já está em cache.

`worker.lua` precisa do mesmo tratamento que `app.lua`: ler as configurações
do banco de dados a partir do ambiente, e não do arquivo.

```sh
docker run -d --name tasklist-worker --network host \
  -e PGHOST=127.0.0.1 -e PGPORT=55432 -e PGDATABASE=tasklist_deploy \
  -e PGUSER=postgres -e PGPASSWORD=akkar \
  -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 \
  mytasks-worker
```

Cadastre alguém pela API do contêiner e depois leia o log do worker:

```sh
curl -s -X POST http://127.0.0.1:3003/signup \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"correct horse battery"}'
```

```
{"id":2,"email":"grace@example.com"}
```

```sh
docker logs tasklist-worker
```

```
INFO  worker waiting for jobs
INFO  welcome email sent to=ada@example.com
INFO  welcome email sent to=grace@example.com
```

Dois e-mails, mas apenas um cadastro aconteceu agora. O outro é o da ada,
enfileirado antes de existir qualquer worker para pegá-lo, esperando no Redis
o tempo todo. Isso é o "se ninguém está ouvindo, o job espera" da página 10,
visto do outro lado.

Dois contêineres, um Redis entre eles, e nenhum sabe da existência do outro.

## Parando sem derrubar requisições

Uma implantação substitui o seu contêiner. O host envia `SIGTERM` e espera que
o processo termine o que está fazendo e saia.

O akkar não instala um manipulador de sinal por conta própria, porque uma
biblioteca que toma conta dos sinais nas costas da sua aplicação entra em
conflito com o que mais o processo estiver fazendo. Em um contêiner, é uma
linha, e ela não é opcional:

```lua no-run
app:handle_signals()
```

Observe:

```sh
docker stop tasklist-api
```

```
INFO  listening url=http://0.0.0.0:3003
INFO  signal received
INFO  shutdown: no longer accepting connections
INFO  shutdown: stopped cleanly
```

Três linhas, em ordem: o sinal chegou, o socket parou de aceitar novas
conexões, e as requisições já em andamento puderam terminar.

Sem `app:handle_signals()` não há manipulador, a ação padrão se aplica, e toda
requisição em andamento é cortada no meio da resposta. Ninguém percebe em
teste, porque uma implantação sem tráfego não derruba nada.

## Colocando em um host de verdade

A execução local acima é a implantação inteira. Um host acrescenta três
coisas: ele constrói a imagem para você, ele fornece um banco de dados e um
Redis, e ele coloca um certificado e um domínio na frente.

No Railway, que foi onde `docs/DEPLOY.md` foi escrito e testado:

```sh
railway login
railway link
railway up
```

Não existe comando de inicialização para configurar. A imagem tem um
`ENTRYPOINT`.

Anexe um Postgres e um Redis pelo próprio menu do host, defina
`SESSION_SECRET` e `FRONTEND_ORIGIN` como variáveis do serviço, e implante.
`docs/DEPLOY.md` tem os detalhes medidos, incluindo quais das suas afirmações
foram de fato executadas e quais foram apenas lidas.

TLS é trabalho do host aqui. Sua aplicação fala HTTP puro dentro do contêiner
e a plataforma encerra o HTTPS na borda dela. É por isso que os cookies
`Secure` funcionam em produção mesmo que o seu contêiner nunca veja um
certificado.

## A aplicação completa

`app.lua`. É mais longo que o da página 11, e cada linha extra é uma das cinco
coisas desta página.

É o único arquivo neste guia que a própria suíte de testes da documentação não
executa, e o motivo é justamente o ponto do arquivo: ele se recusa a iniciar
sem o seu ambiente, e a suíte não tem nenhum para dar a ele. Ele foi verificado
da forma que esta página descreve, sendo construído na imagem acima e
executado contra um Postgres e um Redis reais, o que é um teste melhor do que
o executor de testes poderia ter dado.

```lua no-run
local akkar   = require "akkar"
local db      = require "akkar.db"
local redis   = require "akkar.redis"
local jobs    = require "akkar.jobs.redis"
local health  = require "akkar.health"
local migrate = require "akkar.migrate"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local sql     = require "akkar.sql"
local crypto  = require "akkar.crypto"
local logging = require "akkar.log"

local log = logging.new()

local function required(name)
  local value = os.getenv(name)
  if value == nil or value == "" then
    error("this app needs the environment variable " .. name ..
          " and it is not set", 0)
  end
  return value
end

local MIGRATIONS = {
  { name = "001_create_tasks.sql", sql = [[
    create table tasks (
      id    serial primary key,
      title text    not null,
      done  boolean not null default false
    ) ]] },

  { name = "002_create_accounts.sql", sql = [[
    create table accounts (
      id            serial primary key,
      email         text not null unique,
      password_hash text not null
    ) ]] },

  { name = "003_tasks_belong_to_accounts.sql", sql = [[
    alter table tasks add column user_id integer references accounts (id);
    delete from tasks where user_id is null;
    alter table tasks alter column user_id set not null ]] },

  { name = "004_welcome_email_sent.sql", sql = [[
    alter table accounts add column welcome_email_sent_at timestamptz ]] },
}

local SESSION_SECRET  = required "SESSION_SECRET"
local FRONTEND_ORIGIN = required "FRONTEND_ORIGIN"

local settings = {
  host     = required "PGHOST",
  port     = tonumber(os.getenv "PGPORT") or 5432,
  database = required "PGDATABASE",
  user     = required "PGUSER",
  password = required "PGPASSWORD",
}

do
  local one_off = {}
  for key, value in pairs(settings) do one_off[key] = value end
  one_off.pool_size = 0

  local connection = db.connect(one_off)()
  local runner = migrate.new(connection, { files = MIGRATIONS })
  local applied = runner:apply()
  log:info("migrations applied", { count = #applied })
  for _, name in ipairs(applied) do log:info("migrated", { file = name }) end
  connection:close()
end

settings.statement_timeout = 5
local connect = db.connect(settings)

local app = akkar.new()

local queue = jobs.new(redis.connect {
  host = os.getenv "REDIS_HOST" or "127.0.0.1",
  port = tonumber(os.getenv "REDIS_PORT") or 6379,
}(), "email")

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
  origin = FRONTEND_ORIGIN,
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
  secret = SESSION_SECRET,
  secure = os.getenv "INSECURE_COOKIES" ~= "1",
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
  host = os.getenv "HOST" or "0.0.0.0",
  port = tonumber(os.getenv "PORT") or 8080,
  timeout = 5,
  shutdown_grace = 10,
  db = connect,
  cache = redis.connect {
    host = os.getenv "REDIS_HOST" or "127.0.0.1",
    port = tonumber(os.getenv "REDIS_PORT") or 6379,
  },
}
```

E `worker.lua`, com o mesmo tratamento de ambiente:

```lua no-run
local cqueues = require "cqueues"
local db      = require "akkar.db"
local redis   = require "akkar.redis"
local jobs    = require "akkar.jobs.redis"
local logging = require "akkar.log"

local log = logging.new()

local function required(name)
  local value = os.getenv(name)
  if value == nil or value == "" then
    error("this worker needs the environment variable " .. name ..
          " and it is not set", 0)
  end
  return value
end

local connect = db.connect {
  host     = required "PGHOST",
  port     = tonumber(os.getenv "PGPORT") or 5432,
  database = required "PGDATABASE",
  user     = required "PGUSER",
  password = required "PGPASSWORD",
}

local queue = jobs.new(redis.connect {
  host = os.getenv "REDIS_HOST" or "127.0.0.1",
  port = tonumber(os.getenv "REDIS_PORT") or 6379,
}(), "email")

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

## Ponto de verificação

Você conseguiu se:

- `docker build` produz uma imagem de cerca de seis megabytes e meio
- `docker logs` mostra quatro migrações aplicadas na primeira execução e
  nenhuma na segunda
- o contêiner responde a `/health/ready` e aceita um cadastro
- `docker stop` imprime `shutdown: stopped cleanly`
- não sobrou nenhuma senha, nenhum segredo de sessão e nenhuma origem de
  frontend em nenhum lugar do seu código-fonte

## Essa é a trilha para iniciantes

Doze páginas atrás você ainda não tinha escrito um backend. Agora você tem um,
com banco de dados, contas que são donas das próprias linhas, um frontend que
faz login a partir de outra origem, trabalho que acontece depois da resposta,
limites que mantêm tudo respondendo sob carga, e uma implantação que carrega o
próprio esquema.

Para onde ir a seguir:

- **As receitas** respondem uma tarefa cada: enviar um arquivo, paginar,
  chamar outra API, aceitar um webhook, enviar e-mail de verdade.
- **A referência** documenta cada módulo e cada função.
- **As páginas de explicação** argumentam as decisões: por que os handlers
  retornam em vez de escrever, por que sessões e não JWTs, por que um processo
  por núcleo.
- **`docs/DEPLOY.md`** é a versão medida desta página, incluindo o que foi
  verificado e o que foi apenas lido.
