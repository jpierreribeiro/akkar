# akkar

> [English](README.md) | **Português (Brasil)**

**A backend runtime para Lua que inicializa em 29 milissegundos, fala HTTP/2 sem nginx na frente e não deixa você escrever os bugs que te tiram da cama às três da manhã.**

Uma corrotina por requisição. Uma thread por processo. Uma aplicação inteira, com Postgres, Redis, jobs em background, sessões e métricas, responde à primeira requisição em dezenas de milissegundos em vez de segundos.

```sh
akkar new my-api && cd my-api && akkar run
```

```lua
local akkar = require "akkar"

local app = akkar.new()
app:get("/", function() return { hello = "world" } end)

return app
```

| | |
|---|---:|
| boot até a primeira resposta | **68 ms**, ou 29 ms antes do HTTP/2 |
| memória por conexão ociosa | 9.2 KB |
| testes, Lua 5.4 e Lua 5.5 | **1,852** |
| conformidade HTTP/2, h2spec 2.6.0 | **146 de 146** |
| plataformas testadas a cada commit | Linux x86_64, Linux arm64, macOS |

Todo número nesta página saiu de uma máquina. Onde falta algum, a página diz isso.

---
## Cinco falhas que você já colocou em produção

Não são hipóteses. São as que sobrevivem à revisão de código, passam pelo staging
e depois acordam alguém no meio da noite.

**A resposta duplicada.** Um handler escreve uma resposta, e depois um caminho de
erro escreve outra. Na maioria dos frameworks isso é, na melhor das hipóteses, um
erro em tempo de execução e, na pior, uma resposta corrompida. Aqui um handler
*retorna* sua resposta e nunca segura o socket, então não há nada para escrever
duas vezes.

```lua
app:post("/charges", function(req)
  if not req.body.amount then
    return akkar.bad_request { error = "amount is required" }
  end
  return akkar.created { id = 42 }         -- one value out, always
end)
```

**A conexão que nunca voltou.** Uma requisição é abandonada no meio de uma
query, seu handler é descartado, e o slot do pool que ele tinha emprestado se
perde para sempre. O suficiente disso e o serviço para de responder sem nenhum
erro em lugar nenhum. O akkar libera toda capability que uma requisição
adquiriu em todo caminho de saída, incluindo o deadline e incluindo um raise, e
uma máquina verifica isso sob agendamentos de falha gerados em vez de confiar
na promessa.

**A transação abandonada.** Um `BEGIN` sem o `COMMIT` correspondente segura
locks até que algo estoure o tempo limite. `transaction(fn)` tem escopo de
closure: a transação não pode sobreviver à função, porque não existe um handle
para deixar aberto.

```lua
req.db:transaction(function(tx)
  tx:query("update accounts set balance = balance - $1 where id = $2", 100, 1)
  tx:query("update accounts set balance = balance + $1 where id = $2", 100, 2)
end)                                        -- commits, or rolls back, here
```

**A requisição sem teto.** Um corpo que chega para sempre, uma query sem
deadline, uma mensagem WebSocket de tamanho arbitrário. Corpos, deadlines e
mensagens de socket já vêm limitados antes de você configurar qualquer coisa,
em 1 MB e 30 segundos. Mais dois limites são uma linha cada, quantos sockets
podem estar abertos e quantas instruções um handler pode rodar sem retornar, e
o `akkar doctor` avisa quando você não os configurou.

**O event loop bloqueado.** Uma chamada síncrona em um handler trava todas as
outras requisições do processo, e o sintoma de sempre é uma latência que
ninguém consegue explicar. O akkar percebe e te diz qual arquivo e qual linha
fez isso.

```
WARN  event loop blocked for 240ms at handlers/report.lua:31
```

---
## Sixty segundos até um serviço no ar

```sh
luarocks install https://raw.githubusercontent.com/jpierreribeiro/akkar/main/akkar-0.1.0-1.rockspec
akkar new my-api && cd my-api && akkar run
```

Requer Lua 5.4 e os headers do OpenSSL. Testado com OpenSSL 3.0.13. O Lua 5.5
também funciona e o CI roda toda a suíte de testes nele; o `docs/runtime/lua55-stack.sh`
constrói essa pilha a partir do código-fonte em um único comando.

O `akkar new` gera um projeto que já vem com rotas, um schema, migrations,
testes e um Dockerfile. O `akkar run` recarrega a cada salvamento. O `akkar doctor`
verifica a configuração e avisa o que vai te morder em produção.

---
## O que custa rodar

Medido em um c5.2xlarge, e reproduzível a partir de `bench/`:

| | |
|---|---:|
| boot, `akkar` sozinho | 21 ms |
| boot, mais Postgres, Redis, jobs, auth, metrics | 29 ms |
| alocação por requisição | 5.376 B |
| conexão HTTP ociosa | 9,2 KB |
| WebSocket ocioso | 10,2 KB |
| modelo de capacidade | um processo por núcleo, `reuseport = true` |

Pequeno o suficiente para cem processos ociosos caberem entre 1,1 e 1,4 GB, o que é o motivo de o runtime também servir de substrato para uma plataforma de ensino. A faixa é o resultado: o RSS ocioso foi medido três vezes e deu 11,4, 13,3 e 14,1 MB, e um único número nunca esteve disponível a partir de três execuções que diferem em um quarto. Pequeno o suficiente para que
uma imagem de container tenha 6,4 MB.
## HTTP/2 e WebSocket, sem proxy

Sirva TLS e o navegador negocia HTTP/2 via ALPN. Não existe opção para ligar
nem um segundo listener:

```lua
app:run { port = 443, tls = { certificate = "cert.pem", key = "key.pem" } }
```

Medido aqui, seis requisições de meio segundo em uma única conexão: **552 ms em
HTTP/2 contra 3.071 ms em HTTP/1.1**. Isso é multiplexação, e seus handlers
não mudam nada para ganhar esse resultado.

WebSocket é um tipo de rota, não um segundo modelo de programação. Os handlers
continuam retornando, então nada das garantias acima é suspenso para sockets:

```lua
app:websocket("/chat/:room", {
  open    = function(ws) ws:send("welcome to " .. ws.params.room) end,
  message = function(ws, text)
    ws:scope(function(req)                  -- capabilities para ESTA mensagem
      req.db:query("insert into messages (room, body) values ($1, $2)",
                   ws.params.room, text)
    end)                                    -- liberado aqui, em todo caminho
    ws:send(text)
  end,
})
```

Esse `ws:scope` é uma linha de cerimônia, e é ela que decide se um slot do pool
fica retido por uma mensagem ou pelo tempo em que uma aba do navegador
permanece aberta.

HTTP/3 não está aqui. QUIC é um transporte UDP com seu próprio controle de
congestionamento, e na prática é terminado na borda.
## Como as garantias são verificadas

Toda afirmação acima é verificada por máquina, e a verificação é a parte interessante.

**1.852 testes**, no Lua 5.4 e no Lua 5.5, em três plataformas, a cada commit.

**Conformidade com HTTP/2** via h2spec 2.6.0: **146 de 146, nada pulado**,
execução após execução. `bench/h2spec.sh` baixa a ferramenta e a executa contra um
servidor ativo, para que você possa checar a afirmação em vez de simplesmente acreditar nela.

**Cronogramas de falha gerados.** Uma seed escolhe a carga de trabalho, as falhas e os
prazos, e os invariantes do pool são verificados após cada execução. Quando
`execution.release` foi esvaziado para provar que o teste morde de verdade, a suíte não ficou
vermelha, ela *travou*, que é exatamente a interrupção que o código do pool tem registrada
de uma máquina de estudo.

**Bytes hostis.** Vinte e dois formatos de frame HTTP/2 malformados e quinze
de WebSocket malformados são disparados contra um servidor ativo, e a propriedade verificada não é
"não travar", e sim "o próximo cliente comum ainda é respondido".
## O que um bug custa aqui

Na primeira execução, o fuzzer de HTTP/2 encontrou uma negação de serviço remota no lua-http original: um cabeçalho de frame que chega três bytes mais curto faz o `string.unpack` disparar uma exceção, essa exceção derruba a conexão, e o loop de aceitação morre junto. Processo vivo, socket aberto, nada mais é aceito depois disso, incluindo HTTP/1.1. Três bytes, sem credenciais.

Esse foi o segundo defeito do tipo, não o primeiro: um cabeçalho
`Content-Length` malformado faz um servidor lua-http original parar de aceitar
conexões para sempre, e um valor negativo encerra o processo imediatamente.
[`docs/substrate/lua-http-wedge.md`](docs/substrate/lua-http-wedge.md) contém a
reprodução, as medições e o reparo, que fica na cópia vendorizada de
`h1_stream` do akkar.

Duas coisas saíram daí, e a segunda importa mais.

O parser agora verifica o tamanho que recebeu, algo que o original já faz vinte linhas abaixo para o payload, mas não para o cabeçalho.

E o `add_socket` agora executa cada conexão sob `xpcall`, de modo que o próximo bug do parser, aquele que ninguém ainda encontrou, custa uma conexão em vez do serviço inteiro. Isso foi demonstrado recolocando o defeito original de volta: o servidor registra o traceback e continua respondendo.

Esse é o método de trabalho. Encontrar o defeito, corrigir o defeito, depois perguntar por que o defeito foi fatal e corrigir isso também.

---
## É Lua rápido o suficiente para isso

Para uma API JSON, sim, e a comparação honesta está nesta página, não numa nota de rodapé.

O akkar responde uma requisição JSON em cerca de 93 microssegundos de CPU. Contra o OpenResty ele é 8,75 vezes mais lento, e o OpenResty é nginx: o pipeline de requisição é C e o Lua só roda o seu handler. Contra o Lapis, o outro framework Lua no mesmo formato, o akkar é 1,56 vezes mais rápido. Contra o Luvit, sobre libuv, os dois empatam em throughput e o p99 do akkar é de duas a três vezes melhor.

O que isso significa na prática: um endpoint que gasta quatro milissegundos no Postgres gasta cerca de um décimo de milissegundo no akkar. O runtime não é onde está a sua latência, e se um dia passar a ser, o profiler em `bench/` vai dizer isso com um número.

Várias coisas que deixariam o sistema mais rápido foram medidas e recusadas, com a conta registrada. LuaJIT em 1,62x contra uma barra de 2x (`docs/substrate/LUAJIT.md`). Um tokenizador em C, recusado porque todo o parsing de requisição é **152 bytes, 1,3% de uma requisição** — meses de trabalho e uma nova fronteira relevante para segurança para substituir isso (`docs/PERFORMANCE-PLAN.md`). Validadores gerados, recusados porque **economizam zero bytes** (`bench/study/HTTP-OPTIMISATION.md`).

`docs/pt-BR/why/slower-than-openresty.md` é o relato único: para onde vai o
tempo, qual dos três números publicados para a diferença é o atual, cada
recusa com a meta usada para medi-la e o que ainda está em aberto.

Os dois últimos são recusados por ALOCAÇÃO, não por uma razão de throughput, e este parágrafo costumava citá-los como 1,09x e 1,04x e apontar para `docs/pt-BR/why/`. Nenhum desses números existe neste repositório e esse diretório não trata de nenhum dos dois assuntos. Corrigido em 02/09/2026.

---
## Onde o akkar está hoje

O akkar roda os serviços do seu próprio autor. Ele é jovem, e estas são as três coisas que vale saber antes de colocá-lo na frente dos seus clientes:

**A API vai mudar.** Ainda não existe uma política de compatibilidade. Fixe a versão no rockspec.

**Nenhuma revisão de segurança independente aconteceu.** Os limites, os fuzzers e a suíte de conformidade são reais, mas todos internos.

**Ele ainda não está no luarocks.org**, então instalar significa apontar o LuaRocks para a URL do rockspec acima. Isso é um passo de release, não um obstáculo.

O que já está consolidado: o substrato, a ergonomia e o formato de produção. Limites de corpo, deadlines, pooling, encerramento gracioso, logs estruturados, métricas, tracing, OpenAPI, migrations, jobs, sessões, um adapter em memória para cada capability, declarações Teal e um modo estrito que transforma uma global acidental em erro.

`docs/UNKNOWNS.md` é a lista completa do que ainda não se sabe, mantida atualizada.

---
## Tudo o que vem na caixa

Trinta e seis módulos e oito comandos, cada linha apontando para sua página de referência.

**A linha de comando.** Instalar o rock coloca `akkar` no seu PATH.

| | |
|---|---|
| [`akkar new`](docs/pt-BR/reference/cli.md) | um projeto que já roda: app, spec, migrations, README |
| [`akkar run`](docs/pt-BR/reference/cli.md) | inicia o projeto; `--watch` reinicia a cada mudança |
| [`akkar test`](docs/pt-BR/reference/cli.md) | busted sobre `spec/`, com o path já configurado pra você |
| [`akkar doctor`](docs/pt-BR/reference/doctor.md) | o que está instalado, e se responde |
| [`akkar build`](docs/RUNTIME.md) | um único executável, sem precisar de Lua pra rodar |
| [`akkar archive`](docs/RUNTIME.md) | os archives estáticos que o `build` consome |
| [`akkar watch`](docs/pt-BR/reference/cli.md) | reinicia qualquer comando quando os arquivos mudam |
| `akkar version` | a versão, e o Lua por trás dela |

**Lidando com uma requisição**

| | |
|---|---|
| [`akkar`](docs/pt-BR/reference/akkar.md) | rotas, a tabela de requisição, respostas, `app:run`, `app:test` |
| [`akkar.v`](docs/pt-BR/reference/akkar.md#akkarv) | schemas para params, query, body e response |
| [`akkar.openapi`](docs/pt-BR/reference/openapi.md) | o documento, a partir dos schemas que você já escreveu |
| [`akkar.etag`](docs/pt-BR/reference/etag.md) | `If-Match`, pra um segundo escritor não apagar o primeiro |
| [`akkar.idempotency`](docs/pt-BR/reference/idempotency.md) | a mesma `Idempotency-Key` cobrada uma única vez |
| [`akkar.limit`](docs/pt-BR/reference/limit.md) | concorrência e taxa, decididas dentro do Redis |
| [`akkar.compress`](docs/pt-BR/reference/compress.md) | gzip na saída |
| [`akkar.static`](docs/pt-BR/reference/static.md) | arquivos, com cabeçalhos de cache |
| [`akkar.multipart`](docs/pt-BR/reference/multipart.md) | uploads |

**As capacidades que um handler recebe.** Um conjunto fechado, pra que `req` não vire uma global disfarçada de outro nome.

| | |
|---|---|
| [`req.db`](docs/pt-BR/reference/db.md) | Postgres, quatro métodos, com pool |
| [`req.cache`](docs/pt-BR/reference/redis.md) | Redis, ou uma implementação em processo |
| [`req.log`](docs/pt-BR/reference/log.md) | estruturado, com o id da requisição já embutido |
| [`req.clock`](docs/pt-BR/reference/time.md) | o clock, pra um teste de prazo não precisar dormir |
| [`req.http`](docs/pt-BR/reference/http.md) | HTTP de saída, com pool e um teto |

**Dados**

| | |
|---|---|
| [`akkar.db`](docs/pt-BR/reference/db.md) | o adapter e a fábrica de conexões |
| [`akkar.pq`](docs/pt-BR/reference/db.md#o-driver-pq) | o driver em C sobre libpq, opcional |
| [`akkar.sql`](docs/pt-BR/reference/sql.md) | um builder onde um valor nunca pode virar SQL |
| [`akkar.scope`](docs/pt-BR/reference/scope.md) | um tenant do qual uma query não consegue escapar |
| [`akkar.pool`](docs/pt-BR/reference/pool.md) | pooling de conexões, usado pelo db e pelo http |
| [`akkar.migrate`](docs/pt-BR/reference/migrate.md) | migrations, a partir de um diretório ou como dados |
| [`akkar.redis`](docs/pt-BR/reference/redis.md) | o adapter de cache |
| [`akkar.json`](docs/pt-BR/reference/json.md) | encoding, com tratamento de `null` e array vazio |

**Identidade**

| | |
|---|---|
| [`akkar.auth`](docs/pt-BR/reference/auth.md) | session, bearer e API key, um único middleware |
| [`akkar.session`](docs/pt-BR/reference/session.md) | sessions do lado do servidor atrás de um cookie assinado |
| [`akkar.jwt`](docs/pt-BR/reference/jwt.md) | só verificação, de propósito |
| [`akkar.csrf`](docs/pt-BR/reference/csrf.md) | double-submit, para sessions baseadas em cookie |
| [`akkar.crypto`](docs/pt-BR/reference/crypto.md) | hashing, HMAC, hashing de senha, aleatoriedade |

**Trabalho que sobrevive à requisição**

| | |
|---|---|
| [`akkar.jobs`](docs/pt-BR/reference/jobs.md) | filas at-least-once, retries, dead letters |
| [`akkar.work`](docs/pt-BR/reference/work.md) | trabalho nativo que bloquearia o loop |
| [`app:task`](docs/pt-BR/reference/akkar.md#apptaskname-fn) | um loop supervisionado no próprio processo do servidor |

**Operando o sistema**

| | |
|---|---|
| [`akkar.health`](docs/pt-BR/reference/health.md) | liveness e readiness, separadamente |
| [`akkar.metrics`](docs/pt-BR/reference/metrics.md) | Prometheus, com o caminho da requisição instrumentado |
| [`akkar.trace`](docs/pt-BR/reference/trace.md) | trace context W3C, propagado e exportado |
| [`akkar.log`](docs/pt-BR/reference/log.md) | JSON ou texto, com redaction |
| [`akkar.config`](docs/pt-BR/reference/config.md) | ambiente, tipado e validado no boot |
| [`akkar.doctor`](docs/pt-BR/reference/doctor.md) | a combinação de bibliotecas, verificada |

**Alcançando o mundo externo**

| | |
|---|---|
| [`akkar.http`](docs/pt-BR/reference/http.md) | um client com pool, retries e um teto de tamanho de body |
| [`akkar.email`](docs/pt-BR/reference/email.md) | SMTP |
| [`akkar.storage`](docs/pt-BR/reference/storage.md) | armazenamento de objetos compatível com S3, assinado |

**O runtime em si**

| | |
|---|---|
| [`akkar.build`](docs/RUNTIME.md) | o host de executável único |
| [`akkar.watch`](docs/pt-BR/reference/cli.md#akkar-watch----comando) | observação de arquivos para desenvolvimento |
| [`akkar.strict`](docs/pt-BR/reference/strict.md) | uma global acidental vira um erro |
| [`akkar.time`](docs/pt-BR/reference/time.md) | o clock que o framework lê |
| [`akkar.vm`](docs/pt-BR/reference/vm.md) | uma sandbox para Lua não confiável; leia os limites dela primeiro |

**Adapters que não precisam de nada rodando.** Toda capacidade traz um, para que testes e deploys pequenos não precisem de infraestrutura.

| | |
|---|---|
| [`akkar.db.memory`](docs/pt-BR/reference/db.md#akkardbmemory) | queries programadas, e `:hang()`, `:fail()`, `:drop()` |
| [`akkar.cache.memory`](docs/pt-BR/reference/redis.md) | um cache de verdade com expiração, por processo |
| [`akkar.jobs.memory`](docs/pt-BR/reference/jobs.md#memorynewname-options) | uma fila em um único processo |
| [`akkar.jobs.redis`](docs/pt-BR/reference/jobs.md#redisnewcache-name-options) | uma fila compartilhada por toda a frota |
## A ideia

Três coisas que o akkar faz de forma diferente, cada uma vinda de um defeito concreto
em um framework que existe.

### 1. Os handlers retornam a resposta; eles nunca modificam um contexto

```lua
app:get("/users/:id", function(req)
  local user = req.db:one("select id, name from users where id = $1", req.params.id)
  return user or akkar.not_found "user not found"
end)
```

Escrever a resposta duas vezes se torna **estruturalmente impossível**, porque não existe
um `c.JSON()` para chamar de novo. E não existe um par `Abort()` + `return` em que
esquecer o `return` deixa o handler continuando a rodar.

### 2. Todo I/O passa por adaptadores, e o akkar é dono do contrato

Um handler nunca chama `require "pgmoon"`. Ele recebe `req.db`. É isso que
torna possível testar em processo, e é isso que mantém o substrato substituível.

O akkar define o contrato (para um banco de dados, quatro métodos) e distribui um
adaptador Postgres como referência, não como o único permitido. Ser dono de cada
driver faria do akkar o gargalo.

`req` permanece deliberadamente pequeno. As capacidades vêm de um **conjunto fechado** de `db`,
`cache`, `log`, `clock` e `http`, porque `req` acumulando `req.mailer`,
`req.payments` e `req.storage` é exatamente como um objeto de requisição vira uma global com outro nome. Opções desconhecidas são rejeitadas na inicialização em vez de ignoradas:

```
unknown app:run{} option 'timout'; did you mean 'timeout'?
```

E ler algo que nunca foi configurado dá uma mensagem útil em vez de
`attempt to index a nil value`:

```
req.user is not set; this route is missing the authentication middleware
req.db is not configured; pass db = ... to app:run{}
```

### 3. Um watchdog de bloqueio

O principal modo de falha do Lua em um servidor é uma chamada bloqueante que congela
o processo silenciosamente. O akkar avisa você:

```
[akkar] WARNING: handler blocked the loop for 102 ms without yielding
  at handlers/auth.lua:14
stack traceback:
	handlers/auth.lua:16: in function <handlers/auth.lua:14>
  this stalls every request in this process.
```

Medido: de 0,16 a 0,35 µs por troca, com menos de 2% de overhead. Ele fica ligado em
produção. Go não avisa sobre isso; Node também não.

**O que ele não consegue ver, dito porque esta página prometeu demais até alguém
checar.** O watchdog conta instruções Lua, então ele percebe código Lua que
roda por tempo demais. Uma única chamada para C é uma instrução e continua sendo uma
instrução, não importa quanto tempo ela leve.

O exemplo que importa é o hash de senha: `akkar.crypto.hash_password` é
PBKDF2 dentro do OpenSSL, levou **771 ms** em uma medição feita enquanto se escrevia
o guia para iniciantes, e o watchdog não disse absolutamente nada. O processo inteiro
ficou parado por três quartos de segundo em silêncio.

É por isso que `akkar.crypto` aponta para `akkar.work` na sua própria docstring, e isso
é um limite de verdade, não uma funcionalidade que falta: não existe nenhum ponto em que o Lua
retome o controle durante uma chamada em C, então não há nada para um watchdog em nível Lua
interromper. O `akkar/work.lua` diz a mesma coisa sobre trabalho nativo em
geral.
## A escada

A regra: **subir um degrau nunca exige editar código escrito no degrau abaixo.**

```lua
-- 0. três linhas
app:get("/", function() return { hello = "world" } end)

-- 1. parâmetros
app:get("/users/:id", function(req) return { id = req.params.id } end)

-- 2. corpo da requisição
app:post("/users", function(req) return akkar.created { name = req.body.name } end)

-- 3. validação
app:post("/users", {
  body = { name = "string", email = "string?" },
}, function(req) return akkar.created(req.body) end)

-- 3b. validação expressiva; "string?" é açúcar sintático para v.string{optional=true}
app:put("/users/:id", {
  params = { id = v.integer { min = 1 } },
  body   = { name = v.string { min = 1, max = 100 },
             role = v.string { optional = true, one_of = { "admin", "user" } } },
}, handler)

-- 4. middleware; `next` retorna a resposta, então o pós-processamento funciona
app:use(function(req, next)
  local res = next(req)
  log(req.method, req.path, res.status)
  return res
end)

-- 5. banco de dados
app:get("/users/:id", function(req)
  return req.db:one("select id, name from users where id = $1", req.params.id)
end)

-- 6. configuração
app:run { port = 3000, db = require("akkar.db").connect { ... } }
```

Cada transição foi verificada uma a uma em `docs/PLAN.md`, seção 2.
## Coisas que vale a pena saber

**Uma camada profunda pode sinalizar HTTP sem precisar repassar um valor de retorno até o topo.** O
mesmo valor funciona como retorno e como erro:

```lua
local function find_or_404(db, id)
  local user = db:one("select ... where id = $1", id)
  if not user then error(akkar.not_found "does not exist") end
  return user
end
```

`return akkar.not_found()` e `error(akkar.not_found())` produzem um 404.
Um erro de verdade vira um 500, sem vazar traceback nenhum para o cliente.

**Transações com escopo de closure.** Faz commit no final, e rollback em qualquer erro,
inclusive uma resposta lançada de dentro dela. Não existe caminho onde um `BEGIN` fica
aberto porque alguém esqueceu de fechar.

```lua
return req.db:transaction(function(tx)
  local from = find_or_404(tx, req.params.id)
  tx:exec("update ...", from.id)
  return { ok = true }
end)
```

**Sub-aplicações, não grupos.** Uma sub-app é um app comum montado sob um
prefixo, e continua testável sozinha, sem saber onde está montada:

```lua
local health = akkar.new()
health:get("/live", function() return { status = "live" } end)
app:mount("/health", health)

health:test():get "/live"            -- isolada
app:test():get "/health/live"        -- montada
```

**Um schema de `response` é aplicado de verdade, não só documentado.** Declarar o formato
filtra os campos não declarados de fora do corpo, então um handler que faz `select *` não consegue
vazar `password_hash`. Uma divergência vira um 500, porque uma resposta que quebra
o próprio contrato é responsabilidade do servidor, não do cliente:

```lua
app:get("/users/:id", {
  response = { id = "integer", name = "string", email = "string?" },
}, function(req)
  return req.db:one("select * from users where id = $1", req.params.id)
end)
```

**Adaptadores que você roda sem precisar de infraestrutura.** Toda capacidade vem com uma
implementação em memória ao lado da real, então os testes não precisam de nada rodando
e uma instalação pequena pode dispensar o Redis por completo:

```lua
local app_client = app:test {
  db    = require("akkar.db.memory").factory(function(fake)
            fake:on("from users", { id = 1, name = "ada" })
          end),
  cache = require("akkar.cache.memory").factory(),
}
```

O de cache é uma implementação de verdade, com expiração, não um substituto qualquer. O
de banco de dados casa com queries programadas e não faz parsing de SQL, porque um mecanismo
SQL falso seria um segundo banco de dados, cujas divergências apareceriam como testes
que passam e produção que não funciona.

**Tipos, se você quiser.** O Lua não checa nada antes do programa rodar, e
escrever o akkar com cuidado não muda isso. `types/akkar.d.tl` permite que um
handler escrito em [Teal](https://github.com/teal-language/tl), um dialeto tipado
que compila para Lua puro, seja checado sem que o akkar precise ser reescrito:

```
invalid key 'parms' in record 'req' of type akkar.Request
in local declaration: n: got string, expected integer
unknown field timout
```

Isso não checa se um schema bate com o que um handler retorna; schemas são
valores em tempo de execução, e é a validação que checa isso.

**Globais acidentais são um erro, não uma surpresa.** Num servidor, uma variável global
escrita dentro de um handler sobrevive à requisição e fica visível para a próxima:

```lua
app:run { port = 8080, strict = true }
```

```
assignment to undeclared global 'total' at handlers/cart.lua:14
  a global written in a handler outlives the request and is visible to the next one
  did you mean `local total`?
```

O próprio akkar está limpo nesse quesito, com zero escritas em globais em todos os módulos,
verificado no bytecode, e toda a suíte de testes roda em modo strict para que isso continue
verdadeiro.

**Sockets têm seus próprios limites, e são os que as pessoas esquecem.**
`max_concurrent` conta conexões, e um WebSocket é uma conexão que
dura: dez sockets ociosos contra `max_concurrent = 10`, e o décimo primeiro cliente,
um GET comum para uma rota comum, nunca chega a ser aceito. Medido.

```lua
app:run {
  port = 8080,
  websocket_max_connections = 500,   -- recusado acima disso com 503 + retry-after
  websocket_idle_timeout    = 300,   -- um socket quieto é fechado e esquecido
  body_limit                = 1024 * 1024,   -- também limita uma MENSAGEM de socket
}
```

`body_limit` também cobre uma mensagem de WebSocket, tanto no tamanho que o peer declara quanto
na soma dos seus fragmentos, e a recusa é com o close code 1009. Antes desse
limite existir, uma única mensagem de 64 MB custou **192 MB de memória residente** numa
aplicação que tinha configurado `body_limit = 1 MB`. O `akkar doctor` avisa quando uma
aplicação serve sockets e não configurou um teto para eles.

**Vários processos, uma porta.** Uma VM Lua é um núcleo, então capacidade
é uma questão de processos. O `SO_REUSEPORT` permite que eles compartilhem uma porta sem
nenhum proxy na frente:

```lua
app:run { port = 8080, reuseport = true }
```

Medido numa c5.2xlarge: **linear entre núcleos físicos**, em 1.00x, 1.00x,
1.00x por processo com um, dois e três processos, variando menos do que o ruído de
fundo de 0.7%. Hyperthreads acrescentam cerca de 18% a mais. Veja `bench/RESULTS.md`.

**Logs que se correlacionam sem precisar pedir.** Um request id é tirado de
`x-request-id` ou gerado, ecoado na resposta, e vinculado a `req.log`:

```lua
app:post("/charges", function(req)
  req.log:info("charged", { amount = 10 })   -- request_id já anexado para você
  return akkar.created {}
end)
```

```json
{"level":"info","message":"charged","amount":10,"request_id":"minha-trace-123","time":1786757421}
```

**OpenAPI, gerado a partir do que você já escreveu.** O schema declarado para
validação é o schema no documento, então nenhuma rota se descreve duas vezes:

```lua
local openapi = require "akkar.openapi"
openapi.serve(app, "/openapi.json", { title = "My API", version = "1.0.0" })
```

`v.string { min = 1, max = 100 }` vira `minLength`/`maxLength`, `one_of`
vira `enum`, `match` vira `pattern`, `/users/:id` vira
`/users/{id}`, e o `422` que o próprio akkar produz fica documentado sem
ninguém precisar declará-lo.

**Testes in-process.** Sem socket, sem porta, sem banco de dados, e ainda assim passando pela mesma
cadeia de middleware, validação e dispatch por onde passa uma requisição real:

```lua
local res = app:test():post("/users", { body = { email = "x@y.z" } })
assert.equal(422, res.status)
assert.equal("required", res.body.fields["body.name"])
```

A suíte inteira roda em cerca de dois segundos, a maior parte dos quais é sleep
proposital nos testes de deadline.

---

## Executando os exemplos

Os exemplos precisam de um banco de dados:

```sh
docker run -d --name akkar-pg \
  -e POSTGRES_PASSWORD=akkar -e POSTGRES_DB=akkar \
  -p 55432:5432 postgres:16-alpine
docker run -d --name akkar-redis -p 6379:6379 redis:7-alpine

docker exec -i akkar-pg psql -U postgres -d akkar <<'SQL'
create table if not exists users (
  id serial primary key, name text not null, email text);
insert into users (name, email) values
  ('ada','ada@example.com'), ('alan','alan@example.com');
SQL

PORT=8099 lua5.4 examples/crud.lua
```

## Documentação

**Aprendendo o akkar**

| | |
|---|---|
| [`docs/pt-BR/guide/`](docs/pt-BR/guide/) | treze páginas para quem é novo em backends, em ordem |
| [`docs/pt-BR/sql/`](docs/pt-BR/sql/) | SQL e migrations, do zero até um schema que muda |
| [`docs/pt-BR/recipes/`](docs/pt-BR/recipes/) | dezenove tarefas, uma página cada |
| [`docs/pt-BR/reference/`](docs/pt-BR/reference/) | todo módulo, todo símbolo |
| [`docs/pt-BR/why/`](docs/pt-BR/why/) | as decisões, com as alternativas ao lado |
| [`examples/crud.lua`](examples/crud.lua) | dez cenários contra um Postgres de verdade |

**Fazendo deploy e operando**

| | |
|---|---|
| [`docs/DEPLOY.md`](docs/DEPLOY.md) | Railway, Docker, e o que quebra em um container scratch |
| [`docs/RUNTIME.md`](docs/RUNTIME.md) | `akkar build`, e o que ainda precisa ser feito à mão |
| [`docs/pt-BR/reference/cli.md`](docs/pt-BR/reference/cli.md) | os oito comandos |

**O que é medido, e o que não é**

| | |
|---|---|
| [`bench/study/RESULTS.md`](bench/study/RESULTS.md) | contra Gin e FastAPI, saturação, um soak de oito horas |
| [`bench/study/WHERE-THE-GAP-IS.md`](bench/study/WHERE-THE-GAP-IS.md) | a diferença atribuída: cqueues 11%, lua-http 46%, akkar 43% |
| [`bench/driver/RESULTS.md`](bench/driver/RESULTS.md) | pgmoon contra o driver em C, isolado e via HTTP |
| [`bench/driver/ANOMALY.md`](bench/driver/ANOMALY.md) | quatro experimentos, dois dos quais refutaram uma hipótese |
| [`docs/PERFORMANCE-STUDY.md`](docs/PERFORMANCE-STUDY.md) | dez descobertas, incluindo as que estavam erradas |
| [`docs/UNKNOWNS.md`](docs/UNKNOWNS.md) | **o que ainda ninguém investigou** |

**Para onde caminha**

| | |
|---|---|
| [`docs/RUNTIME-1.0.md`](docs/RUNTIME-1.0.md) | o que continua em Lua, o que merece C, o que sai junto |
| [`docs/PORT-FINDINGS.md`](docs/PORT-FINDINGS.md) | nove defeitos que um serviço real encontrou, e como |
| [`docs/HANDOFF.md`](docs/HANDOFF.md) | onde as coisas estão, e o que fazer a seguir |
| [`docs/PLAN.md`](docs/PLAN.md) | a escada verificada, os invariantes, os marcos |
| [`docs/BACKLOG.md`](docs/BACKLOG.md) | o que foi feito, o próximo passo, e o que deliberadamente não foi construído |
| [`types/`](types/) | declarações Teal, checadas a cada execução de teste |
## Padrões seguros

`app:run()` sem argumentos já vem pronto para produção. A configuração
só entra em cena quando você discorda do padrão.

| Padrão | Valor | Como sobrescrever |
|---|---|---|
| Limite do corpo da requisição | 1 MB | `app:run { body_limit = 5 * 1024 * 1024 }` |
| Prazo da requisição | 30 s | `app:run { timeout = 5 }` |
| Tamanho do pool de conexões | 10 | `db.connect { pool_size = 25 }` |
| Tempo de tolerância no desligamento | 10 s | `app:run { shutdown_grace = 30 }` |
| Timeout de statement | não definido | `db.connect { statement_timeout = 5 }` |
| Requisições concorrentes | a partir de `ulimit -n` | `app:run { max_concurrent = 500 }` |
| Proxies confiáveis | nenhum | `app:run { trusted_proxies = { "10.0.0.0/8" } }` |

**`req.ip` é o peer do socket, não um cabeçalho.** `X-Forwarded-For` é uma
string que o cliente digitou, e o akkar só acredita nela quando a conexão veio
de um proxy que a aplicação nomeou em `trusted_proxies`, e então percorre a
cadeia a partir da *direita*, passando por cada salto confiável, porque a
entrada mais à esquerda é o que quer que o cliente tenha escolhido enviar. Um
endereço que não pode ser interpretado nunca é confiado, então a falha ocorre
fechada.

**A concorrência é limitada por descritores de arquivo, e o limite é
declarado.** Cada requisição em andamento mantém um controlador `cqueues`
pelo seu prazo, e um controlador custa exatamente dois descritores, medidos em
1.030 descritores para 512 requisições concorrentes. Contra o `ulimit -n 1024`
comum, isso vira uma parede em torno de 500 por processo, e atingi-la não é
uma falha limpa: o `accept` começa a falhar e o processo entra em pane. Por
isso o akkar lê o limite na inicialização e diz ao lua-http para parar de
aceitar antes de chegar lá, o que transforma colapso em pressão de retorno
(backpressure). Lento é um estado em que um servidor pode estar; sem
descritores não é.

**O prazo faz o akkar parar de esperar; ele não faz o Postgres parar de
trabalhar.** O servidor só percebe que um cliente foi embora quando tenta
escrever de novo, e uma query que não produz saída até terminar pode não
tentar por minutos, então sob carga um timeout pode deixar o banco de dados
mais ocupado do que se não houvesse timeout nenhum. Configure o
`statement_timeout` para corresponder ao prazo da requisição e o servidor
também o aplica. O akkar pergunta uma vez na inicialização e avisa se existe
um prazo sem um `statement_timeout`; isso não vem ligado por padrão porque
ativá-lo silenciosamente cancelaria a migração de alguém.

As capabilities configuradas são verificadas contra seus contratos na
inicialização, então um adaptador mal configurado falha na inicialização em
vez de na primeira requisição que o toca. Isso significa que **o servidor se
recusa a iniciar quando o banco de dados está inacessível**, o que é correto
para um serviço em que toda rota precisa dele e errado para um que deveria
subir degradado, então `app:run { check_capabilities = false }` permite optar
por sair desse comportamento. As capabilities são adquiridas no primeiro uso,
então uma rota que nunca consulta o banco não toma nenhuma conexão e continua
respondendo mesmo com o banco de dados fora do ar.

Os sinais são opt-in, porque uma biblioteca que instala handlers pelas costas
da aplicação entra em conflito com o que mais o processo estiver fazendo:

```lua
app:handle_signals()      -- SIGTERM e SIGINT chamam app:stop()
app:run()
```

Um corpo grande demais é rejeitado com `413` antes de ser armazenado em
buffer, tanto quando `Content-Length` o declara quanto quando um corpo em
chunks simplesmente continua chegando. Uma requisição que ultrapassa seu prazo
responde `503`.

O prazo é cooperativo: ele dispara enquanto o handler está cedendo controle
(yielding) em uma operação de I/O. Um handler queimando CPU em um loop
apertado não é interrompido por ele. É isso que o watchdog reporta em vez
disso. As duas coisas cobrem falhas diferentes, de propósito.

A arbitragem de timeout segue uma regra: **o vencedor é decidido pelo primeiro
evento que arbitra, e um evento tardio nunca o derruba.** Um handler que
termina em 4,99 s contra um prazo de 5 s foi concluído, e nunca é reportado
como timeout.
## Consultas que um tenant não consegue escapar

Dois dos invariantes do akkar são sobre o banco de dados, e ambos funcionam do mesmo jeito que o resto: o erro não é desencorajado, ele é indisponível.

```lua
local sql = require "akkar.sql"

app:get("/documents", { query = { sort = "string?" } }, function(req)
  local db = req.db:scope("project_id", req.user.project_id)

  local q = sql.select("id, title"):from "documents"
  if req.query.sort then
    q:order_by(req.query.sort, { "id", "title", "created_at" })
  end

  return db:many(q:limit(50))
end)
```

**Um valor nunca pode virar SQL.** `?` marca um valor; a numeração em
`$1, $2` acontece uma única vez, na montagem, então condições adicionadas em
lugares diferentes se compõem sem que ninguém precise rastrear índices, e é
justamente por isso que as pessoas desistem e concatenam. Não existe
`where_raw`; uma válvula de escape é por onde a injeção passa.

**Um nome de coluna não é um valor**, porque o Postgres não tem placeholder
para isso. Então ordenar por um campo fornecido pelo cliente é verificado
contra uma lista que a rota declara: o padrão rejeita uma string forjada, e a
lista rejeita uma coluna real que a rota nunca quis expor.

**Um handle com escopo recusa SQL bruto.** Uma string não pode ser escopada
sem ser parseada, então o `db` acima recebe uma query e aplica o
`project_id` por conta própria. A instrução sem escopo nunca chega a ser
montada. Um insert sobrescreve um `project_id` enviado pelo cliente, um id de
tenant `nil` levanta erro em vez de casar com todas as linhas, e uma
transação entrega ao closure o handle já escopado, de modo que nada dentro
dela consegue ultrapassar esse limite.

Cruzar tenants é trabalho de verdade, então é possível, mas precisa ser dito
em voz alta, o que torna `grep -rn ':unscoped()'` a lista completa:

```lua
req.db:unscoped():many "select count(*) from documents"
```

Da mesma forma, um `UPDATE` ou `DELETE` sem `WHERE` é recusado até você
chamar `:all_rows()`. Essa forma é legítima em uma migration e quase nunca em
um handler.
## Jobs que sobrevivem a falhas

As tentativas automáticas ficam **desativadas até você pedi-las**, a mesma posição que o antigo comportamento de "registrar e descartar" defendia: uma política de repetição que ninguém escolheu esconde a falha e repete quaisquer efeitos colaterais que já aconteceram. A correção foi tornar a escolha explícita, não deixar o recurso de fora.

```lua
local queue = jobs.new(store, "email", {
  retries = 3,                       -- tentativas depois da primeira
  backoff = { first = 60, factor = 2, max = 4 * 3600 },  -- 60s, 120s, 240s ... limitado a quatro horas
})

queue:push("charge", { order = 41 }, { id = "charge:order:41" })  -- uma única vez
queue:push("digest", { user = 7 }, { delay = 3600 })              -- daqui a uma hora
```

O backoff usa **jitter completo** por padrão: sem ele, cem jobs que falharam contra um banco de dados recém-restabelecido tentariam novamente no mesmo segundo e o derrubariam outra vez.

O que falha em definitivo é guardado em vez de descartado, com um limite para que a fila de mensagens mortas não se transforme em um vazamento de memória com nome respeitável, e pode ser lido com `queue:dead_letters()`. Um job sem handler registrado segue o mesmo caminho. Isso normalmente significa que há um deploy em andamento, e descartá-lo perderia um trabalho que seria executado quando o deploy terminasse.

O contrato do armazenamento continua com três métodos; agendamento, reivindicação, consulta e limpeza são opcionais. Pedir uma política de repetição, um atraso ou uma chave de idempotência que o armazenamento não consegue cumprir é **um erro no momento da chamada**, nunca um recurso que silenciosamente não faz nada.
## `akkar doctor`

A pergunta que realmente paralisa um projeto Lua não é "meu código está certo?", mas **"esta combinação de bibliotecas desta máquina funciona?"**. Este projeto pagou esse preço três vezes antes de escrever qualquer código do framework, e cada ocorrência consumiu uma tarde:

- O `pgmoon` exige `mime`, do luasocket, **sem declarar essa dependência**. Uma instalação limpa morre com um traceback de `require` que cita um módulo que ninguém pediu.
- O `cqueues` fixa exatamente `lua == 5.4` e não recebe uma versão nova desde 2020.
- O `luaossl` é compilado com o OpenSSL 3 exibindo avisos de obsolescência que parecem falhas, mas não são.

```sh
akkar doctor                     # o que está instalado e o que vai causar problemas
akkar doctor app.lua             # mais a configuração desta aplicação
akkar doctor app.lua --json      # para algo que será processado por outro programa
akkar doctor app.lua --no-probe  # sem tocar no banco de dados
```

`app.lua` pode ser qualquer arquivo que retorne `app`, ou `app, config`, a mesma tabela aceita por `app:run{}`.

Ele informa o runtime e cada biblioteca com a versão **declarada pela própria biblioteca** (nunca deduzida pelo nome de um diretório), a quantidade de rotas em mounts e hosts, as rotas que nunca podem corresponder, os limites realmente ativos em forma de números e se cada capacidade configurada cumpre seu contrato.

**Um médico que dá alarmes falsos acaba ignorado**, então um achado pertence a uma de três categorias, e elas não são intercambiáveis:

| | |
|---|---|
| `FAIL` | quebrado agora. **Código de saída 1**, para que uma etapa do deploy possa bloqueá-lo |
| `warn` | funciona hoje, mas vai causar problemas. Código de saída 0 |
| `ok` | verificado e correto, exibido para deixar visível a ausência de uma verificação |

A ausência de uma biblioteca opcional é um aviso; "luaossl não está instalado" não deve impedir um serviço que usa HTTP sem TLS. Um banco de dados declarado pela aplicação mas inacessível é uma falha, porque o servidor já se recusa a iniciar nesse estado. Tratá-lo como aviso faria o doctor discordar do framework.

Rotas duplicadas não são verificadas: elas já causam uma falha na inicialização que cita os dois locais. O caso verificado é aquele que nenhuma invariante detecta: `/users/:id` e `/users/:name` são compiladas para o mesmo padrão, portanto a segunda nunca pode corresponder.
## Recusar rapidamente em vez de aceitar lentamente

O estudo mediu `/users/42` em quatro configurações, mudando apenas quanta concorrência era oferecida a um pool fixo:

```
60 pool conns,  50 clients   10,933 req/s   p99    6.79ms
60 pool conns, 100 clients   10,302 req/s   p99  396.09ms
180 pool conns, 100 clients  10,923 req/s   p99   13.58ms
```

O throughput permanece **constante**. Depois da capacidade máxima, aceitar mais trabalho não produz mais respostas. Produz uma fila, e a cauda da distribuição paga um preço sessenta vezes maior.

```lua
app:use(akkar.limit.concurrent { limit = 5 })          -- simultâneas, por cliente
app:use(akkar.limit.rate { per_second = 10, burst = 20 })
```

O limitador de concorrência é a consequência defendida por esses números e o recurso que a maioria dos frameworks não oferece. Um cliente fazendo dez requisições por segundo não é problema; o mesmo cliente mantendo cinquenta abertas contra um pool de vinte impõe aqueles 396 ms a todos os outros.

A decisão acontece **dentro do Redis**, em um script Lua enviado com `EVAL`. Cada limitador lê e depois escreve; entre a leitura e a escrita, outro processo poderia tomar a mesma decisão, criando um limite que não limita. O Redis executa o script de forma atômica, então a decisão acontece onde o estado está. Os timestamps também vêm do Redis, para que o relógio incorreto de um cliente não desloque a janela.

O slot é liberado em **todo** caminho de saída, seja um retorno normal, uma resposta lançada ou um erro do handler. Entradas mais antigas que um TTL são removidas na aquisição, então um handler que morre sem liberar seu slot custa um slot por um TTL, não para sempre. Um limitador que vaza slots é pior que nenhum limitador.

**O limite que precisa ser declarado:** essas garantias só são tão fortes quanto o armazenamento. Com `akkar.cache.memory`, os contadores pertencem a cada processo, então uma frota de seis processos aplica seis vezes o limite configurado. Isso é um padrão para desenvolvimento, não rate limiting. `akkar.limit.scriptable(cache)` informa qual dos dois você tem.
## A mesma requisição duas vezes, uma única cobrança

Um cliente não consegue distinguir "a requisição nunca chegou" de "a resposta nunca voltou", então ele tenta novamente e o cartão é cobrado duas vezes. Somente o servidor pode distinguir os casos, e apenas se guardar essa informação.

```lua
app:use(akkar.idempotency { ttl = 86400,
                            namespace = false })
```

```
POST /charges
Idempotency-Key: 8f14e45f-ea6e-4b3f-9c2a-1d2f3e4b5a60
```

Três dos quatro casos são os interessantes. Uma repetição **depois da conclusão** reproduz o status e o corpo armazenados, com `idempotent-replay: true` para que o cliente saiba que sua nova tentativa não fez nada novo. Uma repetição **enquanto a primeira ainda está em execução** recebe **409**. Não retornar nada é errado, e executar duas vezes é pior. **A mesma chave com um corpo diferente** recebe **422**, porque a chave é uma promessa sobre *qual* requisição é esta; reproduzir silenciosamente esconderia um bug do cliente justamente onde mais importa.

**Um handler que falha libera a chave** em vez de armazenar a falha. Guardar um 500 em cache impediria que a nova tentativa, que é o objetivo inteiro, pudesse funcionar. Somente respostas 2xx são lembradas.

**O que isto não é:** trata-se de deduplicação na entrada, não de um handler idempotente. Se o handler cobrar um cartão e depois cair antes de retornar, a cobrança aconteceu e nada aqui sabe disso. Isso exige usar por baixo desta chave a chave do próprio processador de pagamentos. E a garantia só é tão forte quanto o armazenamento: com `akkar.cache.memory`, ela vale por processo, o que não é deduplicação alguma.
## A escrita que desaparece

Dois clientes leem o mesmo registro. Ambos o editam. Ambos salvam. O segundo sobrescreve o primeiro e **nenhum erro é informado em lugar algum**. Os dois viram 200, e o trabalho de uma pessoa desapareceu, talvez descoberto semanas depois.

O HTTP oferece uma resposta para isso desde 1997, e quase ninguém a ativa.

```lua
app:use(akkar.etag { require_on = { "PUT", "PATCH" }, current = load_document })
```

```
GET /documents/7            ->  200, ETag: "a3f1c9..."
PUT /documents/7            ->  428   no If-Match, and this route demands one
PUT + If-Match: "stale"     ->  412   the resource moved since you read it
PUT + If-Match: "a3f1c9..." ->  200
```

**O 428 é a linha que separa um recurso de uma invariante.** Sem ele, um cliente que simplesmente esquece o cabeçalho entra em uma corrida silenciosa, e na prática o mecanismo se torna opcional. A precondição é verificada *antes* de o handler executar, então uma escrita recusada nunca chega ao banco de dados. Verificá-la depois significaria que a escrita aconteceu e, em seguida, o cliente foi informado de que não aconteceu.

`If-None-Match` oferece a metade barata: um cliente que já possui a versão atual recebe **304** e nenhum corpo.

**O limite:** um ETag derivado do corpo não é uma versão da linha. Duas edições que produzam o mesmo corpo são indistinguíveis, então A-depois-B-depois-A pode deixar passar uma escrita obsoleta. A forma forte usa uma coluna de versão comparada dentro da própria transação de escrita, e somente a aplicação sabe qual é essa coluna. Esta é a metade do transporte: correta, gratuita e muito melhor que o que quase toda API JSON tem hoje, que é nada.
## A fronteira, traçada de propósito

Cada linha abaixo é uma decisão com um motivo, e a maioria delas tem um número. Nada desta lista está esperando para ser descoberto por você em produção.

| | |
|---|---|
| Conexões Postgres no pool mantêm o estado da sessão, a menos que você peça uma limpeza | Um `SET search_path`, uma tabela temporária ou uma GUC de sessão sobrevive à devolução da conexão ao pool e chega à próxima aquisição. Medido. Isso **não** quebra `akkar.scope`, que isola reescrevendo a query e nunca toca no estado da sessão, portanto só afeta aplicações que isolam com `SET ROLE`, RLS ou um `search_path` por tenant. `db.connect { reset_on_release = true }` executa `DISCARD ALL` na devolução; fica desativado por padrão porque custa uma viagem de ida e volta (167 µs, 4,2% de uma query real) desnecessária para a maioria das aplicações |
| Sem HTTP/3 | HTTP/1.1 e HTTP/2 estão presentes; QUIC é um transporte UDP com seu próprio controle de congestionamento e integração TLS, e nem cqueues nem lua-http oferecem isso. Atrás de um proxy, não ter isso não custa nada, e é no proxy que o h3 costuma terminar |
| WebSocket não mantém capacidades entre mensagens | `ws:scope(fn)` é como um callback chega ao banco de dados, e essa cerimônia é deliberada: um slot do pool adquirido quando o socket abre ficaria ocupado até a aba do navegador fechar. A unidade de aquisição é uma mensagem, exatamente como uma requisição |
| HTTP/2 passa por fuzzing e testes de conformidade em dois lugares separados | `spec/h2_framing_spec.lua` lança 22 formatos hostis de frame contra um servidor real e exige que ele continue respondendo; a primeira execução encontrou uma negação de serviço de três bytes no lua-http upstream, corrigida na cópia incluída. Isso não estabelece conformidade h2, que é verificada separadamente por `bench/h2spec.sh` |
| Uploads ficam em buffer, não são transmitidos em streaming | o corpo multipart fica na memória sob o limite `body_limit` |
| `akkar.cache.memory` pertence a cada processo | dois processos têm dois caches, e a resposta do akkar para mais CPU é usar mais processos |
| Teal não confere schemas contra a saída do handler | schemas são valores em runtime; quem faz essa verificação é a validação |
| Busca linear para rotas dinâmicas | medido: 33 µs no pior caso com 50 rotas, contra cerca de 4000 µs para uma query. Reavalie depois de aproximadamente 500 rotas dinâmicas |
| Lua 5.5 funciona, mas você mesmo compila a stack | A suíte passa no 5.5 com **1814 testes passando e 0 falhas**, contra **1852** no 5.4. A diferença de 38 testes vem inteiramente das ferramentas: 32 pertencem ao driver em C e são ignorados porque `akkar/pq_native.so` é um único caminho disputado por duas ABIs Lua; os outros 6 são as declarações Teal, ignoradas porque `tl` não está instalado na árvore do 5.5. O que falta é empacotamento, não portabilidade: nenhuma distribuição fornece Lua 5.5 ainda; o makefile do `luaossl` não tem uma opção para 5.5 (o C compila sem erros em uma chamada de `cc`); e o `cqueues` precisa atualizar o `lua-compat-5.3` incluído para a v0.9. `docs/runtime/lua55-stack.sh` faz tudo isso em um prefixo; 5.4 continua sendo o padrão porque `luarocks install akkar` não consegue fazer esse trabalho |
| `akkar.vm` é um sandbox, não uma VM isolada | Lua 5.4 não consegue criar um estado separado a partir de Lua. É real dentro dos limites declarados; contra código hostil, use outro processo |
| Streaming mantém suas capacidades abertas | um cliente lento lendo uma exportação em streaming mantém um slot do pool durante todo o tempo da leitura |
| O caminho do banco de dados usa pgmoon **por padrão** | decodificar linhas no interpretador representa 55% de uma query de mil linhas. `akkar-pq` transfere esse trabalho, alcança 2,79x em mil linhas e é distribuído como um rock separado para que libpq continue opcional |
## Licença

MIT.
