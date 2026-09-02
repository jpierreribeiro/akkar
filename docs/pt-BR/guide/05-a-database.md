# 5. Um banco de dados, do zero

> **Português (Brasil)** | [Original em inglês](../../guide/05-a-database.md)

Ao final desta página você terá um banco de dados de verdade rodando na sua máquina,
uma tabela `tasks` dentro dele, e uma migration que criou essa tabela.

A lista de tarefas em si não muda nesta página. É na página 6 que ela passa a
usar o banco de dados. Esta página é sobre colocar o banco de dados no lugar.

Tudo acontece dentro da pasta `akkar`, a mesma da
[página 2](02-your-first-route.md).

## Por que as tarefas continuam desaparecendo

Suas tarefas vivem em uma tabela Lua:

```lua no-run
local tasks = {
  { id = 1, title = "buy milk", done = false },
}
```

Essa tabela vive na memória do programa em execução. Quando o programa para,
sua memória volta para o sistema operacional, e tudo o que havia nela se vai.
Isso não é um bug. É o que memória é.

Um banco de dados é um programa separado cuja função inteira é manter os dados
depois que tudo o mais parar. Ele escreve em disco, sobrevive a um reinício, e
vários programas podem ler os mesmos dados ao mesmo tempo.

Este guia usa o **Postgres**, porque é gratuito, é o que a maioria dos backends
usa, e o akkar tem um adaptador para ele.

## Suba o Postgres com Docker

O Docker roda um programa dentro de uma caixa com tudo o que ele precisa já
incluso. Você não instala o Postgres, você baixa uma caixa que já tem ele
dentro.

Se você não tem o Docker, instale o [Docker
Desktop](https://www.docker.com/products/docker-desktop/) primeiro. Se você já
tem o Postgres instalado de outra forma, pode usar esse instalação mesmo. A
única coisa que importa é que os detalhes de conexão abaixo combinem.

Execute isto uma vez:

```sh
docker run -d --name akkar-pg \
  -e POSTGRES_PASSWORD=akkar \
  -e POSTGRES_DB=akkar \
  -p 55432:5432 \
  postgres:16-alpine
```

O Docker imprime uma linha longa de letras e números. Esse é o id do container
que ele acabou de criar, é diferente a cada vez, e você nunca vai precisar
dele. A primeira execução também baixa a imagem do Postgres, o que leva um
minuto.

O que cada parte significa:

| Parte | Significado |
|---|---|
| `-d` | rodar em segundo plano, não travar este terminal |
| `--name akkar-pg` | chamar de `akkar-pg`, para você poder parar e iniciar pelo nome |
| `-e POSTGRES_PASSWORD=akkar` | a senha do usuário do banco de dados |
| `-e POSTGRES_DB=akkar` | criar um banco de dados chamado `akkar` dentro dele |
| `-p 55432:5432` | a porta 55432 na sua máquina alcança a porta 5432 dentro da caixa |
| `postgres:16-alpine` | qual caixa: Postgres 16, versão enxuta |

**Por que 55432 e não 5432?** 5432 é a porta que o Postgres normalmente usa.
Se você já instalou o Postgres diretamente alguma vez, essa porta já está
ocupada, e os dois entrariam em conflito. 55432 está livre em quase toda
máquina, então nada colide.

Confira se está rodando:

```sh
docker ps --filter name=akkar-pg
```

```
CONTAINER ID   IMAGE                COMMAND                  CREATED        STATUS       PORTS                                           NAMES
342dc2d7dc23   postgres:16-alpine   "docker-entrypoint.s…"   36 hours ago   Up 6 hours   0.0.0.0:55432->5432/tcp, [::]:55432->5432/tcp   akkar-pg
```

`Up` é a palavra que você está procurando. Essa linha foi capturada em uma
máquina onde o container já estava rodando há um tempo, então a sua vai dizer
alguns segundos em vez de horas.

Dois comandos para depois, quando você reiniciar a máquina ou quiser a memória
de volta:

```sh
docker stop akkar-pg
docker start akkar-pg
```

`stop` e `start` preservam seus dados. Só `docker rm akkar-pg` os descarta.

## O que existe dentro de um banco de dados

Três palavras, e depois usamos elas.

Uma **tabela** é uma grade, como uma planilha de uma única aba. Sua lista de
tarefas vai ter uma tabela chamada `tasks`.

Uma **coluna** é um espaço nomeado dentro dessa grade, e ela tem um tipo:
`text`, `integer`, `boolean`. Toda linha tem as mesmas colunas.

Uma **linha** é uma entrada. Uma tarefa é uma linha.

```
tasks
 id | title            | done
----+------------------+-------
  1 | buy milk         | false
  2 | walk the dog     | false
```

A tabela precisa existir antes de você conseguir colocar algo nela. Criá-la é
o assunto do restante desta página.

## Converse com o banco de dados a partir do Lua

Crie `check-db.lua` na pasta `akkar`. Este é o arquivo inteiro.

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
print(conn:one("select version() as version").version)
conn:close()
```

```sh
lua5.4 check-db.lua
```

```
PostgreSQL 16.13 on x86_64-pc-linux-musl, compiled by gcc (Alpine 15.2.0) 15.2.0, 64-bit
```

O banco de dados respondeu. Esse é todo o propósito do arquivo.

Três coisas nele valem a pena nomear.

**`db.connect { ... }` não conecta.** Ele retorna uma função. Chamar essa
função, `open()`, é o que abre uma conexão. Isso parece trabalho a mais agora,
e a página 6 mostra por que está certo: um servidor entrega essa função para o
akkar e o akkar a chama uma vez por requisição (request).

**`pool_size = 0` significa "sem pool".** Um servidor mantém um pequeno
conjunto de conexões abertas e as compartilha, porque abrir uma custa tempo de
verdade. Um script avulso quer exatamente uma conexão, e `0` diz isso. A
página 6 usa a configuração normal.

**`conn:one(...)` executa uma query e devolve a primeira linha.** A linha é
uma tabela Lua comum, então `row.version` é essa coluna. `select version()`
pergunta ao Postgres qual é a versão dele, que é a menor pergunta útil que
existe.

### Se o Postgres não estiver rodando

Pare o container e execute o arquivo de novo:

```sh
docker stop akkar-pg
lua5.4 check-db.lua
```

```
lua5.4: db: could not connect to 127.0.0.1:55432 (database "akkar", user "postgres") -- /home/jp/.luarocks/share/lua/5.4/pgmoon/cqueues.lua:18: socket:connect: Connection refused
  Nothing is listening there. Is the database running?
stack traceback:
	[C]: in function 'error'
	...akkar/db.lua:354: in local 'open'
	check-db.lua:12: in main chunk
	[C]: in ?
```

Leia a primeira linha da esquerda para a direita. O akkar diz o endereço
exato que tentou, `127.0.0.1:55432`, e o banco de dados e usuário exatos com
que tentou. Compare essas quatro coisas com o seu comando `docker run` e com
as configurações do seu arquivo. Uma delas vai estar diferente.

A parte do meio, até `Connection refused`, é a mensagem do driver do Postgres
por baixo. `Connection refused` tem um significado preciso: algo respondeu
naquele endereço e disse não, ou melhor, não havia nada ali para responder. É
isso que a segunda linha diz em palavras simples.

`check-db.lua:12` é a linha do seu arquivo que abriu a conexão. O caminho
`akkar/db.lua` vai ter uma aparência diferente na sua máquina.

Quase sempre é uma de três coisas: o container está parado, a porta no seu
arquivo não combina com a porta no comando `docker run`, ou você nunca chegou
a rodar `docker run`.

Suba ele de novo antes de continuar:

```sh
docker start akkar-pg
```

## O que é uma migration

Você precisa de uma tabela `tasks`. O SQL que cria uma é um único comando:

```sql
create table tasks (
  id    serial primary key,
  title text    not null,
  done  boolean not null default false
)
```

Você poderia digitar isso em um terminal uma vez e pronto. Aí as perguntas
começam. Você rodou isso no seu notebook, ou só na máquina do seu colega? O
servidor recebeu? E a cópia do banco de dados que você fez semana passada? Daqui
a três meses, o que exatamente tem nessa tabela, e quem mudou o quê?

**Uma migration é esse SQL guardado em um arquivo, com um número na frente, e
um registro de se ela já rodou ou não.** Três partes, e cada uma responde uma
dessas perguntas.

O executor do akkar é o `akkar.migrate`. Ele faz o seguinte:

1. Olha a lista de migrations, em ordem numérica.
2. Olha no banco de dados uma tabela chamada `akkar_migrations`, que é o
   registro do que já rodou. Vamos chamar isso de livro-razão.
3. Executa as que não estão no livro-razão, da mais antiga para a mais nova.
4. Grava cada uma no livro-razão assim que ela roda.

Então rodar duas vezes não faz nada na segunda vez. É essa propriedade que
torna seguro executar a cada início do programa.

### Três regras, e os motivos

**Toda migration precisa de um número na frente do nome.**
`001_create_tasks.sql`, não `create_tasks.sql`. O número é o que as coloca em
ordem, e ordem importa: uma migration que adiciona uma coluna em `tasks` tem
que rodar depois da que cria `tasks`. O akkar recusa um nome sem número em vez
de tentar adivinhar.

**A linha do livro-razão é gravada na mesma transação da mudança.** Uma
transação é um grupo de comandos que ou acontecem todos, ou nenhum acontece.
Então, ou a tabela é criada e o livro-razão registra isso, ou nenhum dos dois.
Se a máquina morrer no meio do caminho, você nunca chega ao estado em que a
mudança aconteceu e nada registrou isso, que é o estado que faz a próxima
inicialização rodar tudo de novo.

**Não existe forma de desfazer uma migration, e isso é proposital.** Outras
ferramentas têm migrations "down" que revertem uma mudança. O akkar não tem, e
o motivo vale a pena ler uma vez, porque muda a forma como você as escreve.
Desfazer um `add column` significa um `drop column`, o que é tranquilo numa
tabela vazia e destrói uma coluna de dados reais numa tabela cheia. A migration
que adicionou a coluna sabia o que colocar ali. A que a remove não sabe o que
colocar de volta. Então a única direção é para frente: se uma migration
estava errada, o conserto é outra migration que diz o que deveria ter sido
dito.

## Escreva a migration e execute

Crie `migrate.lua` na pasta `akkar`. Este é o arquivo inteiro.

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  pool_size = 0,
}

local conn = open()

local runner = migrate.new(conn, {
  files = {
    { name = "001_create_tasks.sql", sql = [[
      create table tasks (
        id    serial primary key,
        title text    not null,
        done  boolean not null default false
      )
    ]] },
  },
})

local applied = runner:apply()

if #applied == 0 then
  print "nothing to do; the database is already up to date"
end
for _, name in ipairs(applied) do
  print("applied " .. name)
end

conn:close()
```

```sh
lua5.4 migrate.lua
```

```
applied 001_create_tasks.sql
```

Execute de novo:

```sh
lua5.4 migrate.lua
```

```
nothing to do; the database is already up to date
```

Essa segunda execução é toda a ideia. A migration já está no livro-razão
agora, então o akkar a deixou em paz.

Duas coisas de Lua nesse arquivo, caso sejam novas para você.

**`[[ ... ]]` é uma string longa.** Um texto entre colchetes duplos pode
ocupar várias linhas e conter aspas sem precisar escapá-las. SQL está cheio
das duas coisas, então essa é a forma sensata de escrevê-lo.

**`runner:apply()` retorna uma lista com os nomes que ela aplicou**, que fica
vazia quando não havia nada a fazer. `#applied` é quantas há nessa lista.

### As colunas que você acabou de criar

- `id serial primary key` é um número inteiro que o Postgres preenche para
  você, contando a partir de 1. `primary key` significa que ele identifica a
  linha e não pode se repetir.
- `title text not null` é texto, e `not null` significa que uma linha sem um
  título é recusada pelo próprio banco de dados.
- `done boolean not null default false` é verdadeiro ou falso, e uma linha que
  não informa recebe `false`.

## Veja o que aconteceu

Você não precisa ter o Postgres instalado para olhar por dentro. `docker exec`
executa um comando dentro da caixa em execução, e `psql` é o terminal que vem
junto com o Postgres.

```sh
docker exec akkar-pg psql -U postgres -d akkar -c '\d tasks'
```

```
                            Table "public.tasks"
 Column |  Type   | Collation | Nullable |              Default              
--------+---------+-----------+----------+-----------------------------------
 id     | integer |           | not null | nextval('tasks_id_seq'::regclass)
 title  | text    |           | not null | 
 done   | boolean |           | not null | false
Indexes:
    "tasks_pkey" PRIMARY KEY, btree (id)
```

Aí está sua tabela. `\d tasks` significa "descreva a tabela chamada tasks".

E o livro-razão, que o akkar criou sozinho na primeira vez que você rodou a
migration:

```sh
docker exec akkar-pg psql -U postgres -d akkar -c 'select name, applied_at from akkar_migrations'
```

```
         name         |          applied_at           
----------------------+-------------------------------
 001_create_tasks.sql | 2026-08-16 08:31:58.198203+00
(1 row)
```

Uma linha, uma migration. Essa linha é o motivo pelo qual a segunda execução
não fez nada.

## Dois erros que o akkar recusa

Vale a pena ver os dois de propósito, porque os dois são fáceis de cometer.

### Um nome sem número

Mude `name = "001_create_tasks.sql"` para `name = "create_tasks.sql"` e
execute:

```sh
lua5.4 migrate.lua
```

```
lua5.4: akkar.migrate: these files have no leading id, so there is no order to run them in: create_tasks.sql
  name them like `20260816120000_add_users.sql` -- a timestamp rather than a counter, because two people branching from the same commit both pick 007 and two timestamps cannot collide
stack traceback:
	[C]: in function 'error'
	...akkar/migrate.lua:568: in method 'apply'
	migrate.lua:27: in main chunk
	[C]: in ?
```

O caminho até `migrate.lua` dentro do akkar vai ter uma aparência diferente na
sua máquina. `migrate.lua:27` é o seu arquivo, a linha que chama `apply`.

A mensagem sugere data e hora em vez de um contador. Isso é um conselho para
mais adiante, quando mais de uma pessoa escrever migrations: duas pessoas
escolhem `007` e colidem, enquanto dois timestamps não conseguem colidir.
Sozinho, `001`, `002`, `003` é o suficiente, e é isso que este guia usa.

Coloque o nome de volta antes de continuar.

### Editar uma migration que já rodou

Adicione uma coluna ao SQL de `001_create_tasks.sql`, por exemplo uma linha
dizendo `note  text`, e execute de novo:

```sh
lua5.4 migrate.lua
```

```
lua5.4: ...akkar/migrate.lua:544: akkar.migrate: '001_create_tasks.sql' has changed since it was applied (ledger dbc2018b8b23f9ddbc5e6b5cd5d5e4bf3008b664d8295f2ec3b5e89a2aad606e, file 5aae8df89a98b12bdc4c2bbe72c79a96a175c5af6155e58a76bb246fcafc39b2) -- the database no longer matches the files. Restore the file, or write a new migration for whatever the edit was trying to say
stack traceback:
	[C]: in function 'error'
	...akkar/migrate.lua:568: in method 'apply'
	migrate.lua:28: in main chunk
	[C]: in ?
```

O akkar guardou uma impressão digital do texto quando ele rodou, e o texto
agora é diferente. Ele para em vez de tentar adivinhar.

Isso parece rígido e está justamente te protegendo. Sua migration já rodou,
então editá-la não muda o banco de dados. Só faz seus arquivos discordarem da
realidade, silenciosamente, e depois ninguém consegue confiar em nenhum dos
dois. **Editar uma migration que já foi aplicada nunca é a resposta. Escrever
uma nova sempre é.**

Desfaça sua edição antes de continuar.

## Onde as migrations normalmente ficam

Este guia mantém o SQL dentro de `migrate.lua`, porque isso mantém cada
exemplo desta página como um único arquivo que você pode executar.

Um projeto de verdade mantém cada migration como seu próprio arquivo `.sql`
dentro de uma pasta, e aponta o akkar para essa pasta:

```lua no-run
migrate.new(conn, { dir = "migrations" })
```

Aí `migrations/001_create_tasks.sql` é um arquivo com SQL dentro e nada mais,
`002_...` fica ao lado dele, e o akkar lê a pasta inteira em ordem numérica.
Nada nas regras muda. Os nomes, o livro-razão e as recusas são os mesmos.

Uma consequência da forma como este guia faz as coisas, dita em voz alta para
não te surpreender: cada uma das próximas páginas adiciona **apenas a
migration que ela introduz**. A página 7 adiciona `002`, a página 8 adiciona
`003`, e nenhuma repete `001`, porque `001` já está no seu livro-razão. Isso
significa que nenhum arquivo isolado neste guia consegue construir o banco de
dados a partir do zero. Uma pasta de arquivos `.sql` não tem esse problema, e
é exatamente por isso que projetos de verdade usam esse formato.

## Ponto de checagem

Você está no caminho certo se:

- `docker ps --filter name=akkar-pg` mostra uma linha dizendo `Up`
- `lua5.4 check-db.lua` imprime uma versão do PostgreSQL
- `lua5.4 migrate.lua` imprime `nothing to do; the database is already up to
  date`
- `docker exec akkar-pg psql -U postgres -d akkar -c '\d tasks'` mostra três
  colunas

E você consegue dizer o que é uma migration em uma frase: um arquivo numerado
de SQL que roda uma vez, em ordem, e é registrado para nunca rodar duas vezes.

A tabela está vazia e nada escreve nela ainda. Isso vem a seguir:
[6. Storing and reading rows](06-storing-and-reading.md).
