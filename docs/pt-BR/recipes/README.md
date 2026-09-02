# Receitas

> **Português (Brasil)** | [Original em inglês](../../recipes/README.md)

Uma página, um problema, uma solução completa que você pode copiar. Cada página
é independente: nada aqui pressupõe que você leu a página anterior.

Se você está aprendendo akkar em vez de procurar algo específico, comece pelo
guia em [00-quickstart.md](../guide/00-quickstart.md). Estas páginas partem do
princípio de que você já sabe o que quer.

Todo servidor aqui usa a porta 3000, a mesma porta usada pelo guia, então
pare um antes de iniciar o próximo.

## Dados de saída

- [Pagine uma lista](paginate-a-list.md). Uma página de linhas e um cursor
  para a próxima página.
- [Retorne um CSV](return-a-csv.md). Uma planilha em vez de JSON, com um nome
  de arquivo.
- [Transmita uma resposta (response) grande](stream-a-large-response.md). Uma
  exportação de qualquer tamanho, ao custo de memória de uma única linha.

## Dados de entrada

- [Envie um arquivo](upload-a-file.md). Um arquivo vindo de um formulário,
  validado e gravado em disco.
- [Torne uma escrita idempotente](make-a-write-idempotent.md). O mesmo POST
  duas vezes cobra uma vez só.

## Carga e custo

- [Faça cache de uma query cara](cache-an-expensive-query.md). Calcule uma
  vez, sirva todos os outros a partir do Redis.
- [Limite a taxa de um endpoint](rate-limit-one-endpoint.md). Um limite em um
  caminho só, e em nenhum outro.
- [Veja o que está lento](see-what-is-slow.md). Durações por rota, e o aviso
  para um handler que bloqueia.

## Conversando com outros serviços

- [Chame outra API e lide com a falha](call-another-api.md). Um timeout, e
  uma resposta sua para quando eles não tiverem uma.
- [Repita com segurança](retry-safely.md). Repita sem transformar um pedido
  em três.
- [Envie e-mail](send-email.md). Pela API de um provedor, sem que a
  requisição (request) caia quando ela falhar.

## Trabalho que acontece depois

- [Rode um worker no mesmo processo](run-a-worker-in-the-same-process.md).
  `app:task`, uma fila em memória, um processo.
- [Agende um job recorrente](schedule-a-recurring-job.md). A cada minuto, e
  parando de forma limpa junto com o servidor.

## Configuração e deploy

- [Leia a configuração a partir do ambiente](read-config-from-the-environment.md).
  Um schema só, e a recusa de iniciar quando falta uma configuração.
- [Rode as migrações no deploy](run-migrations-on-deploy.md). Um programa que
  migra e encerra.
- [Sirva um frontend a partir do mesmo servidor](serve-a-frontend.md). Uma
  origem só, sem CORS.

## Testes e operação

- [Teste uma rota](test-a-route.md). A cadeia inteira, sem socket.
- [Teste algo que acessa o banco de dados](test-with-the-database.md).
  Postgres de verdade, com linhas limpas entre os testes.
- [Registre logs de forma útil](log-usefully.md). Campos, níveis, e o ID da
  requisição que amarra as linhas entre si.

## O que não está aqui

**Aceitar um webhook e verificar sua assinatura.** O akkar não faz isso hoje,
então não existe aqui uma página fingindo o contrário. Provedores como
Stripe, GitHub e Slack assinam os bytes exatos do corpo da requisição, e o
akkar decodifica o corpo antes de um handler rodar e não guarda os bytes:
`req.body` é uma tabela Lua e não existe `req.raw_body`. Recodificar a tabela
produz bytes diferentes, então a assinatura não vai bater. Um provedor que
assina algo diferente do corpo bruto, como a URL somada aos campos do
formulário em ordem alfabética, pode ser verificado hoje com
`akkar.crypto.hmac_verify` e `akkar.crypto.equal`. Verificar o caso comum
exige que o akkar guarde o corpo não decodificado, o que é uma mudança no
framework, não uma forma de usá-lo.

## Como estas páginas continuam corretas

`spec/docs_spec.lua` extrai cada bloco de Lua delimitado por cercas em cada
página aqui e o executa, do mesmo jeito que faz com o guia. Um bloco que
lança um erro faz a suíte falhar. Dois tipos de bloco são marcados como
`no-run` e são compilados mas não executados: uma spec do busted, porque quem
roda é o busted e não o `lua5.4`, e a página de configuração, porque o que
seu arquivo faz depende do ambiente em que ele é iniciado. Cada página avisa
isso no lugar em que acontece.
