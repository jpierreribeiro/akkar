# 9. Conversando com ele a partir de um frontend

> **Português (Brasil)** | [Original em inglês](../../guide/09-a-frontend.md)

Ao final desta página, uma página web aberta no seu navegador vai fazer login na sua lista de tarefas e mostrar suas tarefas.

Você também vai aprender por que uma requisição (request) pode funcionar perfeitamente no `curl` e falhar no navegador. Essa é a forma mais comum de um primeiro frontend dar errado, e ela tem uma causa e uma correção.

## Dois servidores, não um

Até agora você tinha um terminal rodando um servidor. A partir daqui você precisa de dois servidores, porque é assim que uma configuração real se parece:

| | |
|---|---|
| `http://127.0.0.1:3000` | seu aplicativo akkar, o que você vem construindo |
| `http://127.0.0.1:5173` | um servidor web simples entregando um único arquivo HTML |

São duas **origens** diferentes. Uma origem é o esquema, o host e a porta juntos. `http://127.0.0.1:3000` e `http://127.0.0.1:5173` diferem na porta, então, para o navegador, elas são tão diferentes quanto os sites de dois estranhos.

Esse fato é a página inteira.

## A aplicação, sem mudanças por enquanto

Mesmo arquivo da página 8. Nada de novo nele ainda.

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local memory  = require "akkar.cache.memory"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local sql     = require "akkar.sql"
local crypto  = require "akkar.crypto"

local app = akkar.new()

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
  secure = false,
}

app:use(auth.middleware { sessions = sessions, optional = true })

local function signed_in(req)
  if not req.auth then
    error(akkar.unauthorized "please log in")
  end
  return req.auth.user_id
end

app:post("/signup", { body = { email = "string", password = "string" } },
function(req)
  local taken = req.db:one("select id from accounts where email = $1",
                           req.body.email)
  if taken then
    return akkar.conflict "that email already has an account"
  end

  local account = req.db:one(
    "insert into accounts (email, password_hash) values ($1, $2) returning id",
    req.body.email, crypto.hash_password(req.body.password))

  auth.login(req, account.id)
  return akkar.created { id = account.id, email = req.body.email }
end)

app:post("/login", { body = { email = "string", password = "string" } },
function(req)
  local account = req.db:one(
    "select id, password_hash from accounts where email = $1", req.body.email)
  if not account
     or not crypto.verify_password(req.body.password, account.password_hash) then
    return akkar.unauthorized "wrong email or password"
  end
  auth.login(req, account.id)
  return { id = account.id, email = req.body.email }
end)

app:post("/logout", function(req)
  auth.logout(req)
  return akkar.no_content()
end)

app:get("/tasks", function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  local rows = mine:many(sql.select("id, title, done"):from "tasks")
  return { tasks = akkar.array(rows) }
end)

app:post("/tasks", { body = { title = "string" } }, function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  return akkar.created(mine:one(
    sql.insert_into("tasks", { title = req.body.title }, { "title" })
       :returning "id, title, done"))
end)

app:run {
  port = 3000,
  db = db.connect {
    host = "127.0.0.1", port = 55432, database = "akkar",
    user = "postgres", password = "akkar",
  },
  cache = memory.new(),
}
```

Inicie-o no terminal um:

```sh
lua5.4 app.lua
```

## Uma conta para fazer login

Crie uma agora, para que a página tenha com quem conversar.

```sh
curl -s -X POST http://127.0.0.1:3000/signup \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"correct horse battery"}'
```

```
{"email":"grace@example.com","id":5}
```

Seu `id` vai ser um número diferente. Tudo bem, nada abaixo depende disso.

## A página web

Crie uma pasta chamada `web` ao lado de `app.lua` e coloque isto em `web/index.html`. É o frontend inteiro. Não há etapa de build nem framework.

```html
<!doctype html>
<meta charset="utf-8">
<title>My tasks</title>

<h1>My tasks</h1>

<form id="login">
  <input id="email" value="grace@example.com">
  <input id="password" type="password" value="correct horse battery">
  <button>Log in</button>
</form>

<button id="load">Load my tasks</button>

<pre id="out">nothing yet</pre>

<script>
const API = "http://127.0.0.1:3000";

login.onsubmit = async (event) => {
  event.preventDefault();
  const res = await fetch(API + "/login", {
    method: "POST",
    headers: { "content-type": "application/json" },
    credentials: "include",
    body: JSON.stringify({ email: email.value, password: password.value }),
  });
  out.textContent = res.status + " " + await res.text();
};

load.onclick = async () => {
  const res = await fetch(API + "/tasks", { credentials: "include" });
  out.textContent = res.status + " " + await res.text();
};
</script>
```

Três coisas nesse arquivo merecem ser nomeadas, porque o resto é HTML comum.

**`fetch`** é como uma página web faz uma requisição (request) HTTP. Ele retorna uma promise, então `await` espera pela resposta (response). `res.status` é o número que você vem lendo em `curl -i` esse tempo todo.

**`JSON.stringify`** transforma um objeto JavaScript no texto JSON que seu servidor espera, e o cabeçalho `content-type` diz ao servidor que é isso que é. Exatamente o que o `curl -d` estava fazendo por você.

**`credentials: "include"`** é a linha pela qual esta página existe. Deixe-a por enquanto. Ela tem sua própria seção mais abaixo, e não vai fazer nada útil até que o CORS esteja funcionando.

## Servindo a página

Não abra o arquivo dando duplo clique nele. Um arquivo aberto dessa forma tem a origem `null`, e nada nesta página vai funcionar.

Sirva-o em vez disso. Em um **terceiro terminal**:

```sh
cd web
python3 -m http.server 5173 --bind 127.0.0.1
```

```
Serving HTTP on 127.0.0.1 port 5173 (http://127.0.0.1:5173/) ...
```

Qualquer servidor estático pequeno serve. O `python3` é usado aqui porque já está presente na maioria das máquinas.

Agora abra `http://127.0.0.1:5173/index.html` no seu navegador.

## Não funciona, e nada diz por quê

Clique em **Load my tasks**. Nada acontece. O texto `nothing yet` não muda.

Clique em **Log in**. Nada acontece também.

Essa é a pior parte de toda a experiência, então vale a pena dizer claramente: **a página não está quebrada, e o seu servidor também não.** O navegador se recusou a entregar a resposta ao seu JavaScript, e não disse à página o motivo.

O motivo está no console do navegador. Abra-o com `F12`, ou clique com o botão direito na página e escolha **Inspect**, depois a aba **Console**. Clique nos botões de novo.

Depois de **Load my tasks**:

```
Access to fetch at 'http://127.0.0.1:3000/tasks' from origin
'http://127.0.0.1:5173' has been blocked by CORS policy: No
'Access-Control-Allow-Origin' header is present on the requested resource.
```

Depois de **Log in**:

```
Access to fetch at 'http://127.0.0.1:3000/login' from origin
'http://127.0.0.1:5173' has been blocked by CORS policy: Response to preflight
request doesn't pass access control check: No 'Access-Control-Allow-Origin'
header is present on the requested resource.
```

Acostume-se a recorrer a esse console cedo. É o único lugar onde a mensagem real aparece.

## O que é CORS, em uma tela

O navegador segue uma regra chamada **same-origin policy** (política de mesma origem). Código carregado de uma origem não pode ler a resposta (response) de outra origem.

A regra existe para proteger você, não o servidor. Imagine que você está logado no seu banco. Você abre uma página em `evil.example`. Sem a regra, o JavaScript dessa página poderia chamar a API do seu banco, e seu navegador anexaria alegremente os cookies do seu banco à requisição. A página leria seu saldo e o enviaria para qualquer lugar. Isso não é hipotético; é o motivo pelo qual a regra foi criada.

Por isso o navegador bloqueia por padrão, e pede permissão ao outro servidor. **CORS**, sigla para cross-origin resource sharing (compartilhamento de recursos entre origens), é a forma como o servidor concede essa permissão. É um conjunto de cabeçalhos de resposta que dizem "estas origens podem ler minhas respostas".

Três coisas decorrem disso, e cada uma surpreende as pessoas:

**O servidor não está recusando.** Seu aplicativo akkar respondeu normalmente. O navegador fez a requisição, recebeu a resposta, não viu nenhum cabeçalho de permissão nela, e descartou a resposta antes que seu JavaScript pudesse vê-la. O bloqueio acontece do lado da leitura, não do envio.

**Por isso o `curl` não consegue ver o problema.** O `curl` não é um navegador e não tem same-origin policy. Prove isso a si mesmo enquanto a página ainda está quebrada:

```sh
curl -s -i -c cookies.txt -X POST http://127.0.0.1:3000/login \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"correct horse battery"}'
```

```
HTTP/1.1 200 OK
set-cookie: akkar_session=f78581c309abe921d47c0fba43ab760933a44ab5732672de13bbafd09e49df13.74bad22e6c02257572e2ce90a86c4884ad7257e0b94aaf8039d59b13a94ab907; Path=/; Max-Age=1209600; HttpOnly; SameSite=Lax
x-request-id: 882325a3000001
content-type: application/json
content-length: 36

{"email":"grace@example.com","id":5}
```

```sh
curl -s -i -b cookies.txt http://127.0.0.1:3000/tasks
```

```
HTTP/1.1 200 OK
x-request-id: 882325a3000002
content-type: application/json
content-length: 57

{"tasks":[{"done":false,"title":"call the bank","id":9}]}
```

Ambos funcionam. **"Funciona no curl" não é evidência de que um problema de CORS não é um problema de CORS.** É o resultado esperado.

**A segunda mensagem de erro mencionou um preflight.** Para algumas requisições, o navegador pede permissão antes, com uma requisição `OPTIONS` separada, antes mesmo de enviar a sua. Há uma seção sobre isso mais abaixo. É um passo extra, não uma ideia nova.

## Concedendo permissão, primeiro do jeito errado

O akkar tem o middleware para isso. Adicione estas linhas a `app.lua`, logo depois de `akkar.new()`:

```lua no-run
app:use(akkar.cors {
  origin = "*",
})
```

`*` significa "qualquer origem, sem exceção". É o que todo resultado de busca sugere, e é a primeira coisa que todo mundo tenta.

Reinicie o servidor e clique em **Log in** de novo. O console agora diz algo diferente:

```
Access to fetch at 'http://127.0.0.1:3000/login' from origin
'http://127.0.0.1:5173' has been blocked by CORS policy: Response to preflight
request doesn't pass access control check: The value of the
'Access-Control-Allow-Origin' header in the response must not be the wildcard
'*' when the request's credentials mode is 'include'.
```

Um erro diferente é progresso. O navegador agora está lendo seu cabeçalho de permissão, e está recusando essa permissão específica.

A regra que ele está aplicando é simples uma vez dita: **você pode dizer "qualquer um pode ler isto", ou pode dizer "e envie os cookies também", mas nunca as duas coisas.** "Qualquer um pode ler isto, com os cookies do usuário anexados" é exatamente o ataque que a same-origin policy existe para impedir, então o navegador não vai deixar um servidor conceder isso nem por acidente.

Sua lista de tarefas precisa de cookies. Então o coringa está descartado.

## Concedendo permissão, do jeito certo

Nomeie a origem, e diga que credenciais são permitidas.

```lua no-run
app:use(akkar.cors {
  origin = "http://127.0.0.1:5173",
  credentials = true,
})
```

Reinicie o servidor. Clique em **Log in**, depois em **Load my tasks**. A caixa cinza abaixo dos botões mostra, em sequência:

```
200 {"id":5,"email":"grace@example.com"}
```

```
200 {"tasks":[{"id":9,"title":"call the bank","done":false}]}
```

Isso é um navegador, em uma origem, logado na sua API em outra origem, lendo linhas que pertencem a essa conta e a mais ninguém.

Duas observações sobre as opções:

- `origin` é uma string de origem exata. Faça a correspondência caractere por caractere, incluindo o esquema e a porta. `http://localhost:5173` **não** é a mesma origem que `http://127.0.0.1:5173`, mesmo que ambos alcancem a mesma máquina.
- `credentials = true` envia o cabeçalho `access-control-allow-credentials`, que é a metade do servidor no acordo dos cookies. A metade da página é a próxima seção.

Quando você fizer o deploy, isso se torna o endereço real do seu frontend. A página 12 o lê a partir de uma variável de ambiente, em vez de escrevê-lo no arquivo.

## `credentials: "include"`, a pegadinha que atrapalha todo mundo

Aqui está a falha que faz as pessoas procurarem no lugar completamente errado.

Remova as duas linhas `credentials: "include"` de `index.html`, para que as chamadas fetch fiquem assim:

```js
const res = await fetch(API + "/login", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ email: email.value, password: password.value }),
});
```

```js
const res = await fetch(API + "/tasks");
```

Recarregue a página e clique nos dois botões em sequência. A caixa cinza mostra:

```
200 {"id":5,"email":"grace@example.com"}
```

```
401 {"error":"please log in"}
```

**Leia isso duas vezes.** O login disse `200`. Funcionou. A requisição seguinte diz que você não está logado.

Não há nada de errado com o seu servidor. O `curl` faz exatamente essa sequência e recebe `200` nas duas vezes, e é por isso que horas se perdem aqui.

A causa: **o `fetch` não envia nem armazena cookies entre origens, a menos que você diga a ele para fazer isso.** Por padrão, ele se comporta como se o `Set-Cookie` daquele `200` nunca tivesse chegado. O navegador recebeu o cookie e o descartou, então a próxima requisição não carregou nada, então seu servidor corretamente disse "please log in".

`credentials: "include"` é o que ativa os cookies para um `fetch` entre origens. Ele faz dois trabalhos ao mesmo tempo, e os dois importam:

- ele permite que o navegador **armazene** um `Set-Cookie` que volta de outra origem;
- ele faz o navegador **anexar** esse cookie a requisições futuras para essa origem.

Coloque as duas linhas de volta. Funciona de novo.

As duas metades precisam concordar, e não há um erro útil quando isso não acontece:

| | a página envia | o servidor permite | resultado |
|---|---|---|---|
| ambos desligados | nenhum cookie | nenhuma credencial | você nunca fica logado |
| só a página | cookies | nenhuma credencial | bloqueado, erro de CORS no console |
| só o servidor | nenhum cookie | credenciais | você nunca fica logado |
| ambos ligados | cookies | credenciais | funciona |

Duas dessas quatro linhas falham silenciosamente do ponto de vista da página, e é por isso que essa é a pergunta mais buscada sobre navegadores e APIs.

## O preflight, já que você viu o nome

Seu `POST /login` envia `content-type: application/json`. Isso já é suficiente para fazer o navegador pedir permissão antes de enviar qualquer coisa.

A pergunta de permissão é uma requisição `OPTIONS`. Você pode enviar uma manualmente:

```sh
curl -s -i -X OPTIONS http://127.0.0.1:3000/login \
  -H "Origin: http://127.0.0.1:5173" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type"
```

```
HTTP/1.1 204 No Content
access-control-allow-origin: http://127.0.0.1:5173
allow: OPTIONS, POST
access-control-allow-methods: OPTIONS, POST
access-control-allow-credentials: true
access-control-allow-headers: content-type, authorization
access-control-max-age: 600
x-request-id: 8ab1738b000009
content-length: 0
```

Leia isso como uma conversa. O navegador perguntou "`http://127.0.0.1:5173` pode enviar um `POST` com um cabeçalho `content-type`?" e o servidor respondeu "sim, e `OPTIONS` e `POST` são os métodos que esse caminho tem, e não pergunte de novo pelos próximos 600 segundos".

Você não escreveu nenhuma rota `OPTIONS`. O akkar responde aos preflights a partir da sua própria tabela de rotas, então `access-control-allow-methods` lista os métodos que realmente existem naquele caminho, em vez de um palpite. É também por isso que `allow` diz `OPTIONS, POST` e não, digamos, `DELETE`.

**Esse é o primeiro lugar a olhar quando uma requisição funciona no `curl` e não no navegador.** Rode o `OPTIONS` acima contra o caminho que está falhando. Se ele não voltar com a sua origem nele, o preflight é a falha.

## Por que a lista de tarefas é envolvida em `akkar.array`

Há uma chamada em `GET /tasks` que ainda não foi explicada, e é no navegador que ela mostra seu valor.

Crie uma segunda conta, uma sem nenhuma tarefa:

```sh
curl -s -c new-cookies.txt -X POST http://127.0.0.1:3000/signup \
  -H "content-type: application/json" \
  -d '{"email":"hamilton@example.com","password":"correct horse battery"}'
```

```
{"id":12,"email":"hamilton@example.com"}
```

Agora imagine o handler sem essa chamada, escrito da forma simples:

```lua no-run
app:get("/tasks", function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  return { tasks = mine:many(sql.select("id, title, done"):from "tasks") }
end)
```

```sh
curl -s -b new-cookies.txt http://127.0.0.1:3000/tasks
```

```
{"tasks":{}}
```

`{}`, e não `[]`.

**Isso é um bug, e é seu para consertar, não do navegador para sobreviver.** Um endpoint cujo tipo depende de quantos dados ele encontrou é um endpoint para o qual todo chamador precisa escrever um caso especial.

No `curl` isso parece uma curiosidade. No navegador é uma queda: `data.tasks.map(...)` sobre `{}` lança `data.tasks.map is not a function`, e isso só acontece para contas sem nada nelas, que é todo usuário recém-criado.

A causa é uma ambiguidade real no Lua. Uma tabela Lua vazia é ao mesmo tempo uma lista vazia e um objeto vazio, e nada na tabela diz qual das duas você quis dizer. O codificador JSON do akkar precisa adivinhar, e ele adivinha `{}`.

`akkar.array` é como você diz qual das duas você quis dizer, e é por isso que o handler no seu arquivo se lê assim, em vez disso:

```lua no-run
app:get("/tasks", function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  local rows = mine:many(sql.select("id, title, done"):from "tasks")
  return { tasks = akkar.array(rows) }
end)
```

```sh
curl -s -b new-cookies.txt http://127.0.0.1:3000/tasks
```

```
{"tasks":[]}
```

Só o caso vazio mudou. Adicione uma tarefa e a resposta é a mesma de qualquer forma, porque uma lista com linhas dentro já era um array:

```sh
curl -s -b new-cookies.txt -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"buy a birthday card"}'
```

```
{"id":12,"title":"buy a birthday card","done":false}
```

```sh
curl -s -b new-cookies.txt http://127.0.0.1:3000/tasks
```

```
{"tasks":[{"id":12,"title":"buy a birthday card","done":false}]}
```

**Envolva toda lista que você retornar.** Isso custa uma chamada e elimina uma classe inteira de bug de frontend que aparece só para as contas mais vazias e mais novas, que são exatamente as que você testa por último.

Se você está consumindo uma API que outra pessoa escreveu e ela faz isso, a proteção do seu lado é uma linha:

```js
const tasks = Array.isArray(data.tasks) ? data.tasks : [];
```

## A aplicação inteira

`app.lua`, com as quatro linhas novas nele:

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local memory  = require "akkar.cache.memory"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local sql     = require "akkar.sql"
local crypto  = require "akkar.crypto"

local app = akkar.new()

app:use(akkar.cors {
  origin = "http://127.0.0.1:5173",
  credentials = true,
})

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
  secure = false,
}

app:use(auth.middleware { sessions = sessions, optional = true })

local function signed_in(req)
  if not req.auth then
    error(akkar.unauthorized "please log in")
  end
  return req.auth.user_id
end

app:post("/signup", { body = { email = "string", password = "string" } },
function(req)
  local taken = req.db:one("select id from accounts where email = $1",
                           req.body.email)
  if taken then
    return akkar.conflict "that email already has an account"
  end

  local account = req.db:one(
    "insert into accounts (email, password_hash) values ($1, $2) returning id",
    req.body.email, crypto.hash_password(req.body.password))

  auth.login(req, account.id)
  return akkar.created { id = account.id, email = req.body.email }
end)

app:post("/login", { body = { email = "string", password = "string" } },
function(req)
  local account = req.db:one(
    "select id, password_hash from accounts where email = $1", req.body.email)
  if not account
     or not crypto.verify_password(req.body.password, account.password_hash) then
    return akkar.unauthorized "wrong email or password"
  end
  auth.login(req, account.id)
  return { id = account.id, email = req.body.email }
end)

app:post("/logout", function(req)
  auth.logout(req)
  return akkar.no_content()
end)

app:get("/tasks", function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  local rows = mine:many(sql.select("id, title, done"):from "tasks")
  return { tasks = akkar.array(rows) }
end)

app:post("/tasks", { body = { title = "string" } }, function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  return akkar.created(mine:one(
    sql.insert_into("tasks", { title = req.body.title }, { "title" })
       :returning "id, title, done"))
end)

app:run {
  port = 3000,
  db = db.connect {
    host = "127.0.0.1", port = 55432, database = "akkar",
    user = "postgres", password = "akkar",
  },
  cache = memory.new(),
}
```

Um aviso sobre reiniciar. As sessões vivem em `akkar.cache.memory`, que vive dentro do processo. Pare o servidor e toda sessão desaparece, então a página precisa fazer login de novo. A página 11 as move para o Redis, que sobrevive a um reinício.

## Checkpoint

Você tem isso se:

- a página no navegador faz login e lista as tarefas, sem texto vermelho no console
- você consegue dizer por que o navegador bloqueou a primeira tentativa e o `curl` não
- você consegue dizer o que `credentials: "include"` faz, e o que acontece sem ele
- `curl -X OPTIONS` contra `/login` responde com a sua origem nele

A seguir no guia: trabalho que acontece depois que a resposta já foi enviada.
