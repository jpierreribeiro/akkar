# akkar.static

> **Português (Brasil)** | [Original em inglês](../../reference/static.md)

Serve arquivos de um diretório como middleware: tipos de conteúdo pela extensão,
`ETag` e `Last-Modified`, `304`, intervalos de bytes únicos e um resolvedor de caminho que
recusa travessia. O resolvedor de caminho é puro e exportado, então pode ser testado
sem criar um arquivo.

**Quando você precisa disso.** Quando o mesmo processo que responde sua API também entrega
um frontend já compilado, ou um favicon, ou um arquivo `.well-known`, e colocar um segundo
servidor na frente disso não vale a pena.

```lua no-run
local static = require "akkar.static"
```

Não existe um `akkar.static` na tabela `akkar`. Registre o middleware como
`app:use(static.new { root = "public" })`.

## Conteúdo

- [static.TYPES](#statictypes)
- [static.content_type(path, types, default)](#staticcontent_typepath-types-default)
- [static.decode(s)](#staticdecodes)
- [static.etag_for(info)](#staticetag_forinfo)
- [static.http_date(epoch)](#statichttp_dateepoch)
- [static.lfs_available](#staticlfs_available)
- [static.new(options)](#staticnewoptions)
- [static.parse_http_date(value)](#staticparse_http_datevalue)
- [static.parse_range(header, size)](#staticparse_rangeheader-size)
- [static.resolve(root, request_path, options)](#staticresolveroot-request_path-options)
- [static.stat(path)](#staticstatpath)
- [static.stat_io(path)](#staticstat_iopath)
- [static.stat_lfs(path)](#staticstat_lfspath)
- [static.symlink_check](#staticsymlink_check)
- [static.symlink_free(base, relative)](#staticsymlink_freebase-relative)
- [Não está aqui](#não-está-aqui)
- [Veja também](#veja-também)

## static.TYPES

A tabela de extensão para tipo de conteúdo, indexada pela extensão em minúsculas sem o
ponto. É legível e extensível, embora `options.types` em `static.new` seja a
forma suportada de adicionar a ela para uma montagem específica.

Ela cobre `html`, `htm`, `css`, `js`, `mjs`, `json`, `map`, `txt`, `md`, `csv`,
`xml`, `svg`, `ico`, `png`, `jpg`, `jpeg`, `gif`, `webp`, `avif`, `woff`,
`woff2`, `ttf`, `otf`, `pdf`, `zip`, `gz`, `wasm`, `mp4`, `webm`, `mp3` e
`wav`. Tipos de texto carregam `; charset=utf-8`.

## static.content_type(path, types, default)

O tipo de um caminho, apenas a partir da extensão, nunca do conteúdo. A
extensão é a parte depois do último ponto do último segmento separado por `/`, então
um diretório chamado `assets.js` não decide o tipo dos arquivos dentro dele.

`types` é consultado antes de `static.TYPES`. `default` é retornado quando nenhum dos dois
tem a extensão, e o padrão é `application/octet-stream`.

**Retorna** uma string.

## static.decode(s)

Decodificação por percent-encoding. O `+` deliberadamente não é tratado como espaço: essa
convenção pertence a query strings codificadas como formulário, não a segmentos de caminho, e
um arquivo chamado `c++.txt` ficaria inacessível caso contrário.

Chamada exatamente uma vez por requisição (request) por `static.resolve`. Chamá-la uma segunda vez
em um caminho já decodificado é, por si só, a vulnerabilidade, porque `%252e%252e%252f`
é um nome de arquivo literal depois de uma passagem e `../` depois de duas.

**Retorna** uma string.

## static.etag_for(info)

A tag de um arquivo, a partir dos seus metadados: `"MTIME-SIZE"` em hexadecimal, entre aspas.
Esse é exatamente o esquema do nginx, então uma frota rodando nginx na frente do akkar para
alguns caminhos não produz dois formatos de tag para um único asset.

**Retorna** uma string entre aspas, ou `nil` quando `info` é `nil` ou não tem `mtime`. Uma
tag baseada apenas no tamanho chamaria dois arquivos diferentes de mesmo comprimento pela mesma
representação, então nenhuma tag é retornada em vez de uma errada.

## static.http_date(epoch)

Segundos epoch convertidos para um IMF-fixdate: `Sun, 06 Nov 1994 08:49:37 GMT`. Os nomes
do dia e do mês são escritos por extenso em vez de obtidos de `os.date "%a"`, que
depende do locale.

**Retorna** uma string.

## static.lfs_available

`true` quando `require "lfs"` teve sucesso no momento do carregamento. Veja
[static.symlink_check](#staticsymlink_check) para saber o que depende disso.

## static.new(options)

Middleware.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `root` | string | nenhum, obrigatório | diretório a partir do qual servir |
| `prefix` | string | `""` (todo caminho) | prefixo de URL que essa montagem possui; uma `/` no final é removida |
| `index` | string ou `false` | `"index.html"` | nome de arquivo servido para um diretório; `false` recusa diretórios |
| `dotfiles` | boolean | `false` | permite segmentos que começam com `.` |
| `follow_symlinks` | boolean | `false` | serve através de symlinks (precisa de `lfs` para ter algum efeito) |
| `max_bytes` | number | `1048576` | armazena em buffer até essa quantidade de bytes, faz streaming acima disso |
| `chunk_size` | number | `65536` | bytes por chunk ao fazer streaming |
| `max_age` | number | nenhum | segundos para `cache-control: public, max-age=N`; o cabeçalho é omitido sem isso |
| `types` | table | nenhum | extensões extras ou que sobrescrevem o mapeamento para tipo de conteúdo |
| `stat` | function(path) | `static.stat` | fonte de metadados alternativa |
| `fallthrough` | boolean | `false` | chama `next(req)` em vez de responder `404` |

Toda resposta (response) carrega `x-content-type-options: nosniff` e
`accept-ranges: bytes`.

O que ela responde:

- um caminho fora do seu `prefix`: `next(req)`, sem alterações
- um método diferente de `GET` ou `HEAD`: `405` com `allow: GET, HEAD`
- um caminho que `static.resolve` recusa, ou qualquer coisa que não seja um arquivo
  comum: `404` com corpo `{ error = "not found" }`, ou `next(req)` quando
  `fallthrough` está definido
- um diretório: o arquivo indicado por `index` dentro dele, resolvido pelas mesmas
  regras; `404` quando `index` é `false` ou o caminho combinado escapa da raiz
- um caminho alcançado através de um symlink, com `follow_symlinks` não definido e
  `lfs` instalado: `404`. `fallthrough` não se aplica a esse caso, nem a um arquivo
  que se torna ilegível entre o stat e a leitura.
- um `If-None-Match` ou `If-Modified-Since` ainda válido: `304` com os validadores e
  sem corpo
- um `Range` insatisfazível: `416` com `content-range: bytes */SIZE`
- um único `Range` satisfazível: `206` com `content-range`
- caso contrário, `200`

**Um único status para toda recusa**, e nenhum detalhe no corpo. `403` para uma
travessia e `404` para um arquivo ausente é um oráculo: isso diz a um sondador qual
dos seus palpites tocou um diretório real. Tentativas de travessia são registradas em
`warn` através de `req.log` com o motivo; um arquivo ausente é registrado em `debug`.
Com `fallthrough` definido, os dois ramos que ele cobre são repassados antes de a
recusa ser alcançada, então nada é registrado para eles também.

Uma resposta maior que `max_bytes` é enviada via streaming, o que significa chunked
transfer encoding e nenhum `content-length`. Um `206` ainda carrega `content-range`,
que é o que um player de mídia usa para buscar posições.

**Retorna** uma `function(req, next)`.

**Lança** `akkar.static needs root = "some/directory"` no momento do registro quando
`root` está ausente ou não é uma string não vazia.

```lua
local akkar  = require "akkar"
local static = require "akkar.static"

local root = "/tmp/ref_static_1"
os.execute("mkdir -p " .. root)
local file = assert(io.open(root .. "/hello.txt", "w"))
file:write "hello from disk"
file:close()

local app = akkar.new()
app:use(static.new { root = root, prefix = "/assets", max_age = 3600 })
app:get("/", function() return { ok = true } end)

local client = app:test {}

local hit = client:get "/assets/hello.txt"
print(hit.status, hit.raw, hit.headers["cache-control"])
--> 200   hello from disk   public, max-age=3600

local part = client:get("/assets/hello.txt", {
  headers = { ["range"] = "bytes=0-4" },
})
print(part.status, part.raw, part.headers["content-range"])
--> 206   hello   bytes 0-4/15

-- Recusado, e registrado como uma tentativa de travessia. O cliente não aprende nada.
print(client:get("/assets/../../etc/passwd").status)    --> 404

-- Fora do prefixo, então chega até a rota.
print(client:get("/").status)                           --> 200

os.remove(root .. "/hello.txt")
os.execute("rmdir " .. root)
```

## static.parse_http_date(value)

Um IMF-fixdate convertido para segundos epoch. Apenas essa forma é aceita; os dois
formatos obsoletos listados pela RFC 9110 são recusados. A consequência de recusar
um é um `200` com o corpo completo, o que é correto, ainda que não seja o ideal,
enquanto interpretar um errado e chegar a um epoch incorreto não seria.

A aritmética não tem fuso horário nela. `os.time{...}` lê sua tabela como horário
local, e é por isso que a implementação óbvia fica desalinhada pelo offset UTC da
máquina em qualquer notebook de desenvolvedor que não esteja configurado para UTC.

**Retorna** um número, ou `nil` para qualquer coisa que não seja uma string
exatamente nesse formato.

## static.parse_range(header, size)

Interpreta um cabeçalho `Range` de intervalo único contra um tamanho conhecido.
`bytes=0-499`, `bytes=500-` e a forma de sufixo `bytes=-500` (os **últimos** 500
bytes) são compreendidos. Um `last` além do final é limitado a `size - 1`,
conforme a RFC 9110.

**Retorna** `first, last` inclusivos, ou `nil, "ignore"`, ou
`nil, "unsatisfiable"`. As duas palavras de falha não são intercambiáveis:
`"ignore"` precisa produzir um `200` normal, porque um intervalo que um servidor
não vai respeitar não é um erro, enquanto `"unsatisfiable"` precisa produzir `416`.

`"ignore"` cobre um cabeçalho que não é string, um cabeçalho que não é
`bytes=...`, múltiplos intervalos separados por vírgula, e qualquer coisa que não
seja interpretável. `"unsatisfiable"` cobre `bytes=-0`, um primeiro byte igual ou
além de `size`, e um último byte antes do primeiro.

## static.resolve(root, request_path, options)

Toda a superfície de segurança deste módulo, em uma única função pura. Sem `io`,
sem `lfs`, sem `os`.

Ela decodifica exatamente uma vez, divide por `/`, descarta segmentos vazios e `.`,
e compara segmentos inteiros. Um segmento igual a `..` é rejeitado diretamente em
vez de resolvido removendo um item de uma pilha, então não existe nenhuma
aritmética que possa sofrer underflow além da raiz. A raiz é normalizada pelo
mesmo percorredor, e o caminho montado é então verificado quanto a estar contido
dentro dela. Essa última verificação é inalcançável hoje, e é para ser assim: ela
está ali para que, no dia em que o percorredor for "simplificado", a falha seja
uma recusa e um teste vermelho.

`options.dotfiles` permite segmentos que começam com `.`. O motivo para ativá-lo
é `.well-known`; o motivo para deixá-lo desativado é que os dois arquivos mais
valiosos em um diretório implantado são `.env` e `.git/config`.

**Retorna** `absolute, relative` em caso de sucesso, ou `nil, reason`. Os motivos:
`"nul byte in path"`, `"backslash in path"`, `"newline in path"`,
`"parent segment in path"`, `"dotfile"`, `"root escapes the filesystem"`,
`"resolved outside the root"`. O motivo é para o seu log e nunca para o
cliente.

```lua
local static = require "akkar.static"

print(static.resolve("public", "/css/app.css"))
--> public/css/app.css   css/app.css
print(static.resolve("public", "/../etc/passwd"))
--> nil   parent segment in path
print(static.resolve("public", "/%2e%2e/etc/passwd"))
--> nil   parent segment in path
print(static.resolve("public", "/.env"))
--> nil   dotfile
print(static.resolve("public", "/.well-known/x", { dotfiles = true }))
--> public/.well-known/x   .well-known/x

print(static.content_type "app/index.html")   --> text/html; charset=utf-8
print(static.content_type "logo.unknown")     --> application/octet-stream
print(static.decode "a%20b%2Fc")              --> a b/c

print(static.etag_for { kind = "file", size = 4096, mtime = 1700000000 })
--> "6553f100-1000"
print(static.http_date(784111777))            --> Sun, 06 Nov 1994 08:49:37 GMT
print(static.parse_http_date "Sun, 06 Nov 1994 08:49:37 GMT")  --> 784111777

print(static.parse_range("bytes=0-499", 1000))    --> 0     499
print(static.parse_range("bytes=-500", 1000))     --> 500   999
print(static.parse_range("bytes=5000-", 1000))    --> nil   unsatisfiable
print(static.parse_range("bytes=0-1,5-6", 1000))  --> nil   ignore
```

## static.stat(path)

A fonte de metadados que o middleware usa a menos que você passe `options.stat`.
É `static.stat_lfs` quando `lfs` está presente e `static.stat_io` caso contrário,
escolhida uma única vez no momento do carregamento.

**Retorna** `{ kind = "file"|"directory"|"other", size = number, mtime = number|nil }`,
ou `nil` quando o caminho não existe.

Atribuir um valor a `static.stat` não muda o que o middleware chama. O ponto de
extensão suportado é `static.new { stat = ... }`.

## static.stat_io(path)

O fallback sem `lfs`, exportado pelo nome para que uma máquina que tem `lfs`
ainda consiga testar o caminho que o CI percorre.

Ele distingue um diretório de um arquivo pela **mensagem de erro** de uma leitura
de comprimento zero, não pelo `nil`. `io.open` em um diretório tem sucesso no
Linux e relata um tamanho de 2^63-1, e uma leitura de comprimento zero retorna
`nil` tanto para um diretório quanto para um arquivo vazio. O Lua retorna um
`nil` isolado no fim do arquivo e `nil, message, errno` em um erro de verdade, o
que os separa exatamente.

Ele não consegue produzir um `mtime`, então sem `lfs` não há `Last-Modified`,
nem `ETag`, e toda requisição é um `200` completo.

**Retorna** o mesmo formato que `static.stat`, sempre com `mtime = nil`.

## static.stat_lfs(path)

A implementação com `lfs`: uma chamada a `lfs.attributes`, tudo que o middleware
precisa, incluindo `mtime`.

**Retorna** o mesmo formato que `static.stat`, ou `nil`. O próprio campo é `nil`
quando `lfs` não está instalado.

## static.symlink_check

`true` quando a proteção contra symlink está de fato ativa neste processo, o que
significa que `lfs` está instalado. Leia esse valor em um health check se a
resposta importar para você. Quando é `false`, um symlink dentro da raiz apontando
para fora dela é servido, porque detectar isso exige `lfs.symlinkattributes` e
`luafilesystem` não é uma dependência do akkar.

## static.symlink_free(base, relative)

Percorre cada componente de `base .. "/" .. relative` a partir da raiz para fora
e informa se algum deles é um symlink. Cada componente, porque um **diretório**
symlinked é o caso interessante: `public/data -> /var/lib` coloca todo arquivo
"sob" `public` em um lugar completamente diferente.

**Retorna** `true` quando o caminho está limpo, `false` quando não está, e
**`true` quando `lfs` está ausente**. Não existe uma terceira resposta, e falhar
toda requisição em uma máquina sem uma rock opcional seria pior do que o risco
que ela protege. `static.symlink_check` é o campo que diz qual dessas duas
respostas você está recebendo.

## Não está aqui

- **Listagem de diretórios.** Um arquivo de índice ausente é um `404`, nunca uma
  listagem gerada, e não existe opção para mudar isso.
- **Múltiplos intervalos.** `Range: bytes=0-9,20-29` é ignorado e o corpo inteiro
  é enviado com `200`. A RFC 9110 permite ignorar um `Range` que um servidor não
  vai respeitar, então essa é uma resposta válida. Fazer isso corretamente
  significa gerar um corpo `multipart/byteranges`.
- **Sniffing de conteúdo.** Os tipos vêm da extensão, e `nosniff` é enviado para
  que o navegador também não faça sniffing.
- **Proteção contra symlink sem `lfs`.** Veja `static.symlink_check`.
- **Requisições condicionais sem `lfs`.** Nenhum `mtime` significa nenhum `ETag`
  e nenhum `Last-Modified`, então toda requisição é um `200` completo.
- **Um `ETag` de hash de conteúdo.** A tag é `mtime-size`, que é O(1). O `mtime`
  tem granularidade de um segundo, então duas escritas no mesmo segundo que
  deixam o tamanho inalterado produzem a mesma tag. A correção é um digest de
  conteúdo no nome do arquivo, que é o que um pipeline de assets já faz.
- **Verificação de nome de opção.** Uma chave desconhecida em `options` é
  ignorada silenciosamente.

## Veja também

- [akkar](akkar.md) para `app:use`, `akkar.raw`, `akkar.stream` e `app:test`
- [compress](compress.md), que vê essas respostas e vai codificar um `206`
  junto com tudo mais
- [etag](etag.md) para requisições condicionais em respostas de handler em vez
  de arquivos
- o código-fonte do módulo, `akkar/static.lua`, para entender por que `..` é
  rejeitado em vez de resolvido e por que o fallback de `io.open` inspeciona a
  mensagem de erro
