# O scorecard de produção: o que falta a Lua, e o que o runtime faz a respeito

> **Português (Brasil)** | [Original em inglês](../../why/production-scorecard.md)

O caso contra Lua num backend de produção é uma lista, e a maior parte dela
está correta sobre a linguagem. Sem tipos estáticos. Cinco runtimes
incompatíveis. Uma biblioteca padrão sem HTTP, sem JSON e sem event loop. Sem
workflows duráveis, sem circuit breaker, sem ORM, sem padrão de
observabilidade, e um concorrente compilado que é mais rápido.

Esta página pega essa lista um item de cada vez e confere contra a árvore em
2 de setembro de 2026. Cada item recebe um de dois vereditos. **Neutralizada**
quer dizer que o runtime faz a escolha que a linguagem se recusa a fazer, e a
página diz onde na árvore essa escolha vive. **Risco real** quer dizer que o
buraco continua lá, e a página diz o tamanho dele e o que, se houver algo,
está em andamento para fechá-lo. Nada aqui é dado como entregue sem um
arquivo nomeado ao lado; trabalho planejado ou meio construído está marcado
como *em andamento*, e essa marca é a parte honesta.

A tese que a lista testa: **o akkar responde a "Lua não escala" sendo um
runtime opinativo.** Uma versão de Lua, um event loop, um validador, uma pilha
HTTP, baterias na caixa. A linguagem deixa essas escolhas em aberto, o
ecossistema discute sobre elas há vinte anos, e um runtime que as faz é o que
uma equipe de fato precisa de uma plataforma. Onde essa tese se sustenta, a
crítica está neutralizada; onde não se sustenta, a lacuna é uma feature que o
akkar ainda não construiu, não uma propriedade de Lua.

| # | Crítica | Veredito | Onde olhar |
|---|---|---|---|
| 1 | Sem tipagem estática; Teal, Luau, LuaLS e Pluto fragmentam a resposta | **Neutralizada para segurança; resta uma lacuna de DX** | `akkar/gen.lua`, `akkar/openapi.lua`, `akkar.validate` em `akkar/init.lua` |
| 2 | Fragmentação de runtime: 5.1 a 5.5, LuaJIT, Luau | **Neutralizada, e é uma força** | `akkar-0.1.0-1.rockspec`, `docs/substrate/LUAJIT.md`, `docs/substrate/LUAU.md` |
| 3 | Biblioteca padrão mínima | **Neutralizada, com um custo de manutenção instrumentado** | `akkar/vendor/http/PROVENANCE.md`, `spec/vendor_provenance_spec.lua` |
| 4 | Sem event loop padrão; cqueues está estagnado e é só Unix | **Risco real, o maior** | `docs/substrate/CQUEUES.md`, `docs/substrate/SEGFAULT.md` |
| 5 | Sem workflows duráveis | **Lacuna real, fechável por composição** | `akkar/jobs.lua` |
| 6 | Sem circuit breaker, sem primitivos de resiliência | **Um primitivo faltando** | `akkar/limit.lua`, `akkar/execution.lua`, `akkar/http.lua` |
| 7 | Sem ORM tipado | **Fora de escopo, deliberadamente** | `akkar/sql.lua`, `docs/why/what-akkar-does-not-do.md` |
| 8 | Observabilidade não padronizada | **Parcial, à frente da suposição, uma lacuna nomeada** | `akkar/trace.lua`, `akkar/metrics.lua`, `akkar/log.lua` |
| 9 | Desempenho: V8 e Go vencem o interpretador; OpenResty é 8.75x mais rápido | **Neutralizada como posicionamento; o teto é real e delimitado** | `bench/study/WHERE-THE-GAP-IS.md`, `docs/why/slower-than-openresty.md` |

O resto da página é o argumento por trás de cada linha.

---

## 1. Tipagem estática — neutralizada para segurança; resta uma lacuna de DX

A crítica está correta duas vezes. Lua não tem compilador que confira a
intenção antes de o programa rodar, e as respostas do ecossistema — Teal,
Luau, anotações LuaLS, Pluto — são quatro dialetos que não concordam entre si.
`types/akkar.d.tl` abre concedendo o ponto em vez de discutir com ele.

O que o akkar faz em vez disso é fazer o tipo viver num só lugar e projetá-lo
para todos os outros. Uma rota declara seu schema uma vez:

```lua no-run
app:post("/transfers", {
  body     = { to = "string", amount = akkar.v.integer { min = 1 } },
  response = { id = "string", status = "string" },
}, function(req)
  return { id = "tr_1", status = "posted" }
end)
```

Três coisas leem essa tabela, e nenhuma delas pode discordar das outras
porque leem a mesma tabela pela mesma expansão:

- **O validador a impõe em tempo de execução.** `akkar.validate` em
  `akkar/init.lua` coage `params` e `query`, rejeita um `body` ruim com um
  422 cujo mapa `fields` nomeia o caminho ofensor, e confere a `response` na
  saída. É barato: validar quatro campos aloca 152 bytes, que é exatamente o
  tamanho da tabela de saída limpa e nada mais
  (`bench/study/HTTP-OPTIMISATION.md`).
- **O documento a descreve.** `akkar/openapi.lua` transforma as mesmas tabelas
  num documento OpenAPI 3.1 servido em `/openapi.json`, incluindo as formas do
  422 e do 500 que o próprio akkar produz (`openapi.VALIDATION_FAILED`,
  `openapi.INTERNAL_ERROR`).
- **O cliente é gerado dela.** `akkar gen` (`akkar/gen.lua`) lê esse documento
  e emite um cliente TypeScript: uma interface por entrada que uma rota
  declara, `?` em campos opcionais, um `AkkarError<TBody>` tipado por rota
  como a união de suas respostas de erro, e um comentário acima de cada rota
  listando toda restrição que o servidor impõe e que um tipo TypeScript não
  consegue expressar — TypeScript não tem inteiro nem intervalo, então
  `amount: -3` passa no type-check e só o 422 o recusa. Onde uma rota não
  declarou `response`, o tipo de retorno é `unknown`, nunca `any`, para que a
  lacuna fique visível no checker em vez de conferida contra nada.

Essa última projeção é a que responde à queixa como ela costuma ser feita,
que na verdade é sobre tRPC: uma chamada errada à sua própria API deveria
ficar vermelha no editor, não virar um 422 em produção. `spec/gen_spec.lua`
prova isso com um `tsc` real: uma chave com erro de digitação é erro de
compilação, uma chamada correta não é, e renomear um campo no servidor deixa
vermelho um cliente antes correto assim que ele é regenerado.
`examples/typed-client/` é o menor laço completo, e
`.github/workflows/ci.yml` roda `akkar gen … --check` contra ele, de modo que
uma mudança de schema que ninguém regenerou quebra o build. `akkar doctor`
avisa sobre uma rota que valida a entrada e não declara `response`, porque
isso é um contrato tipado na entrada e sem tipo na saída (`untyped_responses`
em `akkar/doctor.lua`).

**O que isso não é.** tRPC infere; o akkar gera. O arquivo gerado só é tão
atual quanto o último `akkar gen`, e o `--check` no CI é uma garantia de
processo, não uma propriedade do compilador — `examples/typed-client/README.md`
diz isso no segundo parágrafo. E não há checagem estática dentro do corpo do
handler: `types/akkar.d.tl` tipa `req.params` como `{string: any}` e
`req.body` como `any`, então um handler em Teal é conferido contra a API do
akkar e não contra o schema da própria rota. Records Teal por rota e
anotações LuaLS `---@` projetadas da mesma fonte estão **em andamento**; hoje
há zero anotações `---@` sob `akkar/`, e dizer isso é mais útil do que
sugerir o contrário. `docs/substrate/LUAU.md` registra por que a resposta é
codegen e anotações em vez de um dialeto tipado sobre o substrato.

---

## 2. Fragmentação de runtime — neutralizada, e é uma força

A crítica: Lua 5.1, 5.2, 5.3, 5.4, 5.5, LuaJIT e Luau são mutuamente
incompatíveis em sintaxe, semântica e ABI de C, e quem escreve uma biblioteca
tem de escolher um subconjunto da linguagem para alcançar todos eles.

O akkar escolhe um. `akkar-0.1.0-1.rockspec` declara `lua >= 5.4, < 5.6` e
nada abaixo disso, e as duas alternativas que as pessoas perguntam foram cada
uma respondidas com uma medição em vez de uma preferência:

- **LuaJIT foi medido e recusado.** `docs/substrate/LUAJIT.md`: 1.62x em
  `/ping` contra uma barra de 2x escrita antes da rodada. A razão mais
  profunda não é throughput. LuaJIT não tem subtipo inteiro, então `math.type`
  não pode existir honestamente, e `db.lua:57` o usa para vincular um número
  inteiro como `int8` em vez de `float8`, a linha que
  `docs/substrate/LUAJIT.md` destaca como a que um shim mentiroso quebra em
  silêncio. Sob LuaJIT `v.integer` vira consultivo, que é exatamente o
  defeito que ele existe para impedir. Isso é propriedade do runtime, não de
  um shim.
- **Luau não consegue hospedar o substrato.** `docs/substrate/LUAU.md`: todo
  módulo nativo sobre o qual o akkar se apoia é compilado contra a `lua.h` do
  PUC-Lua 5.4, e o Luau traz a sua própria.
- **Lua 5.5 compila e passa.** `docs/substrate/LUA-55.md`, e o CI roda esse
  build como job bloqueante. O que mantém 5.4 como padrão é só empacotamento:
  nenhuma distribuição entrega 5.5 ainda.

Escolher um runtime é o que permite ao código usar a linguagem em que foi
escrito: `math.type`, `string.pack`, `<close>`, operadores bitwise, `goto` em
`akkar/jobs.lua`, tudo sem camada de compatibilidade. O único shim na árvore,
`akkar/bitwise.lua`, existe porque o experimento com LuaJIT precisou dele. O
cabeçalho dele precifica os dois sítios que rodam por requisição em cerca de
0.04% de uma, e a estimativa anterior de `docs/substrate/LUAJIT.md` era
0.07%; qualquer uma está uma ordem de grandeza abaixo do piso de ruído de
1.16% contra o qual o projeto mede. Ele fica como registro do que a
portabilidade custaria, não como promessa de ser portável.

---

## 3. Biblioteca padrão mínima — neutralizada, com um custo instrumentado

A crítica: `require "http"` não existe. Lua entrega string, table, math, io e
os, e tudo que um backend precisa vem do LuaRocks numa dúzia de versões
concorrentes.

A resposta do akkar é a tabela de módulos do rockspec: roteamento, validação,
JSON, cliente e servidor HTTP, TLS, sessões, CSRF, criptografia, um adaptador
Postgres, um adaptador Redis, pool de conexões, jobs, métricas, tracing, logs
estruturados, composição de SQL, migrações, armazenamento de objetos, e-mail,
WebSocket, um sandbox, um observador de arquivos, um módulo de health, uma
ferramenta de build. A aplicação não escolhe nenhum deles e configura poucos.

A parte que merece escrutínio é a pilha HTTP, porque é aquela em que
"baterias inclusas" significa "a bateria é nossa". `akkar/vendor/http/`
carrega 22 arquivos e cerca de 10.350 linhas do lua-http 0.4, dos quais 11
arquivos estão patchados — com os reparos de negação de serviço do próprio
akkar (um cabeçalho de frame de três bytes que matava o accept loop, um
`MAX_CONCURRENT_STREAMS` imposto, um `RST_STREAM` com contabilidade de taxa
para a CVE-2023-44487, uma mensagem WebSocket limitada) e dois consertos
upstream pós-release retroportados à mão. Isso é um órfão adotado, não uma
dependência fixada: a última release do upstream é de 2021 e o último commit
é de 2024-09-08.

O custo de adotar um órfão é ser seu único mantenedor, e o projeto já pagou
por isso uma vez da menor forma possível: o primeiro arquivo de proveniência
estava errado em vinte e quatro horas, certificando dois arquivos como
inalterados enquanto cinco commits colocavam reparos de segurança exatamente
neles. O conserto é o instrumento, e é o padrão que esta página inteira
defende. `akkar/vendor/http/PROVENANCE.md` é o livro-razão;
`spec/vendor_provenance_spec.lua` quebra o CI, nomeando o commit, se algum
patch estiver faltando no arquivo em que o livro diz que ele está, se as duas
colunas discordarem, ou se um arquivo não tiver linha. Prosa que nada executa
é como isso já deu errado uma vez.

**O que isso não é.** Não é promessa de que os arquivos não modificados sejam
byte a byte idênticos ao upstream — essa checagem precisa da tag upstream, o
CI não tem rede, e o livro-razão diz isso. E não é uma biblioteca padrão para
o ecossistema Lua; é a do akkar, e `docs/why/what-akkar-does-not-do.md` lista
o que ficou de fora de propósito.

---

## 4. Sem event loop padrão — risco real, o maior

A crítica: Lua não tem event loop, e o que o akkar escolheu, cqueues, não tem
release desde 2020 e não roda no Windows.

Os dois fatos conferem, e esta é a linha em que a resposta do runtime é
"assumido" em vez de "neutralizado". `docs/substrate/CQUEUES.md` carrega o
relato completo; o resumo é:

- O último rock publicado é `rel-20200726`. O master upstream está vivo — seus
  commits mais recentes são de 18 de março de 2026 e adicionam Lua 5.5 — mas
  o delta inteiro desde a release são dezesseis commits em doze arquivos, e o
  LuaRocks não consegue expressar um commit, então **o que `luarocks install
  akkar` obtém e o que o CI prova não são o mesmo build.** O rockspec diz
  isso nas linhas 46–51 e o nomeia como o argumento mais forte a favor do
  `akkar build`.
- Windows não é uma lacuna para o posicionamento deste runtime.
  `docs/PLATFORMS.md` o lista como "not supported, and not planned".
  Capacidade é um processo por núcleo atrás de `SO_REUSEPORT`
  (`docs/why/one-process-per-core.md`), a implantação é um binário estático
  num container `scratch` (`docs/DEPLOY.md`), e o CI testa Linux x86-64,
  Linux arm64 e macOS. O cqueues seria só a primeira de várias dependências
  com forma de Unix a ficar no caminho do Windows.
- A mitigação é o `akkar build`: `akkar archive cqueues` compila o commit
  fixado num arquivo estático e o host o linka, de modo que o artefato que
  sai contém o cqueues que o CI testou e o rock de 2020 nunca entra. O
  `Dockerfile` fixa o mesmo `CQUEUES_COMMIT` que `.github/workflows/ci.yml`.
- O akkar não carrega **nenhum patch** ao cqueues, e é por isso que ele não
  está forkado como o lua-http foi. As condições de gatilho para um fork
  estão escritas.

O risco não é teórico. Uma falha na camada nativa já foi atingida:
`docs/substrate/SEGFAULT.md` registra um segfault intermitente dentro da
árvore de descritores do cqueues, diagnosticado por um core dump em 2 de
setembro de 2026. O sítio é o `cstack_cancelfd` do cqueues percorrendo todos
os controllers num `connect` que falha; a árvore corrompida pertencia a um
controller que `akkar/health.lua` abandonou com uma sonda expirada ainda
dentro. A causa é do akkar, a falha é nativa, e o conserto — rodar a sonda
como worker no controller em que já se está, com o deadline carregado como um
número puro em `cqueues.poll`, do jeito que `akkar/execution.lua` roda
handlers — está em `akkar/health.lua` (commit `8bf1a21`). Não dá para
prová-lo localmente; a prova é a matriz do CI ficar verde com ele dentro, e
no momento da escrita as últimas execuções concluídas nos dois branches que o
carregam (`feat/typed-contract`, `recover/night-work`) tinham falhado em
todos os jobs de unit — x86-64 e macOS inclusos, não só o arm64 — o que diz
que a matriz tem um problema próprio antes de poder dizer qualquer coisa
sobre este conserto. Até existir uma execução verde, o conserto é um
diagnóstico com um patch, não um defeito fechado.

---

## 5. Workflows duráveis — lacuna real, fechável por composição

A crítica: sem Temporal, sem Inngest, nada que sobreviva a um reinício de
processo no meio de um fluxo.

O que existe é uma fila de jobs cuja semântica está separada do
armazenamento. `akkar/jobs.lua` guarda a lógica e declara o contrato do store
no cabeçalho: três métodos obrigatórios, e opcionais que compram retentativas
com backoff, jobs atrasados, deduplicação na porta (`push` com um `id`
retorna `false, "duplicate"` na segunda vez), dead-letter, um reaper para jobs
cujo lease expirou, e uma garantia de entrega que tem de ser pedida pelo
nome — `delivery = "at_least_once"` é recusado na construção sobre um store
que não sabe fazer lease, porque rebaixar em silêncio para at-most-once é a
falha que o módulo existe para evitar. Todo job carrega um `uid` cunhado uma
vez e preservado pelas retentativas, para que um handler tenha uma chave
estável sob a qual escrever sua marca de já-fiz-isso.
`spec/jobs_delivery_spec.lua` exercita a garantia. Dois stores são entregues:
`akkar/jobs/memory.lua` e `akkar/jobs/redis.lua`.

O que não existe, e o tamanho do buraco:

- **Sem store Postgres.** Uma equipe com Postgres e sem Redis não tem fila
  durável hoje. O contrato do store são catorze métodos e a receita Postgres
  (`SELECT … FOR UPDATE SKIP LOCKED`, `LISTEN/NOTIFY`) é bem conhecida; ela
  reaproveita inalterada toda a lógica de retentativa, backoff, dead-letter e
  lease. **Em andamento.**
- **Sem memoização de passos.** Um workflow que cobra um cartão, depois envia
  um e-mail, depois atualiza um razão não tem como retomar depois do segundo
  passo se o processo morrer antes do terceiro. A forma planejada é a do
  Inngest, não a do Temporal — `ctx:step(name, fn)` persistindo o resultado
  de cada passo na mesma `db:transaction`, `ctx:sleep` como continuação
  agendada — porque replay determinístico precisa de uma VM em sandbox, e
  `akkar/vm.lua` é explícito em dizer que não é isso. **Em andamento**, e
  depende do store acima.

Esta é a linha em que "fechável por composição" está fazendo trabalho de
verdade: os primitivos — `pq`, transações com escopo de closure e savepoints
em `akkar/db.lua`, o `uid`, o padrão claim-and-replay de
`akkar/idempotency.lua` — todos existem, e o workflow é a coisa que ainda não
foi escrita em cima deles.

---

## 6. Resiliência — um primitivo faltando

A crítica: sem timeouts por padrão, sem bulkhead, sem política de
retentativa, sem circuit breaker.

Três dos quatro estão presentes, e o primeiro está à frente do que a crítica
supõe:

- **Timeouts.** Toda requisição tem um deadline quer alguém tenha pedido ou
  não — `akkar.defaults.timeout` é 30 segundos em `akkar/init.lua`, e
  `akkar/execution.lua` o carrega como um número que a execução inteira pode
  ler, em vez de um objeto que alguém tem de passar adiante. O adaptador HTTP
  de saída (`akkar/http.lua`) recebe um deadline absoluto em vez de um timeout
  por chamada, e seu cabeçalho registra por que a versão por chamada era o
  defeito com que ele foi entregue. `akkar doctor` avisa quando o banco não
  tem `statement_timeout` compatível com o deadline da requisição, porque o
  deadline do akkar faz o akkar parar de esperar e não faz o Postgres parar
  de trabalhar.
- **Bulkhead.** `akkar.limit.concurrent` limita quantas requisições um
  chamador pode ter em voo, `akkar.limit.rate` limita a taxa, e
  `akkar.limit.shed` recusa sob carga — tudo em `akkar/limit.lua`, tudo
  compartilhado entre processos via Redis para que o limite seja da
  implantação e não do processo.
- **Retentativa.** Desligada a menos que pedida, nos dois lugares em que
  existe: `akkar/jobs.lua` (`retries`, `backoff`) e `akkar/http.lua`
  (`retries`, e `retry_unsafe = true` antes que um método não idempotente
  possa ser repetido, para que ninguém cobre duas vezes por acidente).
- **Circuit breaker.** Ausente. Uma busca em `akkar/` por `breaker` ou
  `circuit` não encontra nada além da palavra "short-circuit" num comentário
  do HTTP vendorizado. `akkar.breaker` — Fechado, Aberto, Meio-Aberto,
  compondo com o deadline que já existe — está **em andamento**. Até ele
  chegar, um upstream morto é tratado só por deadlines, o que limita o dano
  por requisição e não faz nada para impedir a próxima requisição de
  pagá-lo.

---

## 7. Sem ORM tipado — fora de escopo, deliberadamente

A crítica é precisa e a resposta é uma recusa, registrada com suas razões em
`docs/why/what-akkar-does-not-do.md`. Um ORM é uma opinião sobre modelagem, e
o akkar declina ter uma.

O que ele tem no lugar é mais estreito e mira o erro que importa:
`akkar/sql.lua` compõe condições a partir de dados com placeholders `?`
numerados em `$1, $2` uma vez na montagem, e não tem `where_raw`, porque uma
válvula de escape é por onde a injeção entra. `db:transaction` em
`akkar/db.lua` tem escopo de closure, então um `BEGIN` órfão é
irrepresentável, e chamadas aninhadas viram savepoints. O escopo de tenant
(`akkar/scope.lua`) recusa SQL cru por completo, com o argumento de que uma
string não pode ter escopo sem ser parseada. Migrações foram excluídas junto
com o ORM e depois construídas — `akkar/migrate.lua`, só para cima, com lock
advisory — porque um runner é um razão e um lock, não uma opinião de
modelagem, e a página de exclusões registra a reversão.

---

## 8. Observabilidade — parcial, à frente da suposição, uma lacuna nomeada

A crítica: sem OpenTelemetry, sem métricas padrão, logs que são strings.

As três pernas existem, e a de traces tem uma propriedade que as
implementações de referência usuais da crítica não têm:

- **Traces.** `akkar/trace.lua` fala W3C Trace Context nos dois sentidos — um
  `traceparent` de entrada é validado em vez de confiado, exposto como
  `req.trace`, ecoado na resposta e encaminhado em chamadas de saída — e
  exporta spans OTLP sobre `akkar.http`. Sua única regra: **uma requisição
  nunca bloqueia numa exportação.** `record` anexa a uma fila limitada;
  quando a fila está cheia o span é descartado e contado; um lote que falha
  é descartado, não repetido. `spec/trace_spec.lua` prova isso entregando ao
  exportador um cliente que lança erro ao contato e servindo 200s através
  dele.
- **Métricas.** `akkar/metrics.lua` renderiza texto Prometheus sem
  dependência, rotulado por padrão de rota e nunca por caminho da
  requisição, de modo que `/users/:id` é uma série e não três milhões.
- **Logs.** `akkar/log.lua` emite um objeto JSON por linha ou um formato
  humano, e `req.log` é um logger já vinculado ao id da requisição, para que a
  correlação seja propriedade do logger em vez de uma disciplina que cada
  ponto de chamada tem de lembrar. `app:on_error` (`akkar/init.lua`) é o
  gancho a que um reporter de erros se prende.

As lacunas, em ordem de valor:

- **Logs e traces não têm chave comum.** `akkar/execution.lua` vincula
  `request_id` e o `client_request_id` do chamador em `req.log`; não vincula
  `trace_id` nem `span_id`, e o span não carrega o id da requisição. Hoje uma
  linha de log e um span da mesma requisição não podem ser unidos. Conserto
  pequeno, valor alto, **em andamento**.
- **Só traces saem do processo em OTLP.** Métricas são texto Prometheus e
  logs são stderr. Exportadores OTLP para ambos, reaproveitando o padrão
  nunca-no-relógio-da-requisição de `trace.lua`, estão **em andamento**.
- **Relato de erros é um gancho, não um exportador.** Um exportador no
  formato do Sentry sobre `app:on_error` está **em andamento**.

---

## 9. Desempenho — neutralizada como posicionamento; o teto é real e delimitado

A crítica: V8 e Go vencem o interpretador, OpenResty é 8.75x mais rápido em
`/ping`, e um framework Lua começa toda comparação atrás.

O 8.75x é real e atual (`docs/why/slower-than-openresty.md`). O que está
dentro dele é a parte útil, e `bench/study/WHERE-THE-GAP-IS.md` mediu em vez
de raciocinar:

- **A linguagem não é o teto.** Um servidor HTTP/1.1 real mínimo em Lua 5.4
  interpretado — linha de requisição, cabeçalhos, corpo, roteamento — roda a
  1.69x do Gin nos mesmos dois núcleos. O event loop Lua custa 11.6 µs por
  requisição; o Gin custa 19.6.
- **A velocidade do OpenResty é o nginx, não o LuaJIT.** O LuaJIT responde
  por 1.62x da lacuna de 9.4x; o event loop e o parser em C do nginx
  respondem pelo resto. Tornar o akkar tão rápido quanto o OpenResty é uma
  proposta de escrever o nginx.
- **A lacuna é mais larga onde o trabalho é menor.** Em `/ping` o akkar está
  a 0.19x do Gin. Em `/rows/200`, duzentas linhas do Postgres com o driver em
  C (`akkar.pq`), está a 0.48x do Gin com p99 de 6.53 ms contra 7.04 do Gin.
  Quanto mais uma requisição faz, menos o framework custa em relação a ela.

O teto é declarado como aritmética, com seu rótulo: substituir o caminho
quente do lua-http chega a cerca de 0.35x do Gin em `/ping`, cortar pela
metade o custo próprio do akkar em cima disso chega a cerca de 0.6x, e
paridade exigiria que os 44.6 µs do próprio akkar virassem 8, que são o
roteador, a cadeia, o deadline e o codificador JSON — as coisas que o akkar
existe para fornecer. Então paridade em `/ping` não é meta e 0.35x a 0.6x é.
O posicionamento que segue é o de `docs/why/what-the-runtime-is-for.md`:
tempo de boot, densidade, isolamento e um único artefato, com throughput
como um número publicado e não perseguido.

---

## A tese, reafirmada contra a evidência

Cinco linhas estão neutralizadas ou recusadas por decisão, e em todas elas o
mecanismo é o mesmo: o runtime escolheu. Uma versão, então `math.type` e
`<close>` simplesmente estão disponíveis. Um event loop, então um deadline é
um número e um watchdog pode existir. Um validador, então um documento e um
cliente podem ser projetados dele. Uma pilha HTTP, própria, então uma CVE é
um patch com uma linha no livro-razão e não uma espera pelo upstream.

Quatro linhas carregam lacunas reais — o risco do substrato, workflows
duráveis, o breaker, a chave de correlação — e nenhuma delas é propriedade de
Lua. Cada uma, exceto o substrato, é um módulo que não foi escrito, com um
design que compõe primitivos existentes, e cada uma está marcada como *em
andamento* acima em vez de reivindicada. A do substrato está assumida em vez
de fechada, e `docs/substrate/CQUEUES.md` diz o que assumir significa. Quando
elas chegarem, esta página deve dizê-lo com um arquivo ao lado de cada uma;
uma linha que muda de veredito sem um arquivo ao lado deve ser tratada como
opinião.

## O que esta página não diz

- **Ninguém construiu uma aplicação sobre o akkar.** Todo defeito nomeado
  nesta página foi encontrado engenhando uma exposição, e todo veredito é uma
  afirmação sobre a árvore e não sobre a experiência de uma equipe com ela.
  Essa é a maior lacuna na evidência e nenhum scorecard a fecha.
- **As linhas em andamento são planos.** Um store de jobs em Postgres,
  `akkar.breaker`, `akkar.workflow`, métricas e logs OTLP, correlação
  log-trace, declarações Teal e LuaLS por rota: nenhum está na árvore, e a
  página marca cada um em vez de arredondar para cima.
- **A linha do substrato não é fechada por esta página.** O conserto em
  `akkar/health.lua` está na árvore e sem prova: nenhuma execução do CI que o
  carregasse tinha ficado verde no momento da escrita, e a única prova que
  vai contar é a que o CI dá.
- **Os números são emprestados.** Toda cifra aqui é citada da página que a
  mediu, com as ressalvas dessa própria página — três repetições nos pisos,
  um fixture aposentado em 2026-08-18, máquinas que não existem mais. Leia a
  fonte antes de citar o número.
