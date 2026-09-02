# O que o akkar deliberadamente não faz

> **Português (Brasil)** | [Original em inglês](../../why/what-akkar-does-not-do.md)

Uma lista de exclusões só vale a pena ser lida se ela também listar suas próprias reversões.
Esta lista faz isso, porque dois itens dela foram retratados e fingir o contrário
tornaria o resto pouco confiável.

`docs/BACKLOG.md` mantém a versão viva desta tabela, "escrita porque
a lista fica tentando crescer". Esta página explica isso e diz o que usar
no lugar.

## As retratações, primeiro

### Migrations. Excluídas, depois construídas.

`docs/PLAN.md` seção 1 lista migrations como "permanentemente fora de escopo",
agrupadas com o ORM. `docs/BACKLOG.md` repetiu isso. **Essa exclusão está
retratada**, e `docs/ROADMAP.md` seção 2.1 se chama "AND THIS REVERSES A
DOCUMENTED DECISION".

O argumento para reverter é que o agrupamento foi o erro:

> um ORM é uma opinião sobre modelagem, que o akkar recusa, enquanto um
> executor de migrations é um livro-razão de arquivos aplicados e um lock, sem
> nenhuma opinião sobre schema.

E uma segunda razão que não existia quando a exclusão foi escrita: **`akkar
build` produz um binário cuja promessa inteira é "copie para um servidor", e um
binário que não consegue levar seu próprio schema adiante tem uma promessa
incompleta.**

Agora é `akkar/migrate.lua`, mantido deliberadamente pequeno: arquivos SQL
simples, só para frente, aplicados em ordem, registrados em uma tabela,
protegidos por um advisory lock para que duas instâncias iniciando juntas não
possam rodá-las ao mesmo tempo. **Sem down-migrations**, sob o argumento de que
elas costumam estar erradas diante de dados reais e incentivam fingir que um
deploy é reversível.

A pegadinha operacional está em `docs/DEPLOY.md`: migrations não podem rodar a
partir da imagem `scratch`, porque `io.popen` precisa de um shell e o `scratch`
não tem nenhum.

### `akkar build`. Excluído por uma razão que estava errada.

O item dizia:

> Atraente, mas Redbean é um *substrato diferente*, e `cqueues` é um módulo C.
> Isso é uma mudança de substrato, não um passo de empacotamento.

Verdade para o Redbean. Não vale para um módulo C, porque link estático não
muda substrato nenhum. Um teste de um minuto colocou o cqueues rodando um
event loop dentro de um único binário de 1,5 MB. Veja
`docs/pt-BR/why/what-the-runtime-is-for.md`.

### ~~HTTP/2, e portanto gRPC~~ — CONSTRUÍDO, 2026-08-18

**Esta seção foi escrita como uma exclusão e sobreviveu cerca de uma hora.** Ela
é mantida em vez de apagada porque a forma como caiu é a parte útil.

O argumento para excluir o h2 era que reintroduzi-lo significava uma segunda
camada de framing, HPACK, controle de fluxo e uma superfície própria de CVEs.
Cada cláusula disso é verdadeira sobre ESCREVER uma stack HTTP/2 do zero.
Nenhuma delas era verdadeira sobre a situação real do akkar, e a seção não
verificou em qual das duas situações ele estava.

O que de fato era necessário: a metade h2 do **lua-http 0.4** — `h2_connection`,
`h2_stream`, `hpack`, `h2_error`, e o shim `bit` que eles compartilham — é o
mesmo release do qual a metade h1 daqui foi vendorizada. Ela já estava
instalada na máquina como uma dependência declarada. Trazê-la foi uma cópia com
os prefixos de `require` reescritos, mais quatro edições no servidor: oferecer
`h2` no `alpn_select`, ramificar sobre isso durante a negociação, condicionar a
detecção do preâmbulo em texto puro atrás de `h2c`, e construir um
`h2_connection` quando a versão é 2.

**Duas coisas tornaram isso barato, e ambas foram decisões, não sorte.**

1. `connection_common`, `stream_common`, `tls` e `util` nunca foram modificados
   quando a metade h1 foi vendorizada, então a metade h2 encontrou as
   interfaces que esperava. Divergência é um imposto pago depois, e aqui a
   conta foi zero.
2. Quando a corrotina por requisição foi removida de `handle_socket` para
   economizar os 3.900 bytes que ela custava, a chamada inline foi colocada
   atrás de `conn.version < 2` em vez de substituir `add_stream`. Essa condição
   foi escrita especificamente para que o h2 pudesse retornar sem que ninguém
   precisasse redescobrir qual linha importava — e é a razão pela qual a
   multiplexação funcionou de primeira.

**Uma coisa NÃO foi barata e teve de ser verificada em vez de presumida.** O
`headers.lua` do akkar diverge do upstream em 239 linhas, e uma dessas
mudanças removeu `never_index` de toda entrada de header para economizar 432
bytes por requisição, sob o argumento declarado de que essa é uma flag do
HPACK e o HPACK tinha ido embora. O HPACK lê essa flag em dois lugares. Nenhum
deles quebra — o Lua descarta o argumento extra e o terceiro retorno ausente é
lido como nil — então todo campo segue o caminho indexado normal. O que se
perde é a capacidade de marcar um campo como "nunca coloque isso na tabela
dinâmica", uma dica que o upstream só definia quando solicitado.
`spec/http2_spec.lua` garante o que não se perde: nomes, valores e contagem
sobrevivem a um round trip completo.

**Medido nesta máquina**, seis requisições de 0,5 s em uma única conexão:

| | tempo total |
|---|---:|
| HTTP/2, uma conexão, seis streams | **552 ms** |
| HTTP/1.1, uma conexão | 3.071 ms |

E o ALPN teve uma falha silenciosa que vale a pena registrar, porque nada a
reporta. O akkar constrói seu próprio contexto TLS a partir de `certificate` e
`key` em vez de passar pelo `new_ctx` do lua-http, então ele nunca recebeu o
callback de ALPN: um navegador negociou HTTP/1.1 contra um servidor que falava
h2 perfeitamente bem, o handshake teve sucesso, a requisição foi respondida, e
a multiplexação simplesmente nunca aconteceu. **Um recurso que é meramente
inalcançável não produz erro algum.**

**O que ainda está excluído é o HTTP/3**, e essa exclusão é a que o argumento
desta seção de fato se encaixa. QUIC é um transporte sobre UDP com seu próprio
controle de congestionamento e integração TLS; nem o cqueues nem o lua-http o
possuem, e não há metade nenhuma de nada guardada em disco para vendorizar.
Atrás de um proxy isso não custa nada, que é onde o h3 é terminado na prática.

**E o framing do h2 não tem suíte de fuzzing aqui ainda.** `spec/fuzz_spec.lua`
cobre o h1, onde vive o request smuggling. A camada de framing do h2 é do
upstream, sem modificações, mas o akkar ainda não a testou com fuzzing — isso é
uma lacuna, e pertence a esta página, não a uma mensagem de commit.

### CI, um site de documentação, versionamento, ADRs. Excluídos com um público que mudou.

Esses estavam fora porque "o público é meu próprio uso". O público agora é
público, então eles voltaram. `docs/PLAN.md` seção 1 mantém o objetivo antigo
ao lado do novo em vez de sobrescrevê-lo.

Uma parte disso ainda está deliberadamente ausente, e não é um descuido: **não
há número de versão, nenhuma garantia de CHANGELOG e nenhuma promessa de
compatibilidade até a 1.0.** O rockspec permanece em `dev-1`. Um número de
versão é uma promessa, e há duas coisas que este projeto não pode prometer: o
substrato depende de um commit do cqueues que o upstream nunca lançou como
release, e a API ainda está se movendo sob medição. Fixe um commit e espere que
ele mude.

## O que ainda está excluído, e o que usar no lugar

### Um ORM, e models

**Use:** SQL puro através do adaptador, e `akkar.sql` quando precisar compor
condições.

`docs/DECISIONS.md` seção 5 tinha um query builder como opção B e o rejeitou
como "meio caminho" para um ORM. O que existe em vez disso é mais restrito:
`akkar.sql` marca valores com `?` e os numera em `$1, $2` de uma vez só na
montagem, para que condições adicionadas em lugares diferentes se componham
sem que ninguém precise rastrear índices. Não existe `where_raw`, porque uma
escotilha de escape é por onde entra a injeção.

O único lugar em que o akkar de fato insiste em um builder é o escopo de
tenant, e isso é por uma razão estrutural, não estética: uma string não pode
ser escopada sem ser parseada, e um parser de SQL dentro do framework seria um
segundo banco de dados, e pior.

### Templating, HTML, formulários, um pipeline de assets, scaffolding

**Use:** um framework diferente. Isto não é uma lacuna a ser preenchida depois.

`docs/ROADMAP.md` considerou a outra leitura de "um framework web completo" em
16 de agosto de 2026 e a rejeitou, e a razão é a que está em
`docs/pt-BR/why/handlers-return.md`:

> um renderizador quer transmitir para dentro de uma resposta que ainda está
> sendo montada, que é exatamente a mutação que o design recusa.

Um akkar renderizado no servidor "não seria o akkar com mais recursos. Seria
um framework diferente que por acaso compartilha o event loop, e deveria ser
decidido como tal, com seu próprio nome e seus próprios invariantes".

Servir arquivos estáticos é uma coisa separada e o akkar faz isso.
`docs/ROADMAP.md` é explícito que isso "não é um passo em direção a HTML
renderizado no servidor: servir um arquivo e renderizar uma página são
trabalhos não relacionados".

### Adaptadores de fornecedor para pagamentos, storage e email

**Use:** o contrato de capability, com o fornecedor por trás dele.

O item do backlog diz "Passado 'framework de API JSON'. Seja dono do contrato,
deixe as bibliotecas implementarem." Leia isso como sendo sobre adaptadores de
*fornecedor*, não sobre a capability, que é como `docs/ROADMAP.md` lê isso
quando constrói email mesmo assim.

Dois dos três já foram lançados, e como foram lançados é o ponto:

- `akkar/storage.lua` é object storage sobre HTTP, compatível com S3, e não
  adiciona **dependência nenhuma**: o transporte é `akkar.http` e a
  aritmética é `akkar.crypto`. Não é um adaptador de S3; ele fala o dialeto
  que S3, R2, B2, Spaces, MinIO e Garage compartilham.
- `akkar/email.lua` envia através da API HTTP de um provedor e **não nomeia
  nenhum provedor** em sua interface.

Não há módulo de pagamentos e é improvável que venha a existir um.

### SMTP

**Use:** a API HTTP de um provedor, que é o que `akkar/email.lua` faz.

O raciocínio vale a pena repetir porque não é frescura em relação ao trabalho.
Fazer SMTP direito significa negociação ESMTP, STARTTLS, AUTH em três
mecanismos, canonicalização de fim de linha, dot-stuffing, montagem de MIME
multipart, parsing de endereço RFC 5322 e uma política de retry com estado
próprio, **e nada disso faz o email chegar**, porque uma mensagem enviada
direto de um servidor de aplicação sem SPF, DKIM e um IP de envio aquecido cai
no spam ou é recusada de cara.

Se o SMTP algum dia for desejado, ele pertence a `akkar/smtp.lua` como um
transporte que pode ser entregue ao `akkar.email`. A costura já está lá.

### Assinar JWTs

**Use:** `akkar.session` para logins, e `akkar.jwt.verify` para asserções que
outra parte emitiu.

`akkar/jwt.lua` tem `verify` e nada que assine. Esta é a forma mais forte de
exclusão em todo o projeto: uma função ausente cuja ausência é o argumento.
Veja `docs/pt-BR/why/sessions-not-jwt.md`.

### Uma VM isolada para código hostil

**Use:** um processo separado com um sandbox no nível do SO.

`akkar/vm.lua` roda código não confiável em um `_ENV` curado, com carregamento
somente de texto, um orçamento de instruções e um teto de memória. Dentro
desses limites, é real. Além deles, **não é uma barreira de segurança contra
um atacante determinado compartilhando seu processo**, e o módulo se recusa a
fingir o contrário:

> Se o código é hostil, e não meramente não confiável, rode-o em um processo
> separado com um sandbox no nível do SO. Isso não é frescura; é a diferença
> entre um bug e uma violação.

A razão é um fato sobre o Lua, não sobre o akkar: o Lua 5.4 não consegue criar
um estado isolado a partir do próprio Lua. Isso precisa de C ou de um
subprocesso.

`docs/wasm/DECISION.md` estuda a alternativa com honestidade, incluindo a
parte que a favorece: um módulo Wasm é um espaço de endereçamento, não uma
allowlist, então ele não tem nenhuma instrução que endereça memória fora de si
mesmo e não consegue *nomear* uma capability que não foi declarada como
import. Esse estudo **não está decidido**, e está bloqueado por um número, não
por um argumento. Ele também declara o que o Wasm não resolveria: carrega
computação pura, não software de sistema, porque um componente não traz
sockets, TLS nem um runtime assíncrono.

### Um laboratório de benchmark com oito frameworks

**Use:** as duas comparações que existem. A razão do backlog é que "a versão
barata captura a maior parte do valor: compare com Gin e FastAPI, que eu já
escrevo diariamente e que não exigem toolchain nenhuma".

## Coisas que estão faltando, e não excluídas

A diferença importa. Estas não são decisões, são trabalho ainda não feito, e
`docs/ROADMAP.md` as sequencia.

- ~~**WebSocket.**~~ **Construído em 19-08-2026.** A questão do ciclo de vida
  era a de verdade e teve uma resposta que não custou o invariante: um socket
  é três callbacks e um objeto, não um handler que roda por horas, então os
  handlers continuam retornando. As duas metades que pareciam difíceis
  acabaram sendo a mesma decisão: capabilities são adquiridas por MENSAGEM
  através de `ws:scope`, porque uma mensagem é a unidade de trabalho que uma
  requisição já é, e `app:stop` AVISA os sockets para irem embora com um close
  frame 1001 em vez de drenar conexões que não têm motivo para terminar. Não
  custou nenhuma dependência nova: `basexx`, `lpeg` e `lpeg_patterns` já
  estavam declaradas para o `request.lua` vendorizado, e os requires do
  `compat53` são protegidos atrás de `string.pack`, que o Lua 5.4 tem.
- **Uploads em streaming.** Um corpo multipart é bufferizado em memória sob o
  `body_limit`.
- **Empacotamento para Lua 5.5** — e o bloqueio que este item costumava
  descrever já foi resolvido. O makefile do luaossl ainda não tem um degrau
  para 5.5, mas seu C compila limpo com um único `cc`, e o cqueues roda um
  event loop sob o 5.5 assim que seu `lua-compat-5.3` vendorizado é
  atualizado. `docs/runtime/lua55-stack.sh` monta a stack inteira dentro de um
  prefix, **o CI roda esse mesmo arquivo como um job bloqueante**, e a suíte
  passa: 1.763 testes, zero falhas. O que resta é só o empacotamento: nenhuma
  distribuição ainda entrega o 5.5, então o `luarocks install akkar` não
  consegue, e o 5.4 continua sendo o padrão por essa razão e nenhuma outra.
- **Uma receita de libpq estático**, sem a qual o driver C não consegue ser
  entregue dentro de um binário construído.

## Onde a lista para, por decisão

`docs/ROADMAP.md` termina com uma frase que é o verdadeiro resumo desta
página:

> **O akkar está completo quando está completo para APIs JSON.** Os tiers 0-4
> abaixo são isso, e não há Tier 5.

## O que ler a seguir

- `docs/BACKLOG.md`, "What is deliberately not being built", para a tabela viva.
- `docs/ROADMAP.md`, para o que está vindo e em que ordem.
- `docs/PLAN.md` seção 1, para o objetivo e a política de versionamento.
