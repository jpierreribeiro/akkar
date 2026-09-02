# akkar.time

> **Português (Brasil)** | [Original em inglês](../../reference/time.md)

O relógio que o framework lê. Deadlines, o período de graça de encerramento (shutdown), expiração de cache, horários de vencimento de jobs e o uptime de métricas todos chamam este módulo em vez de `os.time` ou `cqueues.monotime`, de modo que uma única chamada substitui o relógio para todos eles.

**Quando você precisa dele.** Quando um teste precisa provar o que acontece depois que um deadline dispara, um ttl expira ou um backoff de retry vence, e você não quer que o teste durma (sleep) por esse tempo todo.

```lua no-run
local time = require "akkar.time"
```

Só essa grafia. `akkar.time` não é reexportado a partir do módulo de nível superior.

## Conteúdo

- [Clock](#clock)
- [time.manual(options)](#timemanualoptions)
- [time.monotime()](#timemonotime)
- [time.now()](#timenow)
- [time.real](#timereal)
- [time.set(clock)](#timesetclock)
- [time.sleep(seconds)](#timesleepseconds)

## Clock

Um clock é qualquer tabela com três campos: `monotime`, `now` e `sleep`, cada um sendo uma função que não recebe o argumento `self`. `time.real` e a tabela que `time.manual` retorna são ambos clocks. Um clock seu só precisa responder a esses três.

A tabela que `time.manual` retorna carrega dois membros extras.

### clock:advance(seconds)

Move as duas leituras do clock para frente em `seconds`. O padrão é `0`.

**Retorna** o clock, de modo que as chamadas podem ser encadeadas.

**Levanta (raises)** nada.

### clock.sleep(seconds)

Avança o clock em `seconds` e retorna imediatamente. Nada espera de fato.

Escrito com ponto, não com dois-pontos. `clock.sleep(5)` está correto, e `clock:sleep(5)` levanta um erro, porque o clock chegaria onde `seconds` é esperado.

## time.manual(options)

Constrói um clock que só se move quando mandado.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `monotime` | number | `0` | a primeira leitura de `clock.monotime()` |
| `now` | number | `1755000000` | a primeira leitura de `clock.now()` |

`options` pode ser omitido.

**Retorna** um clock, com `advance` e `sleep` nele.

**Levanta** nada.

```lua
local time = require "akkar.time"

local clock = time.manual { now = 1755000000 }
assert(clock.monotime() == 0)
assert(clock.now() == 1755000000)

clock:advance(3600)
assert(clock.monotime() == 3600)
assert(clock.now() == 1755003600)

clock.sleep(10)                       -- retorna imediatamente, tendo avançado
assert(clock.monotime() == 3610)
```

Um clock manual move **timestamps e budgets**, não o event loop. `cqueues.poll` continua intocado, então a E/S ainda leva tempo real. E uma leitura de socket ainda demora o tempo que o peer demorar. Use-o para provar o que acontece depois de um deadline ou um ttl, nunca para provar como duas coisas competem entre si (race).

## time.monotime()

A leitura monotônica atual, a partir de qualquer clock que esteja instalado. Monotônica porque um budget medido contra o tempo de parede (wall time) quebra quando o NTP dá um salto no relógio.

**Retorna** um número de segundos a partir de uma origem arbitrária. Só as diferenças entre duas leituras têm algum significado.

**Levanta** nada.

```lua
local time = require "akkar.time"

local started = time.monotime()
assert(type(started) == "number")
assert(time.monotime() - started >= 0)
```

## time.now()

A leitura atual do relógio de parede (wall clock), a partir de qualquer clock que esteja instalado. Relógio de parede porque uma linha de log carimbada com tempo monotônico não significa nada para quem lê.

**Retorna** um timestamp Unix em segundos, no mesmo formato que `os.time` retorna.

**Levanta** nada.

```lua
local time = require "akkar.time"
assert(math.abs(time.now() - os.time()) <= 1)
```

## time.real

O relógio real, como uma tabela: `monotime` é `cqueues.monotime`, `now` é `os.time`, `sleep` é `cqueues.sleep`. É o que está instalado antes de qualquer chamada a `time.set`, e o que `time.set(nil)` recoloca no lugar.

Lê-lo é uma forma de chamar o relógio real enquanto um manual está instalado.

```lua
local time = require "akkar.time"

local clock = time.manual()
local restore = time.set(clock)
assert(time.now() == 1755000000)          -- a leitura manual
assert(time.real.now() > 1755000000)      -- a real, ainda disponível
restore()
```

## time.set(clock)

Instala um clock para o processo inteiro. Passar `nil` instala `time.real`.

**Retorna** uma função que recoloca o clock anterior no lugar. Chame-a; não assuma que o próximo `set` vai desfazer este.

**Levanta** nada. O clock não é validado, então uma tabela sem `monotime`, `now` ou `sleep` falha depois, na primeira chamada, não aqui.

```lua
local time = require "akkar.time"

local clock = time.manual { now = 1700000000 }
local restore = time.set(clock)

clock:advance(86400)
assert(time.now() == 1700086400)          -- um dia se passou; nada esperou

restore()
assert(math.abs(time.now() - os.time()) <= 1)
```

Global ao processo por design, e isso é uma limitação real: dois testes rodando ao mesmo tempo contra clocks diferentes se enxergariam um ao outro. A função restore é o que impede isso de acontecer.

## time.sleep(seconds)

Dorme através de qualquer clock que esteja instalado. Sob `time.real` isso é `cqueues.sleep`, que cede o controle ao event loop por esse tempo. Sob um clock manual, ele avança o clock e retorna imediatamente.

**Retorna** o que quer que o `sleep` do clock instalado retorne. `time.real.sleep` não retorna nada.

**Levanta** o que quer que o clock instalado levante. `cqueues.sleep` requer um controller cqueues em execução e levanta um erro fora de um.

```lua
local time = require "akkar.time"

local clock = time.manual()
local restore = time.set(clock)

time.sleep(120)                           -- imediato
assert(time.monotime() == 120)

restore()
```

## O que não está aqui

- **Um event loop virtual.** `cqueues.poll` permanece intocado, então a E/S ainda leva tempo real. Tornar o tempo virtual dentro do scheduler significaria escrever um segundo scheduler.
- **Clocks por requisição (request) ou por aplicação.** `time.set` é global ao processo. A capability `clock` que uma aplicação passa para `app:run` é um slot separado; este módulo é o que o próprio framework lê.
- **Timers, agendamentos ou cron.** Trabalho recorrente é `akkar.jobs`.

## Veja também

- [akkar](akkar.md) para `app:run { timeout = ... }`, o deadline de requisição que este clock mede
- o código-fonte do módulo, `akkar/time.lua`, para entender por que um clock manual é honesto sobre o que ele não move
