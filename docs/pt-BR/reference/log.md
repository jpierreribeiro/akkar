# akkar.log

> **Português (Brasil)** | [Original em inglês](../../reference/log.md)

Registro estruturado em dois formatos: um objeto JSON por linha para um coletor, ou texto alinhado para um terminal. Um logger pode carregar campos vinculados, e é assim que `req.log` correlaciona todas as linhas de uma requisição sem que o handler precise passar nada.

**Quando você precisa disso.** Você quer seu próprio logger para código que roda fora de uma requisição (um worker, uma migração, uma checagem no momento do boot), ou quer substituir aquele pelo qual o próprio akkar escreve suas linhas, passando `app:run { log = ... }`.

```lua no-run
local log = require "akkar.log"
```

## Conteúdo

- [log.LEVELS](#loglevels)
- [log.Logger](#loglogger)
- [log.new(options)](#lognewoptions)
- [log.otlp(entries, resource)](#logotlpentries-resource)
- [log.record(entry)](#logrecordentry)
- [log.SEVERITY](#logseverity)
- [Logger](#logger)
  - [logger:debug(message, fields)](#loggerdebugmessage-fields)
  - [logger:error(message, fields)](#loggererrormessage-fields)
  - [logger:info(message, fields)](#loggerinfomessage-fields)
  - [logger:log(level, message, fields)](#loggerloglevel-message-fields)
  - [logger:warn(message, fields)](#loggerwarnmessage-fields)
  - [logger:with(fields)](#loggerwithfields)
- [O que não está aqui](#o-que-não-está-aqui)

## log.LEVELS

Os nomes dos níveis e suas severidades numéricas, como uma tabela. Uma mensagem é escrita quando sua própria severidade não é menor que a do logger.

| nome | severidade |
|---|---|
| `debug` | 10 |
| `info` | 20 |
| `warn` | 30 |
| `error` | 40 |

## log.Logger

A metatable que todo logger compartilha. Exportada para que um teste possa verificar se um valor é um logger, e para que quem a chama possa adicionar um método a todo logger do processo. Nada no akkar exige que você mexa nela.

## log.new(options)

Constrói um logger. Todos os campos são opcionais.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `level` | string | `"info"` | um entre `debug`, `info`, `warn`, `error`. Linhas abaixo dele não são escritas nem formatadas. |
| `format` | string | `"text"` | `"json"` escreve um objeto JSON por linha. Qualquer outro valor escreve texto. |
| `sink` | function | escreve em stderr | chamada com uma string por linha, quebra de linha incluída. |
| `exporter` | table | nenhum | qualquer coisa com um método `record(entry)`, que recebe toda entrada depois que o sink a escreveu; na prática o exportador de logs de [akkar.otlp](otlp.md), e `pipeline:logger` o define por você. Carregado para todo logger que `:with` deriva. |

**Retorna** um logger.

**Levanta** `akkar.log: unknown level '<name>'; use debug, info, warn or error` quando `level` não é um dos quatro, e `akkar.log: exporter needs a record(entry) method; ...` quando `exporter` não tem um. `format` não é validado: um valor que não seja `"json"` produz saída em texto.

```lua
local log = require "akkar.log"

local logger = log.new { level = "info", sink = function(line) io.write(line) end }

logger:info("server started", { port = 3000 })
logger:debug("not printed, below the level")
```

```
INFO  server started port=3000
```

## log.otlp(entries, resource)

Constrói o `ExportLogsServiceRequest` em JSON OTLP/HTTP para uma lista de entradas, cada uma como `log.record` a constrói. `resource` é uma table de atributos de recurso. Este é o `encode` que [akkar.otlp](otlp.md) dá ao seu exportador de logs.

**Retorna** uma table.

## log.record(entry)

Uma entrada -- a table que `logger:log` constrói, com `level`, `message`, `time` e todo campo -- como um `LogRecord` do OTLP. `severityNumber` e `severityText` vêm de `log.SEVERITY`, `body` é a mensagem, `time` vira `timeUnixNano`, e todo outro campo é um atributo. Um `trace_id` de 32 caracteres hexadecimais e um `span_id` de 16 são elevados ao registro como `traceId` e `spanId`; um valor de outro formato permanece atributo.

**Retorna** uma table.

```lua
local log = require "akkar.log"

local record = log.record {
  level = "warn", message = "slow query", time = 1755000000,
  ms = 250, trace_id = "4bf92f3577b34da6a3ce929d0e0e4736",
}
print(record.severityNumber, record.severityText)   --> 13 WARN
print(record.body.stringValue)                      --> slow query
print(record.timeUnixNano)                          --> 1755000000000000000
print(record.attributes[1].key, record.attributes[1].value.intValue)   --> ms 250
print(record.traceId)                               --> 4bf92f3577b34da6a3ce929d0e0e4736
```

## log.SEVERITY

O número de severidade do OpenTelemetry para cada nível, do modelo de dados de logs: `debug = 5`, `info = 9`, `warn = 13`, `error = 17`. Cada nível nomeado possui uma faixa de quatro e o akkar tem uma gradação por nível, então cada um mapeia para o primeiro da sua faixa.

## Logger

### logger:debug(message, fields)

Escreve em `debug`. Mesmo formato de `logger:info`.

### logger:error(message, fields)

Escreve em `error`. Mesmo formato de `logger:info`.

### logger:info(message, fields)

Escreve uma linha em `info`. `message` é uma string. `fields` é uma tabela opcional de chaves extras, mesclada por cima dos campos vinculados do logger.

Um valor de campo que seja string, número ou booleano é escrito como está. Uma tabela é escrita recursivamente. Qualquer outra coisa (uma function, um userdata) passa por `tostring` em vez de ser descartada.

No formato texto os campos são ordenados por chave e o timestamp não é impresso. No formato JSON a entrada carrega `level`, `message` e `time` (segundos desde a epoch, vindos de `akkar.time`) junto com os campos.

**Retorna** nada.

```lua
local log = require "akkar.log"

local logger = log.new { format = "json", sink = function(line) io.write(line) end }
logger:info("payment taken", { account_id = 7, amount = 12.5 })
```

```
{"amount":12.5,"level":"info","time":1786890561,"account_id":7,"message":"payment taken"}
```

### logger:log(level, message, fields)

O método que os quatro nomeados chamam. `level` é um nome de nível.

**Retorna** nada.

**Levanta** `attempt to compare nil with number` quando `level` não é um nome conhecido. Diferente de `log.new`, esse caminho não verifica o nome antes, então prefira os métodos nomeados.

### logger:warn(message, fields)

Escreve em `warn`. Mesmo formato de `logger:info`.

### logger:with(fields)

Retorna um novo logger que escreve `fields` em toda linha, por cima do que ele já carregava. O logger original permanece inalterado, e level, format e sink são copiados.

É isso que o próprio akkar faz por requisição: `req.log` é o logger configurado com `request_id` vinculado àquela requisição.

**Retorna** um logger.

```lua
local log = require "akkar.log"

local logger = log.new { sink = function(line) io.write(line) end }
local bound = logger:with { request_id = "1a2b3c" }

bound:warn("slow query", { took_ms = 120 })
bound:with({ table_name = "tasks" }):error("query failed")
```

```
WARN  slow query request_id=1a2b3c took_ms=120
ERROR query failed request_id=1a2b3c table_name=tasks
```

## O que não está aqui

- **Rotação de arquivo de log.** O sink é uma function, então escrever em um arquivo, em um socket ou em um handle rotativo fica por conta de quem chama arranjar.
- **Um logger global.** Não existe um `log.info` no nível do módulo. Um logger é um valor, e o que o akkar entrega a um handler é `req.log`.
- **Redação.** Um campo é escrito como é dado. Um valor envolvido por `akkar.config.secret` é seguro (ele não guarda nada), mas uma string simples guardando uma senha é escrita por completo.
- **Amostragem ou limitação de taxa de linhas.** Toda linha acima do nível é escrita.
- **Exportação daqui.** `exporter` é um acréscimo a uma fila que outra coisa drena; [akkar.otlp](otlp.md) é essa outra coisa.

## Veja também

- [akkar](akkar.md) para `app:run { log = ... }`, que substitui o logger pelo qual o akkar escreve suas próprias linhas, e para `req.log`
- [akkar.config](config.md) para `config:redacted()`, o valor a ser logado quando se quer a palavra `[redacted]` na linha
- [akkar.otlp](otlp.md) para linhas exportadas a um collector OpenTelemetry
- o código-fonte do módulo, `akkar/log.lua`, para entender por que um float de valor inteiro é impresso sem sua parte fracionária
