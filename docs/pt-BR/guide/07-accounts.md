# 7. Contas

> **Português (Brasil)** | [Original em inglês](../../guide/07-accounts.md)

Ao final desta página sua aplicação terá contas. Alguém vai poder se cadastrar, fazer login, perguntar quem é e fazer logout. As senhas serão armazenadas de uma forma inútil para um ladrão.

As tarefas continuam compartilhadas por todo mundo depois desta página. Fazer uma tarefa pertencer a uma pessoa é assunto da [página 8](08-only-your-own.md). Esta página é sobre saber quem está perguntando.

Você vai precisar do banco de dados da [página 5](05-a-database.md) e da aplicação da [página 6](06-storing-and-reading.md).

## Nunca armazene a senha

Uma conta é um e-mail, uma senha e uma forma de provar depois que a mesma pessoa voltou.

A primeira regra é a que importa: **a senha nunca é armazenada.** Nem criptografada, nem escondida, nem numa coluna chamada `secret`. Bancos de dados vazam. Vazam por um backup esquecido num notebook, uma cópia antiga que ninguém apagou, um erro numa query. Quando o seu vazar, as pessoas nele não podem perder nada além do seu serviço, e a maioria delas usou essa senha em outro lugar também.

O que você armazena em vez disso é um **hash**: a saída de uma função de mão única. Dá para ir da senha até o hash, e não tem como voltar. Quando alguém faz login, você faz o hash do que a pessoa digitou e compara os dois hashes.

### Por que não escrever isso você mesmo

Fazer hash parece fácil. Uma função de hash é uma chamada só. São os detalhes ao redor dela que decidem se o resultado vale alguma coisa, e cada um desses detalhes é invisível quando você erra. Nada quebra. Os testes passam. A página de login funciona.

Três exemplos, para que "não invente isso" seja uma razão em vez de uma ordem:

**Um hash rápido não é suficiente.** SHA-256 foi feito para ser rápido, e uma placa de vídeo roda bilhões deles por segundo. Contra uma tabela vazada, isso significa adivinhar toda senha comum para todo usuário numa tarde. Um hash de senha tem que ser feito para ser lento.

**Duas pessoas com a mesma senha não podem ter o mesmo hash.** Senão um olhar na tabela já diz quais contas compartilham senha, e quebrar uma quebra todas. A solução é um **salt**: bytes aleatórios, diferentes para cada senha, armazenados junto com o hash.

**Comparar com `==` vaza a resposta.** A comparação de strings para no primeiro byte diferente, então um palpite errado que compartilha os primeiros dez caracteres demora mensuravelmente mais para ser rejeitado. Com tentativas suficientes, essa diferença conta pra um atacante o segredo um byte de cada vez.

`akkar.crypto` já cuida dos três. Use.

### Como fica

Crie `hash.lua` na pasta `akkar`. Este é o arquivo inteiro.

```lua
local crypto = require "akkar.crypto"

local started = os.clock()
local hash = crypto.hash_password "correct horse battery staple"
print(hash)
print(("hashing took %.0f ms"):format((os.clock() - started) * 1000))

print("right password:", crypto.verify_password("correct horse battery staple", hash))
print("wrong password:", crypto.verify_password("hunter2", hash))
```

```sh
lua5.4 hash.lua
```

```
pbkdf2-sha256$600000$895ddfacd6bf6ab42c9a3f6842d4b4c5$37652a68a1d6f67c4d1e3f6cbb4a33a6a007d1d281ebc9fe3ba6a457162ebb19
hashing took 771 ms
right password:	true	false
wrong password:	false	false
```

Rode duas vezes e o hash sai diferente nas duas, mesmo com a senha sendo a mesma. É o salt fazendo o trabalho dele.

Essa linha é quatro campos unidos por `$`:

| Campo | É |
|---|---|
| `pbkdf2-sha256` | qual algoritmo o fez |
| `600000` | quantas vezes foi repetido, para ficar lento |
| `c999f3...` | o salt, aleatório, diferente toda vez |
| `b3f207...` | o hash em si |

Tudo isso fica numa única coluna `text`. Ele se descreve sozinho, então no dia em que você decidir que 600.000 rounds não são mais suficientes, os hashes antigos continuam funcionando e são atualizados conforme as pessoas fazem login.

`verify_password` devolve **dois** valores. O primeiro é o que você quer: se a senha bateu. O segundo diz se aquele hash foi feito com menos rounds do que a configuração de hoje, que é como acontece a atualização acima. `if crypto.verify_password(...)` lê o primeiro e ignora o segundo, que é o que este guia faz.

## É lento de propósito, e isso é problema seu para planejar

Esses 600.000 rounds não são acidente. Lentidão é a defesa. Olhe de novo a linha que `hash.lua` imprimiu:

```
hashing took 771 ms
```

Três quartos de segundo, e verificar uma senha no login custa o mesmo, porque faz o mesmo trabalho. Agora lembre o que é o akkar: **um processo, um núcleo, uma coisa de cada vez.** Enquanto esse hash roda, seu servidor não está respondendo mais ninguém. Não lentamente. De jeito nenhum.

Você pode ver isso acontecer assim que a aplicação no fim desta página estiver rodando. Volte e tente depois. Uma requisição (request) faz o cadastro, e uma segunda requisição que não faz nada é enviada um décimo de segundo depois:

```sh
curl -s -o /dev/null -X POST http://127.0.0.1:3000/accounts \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"correct horse battery"}' &
sleep 0.1
curl -s -o /dev/null -w "logout answered in %{time_total}s\n" \
  -X POST http://127.0.0.1:3000/logout
```

```
logout answered in 0.694522s
```

A mesma requisição contra um servidor sem mais nada para fazer:

```
logout on an idle server: 0.001002s
```

Setecentas vezes mais lento, e a segunda requisição não fez trabalho nenhum. Ela simplesmente esperou a sua vez.

**É para isso que serve o `akkar.work`**, e vale a pena ler a documentação dele antes de precisar. Ele pega um trabalho que travaria o processo e o divide em pedaços, dando a outras requisições uma vez no meio do caminho.

Ele não consegue dividir esta aqui, e o próprio módulo diz isso. Dividir um trabalho em pedaços precisa de um lugar para dividir, e o hashing é uma única chamada que desce até C e não volta até terminar. O watchdog do akkar, que normalmente avisa exatamente sobre isso, nem enxerga isso: o watchdog conta instruções Lua, e nenhuma instrução Lua roda lá dentro.

Então as opções honestas são estas, e nenhuma delas é um helper que você importa:

- **Aceitar.** Cadastro e login são raros comparados com tudo mais que o seu serviço faz. Para uma aplicação pequena essa é uma resposta de verdade.
- **Rodar vários processos.** Com quatro processos, um worker travado é um quarto da sua capacidade em vez de tudo. A página 12 chega lá.
- **Tirar isso da requisição.** Passar o trabalho para um job em segundo plano e responder ao chamador na hora, o que muda o que o seu endpoint promete. A página 10 cobre jobs.

Dizer isso claramente é mais útil do que uma função que finge que o custo sumiu.

## Duas formas de lembrar de alguém: sessões e tokens

A senha prova quem a pessoa é uma vez. Depois o navegador faz mais cem requisições e cada uma chega sem saber de nada. Alguma coisa tem que carregar a resposta adiante.

Existem duas formas, e a diferença cabe numa frase.

**Um token carrega a resposta consigo.** O servidor assina um pequeno pedaço de dado dizendo "esta é a conta 1, válida até sexta" e entrega. Toda requisição posterior traz ele de volta, o servidor verifica a assinatura, e é só isso. O servidor não guarda nada.

**Uma sessão mantém a resposta no servidor.** O servidor armazena "esta é a conta 1" sob um id aleatório, e entrega só o id. Toda requisição posterior traz o id de volta, e o servidor faz a busca.

Eles parecem parecidos, e aí alguém precisa ser deslogado.

**Uma sessão pode ser revogada. Um token não.** Apagar a sessão é um delete: o id ainda existe, e agora aponta para nada. Um token continua válido até expirar, porque tudo que ele precisa está dentro dele e o servidor não tem nada para apagar. Não existe "pegar de volta". Isso importa exatamente no dia em que mais importa: um notebook roubado, uma máquina compartilhada, uma troca de senha, uma conta que você precisa encerrar agora.

O akkar faz sessões, e mantém o id num cookie. Cookies acertam mais uma coisa que é fácil deixar passar: um cookie marcado como `HttpOnly` não pode ser lido por JavaScript de jeito nenhum, então um script que consiga rodar na sua página não consegue roubá-lo. Um token guardado em `localStorage` pode ser lido por qualquer script da página.

## A sessão precisa de um lugar para guardar o estado

O servidor tem que guardar "a sessão abc pertence à conta 1" em algum lugar. O akkar chama esse lugar de **cache**, e é uma capability separada, igual ao banco de dados:

```lua no-run
local memory = require "akkar.cache.memory"

app:run { port = 3000, db = open, cache = memory.factory() }
```

`akkar.cache.memory` é um cache de verdade que vive na memória deste processo. Nada para instalar. Duas consequências que vale a pena conhecer antes que te peguem de surpresa:

- **Reinicie o servidor e todo mundo é deslogado**, porque a memória foi junto com o processo. No desenvolvimento tudo bem. É também por isso que uma página que você acabou de reiniciar responde `log in first` até você fazer login de novo.
- **Ela pertence a um processo.** Rode duas cópias do seu servidor e elas terão dois conjuntos separados de sessões. O Redis é a resposta quando esse dia chegar, e é uma mudança de uma linha, porque `cache` é uma capability.

Esqueça o cache completamente e a primeira requisição que toca numa sessão avisa:

```
ERROR middleware raised detail=...akkar/session.lua:106: req.cache is not configured; pass cache = ... to app:run{} request_id=d722f1e1000001
```

## Middleware, que é novidade aqui

Até agora toda rota era uma função só. **Middleware é uma função que roda ao redor dos seus handlers**, antes e depois, para toda requisição.

```lua no-run
app:use(function(req, next)
  -- qualquer coisa aqui acontece antes do handler
  local res = next(req)
  -- qualquer coisa aqui acontece depois dele, e `res` é a resposta
  return res
end)
```

`next(req)` significa "continue", e o que ele devolve é a resposta que o handler produziu. Não chamar `next` de jeito nenhum é como um middleware recusa uma requisição completamente.

Dois middlewares aparecem nesta página.

**`auth.middleware { ... }`** roda em toda requisição. Ele abre a sessão, lê quem está logado, e coloca isso em `req.auth`. Com `optional = true` uma requisição sem sessão passa com `req.auth` deixado como `nil`, que é o que você quer quando o próprio `/login` é uma rota.

**`require_login`** são quatro linhas que você escreve, anexadas a uma rota com `before`, para que essa rota recuse quem não tem conta:

```lua no-run
local function require_login(req, next)
  if not req.auth then
    return akkar.unauthorized "log in first"
  end
  return next(req)
end

app:get("/me", { before = { require_login } }, function(req)
  return { id = req.auth.user_id }
end)
```

`before` recebe uma lista, e elas rodam em ordem, antes do handler.

## A aplicação inteira

Aqui está, com as partes novas ao lado do que você já tinha. Isto é `app.lua`.

A migração `002_create_accounts.sql` é aplicada na inicialização, do jeito que uma implantação de verdade faz isso: traz o schema para frente, depois começa a atender. Ela só nomeia a migração que esta página introduz. `001` já está no seu registro desde a [página 5](05-a-database.md).

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local migrate = require "akkar.migrate"
local crypto  = require "akkar.crypto"
local session = require "akkar.session"
local auth    = require "akkar.auth"
local memory  = require "akkar.cache.memory"
local v       = akkar.v

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  statement_timeout = 30,
}

local conn = open()
local runner = migrate.new(conn, {
  files = {
    { name = "002_create_accounts.sql", sql = [[
      create table accounts (
        id            serial primary key,
        email         text not null unique,
        password_hash text not null
      )
    ]] },
  },
})
for _, name in ipairs(runner:apply()) do print("applied " .. name) end
conn:release()

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
}

local app = akkar.new()

app:use(auth.middleware { sessions = sessions, optional = true })

local function require_login(req, next)
  if not req.auth then
    return akkar.unauthorized "log in first"
  end
  return next(req)
end

app:post("/accounts", {
  body = {
    email    = v.string { min = 3, max = 200, match = "^[^@]+@[^@]+$" },
    password = v.string { min = 8, max = 200 },
  },
}, function(req)
  local hash = crypto.hash_password(req.body.password)
  local account = req.db:one(
    "insert into accounts (email, password_hash) values ($1, $2) " ..
    "on conflict (email) do nothing returning id, email",
    req.body.email, hash)

  if not account then
    return akkar.conflict "that email already has an account"
  end
  return akkar.created(account)
end)

app:post("/login", {
  body = { email = "string", password = "string" },
}, function(req)
  local account = req.db:one(
    "select id, email, password_hash from accounts where email = $1",
    req.body.email)

  if not account or not crypto.verify_password(req.body.password,
                                               account.password_hash) then
    return akkar.unauthorized "wrong email or password"
  end

  auth.login(req, account.id)
  return { logged_in_as = account.email }
end)

app:get("/me", { before = { require_login } }, function(req)
  return req.db:one("select id, email from accounts where id = $1",
                    req.auth.user_id)
end)

app:post("/logout", function(req)
  auth.logout(req)
  return { logged_out = true }
end)

app:run { port = 3000, db = open, cache = memory.factory() }
```

```sh
lua5.4 app.lua
```

```
applied 002_create_accounts.sql
INFO  listening url=http://127.0.0.1:3000
```

### Seis coisas nesse arquivo que merecem uma frase cada

**`email text not null unique`.** `unique` é o banco de dados recusando duas linhas com o mesmo e-mail, seja lá o que o seu código fizer. Regras que você consegue impor lá embaixo são regras que não têm como ser burladas por uma segunda requisição chegando no mesmo instante.

**`on conflict (email) do nothing returning id, email`.** Se aquele e-mail já existe, não insere nada e não devolve nada, então `account` fica `nil` e o handler responde `409 Conflict`. Uma instrução só, sem query separada de "isso existe", sem brecha entre verificar e inserir.

**A inserção nunca busca `password_hash` de volta.** Só as colunas que você nomeia em `returning` voltam, então o hash não pode acabar numa resposta por acidente.

**`secret = os.getenv "SESSION_SECRET" or crypto.token(32)`.** O secret assina o cookie. No desenvolvimento você recebe um novo aleatório a cada início, o que desloga todo mundo quando você reinicia. Em produção você define `SESSION_SECRET` no ambiente e mantém isso fora do seu código-fonte, o que a página 12 cobre.

**`auth.login(req, account.id)`** faz duas coisas: descarta o id de sessão antigo e emite um novo, depois registra a conta. A primeira metade importa. Se alguém consegue plantar um cookie no seu navegador antes de você fazer login, e o id não muda quando você faz, essa pessoa agora está logada como você. Rotacionar exatamente nesse momento é a solução, e fazer disso uma única chamada é como isso deixa de ser esquecido.

**`req.auth.user_id`** é onde o akkar coloca a conta logada. O nome é do akkar, não seu: `auth.login` armazena o que você passa para ele sob `user_id`, então esse é o campo que toda página seguinte lê.

## Experimente

**Cadastrar-se:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/accounts \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com","password":"correct horse battery"}'
```

```
HTTP/1.1 201 Created
x-request-id: 7aab4f95000001
content-type: application/json
content-length: 34

{"email":"ada@example.com","id":1}
```

**Uma senha curta demais nunca chega ao seu handler:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/accounts \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"secret"}'
```

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: 7aab4f95000002
content-type: application/json
content-length: 71

{"fields":{"body.password":"min length 8"},"error":"validation failed"}
```

**O mesmo e-mail duas vezes:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/accounts \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com","password":"correct horse battery"}'
```

```
HTTP/1.1 409 Conflict
x-request-id: 7aab4f95000003
content-type: application/json
content-length: 45

{"error":"that email already has an account"}
```

**Fazer login.** `-c jar.txt` diz ao curl para escrever os cookies que recebe num arquivo, que é o que o seu navegador faz por você:

```sh
curl -s -i -X POST http://127.0.0.1:3000/login \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com","password":"correct horse battery"}' \
  -c jar.txt
```

```
HTTP/1.1 200 OK
set-cookie: akkar_session=88d1af7f017fd7fe8021af725e13e0b88beaab810563b7ce08ed2241538a13f4.95ef24bc5fda77d19bc8f25a858c35b34507636e28c0bac37a5ca7a81b3ac2c6; Path=/; Max-Age=1209600; HttpOnly; Secure; SameSite=Lax
x-request-id: 7aab4f95000004
content-type: application/json
content-length: 34

{"logged_in_as":"ada@example.com"}
```

Esse cabeçalho é o mecanismo de sessão inteiro, então vale a pena ler uma vez:

| Parte | Significa |
|---|---|
| `akkar_session=<id>.<signature>` | um id aleatório, e prova de que o akkar o emitiu |
| `Max-Age=1209600` | mantenha por duas semanas |
| `HttpOnly` | JavaScript na página não pode lê-lo |
| `Secure` | só envie por https (navegadores permitem localhost) |
| `SameSite=Lax` | não envie em requisições iniciadas por outro site |

O id não significa nada por si só. É um número aleatório longo, e a conta a que pertence está no servidor. A assinatura depois do ponto está ali para que um cookie inventado seja descartado imediatamente, em vez de custar uma busca.

**Agora use.** `-b jar.txt` envia os cookies de volta:

```sh
curl -s -i http://127.0.0.1:3000/me -b jar.txt
```

```
HTTP/1.1 200 OK
x-request-id: 7aab4f95000005
content-type: application/json
content-length: 34

{"email":"ada@example.com","id":1}
```

**Sem o cookie, a mesma rota recusa:**

```sh
curl -s -i http://127.0.0.1:3000/me
```

```
HTTP/1.1 401 Unauthorized
x-request-id: 7aab4f95000006
content-type: application/json
content-length: 24

{"error":"log in first"}
```

`401` significa "eu não sei quem você é". Compare com `403 Forbidden`, que significa "eu sei quem você é e mesmo assim você não pode". Você vai querer o segundo na página 8.

**Uma senha errada:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/login \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com","password":"hunter2"}'
```

```
HTTP/1.1 401 Unauthorized
x-request-id: 7aab4f95000007
content-type: application/json
content-length: 35

{"error":"wrong email or password"}
```

A mensagem diz "email or password" e não qual dos dois. Um erro que diz "no such account" conta a um estranho quais dos seus endereços são reais, e essa lista tem valor para essa pessoa.

## Fazer logout realmente desloga

Esta é a diferença entre uma sessão e um token, mostrada em vez de só afirmada.

```sh
curl -s -i -X POST http://127.0.0.1:3000/logout -b jar.txt
```

```
HTTP/1.1 200 OK
set-cookie: akkar_session=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax
x-request-id: 7aab4f95000008
content-type: application/json
content-length: 19

{"logged_out":true}
```

`Max-Age=0` diz ao navegador para descartar o cookie. Mas essa metade só cobre um navegador que coopera. A metade que importa é que o akkar também apagou a sessão do cache no servidor.

Então envie o **valor antigo do cookie de novo**, exatamente como um ladrão faria:

```sh
curl -s -i http://127.0.0.1:3000/me -b jar.txt
```

```
HTTP/1.1 401 Unauthorized
x-request-id: 7aab4f95000009
content-type: application/json
content-length: 24

{"error":"log in first"}
```

O cookie ainda é um cookie perfeitamente formado e corretamente assinado. Ele aponta para uma sessão que não existe mais, então não vale nada. **Com um token assinado carregando suas próprias claims, essa mesma requisição ainda funcionaria**, até o dia em que expirasse, e não haveria nada do lado do servidor para apagar.

## O que tem na tabela agora

```sh
docker exec akkar-pg psql -U postgres -d akkar -c 'select id, email, password_hash from accounts'
```

```
 id |      email      |                                                     password_hash                                                      
----+-----------------+------------------------------------------------------------------------------------------------------------------------
  1 | ada@example.com | pbkdf2-sha256$600000$72e852161d577a79879440dfb338b12b$047260a3ba8270a732d2ef0f8b8b9b1e082735ebc647cba437f548f0148b3a5e
(1 row)
```

Pegue essa linha, entregue a um estranho, e ainda assim essa pessoa não consegue fazer login como a Ada. Esse é o trabalho inteiro desta página.

## Ponto de checagem

Você conseguiu isso se:

- o cadastro retorna `201` e coloca uma string `pbkdf2-sha256$...` na tabela
- o login retorna um cabeçalho `set-cookie` e `/me` então funciona com `-b jar.txt`
- `/me` sem o cookie retorna `401`
- depois de `/logout`, o mesmo cookie não funciona mais

E você consegue dizer a diferença entre uma sessão e um token numa frase: uma sessão pode ser revogada, porque o servidor está segurando a única cópia do que ela significa.

Toda pessoa logada ainda vê todas as tarefas, incluindo tarefas que não são dela. Essa é a última coisa a corrigir: [8. Apenas suas próprias tarefas](08-only-your-own.md).
