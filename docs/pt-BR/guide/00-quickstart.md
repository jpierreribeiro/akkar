# Início rápido

> **Português (Brasil)** | [Original em inglês](../../guide/00-quickstart.md)

Um arquivo, um comando, uma resposta. Cerca de cinco minutos.

## 1. Obtenha o akkar

Você precisa do Lua 5.4, do LuaRocks e dos cabeçalhos de desenvolvimento do OpenSSL.

```sh
git clone https://github.com/jpierreribeiro/akkar.git
cd akkar
luarocks install --local --only-deps akkar-dev-1.rockspec
eval "$(luarocks path --bin)"
```

Permaneça na pasta `akkar` pelo resto desta página.

## 2. Um arquivo

Crie o arquivo `app.lua` nessa pasta:

```lua
local akkar = require "akkar"

local app = akkar.new()

app:get("/hello", function()
  return { hello = "world" }
end)

app:run { port = 3000 }
```

## 3. Um comando

```sh
lua5.4 app.lua
```

```
INFO  listening url=http://127.0.0.1:3000
```

O comando não retorna. Isso está correto. O servidor está em execução e aguardando.

## 4. Uma resposta

Abra um **segundo terminal** e execute:

```sh
curl http://127.0.0.1:3000/hello
```

```
{"hello":"world"}
```

Pressione `Ctrl-C` no primeiro terminal para parar o servidor.

## Se não funcionou

**`module 'akkar' not found`**

```
lua5.4: app.lua:1: module 'akkar' not found:
	no field package.preload['akkar']
	no file '/usr/local/share/lua/5.4/akkar.lua'
	no file '/usr/local/share/lua/5.4/akkar/init.lua'
	...
	no file './akkar.lua'
	no file './akkar/init.lua'
```

O Lua procurou pelo akkar e não conseguiu encontrá-lo. Você está na pasta errada. Dê um `cd` para a pasta `akkar` que você clonou e execute `lua5.4 app.lua` a partir dali.

**`Address already in use`**

```
lua5.4: akkar: port 3000 on 127.0.0.1 is already in use.
  Something else is listening there -- most often a server from a previous run
  that is still going.
  Stop it, or start this one on another port with app:run { port = 3001 }
```

Algo já está escutando na porta 3000, geralmente uma cópia deste servidor que você esqueceu de parar. Pare-o com `Ctrl-C`, ou mude `port = 3000` para outro número, como `3001`.

Essa mensagem costumava ser um stack trace apontando para dentro do próprio código-fonte do akkar, sem nenhuma porta nela. Ela foi reescrita porque esta página existia: registrar o que um iniciante vê foi o que tornou óbvio que a mensagem era inútil para um deles.

---

Isso é todo o início rápido. Ele mostra que o akkar funciona, e nada mais.

**Quer entender o que você acabou de fazer?** Comece em
[1. O que é um backend, afinal](01-what-is-a-backend.md).
