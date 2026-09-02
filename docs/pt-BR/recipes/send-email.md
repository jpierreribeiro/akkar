# Enviando e-mail

> **Português (Brasil)** | [Original em inglês](../../recipes/send-email.md)

Envia uma mensagem por meio da API de um provedor de e-mail, e mantém a requisição (request) funcionando quando o provedor não funciona.

Coloque a chave do seu provedor no ambiente antes de iniciar o servidor:

```sh
export RESEND_API_KEY=re_your_key_here
```

## O arquivo completo

```lua
local akkar = require "akkar"
local email = require "akkar.email"

local mailer = email.new {
  from = "akkar recipes <onboarding@resend.dev>",
  transport = email.resend {
    api_key = os.getenv "RESEND_API_KEY" or "re_no_key_set",
  },
}

local app = akkar.new()

app:post("/signup", { body = { email = "string" } }, function(req)
  local id, why = mailer:send {
    to = req.body.email,
    subject = "Welcome to the task list",
    text = "Thanks for signing up. Your account is ready.",
  }

  if not id then
    -- A conta foi criada de qualquer forma. Um e-mail de boas-vindas que não foi enviado
    -- não é motivo para desfazer um cadastro.
    req.log:error("welcome email failed", { detail = why })
    return akkar.created { account = req.body.email, emailed = false }
  end

  return akkar.created { account = req.body.email, emailed = true, message_id = id }
end)

app:run { port = 3000 }
```

Um mailer não é uma capability, então ele não é passado para `app:run{}`: ele é construído uma única vez no topo do arquivo, e o handler o captura por clausura (closure). `mailer:send` nunca lança exceção. Ele retorna um id de mensagem, ou `nil` e um motivo.

O akkar fala com as APIs HTTP dos provedores, não SMTP. `email.resend` é um provedor pré-configurado; `email.json_api { url = ..., token = ..., fields = ... }` cobre os outros, que diferem apenas nos nomes dos campos e em onde o token é colocado.

## Experimente

```sh
lua5.4 app.lua
```

```sh
curl -X POST http://127.0.0.1:3000/signup \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com"}'
```

Com uma chave que o provedor rejeita, que é o que você obtém se esquecer de exportar uma:

```
{"emailed":false,"account":"ada@example.com"}
```

```
ERROR welcome email failed detail=the email provider refused it (401): API key is invalid request_id=8f7e6cbe000001
```

O cadastro ainda respondeu 201. Com uma chave funcional, a mesma requisição responde `"emailed":true` e carrega o `message_id` do provedor.

## Por que a falha não é um erro

Um provedor de e-mail é um terceiro pela rede, então o envio vai falhar às vezes, e a pergunta interessante é o que essa falha faz com a requisição dentro da qual ela aconteceu. Aqui, ela não faz nada: a conta existe, quem chamou é informado de que o e-mail não foi enviado, e o motivo está no log ao lado do id da requisição. A outra metade desse argumento é que quem chamou não deveria ficar esperando por um provedor de forma alguma. `mailer:send` faz uma chamada HTTP, então ela segura a requisição pelo tempo que o provedor levar. Para qualquer coisa mais movimentada que uma demonstração, envie um job e faça o disparo a partir de um worker:
[Rode um worker no mesmo processo](run-a-worker-in-the-same-process.md).
