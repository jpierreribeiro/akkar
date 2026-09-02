# 13. transaction, e a armadilha nela

> **Português (Brasil)** | [Original em inglês](../../sql/13-transactions.md)

Ao final desta página você será capaz de fazer várias instruções acontecerem
juntas ou nenhuma delas acontecer, e terá visto, com saída real, o único
erro que grava uma linha enquanto diz ao chamador que sua requisição (request) foi rejeitada.

## Para que serve uma transaction

Duas instruções que precisam acontecer juntas. Tirar dinheiro de uma conta e
colocar em outra. Criar um pedido e reduzir o estoque. Escrever uma linha e
escrever o registro de log que diz que você escreveu ela.

Se a primeira tiver sucesso e a segunda falhar, você fica com um estado para o
qual sua aplicação não tem palavra. Uma transaction remove esse estado: ou as
duas instruções acontecem, ou nenhuma acontece.

## O closure é a transaction

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec "create table sqlguide_notes (id serial primary key, body text not null)"

conn:transaction(function(tx)
  tx:exec("insert into sqlguide_notes (body) values ($1)", "first")
  tx:exec("insert into sqlguide_notes (body) values ($1)", "second")
end)

print("rows:", conn:one("select count(*) as n from sqlguide_notes").n)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
rows:	2
```

O akkar enviou `begin` antes da sua função e `commit` depois dela. Você não
escreveu nenhum dos dois, e **não existe forma de deixar uma transaction
aberta por esquecimento**, porque não existe linha para você esquecer.

Se a função lançar um erro, o akkar envia `rollback` no lugar e relança o que
quer que você tenha lançado:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec "create table sqlguide_notes (id serial primary key, body text not null)"

local ok = pcall(function()
  conn:transaction(function(tx)
    tx:exec("insert into sqlguide_notes (body) values ($1)", "undone")
    error "changed my mind"
  end)
end)

print("ok:  ", ok)
print("rows:", conn:one("select count(*) as n from sqlguide_notes").n)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
ok:  	false
rows:	0
```

O insert desaparece. Uma falha vinda do Postgres faz a mesma coisa, então uma
instrução quebrada no meio do caminho não deixa a primeira metade para trás.

`transaction` retorna o que quer que sua função tenha retornado, então você
pode montar a resposta dentro dela e devolvê-la direto.

## Use `tx`, não `req.db`

O argumento que o closure recebe é a conexão com a transaction aberta nela.
Em um handler, `req.db` pode ser uma conexão diferente vinda do pool, e uma
instrução enviada nela fica fora da sua transaction e não será desfeita.

```lua no-run
req.db:transaction(function(tx)
  tx:exec("insert into ...")     -- dentro
  req.db:exec("insert into ...") -- ERRADO: pode ser uma conexão diferente
end)
```

A regra é simples: dentro do closure, o único identificador que você toca é
`tx`.

## A armadilha: retornar um 4xx faz commit

Essa é a cara. Ela está escrita no próprio código-fonte do akkar com uma nota
dizendo que custou uma tarde de alguém, e vale a pena gastar uma tarde sua lendo
as próximas vinte linhas.

Um handler do akkar responde retornando. `akkar.bad_request "..."` é um valor,
e retorná-lo é como você envia um `400`. Então isto parece completamente
razoável:

```lua no-run
req.db:transaction(function(tx)
  tx:exec("insert into tasks ...")
  if something_is_wrong then
    return akkar.bad_request "no"     -- parece uma recusa
  end
end)
```

Não é uma recusa. **O closure retornou, então ele não falhou, então o akkar deu
commit.** O `400` então sobe e responde ao chamador. A linha é escrita, e o
chamador é informado de que sua requisição foi rejeitada, o que é o pior dos
dois mundos.

Aqui está isso acontecendo:

```lua
local akkar = require "akkar"
local db    = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec "create table sqlguide_notes (id serial primary key, body text not null)"

local answer = conn:transaction(function(tx)
  tx:exec("insert into sqlguide_notes (body) values ($1)", "written anyway")
  return akkar.bad_request "no"
end)

print("status:", answer.status)
print("rows:  ", conn:one("select count(*) as n from sqlguide_notes").n)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
status:	400
rows:  	1
```

Um `400` e uma linha. Nada quebrou, nada foi registrado em log, e a linha está
na tabela.

### `error(...)` é a forma que recusa

Mude uma palavra:

```lua
local akkar = require "akkar"
local db    = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec "create table sqlguide_notes (id serial primary key, body text not null)"

local ok, response = pcall(function()
  return conn:transaction(function(tx)
    tx:exec("insert into sqlguide_notes (body) values ($1)", "rolled back")
    error(akkar.bad_request "no")
  end)
end)

print("raised:", not ok)
print("status:", response.status)
print("rows:  ", conn:one("select count(*) as n from sqlguide_notes").n)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
raised:	true
status:	400
rows:  	0
```

O mesmo `400` para o chamador, e nenhuma linha. Era isso que você queria nas
duas vezes.

Isso funciona porque uma resposta lançada com `error` não é um crash no akkar.
O framework trata uma resposta lançada como erro como uma resposta: o `pcall`
dentro de `transaction` vê o erro lançado e faz rollback, depois relança, e a
cadeia de handlers responde com o `400` exatamente como se ele tivesse sido
retornado. [A página 4 do guia](../guide/04-errors.md) é onde essa ideia é
apresentada.

**Dentro de uma transaction, lance um erro para recusar.** Fale isso em voz
alta uma vez e vai grudar.

### Por que o akkar não conserta isso para você

Ele poderia olhar o que o closure retornou, ver um `4xx`, e fazer rollback.
Deliberadamente ele não faz isso, e o motivo é que a mudança seria um chute
sobre o que você quis dizer.

Um closure pode legitimamente retornar um `4xx` depois de um trabalho que
**deveria** persistir. Registrar a tentativa rejeitada é o exemplo comum: você
escreve uma linha dizendo que alguém tentou, depois responde `429` ou `403`.
Uma regra que lesse o código de status descartaria essa linha silenciosamente,
o que é o mesmo defeito apontando para o outro lado e muito mais difícil de
enxergar.

Então a regra permanece mecânica. Retornado significa concluído, lançado
significa que falhou.

## Mais duas coisas que vale a pena saber

### Não existem savepoints

Uma `transaction` dentro de uma `transaction` não é uma transaction aninhada.
Existe uma só, e uma falha em qualquer ponto dela desfaz tudo:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec "create table sqlguide_notes (id serial primary key, body text not null)"

local ok = pcall(function()
  conn:transaction(function(tx)
    tx:exec("insert into sqlguide_notes (body) values ($1)", "outer")
    tx:transaction(function(inner)
      inner:exec("insert into sqlguide_notes (body) values ($1)", "inner")
      error "the inner one failed"
    end)
  end)
end)

print("ok:  ", ok)
print("rows:", conn:one("select count(*) as n from sqlguide_notes").n)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
ok:  	false
rows:	0
```

O insert externo foi junto. Se você queria "tente esta parte, e continue se
ela falhar", uma transaction não é a ferramenta certa.

### Mantenha-as curtas

Uma transaction mantém locks nas linhas que ela tocou até terminar. Qualquer
coisa lenta dentro dela, uma chamada HTTP para um provedor de pagamento, um
upload de arquivo, um `sleep`, mantém esses locks por esse tempo todo, e cada
outra requisição que quer essas linhas fica esperando.

Faça a coisa lenta primeiro, depois abra a transaction para escrever o
resultado.

## Checkpoint

Você domina isto se:

- consegue escrever dois inserts que acontecem juntos ou nenhum acontece
- sabe que deve usar `tx` e nunca `req.db` dentro do closure
- consegue dizer o que `return akkar.bad_request "..."` faz dentro de uma
  transaction, e o que escrever no lugar
- sabe que não existem savepoints

Próxima: [14. scope](14-scope.md).
