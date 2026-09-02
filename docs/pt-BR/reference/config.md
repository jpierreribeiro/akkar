# akkar.config

> **Português (Brasil)** | [Original em inglês](../../reference/config.md)

Configuração tipada lida de uma tabela e do ambiente, verificada uma única vez na inicialização. Um valor declarado com `secret = true` é armazenado em um wrapper que não guarda nada, de modo que imprimir, logar ou codificar a configuração em JSON não pode vazá-lo.

**Quando você precisa disso.** Um serviço que lê a URL de um banco de dados, um segredo de sessão e alguns timeouts do ambiente, e deve se recusar a iniciar quando algum deles estiver faltando, em vez de descobrir isso na primeira requisição (request).

```lua no-run
local config = require "akkar.config"
```

## Conteúdo

- [config.is_secret(value)](#configis_secretvalue)
- [config.load(options)](#configloadoptions)
- [config.REDACTED](#configredacted)
- [config.secret(value)](#configsecretvalue)
- [O schema](#o-schema)
- [De onde vem um valor](#de-onde-vem-um-valor)
- [Config](#config)
  - [config:redacted()](#configredacted-1)
  - [tostring(config)](#tostringconfig)
- [Secret](#secret)
  - [secret:reveal()](#secretreveal)
- [O que não está aqui](#o-que-não-está-aqui)

## config.is_secret(value)

Indica se `value` é um wrapper de segredo. Útil para um logger ou serializador que queira escrever a palavra em vez de um objeto vazio.

**Retorna** `true` ou `false`.

```lua
local config = require "akkar.config"

print(config.is_secret(config.secret "abc"))   --> true
print(config.is_secret "abc")                  --> false
```

## config.load(options)

Lê a configuração, ou lança um erro. Cada folha do schema é convertida para o tipo declarado, e cada valor obrigatório ausente é reportado de uma só vez.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `schema` | table | nenhum, obrigatório | o formato. Veja [O schema](#o-schema). |
| `values` | table | `{}` | valores vindos de um arquivo ou de um literal, no mesmo formato do schema. |
| `env` | table | o ambiente real | para onde vão as buscas no ambiente. Passe uma tabela simples para testar sem definir variáveis. |

**Retorna** uma tabela de configuração selada. Ler uma chave declarada que nunca foi definida retorna `nil`; ler uma chave não declarada lança um erro.

**Lança um erro**, sempre com o prefixo `akkar.config:`

| quando | mensagem |
|---|---|
| uma opção diferente de `schema`, `values` ou `env` | `unknown option '<key>'; use schema, values or env` |
| `schema` não é uma tabela | `load needs a schema` |
| uma folha declara uma opção fora de `type`, `default`, `required`, `secret`, `env` | `<path> declares unknown option '<key>'; use type, default, required, secret or env` |
| uma folha tem um `type` fora dos quatro | `<path> has unknown type "<name>" -- use string, number, boolean or duration` |
| um item do schema não é uma tabela | `<path> must be a table -- either a section or a declaration with a \`type\`` |
| `values` contém uma chave que o schema não declara | `unknown setting '<path>'`, mais `; did you mean '<near>'?` quando há uma chave parecida |
| o valor de uma seção não é uma tabela | `<path> is a section, so its value must be a table, got <type>` |
| um valor não é convertido com sucesso | veja [O schema](#o-schema) para a mensagem de cada tipo |
| um valor obrigatório está ausente | `<n> required setting(s) missing`, seguido de uma linha por configuração nomeando a variável a definir |

```lua
local config = require "akkar.config"

local settings = config.load {
  schema = {
    port     = { type = "number",   default = 8080 },
    timeout  = { type = "duration", default = "30s" },
    database = {
      url      = { type = "string", required = true },
      password = { type = "string", required = true, secret = true },
    },
  },
  values = { port = 3000 },
  env    = { DATABASE_URL = "postgres://localhost/akkar",
             DATABASE_PASSWORD = "hunter2" },
}

print(settings.port)                     --> 3000
print(settings.timeout)                  --> 30
print(settings.database.url)             --> postgres://localhost/akkar
print(settings.database.password)        --> [redacted]
print(settings.database.password:reveal())
```

## config.REDACTED

A string `"[redacted]"`. É o que um segredo exibe ao ser renderizado, exportada para que quem chama possa comparar com ela em vez de repetir o literal.

## config.secret(value)

Envolve em wrapper um valor que não veio de um schema, como um token gerado em tempo de execução, no mesmo wrapper que uma folha com `secret = true` recebe.

**Retorna** um segredo.

```lua
local config = require "akkar.config"

local token = config.secret "a-token-minted-at-runtime"

print(tostring(token))               --> [redacted]
print("bearer " .. token)            --> bearer [redacted]
print(config.is_secret(token))       --> true
print(config.is_secret "plain")      --> false
print(config.REDACTED)               --> [redacted]
print(token:reveal())                --> a-token-minted-at-runtime
```

## O schema

Um schema é uma tabela de seções e folhas. Uma tabela com um campo `type` do tipo string é uma folha; qualquer outra tabela é uma seção, e seções podem se aninhar em qualquer profundidade.

Uma folha aceita estas chaves, e nenhuma outra.

| chave | tipo | padrão | significado |
|---|---|---|---|
| `type` | string | nenhum, obrigatório | `string`, `number`, `boolean` ou `duration` |
| `default` | any | nenhum | usado quando nem o ambiente nem `values` fornecem um valor |
| `required` | boolean | `false` | a ausência é uma falha de inicialização |
| `secret` | boolean | `false` | armazena o valor em um wrapper que é impresso como `[redacted]` |
| `env` | string ou `false` | derivado do caminho | a variável a ser lida. `false` significa nunca ler o ambiente para esta folha. |

Os quatro tipos, e o que cada um aceita.

| tipo | aceita | resultado | mensagem quando não aceita |
|---|---|---|---|
| `string` | apenas uma string. Um número não é convertido. | a string | `<path> must be a string, got <type>` |
| `number` | um número, ou uma string que `tonumber` aceita | um número | `<path> must be a number, got "<raw>"` |
| `boolean` | um booleano, ou `true`/`1`/`yes`/`on` e `false`/`0`/`no`/`off`, em qualquer variação de maiúsculas e minúsculas | um booleano | `<path> is not a boolean: "<raw>" -- use true/false, 1/0, yes/no or on/off` |
| `duration` | um número, ou uma string com uma unidade: `ms`, `s`, `m`, `h`, `d`. Um número isolado é interpretado como segundos. | **segundos**, sempre um número | `<path> is not a duration: "<raw>" -- write 500ms, 30s, 5m, 2h or 1d`, ou `<path> has unknown duration unit "<unit>" -- use ms, s, m, h or d` |

A mensagem nomeia a configuração e, quando o valor veio do ambiente, a variável de onde ele veio:

```
akkar.config: database.port (from PGPORT) must be a number, got "abc"
```

```lua no-run
{
  port    = { type = "number", default = 8080 },
  timeout = { type = "duration", default = "500ms" },   -- é lido de volta como 0.5
  db      = {
    url      = { type = "string", required = true, env = "PGURL" },
    password = { type = "string", required = true, secret = true },
    debug    = { type = "boolean", default = false, env = false },
  },
}
```

## De onde vem um valor

A precedência é **ambiente, depois `values`, depois `default`**. O ambiente prevalece porque `values` é o que fica versionado no repositório, e o ambiente é o que o deploy define.

O nome da variável é o caminho, com os pontos substituídos por underscores e em maiúsculas: `database.url` lê `DATABASE_URL`, e `db.pool.size` lê `DB_POOL_SIZE`. Um `env = "PGURL"` explícito substitui essa derivação. `env = false` significa que a folha nunca lê o ambiente.

Um valor obrigatório ausente em todos os lugares é coletado em vez de lançar um erro na hora, de modo que uma única falha lista todos eles:

```
akkar.config: 2 required settings are missing
  database.password -- set DATABASE_PASSWORD in the environment, or values.database.password
  database.url -- set DATABASE_URL in the environment, or values.database.url
```

## Config

É o valor que `config.load` retorna. Seções também são configs, com os mesmos métodos.

Ler uma chave não declarada lança `akkar.config: no such setting '<key>'`, com `; did you mean '<near>'?` quando existe uma chave declarada parecida. Atribuir a uma chave que ainda não existe lança `akkar.config: configuration is read-only; '<key>' is not a setting and cannot be added after load`. Atribuir sobre uma chave que JÁ existe não é detectado: Lua não oferece nenhuma barreira de escrita para esse caso.

### config:redacted()

Uma tabela simples, no mesmo formato, com a string `"[redacted]"` no lugar de cada segredo. Seções são convertidas recursivamente.

Codificar a própria config já é seguro, porque o wrapper não contém nada. Isso serve para quando você quer a palavra na saída em vez de `{}`.

**Retorna** uma tabela.

```lua
local config = require "akkar.config"
local json   = require "akkar.json"

local settings = config.load {
  schema = { token = { type = "string", required = true, secret = true } },
  values = { token = "s3cret" },
  env    = {},
}

print(json.encode(settings))              -- o wrapper está vazio
print(json.encode(settings:redacted()))   -- a palavra em vez disso
print(tostring(settings))
```

```
{"token":{}}
{"token":"[redacted]"}
akkar.config
  token = [redacted]
```

### tostring(config)

Cada configuração declarada, uma por linha, em ordem, com seções aninhadas escritas como caminhos separados por ponto e segredos exibidos como `[redacted]`. Uma configuração que nunca foi definida aparece como `<unset>`. A primeira linha é `akkar.config`.

## Secret

O wrapper que uma folha com `secret = true` guarda, e o que `config.secret` retorna. É uma tabela vazia: o valor vive em um armazenamento privado com chaves fracas (weak-keyed), fora dela.

| operação | resultado |
|---|---|
| `tostring(secret)` | `[redacted]` |
| `string.format("%s", secret)` | `[redacted]` |
| `"url=" .. secret` | `url=[redacted]` |
| `json.encode(secret)` | `{}`, porque um codificador JSON não consulta nenhum metamétodo |
| `getmetatable(secret)` | a string `akkar.config: secret` |
| `secret.field = 1` | lança `akkar.config: a secret is immutable` |

A defesa é contra imprimir uma tabela, que é como segredos realmente vazam. `debug.getmetatable` e `debug.getupvalue` ainda alcançam o valor, e nada em Lua impede isso.

### secret:reveal()

O valor real.

É um método, e não um campo, para que ler um segredo seja algo escrito de propósito, e que um revisor consiga localizar com um grep.

**Retorna** o valor envolvido pelo wrapper.

## O que não está aqui

- **Parsing de arquivo.** `values` é uma tabela Lua. Ler YAML, TOML ou JSON do disco e repassar o resultado é responsabilidade de quem chama.
- **Recarregamento.** Uma config é lida uma única vez. Não existe observação (watch) nem recarregamento.
- **Criptografia ou um gerenciador de segredos.** Um segredo é protegido contra ser impresso, não contra ser lido pelo processo que o mantém.
- **Validação além dos quatro tipos.** Sem faixas de valores, sem enums, sem padrões.
- **Uma interface de linha de comando.** Não existe um subcomando `akkar config`; a única entrada externa é o ambiente.

## Veja também

- [akkar.doctor](doctor.md) para verificar para o que uma configuração em execução realmente foi resolvida
- [akkar.log](log.md) para `logger:info("boot", { config = config:redacted() })`
- o código-fonte do módulo, `akkar/config.lua`, para entender por que o wrapper de segredo é vazio em vez de ser algo mais sofisticado
