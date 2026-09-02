# akkar.doctor

> **Português (Brasil)** | [Original em inglês](../../reference/doctor.md)

Verifica o que está instalado, com o que esta aplicação está configurada, e o que vai morder mais tarde. Os achados vêm em três níveis, e só `fail` muda o código de saída, então uma etapa de implantação pode travar nele.

**Quando você precisa dele.** Um clone recém-feito que não inicia, uma máquina cujas versões de rock você não confia, ou uma etapa de implantação que deveria recusar a subir uma aplicação cujo banco de dados não responde.

```lua no-run
local doctor = require "akkar.doctor"
```

## Conteúdo

- [A linha de comando](#a-linha-de-comando)
- [Níveis](#níveis)
- [doctor.check_app(app, config, report)](#doctorcheck_appapp-config-report)
- [doctor.check_capabilities(config, report)](#doctorcheck_capabilitiesconfig-report)
- [doctor.check_descriptors(report)](#doctorcheck_descriptorsreport)
- [doctor.check_environment(report)](#doctorcheck_environmentreport)
- [doctor.cli(options)](#doctorclioptions)
- [doctor.descriptor_finding(soft, hard)](#doctordescriptor_findingsoft-hard)
- [doctor.format(report)](#doctorformatreport)
- [doctor.new_report()](#doctornew_report)
- [doctor.report(app, config, options)](#doctorreportapp-config-options)
- [doctor.Report](#doctorreport)
- [Report](#report)
  - [report:add(level, area, title, detail, fix)](#reportaddlevel-area-title-detail-fix)
  - [report:count(level)](#reportcountlevel)
  - [report:fail(area, title, detail, fix)](#reportfailarea-title-detail-fix)
  - [report:healthy()](#reporthealthy)
  - [report:ok(area, title, detail)](#reportokarea-title-detail)
  - [report:warn(area, title, detail, fix)](#reportwarnarea-title-detail-fix)
- [Não está aqui](#não-está-aqui)

## A linha de comando

```sh
akkar doctor [app.lua] [--json] [--no-probe]
```

| argumento | significado |
|---|---|
| `app.lua` | um arquivo que retorna `app`, ou `app, config`. Sem ele, só o ambiente é verificado. |
| `--json` | um único objeto JSON na saída padrão em vez do relatório em texto |
| `--no-probe` | pula qualquer coisa que toque a rede, que é a verificação de capability |

Códigos de saída:

| código | significado |
|---|---|
| `0` | nada está quebrado. Avisos não mudam isso. |
| `1` | pelo menos um achado `fail` |
| `2` | um erro de uso: uma opção desconhecida, ou um arquivo que não carrega ou não retorna uma aplicação |

A saída em texto agrupa os achados por área, `fail` primeiro dentro de cada área, e termina com uma contagem e uma de duas frases:

```
15 ok, 1 warning(s), 1 failure(s)
something is broken; the lines marked FAIL are the ones to read
```

O objeto `--json` tem três chaves: `healthy` (booleano), `findings` (a lista, cada um com `level`, `area`, `title` e, opcionalmente, `detail` e `fix`), e `summary` (contagens de `ok`, `warn` e `fail`).

O arquivo que ele carrega é executado, então ele deve retornar a aplicação em vez de rodá-la:

```lua no-run
local akkar = require "akkar"

local app = akkar.new()
app:get("/health/live", function() return { status = "pass" } end)

return app, { reuseport = true, timeout = 5 }
```

## Níveis

| nível | significa | código de saída |
|---|---|---|
| `ok` | verificado, tudo certo. Mostrado para que a ausência de uma verificação fique visível. | 0 |
| `warn` | funciona hoje, vai morder. | 0 |
| `fail` | quebrado agora. | 1 |

Uma dependência opcional ausente é um aviso. Uma dependência opcional ausente da qual outra já instalada depende silenciosamente é uma falha, e o mesmo vale para uma capability declarada que não pode ser obtida, porque o servidor recusaria subir nesse estado de qualquer forma.

## doctor.check_app(app, config, report)

Adiciona achados sobre uma aplicação: quantas rotas ela tem (contando sub-aplicações e hosts montados), quais rotas nunca podem dar match, cada configuração cujo valor o runtime recusaria, e quais de `body_limit`, `timeout` e `shutdown_grace` estão em vigor, como números, com `configured` ou `default` ao lado de cada um.

Uma rota nunca pode dar match quando uma rota dinâmica anterior do mesmo método tem um padrão que a cobre. `/users/:id` seguido de `/users/:name` é o caso mais comum: elas compilam para o mesmo padrão e a segunda fica inalcançável.

`config` é a tabela que `app:run{}` receberia. `report` é opcional; um novo é criado quando está ausente.

**Retorna** o relatório.

**Adiciona um `fail`** com o título `not an akkar app` quando `app` não é o valor que `akkar.new()` retornou.

**Adiciona um `fail` por configuração cujo valor o runtime não consegue usar**, com a mensagem que o próprio `akkar.check_settings` produz — a mesma função que `app:run{}` chama, e que é exportada justamente para que um chamador que não pode vincular uma porta possa perguntar. Uma chamada por configuração, porque `check_settings` levanta um erro no primeiro valor que rejeita, e um relatório que nomeasse só o primeiro custaria uma segunda implantação:

```
FAIL  timeout is not a value the runtime can use
      app:run{}: timeout must be a number of seconds, or false for no deadline; got string "30"
```

**Adiciona um achado sobre o driver em C quando `AKKAR_DRIVER=pq`** — `ok` quando `akkar.pq` carrega, `warn` quando não carrega, porque `db.connect` levanta um erro só na primeira *conexão* em vez de no carregamento: uma recusa de subir com `check_capabilities` ligado, e um 500 no meio de uma execução com ele desligado.

Essa variável de ambiente é o único sinal de driver que esta verificação consegue ler. `driver = "pq"` é passado para `db.connect{}`, e o que chega em `check_app` é a factory que fechou sobre ele, então o nome não está na config e uma chave `driver` na config de execução não é uma alternativa, porque `app:run{}` rejeita qualquer opção que não conheça. Com `probe` ligado, o caso dentro da config ainda é capturado: obter a capability levanta a própria mensagem de instalação do rock, e isso já é um `fail`.

```lua
local akkar  = require "akkar"
local doctor = require "akkar.doctor"

local app = akkar.new()
app:get("/users/:id", function() return { ok = true } end)
app:get("/users/:name", function() return { ok = true } end)

local report = doctor.new_report()
doctor.check_app(app, { reuseport = true, timeout = 5 }, report)

for _, finding in ipairs(report.findings) do
  print(finding.level, finding.title)
end
```

```
ok	2 routes
warn	GET /users/:name can never match
ok	body_limit = 1048576 bytes
ok	timeout = 5 s
ok	shutdown_grace = 10 s
ok	reuseport is on
```

## doctor.check_capabilities(config, report)

Obtém cada capability declarada exatamente como uma requisição (request) faria, verifica se ela responde ao seu contrato, e a libera.

| capability | deve responder |
|---|---|
| `db` | `one`, `many`, `exec`, `transaction` |
| `cache` | `get`, `set`, `del` |

Uma capability ausente em `config` é reportada como `ok`, com uma nota de que handlers que a leem recebem uma guarda. Uma que levanta erro ao ser obtida é um `fail`, e o mesmo vale para uma que responde só parte do seu contrato.

Esta é a única parte que toca a rede, e a única que pode travar. `doctor.report(app, config, { probe = false })` pula essa etapa.

**Retorna** o relatório.

```lua
local doctor = require "akkar.doctor"

-- Uma capability de cache que responde `get` e `set` mas não `del`.
local report = doctor.new_report()
doctor.check_capabilities({ cache = { get = function() end, set = function() end } },
                          report)

print(report:healthy())            --> false
for _, finding in ipairs(report.findings) do
  print(finding.level, finding.title, finding.detail)
end
```

## doctor.check_descriptors(report)

Adiciona exatamente um achado, na área `descriptors`, sobre os limites de descritores sob os quais este processo está rodando e o `max_concurrent` que o akkar deriva deles.

Este é o teto que decide quantas requisições o processo consegue segurar de uma vez, e nada tinha impresso isso antes. `akkar.descriptor_ceiling` limita `max_concurrent` a 66% do limite **soft**, um descritor por requisição em andamento, então o `ulimit -n 1024` comum resulta em 675, um número que ninguém escolheu, e que é toda a capacidade do processo, incluindo pools e arquivos de log.

Nunca um `fail`: um limite de descritores é um fato operacional, não uma instalação quebrada, e um gate de implantação não deveria recusar um serviço por causa dele.

**Retorna** o relatório.

## doctor.check_environment(report)

Adiciona achados sobre a máquina: a versão do Lua, se `math.type` existe, cada rock obrigatório, cada rock opcional, a versão do OpenSSL por trás do `luaossl`, decodificada de seu inteiro compactado, e os limites de descritores ([`check_descriptors`](#doctorcheck_descriptorsreport)).

Obrigatórios: `cqueues`, `lua-http`, `lua-cjson`. Ausência é um `fail`.

Opcionais: `pgmoon`, `luasocket` (para `mime`), `luaossl`, `tl`, `busted`, `akkar-pq`. Ausência é um `warn`, exceto que `mime` ausente enquanto `pgmoon` está instalado é um `fail`: a primeira query morreria com um traceback de `require` nomeando um módulo que ninguém pediu.

`akkar-pq` é duas metades e só uma delas vem com o akkar: `akkar/pq.lua` está sempre presente, `pq_native.so` é um rock separado. Então suas duas falhas são diferenciadas em vez de ambas serem chamadas de "não instalado":

| o que aconteceu | reportado como |
|---|---|
| `pq_native.so` não foi compilado | `warn akkar-pq` — a metade em Lua está aqui, `db.connect { driver = "pq" }` levantaria um erro na primeira conexão |
| `pq_native.so` foi compilado para um Lua diferente | `warn akkar-pq is built for the WRONG Lua`, com a própria mensagem da verificação de marcador |

O segundo caso importa porque `akkar/pq.lua` recusa esse `.so` no carregamento em vez de causar um segfault na primeira chamada, e dizer a alguém para instalar um rock que já tem, para o Lua que já roda, desperdiça a tarde que este arquivo existe para poupar.

Uma versão é lida do próprio campo `VERSION`, `_VERSION`, `version` ou `_version` do módulo, e reportada como `version not declared` onde não há nenhum. Nada é adivinhado a partir de um nome de diretório.

**Retorna** o relatório.

## doctor.cli(options)

Executa o exame, imprime, e encerra.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `app` | app | nenhum | passado para `check_app` |
| `config` | tabela | nenhum | passado para `check_app` e `check_capabilities` |
| `json` | booleano | `false` | imprime um único objeto JSON em vez do relatório em texto |
| `probe` | booleano | `true` | `false` pula `check_capabilities` |
| `exit` | booleano | `true` | `false` retorna o relatório em vez de chamar `os.exit` |

**Retorna** o relatório, mas só quando `exit = false`. Do contrário não retorna: chama `os.exit(0)` quando está saudável e `os.exit(1)` quando não está.

## doctor.descriptor_finding(soft, hard)

A regra que [`check_descriptors`](#doctorcheck_descriptorsreport) aplica, como uma função pura dos dois números vindos de `/proc/self/limits`.

**Retorna** `level, title, detail, fix`.

| dado | nível | diz |
|---|---|---|
| `soft >= 4096` | `ok` | o teto derivado, e que uma requisição em andamento segura um descritor |
| `soft < 4096` | `warn` | que o limite soft é toda a capacidade do processo, e as três formas de elevá-lo: `ulimit -n`, `LimitNOFILE=` em uma unit do systemd, `--ulimit nofile=` em um container |
| `soft = nil` | `warn` | que **o akkar também não deriva nenhum teto** — `akkar.descriptor_limits` retorna nil fora do Linux, então `max_concurrent` nunca é definido e o servidor aceita conexões até o kernel recusar. `docs/PLATFORMS.md` carrega isso como uma decisão em aberto |

`hard` é usado para uma coisa: se `ulimit -n` consegue elevar o limite soft sem root, o que decide se a correção é uma linha de shell ou um arquivo de unit.

Separado da leitura porque um teste em uma máquina cujo limite soft é 1.048.576 nunca consegue provocar o aviso que importa. Os números entram como parâmetro, então a regra é testável em qualquer limite:

```lua
local doctor = require "akkar.doctor"

-- O que uma máquina no `ulimit -n 1024` de costume receberia como aviso.
local level, title, _, fix = doctor.descriptor_finding(1024, 1048576)
print(level, title)
print(fix)
```

```
warn	max_concurrent 675, from a soft limit of 1024
`ulimit -n 8192` in the shell that starts it; `LimitNOFILE=8192` in the systemd unit; `--ulimit nofile=8192:8192` on the container
```

## doctor.format(report)

Renderiza um relatório como texto. Os achados são agrupados por área na ordem em que as áreas apareceram primeiro, e ordenados como `fail`, depois `warn`, depois `ok` dentro de cada área. Achados no mesmo nível dentro de uma área não têm ordem definida.

**Retorna** uma string, começando com uma linha em branco e terminando com a frase de veredito.

```lua
local doctor = require "akkar.doctor"

local report = doctor.new_report()
report:ok("boot", "migrations applied", "3 files")
report:warn("boot", "no backup configured", "a restore has never been tested",
            "point BACKUP_URL at a bucket")
report:fail("boot", "queue unreachable", "connection refused on 6379")

print(report:count "ok", report:count "warn", report:count "fail")   --> 1  1  1
print(report:healthy())                                              --> false
print(doctor.format(report))
```

## doctor.new_report()

Um relatório vazio, para adicionar achados próprios ou para passar a várias verificações em sequência.

**Retorna** um relatório.

## doctor.report(app, config, options)

O exame completo. Roda `check_environment` sempre, `check_app` quando `app` é fornecido, e `check_capabilities` quando `config` é fornecido e `options.probe` não é `false`.

Sem nenhum dos dois argumentos, ele verifica o ambiente, que é o que um clone recém-feito quer saber primeiro.

**Retorna** um relatório.

```lua
local doctor = require "akkar.doctor"

local report = doctor.report()

print(report:count "fail" == 0)   --> true when nothing is broken
print(report:healthy())           --> the same question
print(doctor.format(report))
```

## doctor.Report

A metatable que todo relatório compartilha.

## Report

Um relatório contém `findings`, uma lista na ordem em que foram adicionados. Cada achado é uma tabela com `level`, `area`, `title`, e opcionalmente `detail` e `fix`.

### report:add(level, area, title, detail, fix)

Adiciona um achado. `level` é `"ok"`, `"warn"` ou `"fail"`. `area` é o cabeçalho sob o qual ele é agrupado. `fix` é a linha impressa depois de `fix:`.

O nível não é validado. Um nível fora dos três é renderizado com um marcador `nil` e não é contado por nada.

**Retorna** o relatório, para que as chamadas se encadeiem.

### report:count(level)

Quantos achados estão naquele nível.

**Retorna** um número.

### report:fail(area, title, detail, fix)

`report:add("fail", ...)`.

**Retorna** o relatório.

### report:healthy()

Se o relatório não contém nenhum achado `fail`. É isso que decide o código de saída.

**Retorna** `true` ou `false`.

### report:ok(area, title, detail)

`report:add("ok", ...)`. Não há `fix` em um achado ok.

**Retorna** o relatório.

### report:warn(area, title, detail, fix)

`report:add("warn", ...)`.

**Retorna** o relatório.

## Não está aqui

- **Consertar qualquer coisa.** Todo achado carrega uma linha `fix` para um humano. Nada é instalado, escrito ou reiniciado.
- **Quais capabilities as rotas realmente usam.** Deliberadamente não tentado: `debug.getupvalue` não consegue enxergar um `req.db` dentro do corpo de uma função, e avisar sobre um palpite é pior do que não dizer nada.
- **Verificar suas próprias dependências.** A lista de opcionais é fixa e é sobre a própria stack do akkar.
- **Uma verificação repetida ou agendada.** Esta é uma execução única. O endpoint que responde à mesma pergunta continuamente é o [akkar.health](health.md).
- **Qualquer coisa sobre um servidor em execução.** Ele examina o ambiente de um processo e um valor de aplicação, não uma porta escutando.

## Veja também

- [akkar.health](health.md) para a versão contínua da pergunta sobre disponibilidade
- [akkar.config](config.md) para transformar uma configuração ausente em uma falha de inicialização em vez de algo que um doctor precisa encontrar
- o código-fonte do módulo, `akkar/doctor.lua`, para as três armadilhas que este arquivo foi escrito para deixar de custar uma tarde cada uma
