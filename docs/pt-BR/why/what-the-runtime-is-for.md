# Para que serve o `akkar build`, e para que não serve

> **Português (Brasil)** | [Original em inglês](../../why/what-the-runtime-is-for.md)

O `akkar build` compila uma aplicação e todo o framework em um único arquivo executável.

```
$ akkar build serve-app.lua -o myapp --root ... --archive ...
akkar build: 369 Lua modules, 46 native modules -> myapp

$ ./myapp 8375 &
$ curl -i http://127.0.0.1:8375/users/7
HTTP/1.1 200 OK
x-request-id: 3824249f000001
content-type: application/json

{"id":7}
```

Roteamento, validação de parâmetros, JSON, o id da requisição (request), toda a pilha de cqueues e lua-http, em um único arquivo.

## Comece pelo que ele não oferece

**Ele não é mais rápido.** Nada no `docs/RUNTIME.md` ou no `docs/DEPLOY.md` afirma uma melhoria de velocidade, e não existe uma medição disso em lugar nenhum deste repositório, porque não há nada para medir. O binário roda a mesma VM Lua 5.4 sobre o mesmo event loop do cqueues, executando o mesmo bytecode. O probe que comprovou a ideia diz isso em uma linha:

> The same cqueues, the same Lua 5.4 VM. Only the linkage changed.

Linkagem estática muda de onde o código é carregado, não como ele roda. Se você está lendo isso na esperança de que os números de throughput em `bench/study/RESULTS.md` melhorem, eles não vão melhorar, e qualquer um que disser a você que um binário único é mais rápido deveria ser questionado sobre o antes e o depois.

Ele também não remove nenhuma dependência do seu programa. Cada módulo continua lá; eles estão dentro do arquivo em vez de ao lado dele.

## O que ele oferece

### 1. A implantação deixa de precisar de um ambiente Lua

Esse era o problema todo. Implantar Lua normalmente significa ter Lua 5.4 na máquina de destino, mais o LuaRocks, mais um conjunto de módulos em C compilados contra a versão certa do OpenSSL, além da capacidade de reproduzir esse conjunto na próxima máquina. O `docs/DEPLOY.md` começa admitindo que, antes de ele existir, "a descrição mais honesta e curta da história de implantação era que ela simplesmente não existia".

O resultado medido, tudo isso vindo de uma única tarde em Linux 6.8 x86-64 com Docker 28.2.2:

| | |
|---|---|
| Imagem final, `scratch` | **6.395.313 bytes, 6,4 MB** |
| O binário dentro dela | 6.177.544 bytes, 6,2 MB |
| O pacote de certificados CA ao lado | cerca de 218 KB, o resto da imagem |
| Variante com shell, `--target slim` | 14.492.687 bytes, 14,5 MB |
| Build a frio, `--no-cache` | 3 min 01 s |
| Rebuild após editar a aplicação | 15 s, dos quais 8,8 s são o `akkar build` |
| Memória residente, ocioso, servindo | 6,7 MiB |
| Parada graciosa por SIGTERM, sem tráfego | 0,38 s |

Uma imagem `scratch` não tem libc nenhuma dentro dela, e mesmo assim esse binário serve HTTP, resolve DNS e consulta o Postgres de dentro dela.

Observe a correção honesta anexada a esses números. O `docs/RUNTIME.md` relata **5,08 MB**, e aquele era um binário glibc ainda linkando `libssl.so` e `libcrypto.so` dinamicamente. O de 6,2 MB tem o OpenSSL embutido e não precisa de libc na máquina hospedeira. O `docs/DEPLOY.md` enquadra a diferença como a troca que ela de fato é: "Um megabyte a mais em troca de 'roda em uma imagem vazia'".

Há uma segunda correção escondida nesse tamanho. O binário estático como linkado tem **21.759.272 bytes** e, depois do `strip`, fica com 6.177.544. **Setenta e dois por cento do artefato não stripado são tabelas de debug**, DWARF do C linkado estaticamente, o OpenSSL à frente de todos. Um binário estático não stripado não é um runtime de 21 MB; é um runtime de 6 MB carregando as tabelas de símbolos de suas dependências para dentro do seu registro de imagens.

### 2. Controle de dependências

O build lê cada `require` literal presente nos fontes que está prestes a embutir e mapeia nomes para símbolos de forma direta, depois verifica se o archive os define. Ninguém chuta. O `docs/RUNTIME.md` explica por que isso importava: reverter a convenção de nomenclatura do C é ambíguo, porque `luaopen__openssl_x509_verify_param` pode ser lido tanto como `_openssl.x509.verify.param` quanto como `_openssl.x509.verify_param`, e um empacotador que chuta produz um binário que morre com "module not found" para um módulo comprovadamente linkado dentro dele.

O efeito prático é que o que está no artefato é exatamente o que uma requisição (request) real tocou. A lista de módulos da primeira linkagem completa não foi escrita à mão: um script iniciou uma aplicação, serviu uma requisição a si mesma e despejou o `package.loaded`.

### 3. Processo por locatário (tenant) fica barato

Esse é o item que muda o que o akkar poderia vir a ser, e o `docs/RUNTIME.md` o coloca ao final de um argumento mais longo.

O terceiro produto tentador é um runtime supervisor que hospeda o código de vários locatários em um único processo, trocado a quente. O akkar já tem a metade do carregamento (`akkar.from_spec`, `App:swap_host`) e não tem a metade do isolamento. O próprio `akkar/vm.lua` diz isso sobre si mesmo: é uma sandbox dentro de um único estado Lua, não uma fronteira contra código hostil, e se o código for hostil, e não apenas não confiável, ele pertence a um processo separado com uma sandbox em nível de sistema operacional.

> Building the supervising runtime now would mean offering, as a product, the guarantee the code explicitly disclaims.

O que desbloqueia isso não é mais código no akkar. É um processo por locatário, o que o binário torna barato: um executável autocontido de 6 MB sem interpretador para instalar é uma proposta muito diferente de "provisionar um ambiente Lua por cliente". A história do isolamento passa a ser do sistema operacional.

## Isso foi excluído, e a exclusão estava errada

O `docs/BACKLOG.md` mantinha o `akkar build` na tabela de coisas deliberadamente não construídas, com esta justificativa:

> Attractive, but Redbean is a *different substrate*, and `cqueues` is a C module. That is a substrate change, not a packaging step.

A primeira parte é verdadeira em relação ao Redbean. **A segunda não decorre disso, e nunca foi medida.** Ser um módulo em C torna algo mais difícil de linkar, não impossível; a linkagem estática é a resposta comum e ela não muda substrato nenhum.

O `docs/runtime/build-probe.sh` é a refutação e roda em cerca de um minuto:

| Probe | Resultado | Tamanho |
|---|---|---|
| Script Lua puro | rodou | 302 KB |
| Mais um módulo em C (`lua-cjson`) | codificou e decodificou | 328 KB |
| Mais `cqueues`, rodando um event loop | `ticks=3` | 1,5 MB |

O terceiro foi o que importou: todo o substrato de concorrência do akkar rodou dentro de um único executável.

A entrada do backlog agora está riscada e marcada como retratada em vez de excluída, o que é o padrão que este projeto usa em todo lugar e a razão pela qual suas afirmações valem a pena ser lidas.

## O que isso custa

### Uma matriz de plataformas, que é uma superfície de manutenção permanente

O `docs/RUNTIME.md` listava "uma plataforma, uma libc" e "não totalmente estático" entre o que o probe não prova. O `docs/DEPLOY.md` respondeu às duas, e as duas respostas são sim: contra musl no Alpine o binário é `statically linked, stripped`, e o `ldd` relata `Not a valid dynamic program`.

O que isso custou foi **um header**. O `sys/queue.h` é um header do BSD que a glibc traz e a musl não, empacotado pela Alpine no `libbsd-dev`, instalado exatamente onde o cqueues já procura. Um único `apk add`. luaossl, lua-cjson, lpeg, lua-http, pgmoon e luasocket, todos compilaram sem nenhuma modificação.

Mas veja o que ainda está em aberto, porque esse é o custo:

- **A glibc estática não foi testada**, e o motivo não é ter falhado. O `getaddrinfo` estático da glibc ainda quer os objetos compartilhados da NSS em tempo de execução, então um binário glibc `-static` em uma imagem vazia plausivelmente não conseguiria resolver um hostname. A musl foi escolhida e o comportamento de DNS foi então *testado* em vez de presumido. (Funciona porque o cqueues carrega seu próprio resolvedor e lê o `/etc/resolv.conf` diretamente, nunca chamando o `getaddrinfo` da libc.)
- **Nenhum macOS, nenhum BSD.** Nada foi rodado lá.
- **Nenhuma compilação cruzada.** Ele compila apenas para a máquina em que roda.

Cada plataforma que alguém pedir é uma plataforma que alguém vai ter que manter verde.

### O akkar passa a distribuir um build, não só uma biblioteca

Esse é o custo estrutural, e é fácil subestimá-lo. Um framework que só é chamado via `require` só precisa estar correto. Um framework que produz executáveis precisa saber compilar cada dependência nativa que embute, em cada plataforma que afirma suportar.

- O `akkar archive` tem receitas para quatro archives: cqueues, luaossl, lua-cjson, lpeg. Uma **quinta é montada à mão no `Dockerfile`**.
- Essa quinta foi encontrada rodando o binário, e não lendo o código: `akkar: [string "pgmoon.util"]:32: module 'mime' not found`. O pgmoon exige `mime` do luasocket sem declarar isso, e cada backend de criptografia em `pgmoon/crypto.lua` está protegido por `pcall`, então o pgmoon silenciosamente escolhe o luaossl e nunca chega a olhar para o luasocket, e então o `pgmoon.util` exige `mime` incondicionalmente para base64. O binário linka, inicializa, serve HTTP perfeitamente, e morre na primeira chamada ao banco de dados.
- **Uma receita de libpq estático para o `akkar build` não existe.** O `docs/BACKLOG.md` lista isso como pendente: o `libpq.a` do Debian arrasta junto pgcommon, pgport, curl, ssl, gssapi e ldap. Então o driver em C de `docs/pt-BR/why/adapters.md` não pode, atualmente, ser embarcado no binário.
- Um módulo nativo escrito para carregamento dinâmico pode carregar premissas que só a linkagem estática viola. O `dl_anchor()` do luaossl chama `dladdr` no seu próprio ponto de entrada e depois faz `dlopen` do arquivo onde ele cai, o que, em um build estático, é o próprio executável, e `dlopen` sobre um executável falha por definição. O erro aparece como `openssl.init: cannot dynamically load executable`, vindo de um módulo que ninguém mencionou, e o `openssl.init` acaba sendo um rótulo de erro em C, e não um módulo de fato. A correção é `-DHAVE_DLADDR=0`. Encontrá-la exigiu ler o código C do luaossl.

### Uma imagem vazia não tem shell, e algumas coisas precisam de um

**Migrações não podem rodar a partir da imagem `scratch`.** O `io.popen` precisa de um shell e o `scratch` não tem nenhum. Isso foi descoberto rodando o binário, e a prova de que o shell é a única causa é que o mesmo binário roda migrações a partir da imagem `--target slim`, que difere apenas por ter o busybox nela.

O `docs/DEPLOY.md` dá três opções em ordem de preferência: rodar as migrações a partir da imagem slim e servir a partir da scratch; distribuir a slim para tudo, em 14,5 MB em vez de 6,4 MB; ou rodar as migrações a partir de um notebook. Essa é uma consequência operacional real de uma imagem de 6 MB, não uma nota de rodapé.

### Recompilar para mudar uma linha

A aplicação vem compilada junto. Editá-la significa recompilar, o que leva 15 s aqui. É por isso que o `akkar run app.lua`, o binário que hospeda uma aplicação lida no início da execução, é o próximo passo e é deliberadamente pequeno: "ele torna possível o ciclo de editar e reiniciar sem um compilador, que é como qualquer pessoa de fato desenvolve".

Seu custo real também não é código. Ele cria uma **segunda interface versionada**, entre o binário do runtime e o código-fonte da aplicação, em um momento em que este projeto deliberadamente não promete nenhuma compatibilidade. Então o `akkar run` vai declarar qual versão do akkar compilou o binário e parar por aí.

## O que ler a seguir

- `docs/RUNTIME.md`, para os probes e a questão de design.
- `docs/DEPLOY.md`, para os números acima e uma implantação real no Railway.
- `docs/pt-BR/why/what-akkar-does-not-do.md`, para as outras exclusões retratadas.
