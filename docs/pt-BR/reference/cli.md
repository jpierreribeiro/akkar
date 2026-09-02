# O comando `akkar`

> **Português (Brasil)** | [Original em inglês](../../reference/cli.md)

`luarocks install akkar` coloca o `akkar` no seu PATH. Tudo abaixo é um único comando; nada precisa de arquivo de configuração.

| comando | o que faz |
|---|---|
| [`akkar new`](#akkar-new-nome) | cria um projeto que roda |
| [`akkar run`](#akkar-run-applua) | inicia esse projeto |
| [`akkar test`](#akkar-test-opções-do-busted) | roda seus testes |
| [`akkar doctor`](#akkar-doctor-applua) | o que está instalado, e se ele responde |
| [`akkar build`](#akkar-build-applua) | um executável só, sem precisar de Lua para rodar |
| [`akkar watch`](#akkar-watch----comando) | reinicia qualquer comando quando os arquivos mudam |
| `akkar version` | a versão, e o Lua em que ela está baseada |

## O primeiro minuto

```sh
akkar new my-api
cd my-api
akkar run
```

```sh
$ curl localhost:8080/health
{"ok":true}
```

## Um arquivo, três comandos

`akkar run`, `akkar doctor` e `akkar build` leem todos o mesmo formato: um arquivo que **retorna a aplicação**, opcionalmente com a configuração que `app:run` receberia.

```lua no-run
local akkar = require "akkar"

local app = akkar.new()
app:get("/health", function() return { ok = true } end)

return app, { port = 8080 }
```

É por isso que o scaffold escreve dessa forma. Um arquivo que chama `app:run()` no final funciona quando você o roda com `lua`, mas aí o `akkar doctor` não consegue inspecioná-lo e o `akkar build` não consegue embuti-lo, porque carregar o arquivo já inicia um servidor que nunca retorna.

## akkar new NOME

Cria um projeto: `app.lua`, `spec/app_spec.lua`, `migrations/` e um `README.md`.

Quatro arquivos, de propósito. Um scaffold que gera doze ensina sobre a própria estrutura, não sobre o framework, e cada um deles é um arquivo que alguém precisa ler antes de apagar.

**Recusa sobrescrever.** Se `NOME/app.lua` já existe, o comando para e não muda nada.

**Levanta um erro** em um nome que contenha qualquer coisa além de letras, dígitos, ponto, hífen e underscore.

## akkar run [app.lua]

Carrega o arquivo, instala o tratamento de sinais e inicia o servidor. O caminho padrão é `app.lua`.

| opção | significado |
|---|---|
| `--watch` | reinicia quando um arquivo muda |
| `--root DIR` | o que observar; repetível, o padrão é `.` |

`--watch` reinicia executando novamente esse mesmo comando sem essa opção, de modo que o processo observado e o processo comum iniciam de forma idêntica. Um recarregamento que rodasse algo sutilmente diferente esconderia justamente o bug que deveria mostrar a você.

## akkar test [opções do busted]

Roda o [busted](https://lunarmodules.github.io/busted/) sobre `spec/`, com o `package.path` apontando para o projeto, de modo que `require "app"` encontre sua aplicação.

Qualquer coisa depois de `akkar test` é repassada diretamente:

```sh
akkar test --tags=slow
akkar test spec/invoices_spec.lua
```

É um wrapper, não um executor de testes. Ter que manter asserções, formatos de saída e uma superfície de plugins próprios para substituir algo que todo desenvolvedor Lua já tem seria uma troca ruim.

**Falha** com a linha de instalação quando o busted não está no PATH. `BUSTED=` permite sobrescrever onde encontrá-lo.

## akkar doctor [app.lua]

Relata o runtime, as bibliotecas instaladas, as rotas e configurações da aplicação, e se suas capacidades respondem. Sai com código `1` quando algo está quebrado, de modo que uma etapa de implantação possa bloquear com base nisso; um aviso não é uma falha.

| opção | significado |
|---|---|
| `--json` | legível por máquina |
| `--no-probe` | pula qualquer coisa que toque a rede |

Veja [akkar.doctor](doctor.md).

## akkar build app.lua

Gera um host em C que embute a VM Lua, todos os módulos Lua que a aplicação precisa e todos os módulos nativos, e os vincula em um único executável. A implantação então não precisa de Lua, de LuaRocks nem de objetos compartilhados.

Veja [`docs/RUNTIME.md`](../../RUNTIME.md) para saber o que ele produz e o que ainda precisa ser feito manualmente.

## akkar watch -- COMANDO

Roda qualquer comando e o reinicia quando os arquivos mudam. `akkar run --watch` é isso com o comando já preenchido.

```sh
akkar watch --root . -- ./my-api
```
