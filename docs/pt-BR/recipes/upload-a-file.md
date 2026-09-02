# Envie um arquivo

> **Português (Brasil)** | [Original em inglês](../../recipes/upload-a-file.md)

Recebe um arquivo de um formulário HTML ou de um `curl -F`, verifica o que ele é e o grava em disco com um nome escolhido pelo servidor.

## O arquivo inteiro

```lua
local akkar  = require "akkar"
local crypto = require "akkar.crypto"

local UPLOADS = os.getenv "UPLOAD_DIR" or "/tmp/akkar-uploads"
os.execute("mkdir -p " .. UPLOADS)

local EXTENSIONS = { ["image/png"] = "png", ["image/jpeg"] = "jpg" }

local app = akkar.new()

app:post("/avatars", { body = { avatar = "table" } }, function(req)
  local file = req.body.avatar

  local extension = EXTENSIONS[file.content_type]
  if not extension then
    return akkar.bad_request("avatar must be a PNG or a JPEG, not " ..
                             tostring(file.content_type))
  end

  -- O nome é nosso, nunca do cliente. Um nome de arquivo chega pela rede
  -- e pode conter ../ ou um nome que já existe em disco.
  local name = crypto.token(16) .. "." .. extension

  local out, why = io.open(UPLOADS .. "/" .. name, "wb")
  if not out then
    req.log:error("could not write an upload", { detail = why })
    return akkar.unavailable "the file could not be stored"
  end
  out:write(file.data)
  out:close()

  return akkar.created { id = name, size = file.size, name = file.filename }
end)

app:run { port = 3000, body_limit = 5 * 1024 * 1024 }
```

O akkar interpreta `multipart/form-data` antes de o handler rodar. Uma parte de arquivo chega até você como uma tabela com quatro campos: `filename`, `content_type`, `data` e `size`. Um campo de texto simples no mesmo formulário chega como uma string.

## Testando

```sh
lua5.4 app.lua
```

Em um segundo terminal:

```sh
curl -F "avatar=@cat.png;type=image/png" http://127.0.0.1:3000/avatars
```

```
{"size":22,"id":"54f3a654004ef069b27fd49f5f3aa949.png","name":"cat.png"}
```

Um campo de texto onde deveria haver um arquivo é recusado antes de o handler rodar, porque a rota declara `avatar` como uma tabela:

```sh
curl -F "avatar=hello" http://127.0.0.1:3000/avatars
```

```
{"fields":{"body.avatar":"expected table"},"error":"validation failed"}
```

Um arquivo de um tipo que essa rota não aceita:

```sh
curl -F "avatar=@cat.png;type=application/pdf" http://127.0.0.1:3000/avatars
```

```
{"error":"avatar must be a PNG or a JPEG, not application\/pdf"}
```

Qualquer coisa maior que `body_limit` recebe um `413` e nunca chega ao handler. O limite padrão é 1 MB, por isso este arquivo o eleva para 5 MB.

## Por que o limite do corpo é a linha mais importante

O akkar armazena o upload inteiro em memória antes de o handler vê-lo, então `body_limit` não é uma formalidade: é o número que decide quanta memória um chamador pode fazer esse processo alocar. Cinco uploads simultâneos de 5 MB são 25 MB de memória residente. Defina o limite para o maior arquivo que você de fato aceita e nada além disso, e lembre-se de que `content_type` é uma string escolhida pelo cliente, então ela diz o que o cliente afirma ter enviado, e não o que os bytes realmente são. Verifique também os bytes se o arquivo for servido de volta em algum momento.
