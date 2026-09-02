# akkar.health

> **Português (Brasil)** | [Original em inglês](../../reference/health.md)

Sondas de vivacidade (liveness) e prontidão (readiness). `live()` responde a partir de dois números e não toca em nada; `ready()` executa as verificações que você registrou, cada uma com seu próprio timeout, e armazena o resultado em cache.

**Quando você precisa disso.** Uma plataforma de contêineres faz duas perguntas diferentes em um cronograma: reinicie este processo, e direcione tráfego para este processo. Responder as duas a partir do mesmo endpoint é como um banco de dados lento consegue derrubar uma frota inteira.

```lua no-run
local health = require "akkar.health"
```

## Conteúdo

- [health.DEFAULT_CACHE](#healthdefault_cache)
- [health.DEFAULT_TIMEOUT](#healthdefault_timeout)
- [health.Health](#healthhealth)
- [health.new(options)](#healthnewoptions)
- [O que uma verificação retorna](#o-que-uma-verificação-retorna)
- [Health](#health)
  - [probe:invalidate()](#probeinvalidate)
  - [probe:live()](#probelive)
  - [probe:ready(options)](#probereadyoptions)
- [Servindo os dois endpoints](#servindo-os-dois-endpoints)
- [O que não está aqui](#o-que-não-está-aqui)

## health.DEFAULT_CACHE

`5`. O `cache` padrão, em segundos.

## health.DEFAULT_TIMEOUT

`2`. O `timeout` padrão, em segundos, aplicado por verificação.

## health.Health

A metatable que toda sonda compartilha. Exportada para um teste que queira identificar uma. Nada no akkar exige que você a manipule.

## health.new(options)

Constrói uma sonda.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `checks` | table | `{}` | nome para função. Lida somente por `ready()`. |
| `timeout` | number | `2` | segundos que uma verificação pode levar. `0` ou `nil` executa a verificação sem prazo. |
| `cache` | number | `5` | segundos que um resultado de prontidão é reaproveitado, falhas inclusive. `0` desativa o cache. |

**Retorna** uma sonda.

**Lança**

- `akkar.health: unknown option '<key>'; use checks, timeout or cache`
- `akkar.health: check '<name>' is a <type>, not a function`

```lua
local health = require "akkar.health"

local probe = health.new {
  checks = {
    disk  = function() return true end,
    queue = function() return false, "backlog is 12000 deep" end,
  },
  timeout = 1,
  cache   = 5,
}

local ready = probe:ready()
print(ready.status)                    --> fail
print(ready.checks.disk.status)        --> pass
print(ready.checks.queue.status)       --> fail
print(ready.checks.queue.reason)       --> backlog is 12000 deep
print(probe:live().status)             --> pass
```

## O que uma verificação retorna

Uma verificação é uma função sem argumentos.

| o que retorna | resultado |
|---|---|
| `true` | pass |
| `false` ou `nil`, mais uma string de motivo | fail, com `reason` definido |
| `false` ou `nil`, sem motivo | fail, sem o campo `reason` |
| ela lança um erro | fail, com a primeira linha do erro como `reason` |
| ela não retorna dentro do `timeout` | fail, `reason = "timed out after <n>s"`, e `timed_out = true` |

Uma verificação que lança um erro não derruba a sonda: o endpoint que existe para dizer qual dependência está com problema não pode responder 500 ele mesmo.

O timeout é cooperativo. Uma verificação que espera por I/O é interrompida no prazo; uma verificação que consome CPU sem ceder o controle (yield) não é interrompida por nada. Uma verificação que estoura o prazo vaza seu agendador até o coletor de lixo rodar, o que é viável porque o cache faz com que uma verificação que estoura o prazo custe isso uma vez por período de cache, em vez de uma vez por sonda.

## Health

### probe:invalidate()

Descarta o resultado de prontidão em cache, para que o próximo `ready()` execute as verificações. Serve para um processo que acabou de terminar de iniciar, ou um teste que acabou de corrigir aquilo que uma verificação estava reportando como falha.

**Retorna** a sonda.

### probe:live()

Este processo está rodando seu event loop?

Não toca em nada: não lê nenhuma verificação, não abre nenhuma conexão, e responde a partir do horário de início que guarda desde que foi construída. `checks` fica vazio por construção, não porque nenhuma passou.

**Retorna** uma tabela.

| campo | tipo | significado |
|---|---|---|
| `status` | string | sempre `"pass"` |
| `checks` | table | sempre vazio |
| `uptime` | number | segundos desde que a sonda foi criada |

### probe:ready(options)

Este processo deve receber tráfego?

Todas as verificações são executadas, em ordem de nome, mesmo depois que uma delas falhou. O resultado fica em cache por `cache` segundos, falhas inclusive, para que uma dependência fora do ar não seja bombardeada pelas sondas reportando que ela está fora do ar. Passe `{ fresh = true }` para ignorar o cache e executar as verificações agora; o resultado de uma execução fresca ainda é armazenado.

Cada chamada retorna uma cópia nova, de modo que um handler que decora o resultado não consegue escrever no cache.

**Retorna** uma tabela.

| campo | tipo | significado |
|---|---|---|
| `status` | string | `"pass"` quando todas as verificações passaram, senão `"fail"` |
| `checks` | table | uma entrada por verificação, indexada pelo nome |
| `cached` | boolean | se esta resposta veio do cache |
| `uptime` | number | segundos desde que a sonda foi criada |

Cada entrada em `checks` traz:

| campo | tipo | significado |
|---|---|---|
| `status` | string | `"pass"` ou `"fail"` |
| `took_ms` | number | quanto tempo a verificação levou, arredondado para o milissegundo |
| `reason` | string | presente apenas em uma falha que forneceu um motivo |
| `timed_out` | boolean | presente apenas quando a verificação ficou sem tempo |

```lua
local health = require "akkar.health"

local calls = 0
local probe = health.new {
  checks = { thing = function() calls = calls + 1 return true end },
  cache  = 5,
}

probe:ready()
probe:ready()
print(calls, probe:ready().cached)          --> 1   true
print(probe:ready({ fresh = true }).cached) --> false
print(calls)                                --> 2
probe:invalidate()
probe:ready()
print(calls)                                --> 3
```

## Servindo os dois endpoints

Nenhum dos dois métodos é uma resposta (response). Ambos retornam uma tabela, que um handler retorna ou transforma em um 503. Aponte a política de reinicialização da plataforma para o caminho de vivacidade e o roteamento de tráfego dela para o caminho de prontidão, nunca o contrário.

```lua
local akkar  = require "akkar"
local health = require "akkar.health"

local probe = health.new {
  checks = { cache = function() return false, "redis is not answering" end },
  cache  = 0,
}

local app = akkar.new()

app:get("/health/live", function() return probe:live() end)

app:get("/health/ready", function()
  local result = probe:ready()
  if result.status == "fail" then error(akkar.unavailable(result)) end
  return result
end)

local client = app:test {}
print(client:get("/health/live").status)    --> 200
print(client:get("/health/ready").status)   --> 503
```

## O que não está aqui

- **Rotas.** O módulo não registra nada. Os dois caminhos acima são seus para escrever, e é por isso que podem ser isentados de um limitador de taxa (rate limiter) ou renomeados.
- **Um código de status.** Os dois métodos retornam uma tabela com uma string `status` dentro. Transformar uma falha em 503 é responsabilidade do handler.
- **Uma sonda de inicialização.** Existem duas perguntas aqui, não três. Um processo que ainda está iniciando falha na prontidão, que é exatamente o que uma sonda de inicialização diria.
- **Verificações que o akkar fornece.** Não existe verificação de banco de dados embutida. Uma verificação é uma função que você escreve, porque só você sabe de qual dependência este serviço não consegue funcionar sem.
- **Qualquer verificação dentro de `live()`.** Por construção, e um teste garante isso.

## Veja também

- [akkar](akkar.md) para `app:test{}`, `akkar.unavailable` e
  `check_capabilities`
- [akkar.doctor](doctor.md) para a versão de tiro único da mesma pergunta na
  inicialização ou em um deploy
- o guia, `docs/pt-BR/guide/11-not-falling-over.md`, para o que acontece com uma
  frota cuja sonda de vivacidade consulta o banco de dados
- o código-fonte do módulo, `akkar/health.lua`, para entender por que as
  falhas também são armazenadas em cache
