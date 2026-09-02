# Por que um handler retorna em vez de escrever uma resposta

> **Português (Brasil)** | [Original em inglês](../../why/handlers-return.md)

Um handler no akkar é uma função que recebe uma requisição (request) e **retorna um valor**.
Ele nunca recebe uma conexão, um writer ou um objeto de resposta (response) para preencher.

```lua no-run
app:get("/users/:id", function(req)
  return req.db:one("select id, name from users where id = $1", req.params.id)
end)
```

A maioria dos frameworks faz diferente. No Gin você chama `c.JSON(200, user)`. No
Express você chama `res.json(user)`. No Flask você pode fazer das duas formas. O objeto
fica ali, na sua mão, durante todo o handler, e você pode chamá-lo quantas vezes quiser.

Esta página argumenta que entregar esse objeto a você é um erro, mostra o preço que o akkar
paga por recusar isso e aponta os casos em que a recusa é genuinamente pior.

## O que isso torna impossível

### Responder duas vezes

Se não existe `c.JSON()`, não existe um segundo `c.JSON()`. O bug em que um
handler escreve um 200, continua executando, cai num caminho de erro e escreve um 500 na
mesma conexão não pode acontecer. Nem seu irmão mais discreto, o
`Abort()` sem um `return` depois, em que o framework marca a requisição como
concluída e o handler continua executando mesmo assim.

Isso não é uma regra que o akkar verifica. É uma forma. O `akkar/init.lua` diz
isso logo no comentário de abertura:

> Handlers RETORNAM uma resposta em vez de alterar um contexto, o que faz
> escrever a resposta duas vezes estruturalmente impossível.

A diferença importa porque uma regra verificada tem uma mensagem de erro e uma
API bem desenhada não precisa de uma. Não há nada para avisar.

### Um erro lá no fundo da pilha que não consegue responder

O preço costumeiro de "retorne a resposta" é que toda função entre o
handler e a falha precisa carregar a falha de volta manualmente:

```lua no-run
local user, err = find_user(db, id)
if err then return err end
```

O akkar não paga esse preço. **O mesmo valor funciona como retorno e como exceção.**
A seção 4 do `docs/DECISIONS.md` registra as alternativas que estavam na mesa e
por que esta venceu:

```lua
local akkar = require "akkar"
local app = akkar.new()

-- Três camadas abaixo, e ainda assim consegue responder HTTP.
local function find_user(db, id)
  local user = db:one("select id, name from users where id = $1", id)
  if not user then error(akkar.not_found "no such user") end
  return user
end

app:get("/users/:id", function(req)
  return find_user(req.db, req.params.id)
end)

local client = app:test {
  db = require("akkar.db.memory").factory(function(fake)
    fake:on("from users", function(_, id)
      if id == "1" then return { id = 1, name = "ada" } end
    end)
  end),
}

print(client:get("/users/1").status)    --> 200
print(client:get("/users/99").status)   --> 404
```

O akkar distingue uma resposta lançada de um erro real, e só transforma o segundo em
um 500. Não há traceback no corpo em nenhum dos dois casos.

### Middleware que não consegue ver a resposta

Como um handler retorna, `next` também retorna. Middleware é uma função
comum que pode olhar a resposta antes de ela sair:

```lua no-run
app:use(function(req, next)
  local res = next(req)
  log(req.method, req.path, res.status)
  return res
end)
```

Num framework em que o handler escreve, pós-processamento significa envolver ou
substituir o writer, e é por isso que middleware que modifica a resposta é a parte
desses frameworks que as pessoas mais erram.

### Um `BEGIN` que ninguém fechou

`req.db:transaction(fn)` faz commit quando a closure retorna e faz rollback em qualquer
erro, **incluindo uma resposta lançada de dentro dela**. Isso só funciona porque
lançar uma resposta é um caminho de erro normal. Se um handler pudesse escrever um 404 na
conexão e depois retornar normalmente, a transação daria commit.

### Mais três coisas que decorrem disso

- **Um schema de `response` pode ser aplicado.** O akkar tem o corpo inteiro em mãos
  antes de qualquer coisa ser escrita, então consegue filtrar campos não declarados. Um handler
  que faz `select *` não consegue vazar `password_hash`, e um corpo que quebra seu próprio
  contrato declarado é um 500, porque a culpa é do servidor.
- **O OpenAPI é derivável.** O schema usado para validação é o schema no
  documento. Nada descreve a si mesmo duas vezes.
- **O escopo do tenant permanece aplicável**, porque toda leitura passa por um builder
  em vez de uma string montada ao lado de um writer.

O `docs/ROADMAP.md` torna a dependência explícita ao rejeitar HTML renderizado no servidor: a forma de retorno "é o que torna escrever a resposta duas vezes
estruturalmente impossível, o que torna o OpenAPI derivável dos schemas e o que mantém
o escopo do tenant aplicável". São uma decisão só, não três.

## O que isso custa

Esta é a metade que a maioria das páginas como esta deixa de fora.

### Streaming precisa do seu próprio valor, e ele tem três arestas afiadas

Uma exportação de 200 MB não cabe em "retorne o corpo". A resposta do akkar mantém o
invariante retornando um valor que *descreve* um corpo produzido sob demanda:

```lua no-run
return akkar.stream(function(write)
  write '{"rows":['
  for i, row in ipairs(rows) do
    if i > 1 then write "," end
    write(cjson.encode(row))
  end
  write ']}'
end)
```

O produtor recebe `write` e nada mais. Sem conexão, sem status, sem
cabeçalhos, então ele ainda não consegue responder duas vezes. O que foi rejeitado foi a
alternativa óbvia, entregar ao handler o objeto de stream, porque isso tornaria
todo outro invariante condicional: uma válvula de escape desfaz a garantia para
todas as rotas, não só para as de streaming.

Os três custos estão escritos no `akkar/init.lua`, ao lado da função, e na
seção 10 do `docs/DECISIONS.md`:

1. **O status se compromete com o primeiro byte.** Um produtor que lança uma exceção depois de
   escrever não consegue virar um 500. O 200 já está no fio. O akkar registra isso em log e
   derruba a conexão sem o chunk final, então o cliente vê uma resposta truncada em vez de
   uma mentira com aparência de completa. Valide antes do primeiro `write`.
2. **Capabilities sobrevivem ao handler.** Um stream que lê de `req.db` mantém
   essa conexão até o último byte, porque liberá-la no retorno entregaria um cursor vivo à
   próxima requisição. Um cliente lento, portanto, segura um slot do pool enquanto estiver lendo.
3. **O prazo cobre o handler, não o corpo.** Uma exportação deve, por natureza,
   sobreviver a um orçamento de requisição de 30 segundos.

Nada disso é de graça, e nada disso fica escondido.

### Controle de fluxo por exceções

`error(akkar.not_found())` é uma exceção usada para um resultado não excepcional.
Algumas pessoas não gostam disso por princípio, e não estão sendo irracionais.
O `docs/DECISIONS.md` registra isso como o único custo honesto da escolha B, e os dois
estilos coexistem: um handler raso ainda escreve `return`.

### Isso descarta um produto inteiro

Uma engine de templates quer transmitir para dentro de uma resposta que ainda está sendo
montada, exatamente a mutação que este desenho recusa. Então o akkar não pode
crescer para incluir HTML renderizado no servidor como funcionalidade. O `docs/ROADMAP.md` decidiu, em
16 de agosto de 2026, que um akkar com renderização no servidor "não seria o akkar com mais
funcionalidades. Seria um framework diferente que por acaso compartilharia o event
loop". Se você quer HTML, esta é a ferramenta errada, e isso é uma decisão, não uma lacuna.

WebSocket é o mesmo tipo de problema. O `docs/ROADMAP.md`, no Tier 4, lista isso como
presente no lua-http e ainda assim **"não pequeno"**, porque uma conexão de longa duração
fora do modelo de requisição e resposta precisa de sua própria capability e sua própria
história de encerramento.

### Isso não impede que você esteja errado

A forma remove uma classe de bug. Ela não faz nada quanto a retornar o status
errado, o corpo errado, ou o corpo certo para o usuário errado. Vale deixar
claro que "estruturalmente impossível" se aplica a responder duas vezes e a mais nada.

## O que ler a seguir

- `docs/pt-BR/why/adapters.md`, porque `req.db` nos exemplos acima é a outra
  metade da mesma decisão.
- `docs/DECISIONS.md`, seções 4 e 10, para ver as alternativas lado a lado.
- `docs/pt-BR/guide/04-errors.md`, se você quiser ser mostrado em vez de argumentado.
