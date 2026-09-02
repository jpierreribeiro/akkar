# akkar.crypto

> **Português (Brasil)** | [Original em inglês](../../reference/crypto.md)

As quatro primitivas criptográficas de que um backend precisa, sobre o OpenSSL que o akkar já vincula para TLS: um CSPRNG, SHA-256, HMAC-SHA2 e PBKDF2. Nada aqui é criptografia nova.

**Quando você precisa disso.** Ao armazenar uma senha, comparar um segredo com algo que quem chamou enviou, gerar uma chave de API ou um id de sessão, ou assinar um valor que você vai conferir depois.

```lua no-run
local crypto = require "akkar.crypto"
```

## Índice

Todo símbolo público desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`crypto.DEFAULT_ITERATIONS`](#cryptodefault_iterations) | número |
| [`crypto.equal`](#cryptoequala-b) | função |
| [`crypto.from_hex`](#cryptofrom_hextext) | função |
| [`crypto.hash_password`](#cryptohash_passwordpassword-options) | função |
| [`crypto.hmac`](#cryptohmackey-data-algorithm) | função |
| [`crypto.hmac_verify`](#cryptohmac_verifykey-data-signature-algorithm) | função |
| [`crypto.random`](#cryptorandomn) | função |
| [`crypto.sha256`](#cryptosha256data) | função |
| [`crypto.to_hex`](#cryptoto_hexbytes) | função |
| [`crypto.token`](#cryptotokenbytes) | função |
| [`crypto.verify_password`](#cryptoverify_passwordpassword-stored-options) | função |

## crypto.DEFAULT_ITERATIONS

A contagem de iterações do PBKDF2 que `hash_password` usa quando quem chamou não nomeia nenhuma, e a contagem contra a qual `verify_password` compara um hash armazenado para decidir `needs_rehash`. É `600000`, que é a orientação de 2023 da OWASP para PBKDF2-HMAC-SHA256.

**Retorna** um número.

```lua
local crypto = require "akkar.crypto"
print(crypto.DEFAULT_ITERATIONS)
```

## crypto.equal(a, b)

Compara duas strings sem vazar onde elas diferem. O comprimento é comparado primeiro e separadamente, depois cada byte restante é combinado com XOR num acumulador, de modo que o laço sempre roda até o fim da entrada.

Duas entradas de comprimentos diferentes retornam `false` imediatamente, e o mesmo vale para duas entradas que não sejam ambas strings. Comprimentos não são tratados como segredo.

**Retorna** `true` ou `false`.

```lua
local crypto = require "akkar.crypto"

print(crypto.equal("token", "token"))     --> true
print(crypto.equal("token", "tokeo"))     --> false
print(crypto.equal("token", "tok"))       --> false
print(crypto.equal(nil, "token"))         --> false
```

## crypto.from_hex(text)

Transforma uma string hexadecimal de volta em bytes. É o inverso de `to_hex`.

Só o comprimento é validado. `from_hex` verifica se a entrada tem um número par de caracteres e então substitui cada par de dígitos hexadecimais que encontra; caracteres fora de `0-9a-fA-F` são deixados na saída sem alteração, em vez de rejeitados. Valide o alfabeto você mesmo se a entrada veio de quem chamou.

**Retorna** a string decodificada, ou `nil` e `"odd-length hex"`.

```lua
local crypto = require "akkar.crypto"

print(crypto.from_hex "616b6b6172")        --> akkar
print(crypto.from_hex "abc")               --> nil    odd-length hex
print(crypto.from_hex "zzzz")              --> zzzz   (não rejeitado)
```

## crypto.hash_password(password, options)

Gera o hash de uma senha com PBKDF2-HMAC-SHA256 e um salt por senha. **É lento de propósito**, e o akkar roda uma corrotina por vez, então uma chamada na contagem de iterações padrão trava o processo de responder a qualquer pessoa durante esse tempo. Rode isso através de `akkar.work`, não diretamente num handler.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `options.iterations` | número | `crypto.DEFAULT_ITERATIONS` (600000) | contagem de iterações do PBKDF2, armazenada dentro do resultado |
| `options.salt` | string | 16 bytes de `crypto.random` | o salt, para quando você precisa de um fixo num teste |

**Retorna** uma string no formato autodescritivo `pbkdf2-sha256$iterations$salt_hex$key_hex`. A chave tem 32 bytes. Como a contagem está dentro da string, aumentá-la depois não invalida hashes antigos.

**Levanta erro** quando o OpenSSL rejeita a derivação, que é o que `options.iterations = 0` faz: `integer value out of range`. A menor contagem válida é 1.

```lua
local crypto = require "akkar.crypto"

-- iterations = 1 mantém este exemplo rápido. Em produção usa-se o padrão, e
-- o padrão é toda a defesa.
local stored = crypto.hash_password("correct horse battery staple",
                                    { iterations = 1 })
print(stored)

print(crypto.verify_password("correct horse battery staple", stored))
print(crypto.verify_password("hunter2", stored))
```

## crypto.hmac(key, data, algorithm)

HMAC de `data` sob `key`, retornado como bytes brutos. Passe por `to_hex` antes de colocar num cabeçalho, um cookie ou um log.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `key` | string | obrigatório | o segredo |
| `data` | string | obrigatório | a mensagem |
| `algorithm` | string | `"sha256"` | qualquer nome de digest que o OpenSSL conheça: `sha256`, `sha384`, `sha512` |

**Retorna** o MAC bruto: 32 bytes para sha256, 48 para sha384, 64 para sha512.

**Levanta erro** `bad argument #2 to 'new' (<name>: invalid digest type)` quando o algoritmo não é um que o OpenSSL tenha.

```lua
local crypto = require "akkar.crypto"

local mac = crypto.hmac("a secret key", "the message")
print(#mac)                        --> 32
print(crypto.to_hex(mac):sub(1, 16))
```

## crypto.hmac_verify(key, data, signature, algorithm)

Recalcula o HMAC de `data` e compara com `signature` através de `crypto.equal`. Existe para que ninguém escreva `hmac(...) == signature`, que é justamente o vazamento por tempo de resposta que `equal` existe para evitar.

`signature` é o MAC bruto, não hexadecimal. Codifique ambos os lados em hexadecimal você mesmo se for isso que você tem em mãos.

**Retorna** `true` ou `false`.

```lua
local crypto = require "akkar.crypto"

local key = "a secret key"
local mac = crypto.hmac(key, "transfer 100")

print(crypto.hmac_verify(key, "transfer 100", mac))   --> true
print(crypto.hmac_verify(key, "transfer 900", mac))   --> false
```

## crypto.random(n)

`n` bytes do CSPRNG do sistema operacional, através de `openssl.rand`. Nada neste módulo chega a usar `math.random`.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `n` | número | `32` | quantos bytes |

**Retorna** uma string de exatamente `n` bytes.

**Levanta erro** `akkar.crypto: the CSPRNG returned too few bytes` numa leitura curta. Recusar é a única resposta segura: uma leitura curta produziria um token com menos entropia do que seu comprimento sugere, e nada adiante conseguiria perceber isso.

```lua
local crypto = require "akkar.crypto"

local bytes = crypto.random(16)
print(#bytes)                      --> 16
print(#crypto.random())            --> 32
```

## crypto.sha256(data)

SHA-256 de `data`, retornado como 32 bytes brutos.

Este é o hash certo para algo que já tem alta entropia, como uma chave de API. É o hash errado para uma senha: veja `hash_password`.

**Retorna** uma string de 32 bytes.

**Levanta erro** `bad argument #1 to 'final' (string expected, got nil)` quando `data` não é uma string.

```lua
local crypto = require "akkar.crypto"
print(crypto.to_hex(crypto.sha256 "akkar"))
```

## crypto.to_hex(bytes)

Renderiza uma string de bytes como hexadecimal em minúsculas, dois caracteres por byte.

**Retorna** uma string de `2 * #bytes` caracteres.

```lua
local crypto = require "akkar.crypto"
print(crypto.to_hex "akkar")       --> 616b6b6172
```

## crypto.token(bytes)

Um token aleatório seguro para URL: `bytes` de saída do CSPRNG renderizados como hexadecimal. Hexadecimal em vez de base64 porque um token trafega em URLs, cookies e logs, e `+`, `/` e `=` do base64 precisam cada um de escape em pelo menos um desses contextos.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `bytes` | número | `32` | bytes de entropia, então a string fica com o dobro do comprimento |

**Retorna** uma string hexadecimal de `2 * bytes` caracteres.

**Levanta erro** o que quer que `crypto.random` levante.

```lua
local crypto = require "akkar.crypto"

local id = crypto.token(32)
print(#id)                         --> 64
print(#crypto.token(16))           --> 32
```

## crypto.verify_password(password, stored, options)

Confere uma senha contra um hash que `hash_password` produziu. A contagem de iterações e o salt são lidos de dentro de `stored`, então um hash feito sob um custo mais antigo ainda é verificado. A comparação final passa por `crypto.equal`.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `options.iterations` | número | `crypto.DEFAULT_ITERATIONS` | a contagem contra a qual o SEGUNDO valor de retorno é comparado. Isso não muda como a senha é verificada |

**Retorna** dois valores: `ok` e `needs_rehash`. `needs_rehash` só é verdadeiro quando a senha bateu e o hash armazenado usou menos iterações do que `options.iterations`. É assim que uma implantação aumenta seu custo ao longo do tempo: verifique com a contagem antiga, depois gere o hash de novo com a nova contagem enquanto o texto puro ainda está em mãos.

Qualquer coisa que não consiga interpretar resulta em `false, false`, não num erro: um `stored` que não é uma string, um algoritmo diferente de `pbkdf2-sha256`, uma string que não bate com `^([%w%-]+)%$(%d+)%$(%x+)%$(%x+)$`.

`if crypto.verify_password(...)` lê o primeiro valor e ignora o segundo, o que geralmente é o que você quer.

```lua
local crypto = require "akkar.crypto"

local old = crypto.hash_password("correct horse", { iterations = 1 })

-- Verificado sob a contagem que está dentro do hash, seja qual for o padrão de hoje.
local ok, needs_rehash = crypto.verify_password("correct horse", old,
                                                { iterations = 2 })
print(ok, needs_rehash)            --> true    true

-- Algo que não consegue interpretar continua não sendo um erro.
print(crypto.verify_password("correct horse", "sha1$deadbeef"))
```

## O que não está aqui

**Nenhum JWT, e nenhuma forma de emitir um token de sessão.** Nas palavras da própria docstring do módulo: "Um token assinado que carrega suas próprias claims não pode ser revogado antes de expirar, que é justamente a propriedade de que uma sessão mais precisa." Use [akkar.session](session.md) para logins, e [akkar.jwt](jwt.md) para verificar uma assertion emitida por outra parte.

**Nenhum `encrypt`, nenhum `decrypt`, nenhum AEAD.** Este módulo é as quatro chamadas de que um backend precisa (um CSPRNG, um digest, um HMAC, um KDF) sobre o OpenSSL que o akkar já vincula. Criptografar dados da aplicação não é uma delas, e escolher um modo e uma política de nonce não é algo que um framework deva decidir por você.

## Veja também

- [akkar.session](session.md), onde `equal`, `hmac` e `token` são usados para construir um login
- [akkar.auth](auth.md), para chaves de API, que são geradas com hash usando `sha256` aqui, em vez de `hash_password`
- o código-fonte do módulo, `akkar/crypto.lua`, para os quatro erros que ele existe para evitar
