# Sirva um frontend a partir do mesmo servidor

> **Português (Brasil)** | [Original em inglês](../../recipes/serve-a-frontend.md)

Serve o HTML, o CSS e o JavaScript a partir do mesmo processo akkar que responde a API, então há uma única origem, uma única porta e nenhum CORS.

Coloque seu frontend já compilado em um diretório `web` ao lado de `app.lua`. O menor exemplo que prova que funciona:

```html
<!doctype html>
<meta charset="utf-8">
<title>Tasks</title>
<h1>Tasks</h1>
<ul id="tasks"></ul>
<script>
  fetch("/api/tasks")
    .then(function (r) { return r.json() })
    .then(function (data) {
      document.getElementById("tasks").innerHTML =
        data.tasks.map(function (t) { return "<li>" + t.title + "</li>" }).join("")
    })
</script>
```

## O arquivo inteiro

```lua
local akkar  = require "akkar"
local static = require "akkar.static"

local ROOT = "web"

local function shell()
  local file = io.open(ROOT .. "/index.html", "rb")
  if not file then return akkar.not_found "no frontend was built" end
  local html = file:read "a"
  file:close()
  return akkar.raw(html, "text/html; charset=utf-8")
end

local app = akkar.new()

-- Último recurso. Um GET que não bateu com nenhum arquivo nem rota é o shell da aplicação, então
-- recarregar um link profundo como /tasks/42 no navegador continua funcionando. Caminhos
-- sob /api ficam de fora, porque um caminho de API desconhecido é um 404 de verdade.
app:use(function(req, next)
  local res = next(req)
  if res.status == 404 and req.method == "GET" and not req.path:find "^/api/" then
    return shell()
  end
  return res
end)

-- Serve web/ para qualquer caminho que tenha um arquivo correspondente, e repassa tudo o mais adiante.
app:use(static.new {
  root = ROOT,
  index = "index.html",
  max_age = 3600,
  fallthrough = true,
})

app:get("/api/tasks", function()
  return { tasks = akkar.array { { id = 1, title = "buy milk", done = false } } }
end)

app:run { port = 3000 }
```

O middleware roda na ordem em que é registrado e se desfaz na ordem inversa, então o middleware do shell é adicionado primeiro e vê a resposta que tudo o mais produziu. `fallthrough = true` é o que permite que um caminho para o qual o servidor de arquivos não tem arquivo chegue até o roteador em vez de receber um 404 ali mesmo.

## Experimente

```sh
lua5.4 app.lua
```

Depois abra `http://127.0.0.1:3000/` em um navegador. Pela linha de comando:

```sh
curl -i http://127.0.0.1:3000/
```

```
HTTP/1.1 200 OK
accept-ranges: bytes
etag: "6a81ce45-15f"
x-content-type-options: nosniff
last-modified: Sun, 16 Aug 2026 14:50:45 GMT
cache-control: public, max-age=3600
x-request-id: f9f99982000001
content-type: text/html; charset=utf-8
content-length: 351
```

A API está na mesma origem:

```sh
curl http://127.0.0.1:3000/api/tasks
```

```
{"tasks":[{"title":"buy milk","done":false,"id":1}]}
```

Um link profundo que o próprio frontend roteia recebe o shell:

```sh
curl -i http://127.0.0.1:3000/tasks/42
```

```
HTTP/1.1 200 OK
x-request-id: f9f99982000003
content-type: text/html; charset=utf-8
content-length: 351
```

Um caminho de API desconhecido continua sendo um 404, que é o que um cliente de API precisa:

```sh
curl http://127.0.0.1:3000/api/nope
```

```
{"error":"no route for GET \/api\/nope"}
```

## Por que uma única origem vale o middleware

Servir o frontend de outro lugar transforma toda chamada em cross-origin, e então os cookies precisam de `SameSite`, `credentials`, um `Access-Control-Allow-Origin` que não pode ser `*`, e um preflight em qualquer coisa que não seja um GET simples. Uma única origem elimina tudo isso, e o custo são os dois trechos de middleware acima. O akkar define `etag` e `last-modified` em cada arquivo, então um recarregamento depois do primeiro custa um 304 e nenhum corpo. Mantenha o `max_age` baixo, ou zero, para `index.html` se o seu build coloca hashes nos nomes dos arquivos de asset, ou um navegador vai continuar segurando o shell antigo. Se o frontend realmente mora em outro lugar, a [página 9](../guide/09-a-frontend.md) do guia cobre o lado do CORS.
