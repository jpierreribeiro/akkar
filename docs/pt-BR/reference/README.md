# Referência

> **Português (Brasil)** | [Original em inglês](../../reference/README.md)

Uma página por módulo. Cada função pública, sua assinatura, seus argumentos e
os tipos deles, o que ela retorna, o que ela lança como erro e um exemplo mínimo.

Esta é a parte da documentação em que você consulta as coisas. Ela não ensina.
Se você está aprendendo akkar, comece pelo [guia](../guide/00-quickstart.md),
que constrói uma aplicação ao longo de doze páginas e vai explicando no caminho.

Todo exemplo de Lua em bloco de código em cada página abaixo é executado por
`spec/docs_spec.lua`. Um bloco marcado como `no-run` é compilado mas não
executado, e é marcado assim porque é um fragmento: uma linha de `require`,
um valor, ou um campo para adicionar a uma tabela que você já tem.

## Por onde começar

| você quer | leia |
|---|---|
| declarar rotas, retornar respostas, rodar o servidor | [akkar](akkar.md) |
| conversar com o Postgres | [akkar.db](db.md), [akkar.sql](sql.md), [akkar.migrate](migrate.md) |
| tirar trabalho do caminho da requisição | [akkar.jobs](jobs.md), [akkar.work](work.md) |
| saber quem é o chamador | [akkar.session](session.md), [akkar.auth](auth.md) |
| impedir que um chamador tome o servidor inteiro | [akkar.limit](limit.md) |
| parar de discar uma dependência que caiu | [akkar.breaker](breaker.md) |
| ver o que o servidor está fazendo | [akkar.log](log.md), [akkar.metrics](metrics.md), [akkar.trace](trace.md) |
| colocar em produção | [akkar.build](build.md), [akkar.config](config.md), [akkar.health](health.md) |

## Todos os módulos

### Núcleo

| módulo | o que é |
|---|---|
| [akkar](akkar.md) | aplicações, rotas, respostas, validação, o servidor |
| [akkar.scope](scope.md) | linhas que um tenant pode ver, aplicado na conexão |
| [akkar.strict](strict.md) | transforma uma variável global em erro |

### Dados

| módulo | o que é |
|---|---|
| [akkar.db](db.md) | o adaptador do Postgres e seu pool |
| [akkar.migrate](migrate.md) | mudanças de esquema, aplicadas em ordem, uma única vez |
| [akkar.pool](pool.md) | o pool genérico de recursos sobre o qual os adaptadores são construídos |
| [akkar.sql](sql.md) | constrói statements com parâmetros, nunca com concatenação |

### Estado e trabalho em segundo plano

| módulo | o que é |
|---|---|
| [akkar.cache](cache.md) | a capacidade de cache, em memória ou no Redis |
| [akkar.jobs](jobs.md) | uma fila com entrega pelo menos uma vez |
| [akkar.redis](redis.md) | o cliente Redis que os outros módulos usam |
| [akkar.storage](storage.md) | arquivos, em algum lugar que não seja este disco |
| [akkar.work](work.md) | trabalho que precisa acontecer depois que a resposta é enviada |

### HTTP

| módulo | o que é |
|---|---|
| [akkar.breaker](breaker.md) | um circuit breaker, para uma dependência morta parar de ser discada |
| [akkar.compress](compress.md) | compressão de resposta |
| [akkar.etag](etag.md) | requisições condicionais, e a escrita que desapareceria |
| [akkar.http](http.md) | o cliente de saída, como uma capacidade |
| [akkar.idempotency](idempotency.md) | a mesma requisição duas vezes, cobrada uma vez |
| [akkar.multipart](multipart.md) | envio de arquivos |
| [akkar.openapi](openapi.md) | um documento descrevendo as rotas que existem |
| [akkar.static](static.md) | arquivos servidos do disco |

### Segurança

| módulo | o que é |
|---|---|
| [akkar.auth](auth.md) | hashing de senhas e o middleware de autenticação |
| [akkar.crypto](crypto.md) | hashing, bytes aleatórios, comparação em tempo constante |
| [akkar.csrf](csrf.md) | a defesa contra falsificação de requisição entre sites (CSRF) |
| [akkar.jwt](jwt.md) | verificando tokens que outra pessoa emitiu |
| [akkar.limit](limit.md) | limites de taxa e de concorrência |
| [akkar.session](session.md) | quem é o chamador, entre requisições |

### Operações

| módulo | o que é |
|---|---|
| [akkar.config](config.md) | configurações a partir do ambiente, checadas na inicialização |
| [akkar.doctor](doctor.md) | o que está errado com esta instalação |
| [akkar.health](health.md) | vivacidade e prontidão (liveness e readiness) |
| [akkar.log](log.md) | logging estruturado |
| [akkar.metrics](metrics.md) | contadores e histogramas, em formato de texto do Prometheus |
| [akkar.trace](trace.md) | contexto de rastreamento W3C (trace context), de entrada e saída |

### Utilitários e ferramentas

| módulo | o que é |
|---|---|
| [akkar.build](build.md) | um diretório que roda em qualquer lugar |
| [akkar.email](email.md) | envio de e-mail |
| [akkar.json](json.md) | codificação e decodificação, e o problema do array vazio |
| [akkar.time](time.md) | relógios, e qual usar para um prazo (deadline) |
| [akkar.vm](vm.md) | executando código que não é seu |
| [akkar.watch](watch.md) | reinício a cada mudança, em desenvolvimento |

## Convenções em cada página

**Assinaturas.** `akkar.new()` é chamada com ponto. `app:get(...)` é chamada
com dois-pontos, o que passa a coisa à esquerda como um primeiro argumento
oculto. A página sempre mostra qual dos dois.

**Tabelas de campos.** Um `required` na coluna de valor padrão significa que a
chamada lança um erro sem ele. Uma coluna de valor padrão vazia significa que
o campo é opcional e não tem valor quando ausente.

**Erros lançados.** akkar lança erro para enganos do programador, encontrados
na inicialização ou no registro: uma opção desconhecida, uma rota duplicada,
um adaptador que não consegue cumprir seu contrato. Ele retorna um status para
qualquer coisa que o chamador tenha feito: um corpo que falha em um schema é
422, não um erro. Cada página diz qual é qual.

**Não está aqui.** Onde um leitor razoavelmente procuraria por uma função que
não existe, a página diz isso e dá o motivo em uma linha, em vez de deixá-lo
procurando.

**Encontrando um símbolo em uma página.** Uma página com mais de seis
entradas, aproximadamente, abre com uma lista delas, e as entradas ficam em
ordem alfabética abaixo dela. [akkar](akkar.md) carrega cerca de sessenta e
usa uma tabela em vez de uma lista com marcadores, porque uma lista com
marcadores de sessenta itens não é algo que se escaneia visualmente.

**Onde estão os motivos.** Estas páginas dizem o que uma função faz, não por
que ela foi construída daquele jeito. A maioria dos módulos carrega um
comentário longo no topo que apresenta o argumento, e cada página termina
apontando para seu próprio arquivo-fonte por causa disso. As
[páginas de porquês](../why/) reúnem os maiores desses argumentos.
