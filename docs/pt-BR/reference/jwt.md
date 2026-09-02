# akkar.jwt

> **Português (Brasil)** | [Original em inglês](../../reference/jwt.md)

Verifica um JWT emitido por outra pessoa. Apenas assinaturas HMAC, e o algoritmo é informado por quem chama, em vez de ser lido do token.

**Quando você precisa dele.** Um provedor de identidade (Auth0, Okta, Keycloak, Google, o SSO da sua empresa) entrega a quem chama uma assertiva de curta duração, e você a verifica na sua borda. Leia `sub` e então abra uma [sessão](session.md) de verdade se quem chama for um navegador. Este não é o módulo para manter um usuário logado.

```lua no-run
local jwt = require "akkar.jwt"
```

## Índice

Todos os símbolos públicos desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`jwt.b64url_decode`](#jwtb64url_decodetext) | function |
| [`jwt.DEFAULT_LEEWAY`](#jwtdefault_leeway) | number |
| [`jwt.HMAC_ALGORITHMS`](#jwthmac_algorithms) | table |
| [`jwt.MAX_TOKEN_BYTES`](#jwtmax_token_bytes) | number |
| [`jwt.verify`](#jwtverifytoken-options) | function |

## jwt.b64url_decode(text)

Decodifica um segmento base64url. É exportada porque às vezes você quer o payload bruto de um token que já verificou.

Rígida em quatro pontos, cada um deles uma superfície de falsificação, não pedantismo: o alfabeto é somente base64url, então `+`, `/` e `=` são recusados; um comprimento igual a 1 módulo 4 codifica um byte fracionário e não pode ter vindo de um codificador; e bits finais não nulos no último grupo são recusados, porque aceitá-los equivale a aceitar até quatro grafias diferentes para os mesmos bytes. Uma assinatura com duas grafias é uma assinatura que pode ser reproduzida (replay) driblando uma lista de negação indexada pelo texto do token.

**Retorna** a string decodificada, ou `nil` e uma das mensagens: `"not a string"`, `"empty"`, `"length is impossible for base64url"`, `"contains %q, which is not base64url"`, `"has trailing bits set, so it is not canonical base64url"`.

```lua
local jwt = require "akkar.jwt"

print(jwt.b64url_decode "eyJhbGciOiJIUzI1NiJ9")
print(jwt.b64url_decode "YWJjZA==")                --> nil, contains "=" ...
print(jwt.b64url_decode "YWJ+")                    --> nil, contains "+" ...
print(jwt.b64url_decode "a")                       --> nil, length is impossible
```

## jwt.DEFAULT_LEEWAY

A tolerância de desvio de relógio (clock skew) que `verify` usa quando `options.leeway` está ausente, em segundos. É `30`, não os 300 mais comuns: a tolerância existe porque duas máquinas discordam sobre o horário, não porque a expiração é negociável. O teto rígido é 300, e `verify` lança um erro acima disso.

**Retorna** um número.

## jwt.HMAC_ALGORITHMS

Os algoritmos que este módulo consegue verificar, como uma tabela que mapeia o nome do JWT para o nome do digest do OpenSSL: `HS256`, `HS384`, `HS512`. É também o teste de pertencimento que `verify` usa, então não é possível adicionar um algoritmo e esquecer de ensinar o verificador sobre ele.

**Retorna** uma tabela.

```lua
local jwt = require "akkar.jwt"

local names = {}
for name in pairs(jwt.HMAC_ALGORITHMS) do names[#names + 1] = name end
table.sort(names)
print(table.concat(names, " "))          --> HS256 HS384 HS512
print(jwt.DEFAULT_LEEWAY, jwt.MAX_TOKEN_BYTES)
```

## jwt.MAX_TOKEN_BYTES

O teto para a string do token, aplicado antes de qualquer decodificação: `8192`. Maior do que qualquer assertiva que um provedor de identidade emite, e a alternativa a um limite é decodificar o que quer que quem chama tenha decidido enviar.

**Retorna** um número.

## jwt.verify(token, options)

Verifica um token e retorna suas claims. Toda verificação recusa; não existe um caminho que registre um problema e ainda assim retorne as claims.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `alg` | string | **obrigatório** | o algoritmo que você espera. `HS256`, `HS384` ou `HS512` |
| `key` | string | obrigatório a menos que `keys` seja informado | o segredo compartilhado |
| `keys` | table | nenhum | `kid` para segredo. Quando definido, o cabeçalho do token precisa trazer um `kid`, e não há fallback para `key` |
| `iss` | string ou lista | nenhum | emissores aceitáveis. Quando definido, um token sem `iss` é recusado |
| `aud` | string, lista ou `false` | nenhum | audiências aceitáveis. Veja abaixo |
| `leeway` | number | `30` | desvio de relógio, em segundos. Precisa estar entre 0 e 300 |
| `require_exp` | boolean | `true` | defina como `false` para aceitar um token sem `exp` |
| `max_age` | number | nenhum | recusa um token cujo `iat` seja mais antigo do que isso. Um token sem `iat` é recusado quando isso é definido |
| `require` | list | `{}` | nomes de claims que precisam estar presentes |

**`alg` é obrigatório, e é essa a propriedade de segurança.** Ele não tem valor padrão, porque um valor padrão é um valor que ninguém escolheu, e o valor que ninguém escolheu é justamente aquele que o atacante consegue influenciar através do cabeçalho. Com `alg` declarado, `alg: none` e a confusão RS256-para-HS256 se tornam a mesma recusa: o cabeçalho não declara o que o chamador informou.

**`aud` é verificado ou o token é recusado; não existe um terceiro estado.** Um `aud` nomeia o serviço para o qual o token foi emitido, e um usuário normalmente consegue obter um token legítimo para outra parte confiável (relying party) do mesmo provedor de identidade e reproduzi-lo (replay) aqui. Por isso, um token que carrega `aud` é recusado a menos que quem chama diga qual é a audiência dele. `aud = false` diz "eu aceito um token emitido para qualquer um", e isso se lê exatamente como a decisão que é.

A assinatura é verificada antes de o payload ser decodificado. Nada nas claims é examinado, nem mesmo para construir um erro melhor, até que se saiba que os bytes são do emissor. A comparação passa por `akkar.crypto.hmac_verify`, que é de tempo constante.

**Retorna** a tabela de claims, ou `nil` e uma string de motivo. O motivo é para o seu log, não para o cliente: dizer a quem chama qual das oito verificações o token forjado falhou é um oráculo de graça. Responda 401 sem nada dentro.

**Lança um erro**, em vez de retornar um motivo, quando quem chama configurou o verificador de forma errada. Cada um destes é um erro no seu código, não no token:

- `akkar.jwt: verify needs `alg`, the algorithm you expect. ...` quando `alg` não é uma string.
- `akkar.jwt: RS256 is not supported. akkar verifies HMAC signatures only ...` para `RS*`, `PS*`, `ES*` e `EdDSA`. Verificar silenciosamente um token RSA com um HMAC é exatamente o ataque de confusão.
- `akkar.jwt: unknown algorithm <name>; this module verifies HS256, HS384 and HS512`.
- `akkar.jwt: leeway must be between 0 and 300 seconds. ...`
- `akkar.jwt: verify needs `key` (a string) or `keys` (a table of kid -> string)` quando nenhum dos dois é utilizável e `keys` não foi informado.

```lua
local jwt    = require "akkar.jwt"
local crypto = require "akkar.crypto"
local json   = require "akkar.json"

local SECRET = crypto.token(32)

-- akkar.jwt não tem `issue`, então este exemplo simula o provedor de identidade.
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function b64url(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    local chunk = { ALPHABET:sub((n >> 18 & 63) + 1, (n >> 18 & 63) + 1),
                    ALPHABET:sub((n >> 12 & 63) + 1, (n >> 12 & 63) + 1) }
    if b then chunk[3] = ALPHABET:sub((n >> 6 & 63) + 1, (n >> 6 & 63) + 1) end
    if c then chunk[4] = ALPHABET:sub((n & 63) + 1, (n & 63) + 1) end
    out[#out + 1] = table.concat(chunk)
  end
  return table.concat(out)
end

local header  = b64url(json.encode { alg = "HS256", typ = "JWT" })
local payload = b64url(json.encode {
  sub = "user-42",
  iss = "https://idp.example.com/",
  aud = "https://api.example.com",
  exp = os.time() + 3600,
})
local signed = header .. "." .. payload
local token  = signed .. "." .. b64url(crypto.hmac(SECRET, signed, "sha256"))

local claims, why = jwt.verify(token, {
  alg = "HS256",
  key = SECRET,
  iss = "https://idp.example.com/",
  aud = "https://api.example.com",
})
print("subject:", claims and claims.sub, why)

-- O mesmo token apresentado a um serviço para o qual não foi emitido.
print("replayed:", jwt.verify(token, {
  alg = "HS256", key = SECRET, aud = "https://other.example.com",
}))

-- Um erro de configuração lança uma exceção, em vez de retornar um motivo.
print(pcall(jwt.verify, token, { key = SECRET }))
print(pcall(jwt.verify, token, { alg = "RS256", key = SECRET }))
```

Leia o motivo, não o retorne:

```lua no-run
local claims, why = jwt.verify(token, { alg = "HS256", key = SECRET,
                                        aud = "https://api.example.com" })
if not claims then
  req.log:info("rejected an assertion", { reason = why })
  return akkar.unauthorized()
end
```

## Todos os motivos que verify retorna

Na ordem em que as verificações rodam. Todos eles são `nil, "<reason>"`.

| motivo | significado |
|---|---|
| `no token` | `token` não é uma string, ou está vazio |
| `the token is %d bytes, over the %d byte ceiling` | maior que `MAX_TOKEN_BYTES` |
| `the token is not three base64url segments separated by dots` | não é `a.b.c`. Um JWE, que é criptografado, tem cinco segmentos e não é legível aqui |
| `the header segment <why>` | o cabeçalho não é base64url canônico |
| `the header is not a JSON object` / `... is a JSON array, not an object` | decodificou para outra coisa |
| `the token header has no alg` | `alg` está ausente ou não é uma string |
| `the token asks to be accepted unsigned (alg: none), ...` | comparado sem diferenciar maiúsculas de minúsculas, porque `None` e `NONE` já funcionaram em bibliotecas publicadas |
| `the token is signed with %s and this verifier accepts only %s` | o ataque de confusão de algoritmo, bloqueado |
| `the token header carries crit, and akkar understands no critical header parameters` | `crit` lista parâmetros que o emissor diz que precisam ser compreendidos |
| `this verifier is configured with keys by id and the token header carries no kid` | `keys` foi definido e o cabeçalho não tem `kid` |
| `no key is configured for kid %q` | não há fallback para `key` |
| `the signature segment <why>` | não é base64url canônico |
| `the signature does not verify` | |
| `the payload segment <why>` / `the payload is not a JSON object` | |
| `the token has no exp, and a token that never expires cannot be withdrawn; set require_exp = false to accept it` | |
| `exp is not a number` / `the token expired at %d and it is now %d` | |
| `nbf is not a number` / `the token is not valid until %d and it is now %d` | |
| `iat is not a number` / `the token claims to have been issued at %d, which is in the future; it is now %d` | |
| `the token is older than the %d seconds this caller accepts` | `max_age` |
| `max_age was asked for and the token carries no iat` | |
| `an issuer was required and the token carries no iss` | |
| `the token was issued by %q, which this verifier does not accept` | |
| `the token names an audience and this verifier was not told which audience it is; pass aud = "...", or aud = false to accept a token minted for anybody` | |
| `an audience was required and the token carries no aud` | |
| `the token was minted for a different audience` | |
| `the token carries no %s, which this caller requires` | de `options.require` |

O horário é lido através de [akkar.time](time.md), para que uma spec possa provar a expiração usando `time.manual` em vez de esperar (sleeping) de verdade.

## Não está aqui

**Sem `issue`, `sign`, `encode` ou `new`.** Da própria docstring do módulo: "uma função `issue` aqui seria adotada em uma semana por alguém que quisesse um login sem precisar de Redis, e o argumento em `session.lua` se perderia para a conveniência. A única forma de sustentar esse argumento é não disponibilizar a função." `spec/jwt_spec.lua` garante essa ausência.

**Sem verificação RSA ou ECDSA.** Apenas HMAC, e `alg = "RS256"` é um erro com uma mensagem, em vez de uma verificação de assinatura com uma surpresa, porque cair para uma comparação HMAC é exatamente o ataque de confusão. Verifique uma assertiva assimétrica em um gateway que detenha a chave pública do emissor.

**Sem busca de JWKS e sem cliente de rotação de chaves.** `keys` é uma tabela que você preenche. Buscar um `jwks_uri` em caso de cache miss é uma chamada de rede dentro de um caminho de verificação, e o akkar não vai fazer uma pelas suas costas.

## Veja também

- [akkar.session](session.md), que é o que este projeto usa para manter alguém logado
- [akkar.crypto](crypto.md), para a comparação HMAC de tempo constante por baixo
- o código-fonte do módulo, `akkar/jwt.lua`, e `spec/jwt_spec.lua`, que executa os dois ataques contra um verificador configurado corretamente e garante a recusa
