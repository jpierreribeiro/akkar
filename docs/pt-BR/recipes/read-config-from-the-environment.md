# Leia a configuração a partir do ambiente

> **Português (Brasil)** | [Original em inglês](../../recipes/read-config-from-the-environment.md)

Declara todas as configurações que o serviço tem em um único lugar, lê-as a partir do ambiente e recusa iniciar quando falta alguma que importa.

## O arquivo inteiro

Este bloco está marcado como `no-run`. O que ele faz depende do ambiente em que é iniciado, e a suíte de testes da documentação não tem um ambiente fixo, então a suíte verifica que ele compila, e as duas execuções abaixo são o que ele de fato faz.

```lua no-run
local akkar  = require "akkar"
local config = require "akkar.config"
local db     = require "akkar.db"

local settings = config.load {
  schema = {
    port = { type = "number", default = 3000 },
    request_timeout = { type = "duration", default = "5s" },
    database = {
      host     = { type = "string", default = "127.0.0.1" },
      port     = { type = "number", default = 55432 },
      name     = { type = "string", default = "akkar", env = "PGDATABASE" },
      user     = { type = "string", default = "postgres", env = "PGUSER" },
      password = { type = "string", required = true, secret = true,
                   env = "PGPASSWORD" },
    },
  },
}

local app = akkar.new()

app:get("/config", function()
  -- `redacted` é o que torna isso seguro de responder: a senha volta como
  -- "[redacted]" em vez de vir como ela mesma.
  return settings:redacted()
end)

app:run {
  port = settings.port,
  timeout = settings.request_timeout,
  db = db.connect {
    host = settings.database.host,
    port = settings.database.port,
    database = settings.database.name,
    user = settings.database.user,
    password = settings.database.password:reveal(),
    statement_timeout = 5,
  },
}
```

O nome da variável de ambiente de uma configuração é o seu caminho em maiúsculas, com os pontos trocados por sublinhados, então `port` vira `PORT` e `database.host` vira `DATABASE_HOST`. `env = "PGPASSWORD"` substitui isso quando a variável já tem um nome próprio. Uma `duration` aceita `500ms`, `5s`, `10m` e devolve o valor em segundos.

## Experimente

Com nada definido:

```sh
lua5.4 app.lua
```

```
lua5.4: app.lua:5: akkar.config: 1 required setting is missing
  database.password -- set PGPASSWORD in the environment, or values.database.password
```

Isso nomeia a configuração, a variável a definir e a outra forma de fornecê-la. Agora com a variável definida:

```sh
PGPASSWORD=akkar lua5.4 app.lua
```

```
INFO  listening url=http://127.0.0.1:3000
```

```sh
curl http://127.0.0.1:3000/config
```

```
{"port":3000,"database":{"user":"postgres","host":"127.0.0.1","port":55432,"password":"[redacted]","name":"akkar"},"request_timeout":5}
```

## Por que um schema em vez de `os.getenv` onde for necessário

`os.getenv` espalhado pelo código não tem uma lista, então nada consegue te dizer do que esse serviço precisa até que a requisição (request) que precisa dele falhe, e um erro de digitação aparece como nil em vez de como um erro. Um schema é essa lista: cada configuração é declarada uma única vez, os valores obrigatórios que estão faltando são todos reportados juntos na inicialização em vez de um por reinício, `PORT=abc` é recusado por não ser um número, e ler uma configuração que nunca foi declarada gera um erro em vez de silenciosamente virar nil. Marcar um valor como `secret` o envolve para que não possa ser impresso por acidente, e é por isso que `settings:redacted()` é seguro de devolver em uma rota e `password` precisa de `:reveal()` no único lugar que realmente o usa. A [página 12](../guide/12-deploying.md) do guia faz o mesmo trabalho com um helper `required` escrito à mão e sem dependência, o que é a quantidade certa de maquinário para uma ou duas variáveis.
