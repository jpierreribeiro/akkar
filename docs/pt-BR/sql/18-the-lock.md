# 18. O lock

> **Português (Brasil)** | [Original em inglês](../../sql/18-the-lock.md)

Ao final desta página você vai entender por que um executor de migrações é um módulo em vez de um script de shell, o que acontece quando dois servidores sobem no mesmo instante e qual conexão você precisa entregar a ele.

## A corrida

Tudo que um executor de migrações faz parece simples. Ler uma lista de arquivos, rodar os que ainda não rodaram, registrar quais foram executados. São trinta linhas de `psql` num loop.

Aí você faz o deploy.

Um deploy em rolagem (rolling deploy) sobe várias cópias do seu serviço ao mesmo tempo, de propósito, para que as antigas possam ser encerradas sem nenhum tempo de indisponibilidade. Todas elas rodam suas migrações na inicialização. Então:

1. A instância A lê o registro (ledger) e vê que `007` está pendente.
2. A instância B lê o registro e vê que `007` está pendente.
3. Ambas executam.

O resultado de sorte é uma delas bater num erro de chave duplicada no registro e entrar num crash-loop até alguém dar uma olhada. O de azar é uma migração cujas instruções não são, elas mesmas, únicas, um `insert`, um `update ... set n = n + 1`, aplicada duas vezes sem nenhum erro em lugar nenhum.

## A execução inteira acontece sob um único lock

O akkar toma um **lock consultivo (advisory lock)** do Postgres antes de fazer qualquer coisa, sobre uma chave fixa:

```lua
local migrate = require "akkar.migrate"

print(migrate.LOCK_KEY)
print(string.format("%x", migrate.LOCK_KEY))
```

```
418414027122
616b6b6172
```

Um lock consultivo é um lock sobre um número, e não sobre uma tabela. O Postgres não sabe nem se importa com o que aquele número significa. Basta que duas conexões peçam o mesmo número: a segunda espera.

O número é o ASCII da palavra `akkar` lido como inteiro, e é por isso que o hexadecimal acima a soletra. Ele não significa nada para o Postgres, e significa algo para quem estiver lendo `pg_locks` às três da manhã.

A chave é fixa e não é derivada do diretório nem do nome do registro, então no máximo uma execução de migração pode acontecer por banco de dados por vez. Uma execução que espera atrás de outra sem relação alguma perdeu apenas alguns segundos na inicialização, e nada mais.

### A ordem das operações é o ponto central

```
take the lock
  create the ledger if it is missing
  work out what is pending
  apply them, one transaction each
release the lock
```

Descobrir o que está pendente acontece **depois** que o lock é obtido. Fazer isso primeiro e só então travar parece correto, mas devolve exatamente a corrida que o lock foi criado para fechar: a instância B calculou sua lista enquanto A ainda não tinha terminado, e a lista de B fica desatualizada no momento em que B consegue entrar.

Como a lista é calculada por dentro, a instância B relê o registro quando obtém o lock, não encontra nada pendente e não faz nada. Esse é o resultado desejado de um deploy em rolagem: uma instância migra, as demais confirmam que não há nada a fazer.

## Esperar é normal, esperar para sempre não é

O akkar espera, com um limite. O padrão é 30 segundos e `lock_timeout` muda isso.

Aqui está o que acontece quando outra pessoa está segurando o lock. Este exemplo o toma manualmente em uma conexão e depois tenta migrar em outra:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local config = {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}

local holder = db.connect(config)()
local waiter = db.connect(config)()

holder:one("select pg_advisory_lock($1)", migrate.LOCK_KEY)

local runner = migrate.new(waiter, {
  table = "sqlguide_migrations",
  lock_timeout = 1,
  files = { { name = "001_create_tasks.sql",
              sql = "create table sqlguide_tasks (id serial primary key)" } },
})

local started = os.time()
local ok, why = pcall(function() return runner:apply() end)
print(ok)
print(why)
print("waited about " .. (os.time() - started) .. " second(s)")

holder:one("select pg_advisory_unlock($1)", migrate.LOCK_KEY)
holder:close()
waiter:close()
```

```
false
akkar.migrate: another runner has held the migration lock for more than 1 seconds.
  That is normal for a slow migration and not normal for a fast one -- check whether a previous deploy died holding it. `select * from pg_locks where locktype = 'advisory'` names the session.
waited about 1 second(s)
```

`lock_timeout = 1` serve apenas para manter o exemplo curto. Deixe como está num projeto de verdade, a não ser que suas migrações sejam genuinamente lentas, caso em que você deve aumentar o valor.

Dois desenhos foram rejeitados aqui, e saber o motivo ajuda a entender a mensagem.

**Esperar para sempre** foi a primeira versão, e ela está errada da forma que só aparece às três da manhã. Um lock deixado para trás por um executor que travou, ou uma migração genuinamente levando vinte minutos, transforma todo deploy seguinte num processo que fica pendurado sem nenhuma saída. Nada expira, nada registra log, e o orquestrador acaba matando um contêiner que parecia saudável o tempo todo.

**Recusar imediatamente** se o lock estiver ocupado é a outra resposta óbvia, e ela está errada porque um deploy em rolagem sobe várias instâncias de propósito. Todas menos uma encontrarem o lock ocupado é o caso **normal**, não um incidente. Falhar com elas significa que um deploy saudável precisa de um loop de novas tentativas em outro lugar.

Então: espere, mas não para sempre, e avise quando a espera se esgotar.

### Descobrindo quem está segurando

A mensagem informa a consulta. Aqui está ela com um lock de fato mantido:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local config = {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}

local holder = db.connect(config)()
holder:one("select pg_advisory_lock($1)", migrate.LOCK_KEY)

for _, row in ipairs(holder:many [[
  select locktype, classid, objid, mode, granted
  from pg_locks where locktype = 'advisory']]) do
  print(row.locktype, row.classid, row.objid, row.mode, row.granted)
end

holder:one("select pg_advisory_unlock($1)", migrate.LOCK_KEY)
holder:close()
```

```
advisory	97	1802199410	ExclusiveLock	true
```

A chave é dividida entre duas colunas, `classid` contendo a metade superior e `objid` a metade inferior, e é por isso que nenhuma das duas se parece com o número que você imprimiu antes. Acrescente `pid` a esse select num incidente real e você terá o processo a examinar.

Se o lock estiver genuinamente encalhado, o jeito honesto de resolver é encerrar a sessão que o mantém. `select pg_terminate_backend(pid)` faz isso, e é algo a se fazer deliberadamente depois de você ter verificado se a migração ainda está em execução, nunca como reflexo.

## Entregue a ele uma conexão que ele possa manter

O lock é de **nível de sessão**, tomado com `pg_advisory_lock` em vez do `pg_advisory_xact_lock`, que tem escopo de transação. Isso não é um detalhe que você pode ignorar, porque ele decide qual conexão o executor precisa.

Por que de nível de sessão: cada migração faz commit por conta própria, então um lock com escopo de transação seria liberado logo no primeiro `commit`, deixando todas as migrações depois da primeira sem proteção.

O que decorre disso: o lock vive na **sessão**, o que significa a conexão. Um handle que volta para um pool no meio do caminho leva o lock junto e a proteção acaba. Então o executor precisa de uma conexão que possua para toda a execução.

Na prática isso significa `pool_size = 0` e um único `open()`, que é o que todo exemplo nestas páginas faz:

```lua no-run
local open = db.connect {
  host = ..., port = ..., database = ..., user = ..., password = ...,
  pool_size = 0,
}
local conn = open()

migrate.new(conn, { dir = "migrations" }):apply()

conn:close()
```

E é por isso que `migrate.new` recusa a própria fábrica (factory) com uma mensagem dizendo isso.

## Não coloque `statement_timeout` nessa conexão

Esta seção merece destaque próprio, porque a falha é confusa.

`db.connect { statement_timeout = 30 }` define um limite em toda instrução, na conexão, por boas razões que seus handlers precisam. Mas o Postgres também conta a espera por um lock consultivo dentro do `statement_timeout`. Então uma conexão construída dessa forma cancela a espera pelo lock cedo demais, **e** cancelaria uma migração longa.

O resultado é uma mensagem que informa o número errado:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local holder = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}()
holder:one("select pg_advisory_lock($1)", migrate.LOCK_KEY)

local timed = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
  statement_timeout = 1,
}()

local runner = migrate.new(timed, {
  table = "sqlguide_migrations",
  lock_timeout = 30,
  files = { { name = "001_create_tasks.sql", sql = "select 1" } },
})

local started = os.time()
local ok, why = pcall(function() return runner:apply() end)
print(ok)
print(why)
print("but it only waited about " .. (os.time() - started) .. " second(s)")

holder:one("select pg_advisory_unlock($1)", migrate.LOCK_KEY)
holder:close()
timed:close()
```

```
false
akkar.migrate: another runner has held the migration lock for more than 30 seconds.
  That is normal for a slow migration and not normal for a fast one -- check whether a previous deploy died holding it. `select * from pg_locks where locktype = 'advisory'` names the session.
but it only waited about 1 second(s)
```

A mensagem diz trinta segundos. A espera foi de um. Nada está quebrado no akkar: o `statement_timeout` da conexão cancelou a espera primeiro, e o akkar só consegue relatar o limite que ele mesmo pediu.

**Então abra uma conexão separada para migrações, sem `statement_timeout`.** O pool da sua aplicação mantém o timeout dele, e a conexão de migração não tem nenhum. A [Página 20](20-on-deploy.md) mostra como isso se estrutura.

O akkar cuida da outra metade disso para você. Ele define o próprio `lock_timeout` do Postgres para limitar a espera, depois o redefine para `0` antes de rodar qualquer migração, de modo que uma migração que legitimamente espera por um lock próprio, um `alter table` atrás de uma leitura longa, não herde a paciência do deploy.

## O lock é sempre liberado

No sucesso e na falha, e antes de o erro ser relançado. Uma migração que falhasse e mantivesse o lock deixaria toda outra instância bloqueada na inicialização atrás de uma execução que já terminou, transformando uma migração ruim numa indisponibilidade de toda a frota, vinda justamente do código que deveria tornar a inicialização mais segura.

E se a própria liberação falhar, o lock está na sessão, então fechar a conexão o libera. O akkar diz isso na mensagem também.

## Ponto de checagem

Você está pronto se:

- consegue descrever a corrida entre duas instâncias subindo em três linhas
- sabe que a lista de pendentes é calculada depois do lock, e por que essa ordem importa
- sabe por que o lock é de nível de sessão e o que isso significa para a conexão que você passa
- não daria `statement_timeout` à conexão de migração

Próxima: [19. Migrações como dados](19-migrations-as-data.md).
