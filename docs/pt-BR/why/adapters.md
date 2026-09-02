# Por que todo I/O passa por um adaptador que o akkar possui

> **Português (Brasil)** | [Original em inglês](../../why/adapters.md)

Um handler nunca chama `require "pgmoon"`. Ele recebe `req.db` e chama quatro
métodos nele.

```lua no-run
db:one(sql, ...)                  -- primeira linha, ou nil
db:many(sql, ...)                 -- array de linhas, possivelmente vazio
db:exec(sql, ...)                 -- nenhuma linha esperada
db:transaction(function(tx) end)  -- commit no final, rollback em qualquer erro
```

Esse é todo o contrato de banco de dados. São quatro funções, e o tamanho é o
argumento: um contrato pequeno o bastante para implementar à mão é um contrato
que um teste consegue implementar à mão.

Pela maior parte da vida deste projeto isso foi um princípio. Deixou de ser, e
o resto desta página trata do que veio no lugar.

## A alegação, e o dia em que ela virou uma medição

`docs/PLAN.md` sempre disse que trocar o driver reescreve `akkar/db.lua` e
mais nada. `akkar/db.lua` diz a mesma coisa em suas dez primeiras linhas:

> Este arquivo existe para impor a regra arquitetural do framework:
> um handler nunca chama `require "pgmoon"`.

Uma afirmação dessas é fácil de fazer e difícil de acreditar, porque ninguém
jamais tinha feito a troca.

Então chegou um segundo driver. `akkar/pq.lua` é libpq com a espera feita em
Lua: `src/akkar_pq.c` fala o protocolo e nunca espera, `akkar/pq.lua` espera
com `cqueues.poll` e nunca fala com libpq. E `spec/db_spec.lua` agora roda
**um único contrato contra os dois drivers**:

```lua no-run
local DRIVERS = { "pgmoon" }
if pcall(require, "akkar.pq_native") and reachable "pq" then
  DRIVERS[#DRIVERS + 1] = "pq"
end

for _, DRIVER in ipairs(DRIVERS) do
  -- o conjunto inteiro de testes, sem alteração, para cada um
end
```

Vinte e dois testes sobre vinculação de parâmetros, tipagem de parâmetros,
leituras em buffer, `statement_timeout` e o aviso de tempo de boot, rodam uma
vez para cada driver presente. O spec explica o porquê em seu próprio
comentário:

> Até existir apenas um driver isso era uma alegação; rodar um único conjunto
> de testes contra os dois é o que a transforma em uma verificação.

Escolher um driver agora é uma chave em uma tabela:

```lua no-run
local pool = db.connect { host = "127.0.0.1", port = 5432, driver = "pq" }
```

pgmoon continua sendo o padrão. Um driver ganha promoção respondendo ao
contrato, não por ser mais novo.

## O que a fronteira comprou, em microssegundos

O segundo driver também é a primeira chance de dizer quanto essa fronteira
vale, e a resposta honesta é "depende inteiramente da query".

`bench/driver/RESULTS.md` mede os dois drivers contra um piso: `bench/driver/floor.c`
é a mesma query passando por `PQexecParams` bloqueante em um loop C
apertado, sem Lua nenhum. O que quer que isso custe é Postgres mais libpq, e
tudo acima disso pertence ao akkar.

```
                        1 row        1000 rows
floor (libpq in C)     165.99 us       996.70 us
akkar.pq               200.96 us      1639.70 us
pgmoon                 219.63 us      4931.94 us
```

Subtraia o piso e você chega ao único número que de fato mede um driver:

| | custo do driver, 1 linha | custo do driver, 1000 linhas |
|---|---:|---:|
| pgmoon | 53.6 us | 3.935 us |
| akkar.pq | 35.0 us | 643 us |
| redução | 1.53x | **6.1x** |

Isso é um laptop com Postgres em um container, não a máquina de benchmark, e a
página avisa isso logo no topo. O que se transfere é a forma da curva.

**A parte incômoda, que a própria página de benchmark declara antes do seu
próprio título.** Em uma linha a diferença não ultrapassa o ruído de medição, e
`/users/:id` é justamente uma query de uma linha. É a rota usada no estudo
comparativo, na varredura de saturação e no soak. Então o driver em C **não vai
mudar o throughput principal**, e quem espera que essa rota se aproxime do Gin
só porque o driver mudou vai se decepcionar. O que muda são os endpoints de
listagem, e a latência de cauda sob carga, sendo que essa segunda ainda não foi
medida.

Leia com atenção a versão dessa mesma frase na própria página: ela foi escrita
com o akkar em 2.744 req/s e o Gin em 26.212, números vindos de
`bench/compare/RESULTS.md`, uma página desde então retratada. A medição atual
da mesma rota está em `bench/study/RESULTS.md`: akkar com 7.321,95 req/s contra
26.358,92 do Gin. A conclusão não muda, porque ela se apoia no cruzamento entre
1 e 10 linhas e não na proporção.

### A correção que veio junto

A primeira rodada desse benchmark foi tirada em uma máquina com **vinte e dois
processos girando em segundo plano nela**, deixados por um teste que
deliberadamente trava um servidor lua-http e faz a limpeza na sua última
linha, então uma asserção que falhava pulava a limpeza. Load average de 23.
Nada no benchmark conseguia detectar isso: ele rodou, produziu uma curva
consistente, e todo número saiu errado.

Remedido em silêncio, o ganho de velocidade em 1000 linhas caiu de 3,91x para
**3,01x** e a redução de custo do driver caiu de 7,3x para 6,1x. A
contaminação **inflou** a vantagem, porque o pgmoon faz seu trabalho dentro do
interpretador e perde mais para a disputa de CPU do que um driver que passa o
tempo dentro de libpq e do kernel.

Uma máquina barulhenta favorece o produto sendo vendido, que é a pior forma de
um benchmark estar errado. Os números na tabela acima são os silenciosos.

## O que mais a fronteira pagou

A troca de driver é a evidência mais nova, não a única.

**Um tipo de parâmetro errado, corrigido em um único arquivo, valendo 43x em
uma query.** pgmoon declara todo número Lua como `numeric`. Comparar uma
coluna `integer` com um parâmetro `numeric` é uma comparação entre tipos
diferentes que o Postgres não consegue resolver pelo índice, então ele faz um
cast da coluna em cada linha. Medido em uma tabela de 10.000 linhas
(`akkar/db.lua`):

```
$1 numeric   Seq Scan,   Rows Removed by Filter: 10001,  3.287 ms
$1 bigint    Index Scan, Index Cond: (id = '42'::bigint), 0.153 ms
```

De ponta a ponta, `docs/PERFORMANCE-STUDY.md` certifica essa correção em
**3,91x** na rota do banco de dados. Toda aplicação em todo handler ganhou isso
sem mudar uma linha, porque nenhum handler nomeia um tipo.

**Mexendo dentro de uma dependência, no único lugar em que isso é permitido.**
pgmoon pede ao socket cinco bytes e depois um corpo, uma vez por mensagem do
protocolo, e o Postgres manda uma mensagem por linha: 2.006 chamadas em nível
Lua para mil linhas. Servir isso a partir de uma única leitura grande é
certificado em **1,05x de throughput e p99 caindo 20%**, de 106,16 ms para
84,91 ms em uma query de 200 linhas. `docs/PERFORMANCE-STUDY.md` observa que
isso "é o único lugar em que o akkar mexe nas entranhas de uma dependência,
então isso vive no arquivo cujo único trabalho é isolar o pgmoon", com uma
chave de desligamento que não precisa de fork.

**Sobrevivendo a um defeito no substrato.** `docs/substrate/lua-http-wedge.md`
documenta uma requisição com `Content-Length: banana` que deixa o lua-http
vivo, escutando, girando e não respondendo a ninguém, para sempre. Todo
verificador de vivacidade baseado em porta considera esse servidor saudável. A
página originalmente terminava com "não cabe ao akkar consertar isso"; isso
foi corrigido, porque era verdade quanto a *relatar* o bug, mas falso quanto a
*sobreviver* a ele. `akkar/substrate.lua` carrega o reparo e
`spec/substrate_repair_spec.lua` prova isso iniciando um servidor sem ele e
exigindo que esse morra.

Você só consegue reparar uma dependência que já embrulhou.

## Escrevendo seu próprio adaptador

Não existe registro nem classe base. Se tem os quatro métodos, é um banco de
dados.

```lua
local akkar = require "akkar"

-- O contrato inteiro de banco de dados, feito à mão.
local my_own_adapter = {
  one = function(_, _, id) return { id = tonumber(id), name = "ada" } end,
  many = function() return {} end,
  exec = function() return 0 end,
  transaction = function(self, fn) return fn(self) end,
}

local app = akkar.new()
app:get("/users/:id", function(req)
  return req.db:one("select id, name from users where id = $1", req.params.id)
end)

print(app:test { db = my_own_adapter }:get("/users/1").status)   --> 200
```

akkar verifica o contrato uma única vez na inicialização, então um adaptador
mal configurado falha no boot em vez de falhar na primeira requisição que
acaba tocando nele.

## A regra ficou mais estreita do que costumava ser

O README já disse "todo I/O passa por adaptadores que o framework possui", e a
seção 8 de `docs/DECISIONS.md` registra por que isso foi revertido. Possuir
implementações para Postgres, Redis, S3, SMTP e filas "faria do akkar o gargalo
do ecossistema, e não existe versão disso que este projeto consiga manter com
gente". A regra que sobreviveu é:

> **O akkar possui o contrato. As bibliotecas o implementam.**

`akkar.db` é a implementação de referência para Postgres, não a única
permitida.

Às vezes escrever a implementação ainda é a decisão certa, e isso precisa de
um motivo, não de uma preferência. `akkar.redis` existe porque **não existe
cliente Redis não bloqueante para Lua 5.4 em cqueues**: todo `lua-resty-*`
precisa dos cosockets do OpenResty, `lua-hiredis` bloqueia, e `lredis` não é
empacotado para 5.4. Um cliente bloqueante passa em todo teste funcional e trava
o event loop em todo comando. RESP2 era pequeno o bastante para que escrevê-lo
custasse menos do que o risco, e a prova de que funciona não é que `GET`
retorna um valor, é que oito chamadas concorrentes de `BLPOP` de um segundo,
através de um pool de quatro, terminam em 2,07 s.

## O que isso custa

### O conjunto de capabilities precisa continuar fechado, e ele se moveu

`req` carrega dados da requisição e capabilities em uma única tabela plana. O
risco conhecido é que `req` vire um localizador de serviços, acumulando
`req.mailer`, `req.payments`, `req.storage`, até virar uma variável global com
outro nome. O que impede isso é uma regra de admissão, imposta em código:

> Uma capability é infraestrutura que o framework sabe como injetar, guardar e
> falsificar. Qualquer coisa pertencente à aplicação não se qualifica.

`app:run{}` rejeita chaves desconhecidas e aponta a mais próxima, então
`timout = 5` é um erro em vez de um servidor rodando com um prazo de 30
segundos que seu autor acreditava ser 5.

A nota honesta: o conjunto é descrito como `db`, `cache`, `log`, `clock` tanto
em `README.md` quanto em `docs/DECISIONS.md`, e `akkar/init.lua` agora lê
`db, cache, log, clock, http`. O conjunto foi ampliado deliberadamente para o
caminho de saída (outbound), e as páginas mais antigas ainda não
acompanharam isso. Um conjunto fechado que cresce continua fechado se cada
adição for justificada; ele deixa de ser fechado se a documentação parar de
acompanhar.

### O fake não pode virar uma segunda implementação

`akkar.db.memory` casa com queries programadas e **não interpreta SQL**,
porque um motor SQL falso seria um segundo banco de dados cujas divergências
aparecem como testes que passam e produção que não funciona. O fake de cache
é diferente: é uma implementação real com expiração, e implantações pequenas
podem embarcá-lo em produção. Saber qual tipo você tem nas mãos é
responsabilidade sua.

### Acoplamento no momento de boot

Como os contratos são verificados na inicialização, **o servidor se recusa a
iniciar quando o banco de dados está inacessível**. Isso é correto para um
serviço em que toda rota depende dele, e errado para um que deveria subir de
forma degradada, então `app:run { check_capabilities = false }` permite optar
por sair dessa verificação.

### Uma indireção a mais entre você e o driver

Todo recurso do pgmoon que não está nos quatro métodos é inalcançável a partir
de um handler. Esse é o objetivo, e também é ocasionalmente irritante. O
contrato de cache mantém uma válvula de escape explícita,
`cache:command(name, ...)`; o contrato de banco de dados não tem uma, e SQL
bruto através de `:one` é o mais perto que se chega disso.

## O que ler a seguir

- `bench/driver/RESULTS.md` para os números do driver e a história da
  contaminação.
- `docs/PERFORMANCE-STUDY.md` para as certificações de tipagem de parâmetros e
  leitura em buffer.
- `docs/DECISIONS.md` seções 5, 7 e 8.
