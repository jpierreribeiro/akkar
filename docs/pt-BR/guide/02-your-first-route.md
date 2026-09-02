# 2. Sua primeira rota

> **Português (Brasil)** | [Original em inglês](../../guide/02-your-first-route.md)

Ao final desta página, você terá um servidor rodando na sua máquina que responde a `GET /tasks` com uma lista de tarefas em JSON.

Você precisa ter o akkar instalado. Se ainda não fez isso, siga os passos 1 a 3 do [Quickstart](00-quickstart.md) primeiro, depois volte aqui.

## O arquivo inteiro

Crie `app.lua` dentro da pasta `akkar`. Este é o arquivo completo. Nada está faltando e nada está abreviado.

```lua
local akkar = require "akkar"

local app = akkar.new()

app:get("/tasks", function()
  return {
    tasks = {
      { id = 1, title = "buy milk",       done = false },
      { id = 2, title = "read the guide", done = true  },
    },
  }
end)

app:run { port = 3000 }
```

Execute:

```sh
lua5.4 app.lua
```

```
INFO  listening url=http://127.0.0.1:3000
```

Deixe rodando. Em um **segundo terminal**:

```sh
curl http://127.0.0.1:3000/tasks
```

```
{"tasks":[{"id":1,"title":"buy milk","done":false},{"id":2,"title":"read the guide","done":true}]}
```

Isso é um backend funcionando. Seis linhas dele são suas.

## O que cada linha faz

**`local akkar = require "akkar"`**

Carrega o akkar e o coloca em uma variável chamada `akkar`. Todo arquivo Lua que usa akkar começa com essa linha.

**`local app = akkar.new()`**

Cria uma aplicação vazia. Ela ainda não tem rotas, então agora mesmo não responderia nada.

**`app:get("/tasks", function() ... end)`**

Adiciona uma rota. Leia como uma frase: quando chegar uma requisição (request) `GET` para o caminho `/tasks`, execute esta função.

A função é escrita inline, entre `function()` e `end`. Ela não é chamada agora. O akkar a guarda e a chama depois, uma vez para cada requisição que corresponder.

Há uma dessas para cada método: `app:get`, `app:post`, `app:put`, `app:patch`, `app:delete`.

**`return { ... }`**

O handler retorna uma tabela Lua. O akkar transforma essa tabela em JSON e a envia de volta com status `200 OK`.

Essa é a parte diferente da maioria dos frameworks, e vale a pena notar isso agora. Sua função não escreve a resposta (response). Ela não recebe uma conexão para manipular. Ela retorna um valor, e o akkar faz o resto. Isso significa que você nunca pode responder a mesma requisição duas vezes por acidente, porque não há nada para chamar duas vezes.

**`app:run { port = 3000 }`**

Abre a porta e espera. Essa linha nunca retorna. Tudo depois dela no arquivo nunca seria executado.

## Um pouco de Lua, se você é novo nisso

Alguns detalhes de Lua aparecem ao longo deste guia. Aqui estão eles de uma vez, para que nenhuma página posterior precise parar para explicar.

**`local x = ...`** declara uma variável. Sempre escreva `local`. Sem isso a variável é global, o que em um servidor significa que ela é compartilhada entre requisições, e um chamador pode ver os dados de outro chamador.

**Tabelas são o único container que o Lua tem.** `{ id = 1 }` é uma tabela com um nome dentro. `{ "a", "b" }` é uma tabela com dois valores em ordem. São o mesmo tipo de coisa, por isso uma única sintaxe cobre as duas.

**`t[1]` é o primeiro item, não `t[0]`.** Lua conta a partir de 1.

**`#t` é quantos itens há em uma lista**, então `t[#t + 1] = x` adiciona um ao final.

**`for _, item in ipairs(t) do ... end`** percorre uma lista em ordem. `ipairs` te dá a posição e o valor, e `_` é o nome comum para "eu não preciso deste aqui".

**`app:get(...)` tem dois-pontos, `akkar.new()` tem ponto.** Os dois-pontos passam a coisa à esquerda para a função como um primeiro argumento oculto. Você não precisa pensar sobre isso, apenas digitar o correto, e este guia sempre mostra qual usar.

**`nil` significa "sem valor".** Um nome que nunca foi definido é `nil`, e usar `nil` como se fosse uma tabela é o erro Lua mais comum que você vai ver: `attempt to index a nil value`.

## Como a tabela virou JSON

Tabelas Lua vêm em dois formatos, e o JSON tem um formato correspondente para cada um. Os dois blocos Lua abaixo estão marcados como `no-run`, porque são valores isolados e não arquivos completos. Todo bloco marcado apenas como `lua` neste guia é um arquivo completo que você pode executar.

Uma tabela com **nomes** vira um objeto JSON com `{ }`:

```lua no-run
{ id = 1, title = "buy milk" }
```

```
{"id":1,"title":"buy milk"}
```

Uma tabela **sem nomes**, apenas valores em ordem, vira uma lista JSON com `[ ]`:

```lua no-run
{ "buy milk", "walk the dog" }
```

```
["buy milk","walk the dog"]
```

O arquivo acima aninha uma dentro da outra. `tasks` é um nome, e seu valor é uma lista, e cada item da lista é um objeto. É por isso que a saída tem `{"tasks":[{...},{...}]}`.

**Uma coisa que vai te confundir se ninguém avisar:** a ordem dos campos no JSON não é fixa. Você pode obter `{"id":1,"title":"buy milk"}` em uma execução e `{"title":"buy milk","id":1}` na próxima. Lua não guarda a ordem em que você digitou os nomes, então a saída também não guarda. Isso é normal. Objetos JSON não têm ordem, e todo leitor de JSON no mundo trata esses dois como idênticos. Nunca escreva código que dependa da ordem dos campos.

## Os dois primeiros erros que você vai encontrar

Deixe o servidor rodando e tente isto. Vale a pena ver de propósito, porque você vai encontrar isso por acidente mais tarde.

### Pedindo um caminho que não tem rota

```sh
curl -i http://127.0.0.1:3000/task
```

`curl -i` mostra os cabeçalhos da resposta além do corpo, que é como você vê o código de status.

```
HTTP/1.1 404 Not Found
x-request-id: eaee221f000004
content-type: application/json
content-length: 35

{"error":"no route for GET \/task"}
```

`404` significa que o caminho não existe aqui. Note o erro de digitação: a rota é `/tasks` e a requisição pediu `/task`. O akkar te diz exatamente qual método e caminho ele não conseguiu corresponder, o que geralmente é suficiente para localizar o problema.

(O `\/` é apenas a forma do JSON de escrever `/`. Significa a mesma coisa. `x-request-id` é um id que o akkar coloca em cada resposta para que você possa encontrar aquela requisição específica nos logs depois.)

### Usando o método errado

```sh
curl -i -X POST http://127.0.0.1:3000/tasks
```

```
HTTP/1.1 405 Method Not Allowed
allow: GET
x-request-id: eaee221f000005
content-type: application/json
content-length: 48

{"allowed":["GET"],"error":"method not allowed"}
```

`405` é diferente de `404` e a diferença é útil. `404` significa que o caminho não existe. `405` significa que o caminho existe, mas não com esse método. O cabeçalho `allow` diz quais métodos funcionariam, então você pode ver que `/tasks` aceita `GET` e nada mais. Você não escreveu nenhum código para produzir isso. O akkar sabe quais rotas existem, então ele pode responder isso sozinho.

### Mais um, porque é um erro real

Mude o handler para retornar uma string em vez de uma tabela:

```lua
local akkar = require "akkar"

local app = akkar.new()

app:get("/tasks", function()
  return "buy milk"
end)

app:run { port = 3000 }
```

Pare o servidor com `Ctrl-C`, inicie-o novamente, e chame-o:

```sh
curl -i http://127.0.0.1:3000/tasks
```

```
HTTP/1.1 500 Internal Server Error
x-request-id: 80a40ab1000002
content-type: application/json
content-length: 33

{"error":"internal server error"}
```

O chamador não recebe nada útil, de propósito. Olhe o terminal rodando o servidor:

```
ERROR handler raised at=app.lua:5 detail=handler returned string; return a table, nil, or akkar.*() request_id=80a40ab1000002
```

Aí está a mensagem real, com o número da linha da sua rota. Um handler deve retornar uma tabela, ou `nil`, ou um dos helpers de resposta do akkar. A página 4 cobre esses helpers e explica por que o detalhe fica no seu log em vez de ir para o chamador.

Coloque a versão com a tabela de volta antes de continuar.

## Checkpoint

Você conseguiu isso se:

- `lua5.4 app.lua` imprime `listening url=http://127.0.0.1:3000` e continua rodando
- `curl http://127.0.0.1:3000/tasks` imprime suas duas tarefas como JSON
- `curl -i http://127.0.0.1:3000/task` te dá um `404`, e você sabe por quê

Agora mesmo a lista é fixa. Todo chamador recebe as mesmas duas tarefas e não há como pedir uma delas especificamente. Isso é o próximo passo: [3. Reading input](03-reading-input.md).
