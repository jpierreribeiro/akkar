# akkar.http

> **Português (Brasil)** | [Original em inglês](../../reference/http.md)

O cliente HTTP de saída: um prazo, um teto de resposta aplicado no ponto onde os bytes chegam, uma política de retentativas que sabe o que é seguro repetir, pool de conexões por origem e propagação de trace. A resposta (response) é um valor simples.

**Quando você precisa dele.** Quando um handler precisa chamar outro serviço: um provedor de pagamento, um geocodificador, um webhook que você envia em vez de receber. Configure-o uma vez como a capacidade `http` e os handlers usam `req.http`.

```lua no-run
local http = require "akkar.http"
```

`http` é uma das cinco capacidades do akkar (`db`, `cache`, `log`, `clock`, `http`). Passe a factory que `http.connect` retorna como um campo de `app:run{}`:

```lua no-run
http = http.connect { timeout = 5, retries = 2 },
```

O contrato da capacidade é `request`, `get` e `post`. Os auxiliares de verbo são conveniências sobre `request`, portanto um adaptador que responde apenas a esses três é um adaptador válido, o que é o que viabiliza um fake sem reimplementar seis métodos que fazem todos a mesma coisa.

## Conteúdo

- [http.Client](#httpclient)
- [http.SAFE_TO_RETRY](#httpsafe_to_retry)
- [http.connect(config)](#httpconnectconfig)
- [O valor de resposta](#o-valor-de-resposta)
- [Opções da requisição](#opções-da-requisição)
- [Cliente](#cliente)
  - [client:close()](#clientclose)
  - [client:delete(url, options)](#clientdeleteurl-options)
  - [client:get(url, options)](#clientgeturl-options)
  - [client:head(url, options)](#clientheadurl-options)
  - [client:json(method, url, options)](#clientjsonmethod-url-options)
  - [client:patch(url, options)](#clientpatchurl-options)
  - [client:post(url, options)](#clientposturl-options)
  - [client:put(url, options)](#clientputurl-options)
  - [client:release()](#clientrelease)
  - [client:request(method, url, options)](#clientrequestmethod-url-options)
  - [client:stats()](#clientstats)
- [O que não está aqui](#o-que-não-está-aqui)
- [Veja também](#veja-também)

## http.Client

A metatable que todo cliente carrega. Exportada para que um teste possa verificar `getmetatable(req.http) == http.Client`, e para que um adaptador possa emprestar um método. Não é algo para construir diretamente; use `http.connect`.

## http.SAFE_TO_RETRY

O conjunto de métodos em que uma requisição (request) malsucedida pode ser repetida: `GET`, `HEAD`, `PUT`, `DELETE`, `OPTIONS`, `TRACE`.

`POST` e `PATCH` estão ausentes, e esse é o ponto. Uma requisição `POST` repetida é uma segunda cobrança, um segundo e-mail, um segundo pedido. Quem sabe que seu endpoint é idempotente diz isso por chamada com `retry_unsafe = true`.

## http.connect(config)

Constrói um cliente e devolve uma factory que o entrega. O formato é igual ao de `db.connect` e `redis.connect`, então um campo de capacidade é escrito da mesma forma para todos eles. Toda chamada à função retornada devolve o mesmo cliente, então os pools são compartilhados.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `headers` | table | nenhum | headers acrescentados a cada requisição, antes dos headers por chamada |
| `timeout` | number | `10` | segundos para uma tentativa, cobrindo conexão, headers e corpo |
| `max_body` | number | `8388608` | teto de resposta em bytes |
| `retries` | number | `0` | tentativas **além** da primeira |
| `retry_backoff` | number | `0.1` | segundos antes da primeira retentativa, dobrando a cada vez |
| `pool_size` | number | `8` | conexões vivas por `scheme://host:port` |
| `reuse` | boolean | `true` | `false` fornece uma conexão por requisição pelo mesmo caminho de código |
| `http_version` | number | nenhum | deixado sem definição para que o lua-http negocie; fixe `1.1` para um peer que anuncia h2 incorretamente |
| `breaker` | table | nenhum | uma tabela de opções de [breaker](breaker.md) dá um breaker por origem; uma instância de breaker é compartilhada por toda origem |

A chave do pool vem da URI interpretada, então `http://x/a` e `http://x:80/b` compartilham um pool, e `http://x` e `https://x` nunca compartilham.

**Retorna** uma `function() -> client`.

**Lança** nada. Uma chave desconhecida em `config` é ignorada silenciosamente.

```lua
local http = require "akkar.http"

-- `connect` retorna uma factory. Chamá-la devolve o único cliente compartilhado.
local factory = http.connect { timeout = 5, retries = 2, pool_size = 4 }
local client = factory()
print(factory() == client)          --> true

local stats = client:stats()
print(stats.stale_reused, stats.retried_stale, next(stats.origins))
--> 0   0   nil

client:release()          -- um no-op, mantido para que `req.http` tenha o mesmo formato
client:close()            -- idempotente
client:close()
```

## O valor de resposta

Toda chamada bem-sucedida retorna uma table com três campos e nada mais. Nada é alterado (mutado) e nada é transmitido em stream, pelo mesmo motivo que os handlers retornam em vez de escrever diretamente: um valor pode ser logado, repetido em uma nova tentativa e verificado com asserts.

| campo | tipo | significado |
|---|---|---|
| `status` | number | o status numérico |
| `headers` | table | nome em minúsculas para valor; um header **repetido** vira uma lista, porque `set-cookie` legitimamente se repete |
| `body` | string | o corpo inteiro, sempre uma string, nunca `nil` |

Pseudo-headers (`:status` e afins) não estão em `headers`. Uma resposta informativa `1xx` é ignorada e o próximo conjunto de headers é lido, exceto `101`, que é final e é devolvido como está.

## Opções da requisição

A table `options` aceita por toda chamada.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `headers` | table | nenhum | headers por chamada; os nomes são convertidos para minúsculas, os valores passam por `tostring`, e esses headers sobrepõem os headers do cliente |
| `body` | string ou table | nenhum | uma table é codificada como JSON e define `content-type: application/json` |
| `timeout` | number | do cliente | segundos para uma tentativa |
| `max_body` | number | do cliente | teto de resposta para esta chamada |
| `retries` | number | do cliente | tentativas além da primeira |
| `retry_backoff` | number | do cliente | segundos antes da primeira retentativa |
| `retry_unsafe` | boolean | `false` | permite repetir um `POST` ou `PATCH` |
| `traceparent` | string | nenhum | enviado como o header `traceparent` |

`content-length` é definido a partir do corpo, e nenhum `expect: 100-continue` é gerado. Esse header é o que `request:set_body` no lua-http acrescenta acima de 1024 bytes, e isso custou, em medição, 1,005 s e um `408` em um corpo de dois mil bytes contra o próprio servidor do akkar.

## Cliente

### client:close()

Fecha toda conexão em pool e descarta os pools. Idempotente.

**Retorna** nada.

### client:delete(url, options)

`client:request("DELETE", url, options)`.

### client:get(url, options)

`client:request("GET", url, options)`.

### client:head(url, options)

`client:request("HEAD", url, options)`.

### client:json(method, url, options)

Faz uma requisição e decodifica o corpo como JSON.

**Retorna** `decoded, res` em caso de sucesso, em que `res` é o valor de resposta completo, ou `nil, message` em caso de falha. Note que o segundo retorno significa duas coisas diferentes dependendo do primeiro, então teste o primeiro retorno, não o segundo.

As mensagens de falha: o que quer que tenha feito `client:request` falhar, `empty body` quando o corpo é `""` (o que inclui todo `204` legítimo), e `response was not JSON: ...`.

### client:patch(url, options)

`client:request("PATCH", url, options)`. Não é repetida a menos que `retry_unsafe = true`.

### client:post(url, options)

`client:request("POST", url, options)`. Não é repetida a menos que `retry_unsafe = true`.

### client:put(url, options)

`client:request("PUT", url, options)`.

### client:release()

Um no-op. Mantido em vez de removido porque `req.http` é entregue aos handlers da mesma forma que `req.db`, e uma capacidade cujo release quem chama precisa lembrar de fazer é uma capacidade que vaza. Aqui não há nada para lembrar. As conexões voltam para seu pool em todo caminho dentro do cliente, inclusive os que falham.

**Retorna** nada.

### client:request(method, url, options)

Faz uma requisição. `method` é convertido para maiúsculas. Esse é todo o contrato; os auxiliares de verbo acima têm uma linha cada.

Retentativas, na ordem em que se aplicam:

- `retries` é silenciosamente reduzido a `0` para um método que não está em `SAFE_TO_RETRY`, a menos que `retry_unsafe` esteja definido. Não é um erro: a requisição ainda acontece uma vez, porque recusar de imediato faria de `retries` uma configuração que ninguém poderia aplicar globalmente.
- um `5xx` é repetido; um `4xx` nunca é, porque o servidor que te diz que a requisição estava errada vai te dizer de novo.
- o backoff antes da tentativa `n` é `retry_backoff * 2^n`.
- separadamente de `retries`, uma tentativa malsucedida em uma conexão em pool **reutilizada** é repetida uma vez em uma conexão nova, e apenas para um método repetível. O probe de liveness não pode ser atômico com a escrita, então uma conexão pode morrer nesse intervalo.

**Retorna** um valor de resposta, ou `nil, reason`. Os motivos são strings e incluem `"timed out reading the response body"`, `"response exceeded max_body of N bytes"`, `"the pooled connection was closed"`, `"the pool for KEY kept returning connections the peer had closed"`, e o que quer que o lua-http tenha reportado para uma falha de connect, write ou leitura de header. Uma resposta acima de `max_body` é **recusada, não truncada**: um corpo truncado é indistinguível de um completo no ponto de chamada.

**Lança** nada em caso de falha de rede. Ela retorna `nil` e um motivo.

```lua
local akkar = require "akkar"
local http  = require "akkar.http"

-- A política de retentativas, como uma table que você pode ler.
print(http.SAFE_TO_RETRY.GET, http.SAFE_TO_RETRY.POST)   --> true   nil

-- Um fake no lugar da capacidade. `req.http` precisa de `request`, `get`
-- e `post`; os outros verbos são conveniências sobre `request`.
local fake = {}
function fake:request(method, url, options)
  return { status = 200, headers = {}, body = '{"rate":0.91}' }
end
function fake:get(url, options)  return self:request("GET", url, options)  end
function fake:post(url, options) return self:request("POST", url, options) end

local app = akkar.new()

app:get("/rate", function(req)
  local res, why = req.http:get "https://example.test/rates/eur"
  if not res then return akkar.unavailable(why) end
  return { body = res.body, status = res.status }
end)

local client = app:test { http = fake }
local answer = client:get "/rate"
print(answer.status, answer.body.body)
--> 200   {"rate":0.91}
```

Os exemplos desta página nunca alcançam a rede. Uma chamada real se parece com isto:

```lua no-run
local res, why = req.http:post("https://api.example.com/charges", {
  headers = { ["authorization"] = "Bearer " .. token },
  body    = { amount = 500, currency = "eur" },
  timeout = 3,
})
if not res then
  return akkar.unavailable("the payment provider did not answer: " .. why)
end
if res.status >= 400 then
  return akkar.bad_request("the payment provider refused it")
end
```

### client:stats()

O que os pools estão fazendo, por origem em vez de como um total único: um único número não consegue dizer se um host está saturado ou se todo host está ocioso, e essas situações pedem respostas opostas.

**Retorna** `{ stale_reused = n, retried_stale = n, origins = { ["scheme://host:port"] = pool_stats } }`. `stale_reused` conta as conexões retiradas do conjunto ocioso por estarem mortas; `retried_stale` conta as requisições repetidas em uma conexão nova depois que uma reutilizada falhou.

## O que não está aqui

- **Seguir redirecionamentos.** O cliente conduz o stream ele mesmo em vez de passar por `request:go()`, então um `301` ou `302` é devolvido a você como um valor de resposta com um header `location`. Siga-o você mesmo se quiser que ele seja seguido.
- **Um cookie jar.** Nada é armazenado entre chamadas. `set-cookie` chega como um header (uma lista quando se repete) e cabe a você tratá-lo.
- **Fazer stream de uma requisição ou de um corpo de resposta.** Ambos são strings. O teto de resposta é `max_body`, e ele recusa em vez de truncar.
- **Rate limiting por host.** [limit](limit.md) é a metade de entrada e não tem uma contraparte de saída. Um circuit breaker é o campo `breaker` de `http.connect`; sua página é [breaker](breaker.md).
- **Verificação de nomes de opção.** Chaves desconhecidas em `config` e nas `options` de uma chamada são ignoradas silenciosamente, diferentemente de `app:run{}`.
- **`client:acquire`, `client:attempt`, `client:pool_for`.** Estão em `http.Client` e são internos. Suas assinaturas mudam sem aviso.

## Veja também

- [akkar](akkar.md) para como uma capacidade é configurada e como `req.http` chega a um handler
- [pool](pool.md), cujo `pool:stats()` é o que aparece em `origins`
- [breaker](breaker.md), cujo `b:stats()` é o que aparece em `breakers`
- o código-fonte do módulo, `akkar/http.lua`, para os dois defeitos encontrados durante a construção do pool (uma leitura de corpo sem timeout, e um segundo fixo por corpo acima de 1 KiB) e para o quanto o pooling vale a pena, conforme medido
