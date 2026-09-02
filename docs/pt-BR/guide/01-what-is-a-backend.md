# 1. O que é um backend, afinal

> **Português (Brasil)** | [Original em inglês](../../guide/01-what-is-a-backend.md)

Ao final desta página você será capaz de imaginar o que um backend faz, com
detalhes suficientes para ler a próxima página e saber o que está construindo.

Não há código aqui. Nada para instalar, nada para rodar. Leia uma vez.

## Um backend é um programa que espera

A maioria dos programas que você já escreveu começa, faz alguma coisa e
termina.

Um backend não termina. Ele inicia, abre uma porta na rede e então espera.
Alguém bate, ele responde, e volta a esperar. Ele faz isso durante meses.

Essa é a forma inteira. O resto desta página é sobre o que significam "bater"
e "responder".

## A batida se chama requisição (request)

Uma requisição (request) é uma mensagem curta. Três partes importam para você
agora.

**Um método.** Uma palavra dizendo que tipo de coisa quem chamou quer:

| Método | Significa |
|---|---|
| `GET` | me dê algo. Não mude nada |
| `POST` | aqui está algo novo, crie isso |
| `PUT` / `PATCH` | mude algo que já existe |
| `DELETE` | remova algo |

Essas são convenções, não regras que a rede impõe. Mas todo mundo as segue, e
você também deveria, porque ferramentas e navegadores partem desse
pressuposto.

**Um caminho.** Qual coisa: `/tasks`, `/tasks/7`, `/users/3/settings`.

**Às vezes um corpo.** Dados extras anexados à requisição. Um `GET` normalmente
não tem corpo. Um `POST` normalmente tem, porque você precisa dizer o que
criar.

Juntando tudo, uma requisição é uma frase: `GET /tasks` é "me dê as tarefas".
`POST /tasks` com um corpo é "crie uma tarefa, aqui estão os detalhes".

## A resposta se chama resposta (response)

Uma resposta (response) tem duas partes que importam agora.

**Um código de status.** Um número de três dígitos dizendo como foi. O
primeiro dígito é o resumo:

| Começa com | Significa | Exemplo |
|---|---|---|
| `2` | deu certo | `200 OK`, `201 Created` |
| `4` | quem chamou errou em algo | `404 Not Found` |
| `5` | o servidor errou em algo | `500 Internal Server Error` |

A diferença entre `4` e `5` importa mais do que parece, e a página 4 é
inteiramente sobre isso.

**Um corpo.** Os dados de fato. Para o tipo de backend que este guia constrói,
esse corpo é sempre JSON.

## Uma rota é um caminho mais um método

Seu backend vai responder algumas requisições e não outras. Cada combinação
que ele concorda em responder é uma **rota**.

`GET /tasks` é uma rota. `POST /tasks` é uma rota diferente, mesmo que o
caminho seja o mesmo, porque o método é diferente. `GET /tasks/7` é uma
terceira.

Escrever um backend é basicamente: decidir quais rotas existem, e escrever o
código que responde a cada uma delas.

## JSON é dado escrito como texto

Dois programas não conseguem passar uma tabela ou um objeto um para o outro.
Eles só conseguem enviar bytes por um fio. Então eles combinam uma forma de
escrever dados como texto, e JSON é a forma que quase todo mundo combinou usar.

Se parece com isto:

```
{"id": 1, "title": "buy milk", "done": false}
```

Isso é um objeto com três campos. O nome de um campo está sempre entre aspas
duplas. Valores podem ser texto (entre aspas), números, `true`, `false`,
`null`, outro objeto, ou uma lista entre colchetes:

```
{"tasks": [{"id": 1, "title": "buy milk"}, {"id": 2, "title": "walk the dog"}]}
```

É isso. JSON não tem mais recursos além desses. Toda linguagem de programação
consegue ler e escrever JSON, e é exatamente por isso que ele venceu.

O akkar lê JSON das requisições recebidas para você, e transforma o que seu
código retorna em JSON na saída. Você raramente vai digitar JSON à mão.

## Por que o navegador não pode simplesmente falar com o banco de dados

Esta é a pergunta que faz o trabalho inteiro fazer sentido, então vale dois
minutos.

Um banco de dados também é um programa. Ele também espera conexões. Então uma
pergunta justa é: por que não deixar a página web se conectar direto ao banco
de dados e pular o backend inteiramente?

**Porque tudo o que um navegador guarda é público.** Código que você envia
para um navegador pode ser lido por quem estiver usando esse navegador. Se a
página carrega a senha do banco de dados, então todo visitante tem a senha do
banco de dados. Não "poderia conseguir com esforço". Tem. Dois cliques nas
ferramentas de desenvolvedor.

E uma senha de banco de dados não é uma chave pequena. Normalmente é permissão
para ler toda linha pertencente a todo usuário, e apagar tudo isso.

**Porque o banco de dados não faz ideia de quem é ninguém.** Um banco de dados
verifica uma coisa: se essa conexão tem uma senha válida. Ele não consegue
verificar "essa pessoa tem permissão para ver a tarefa 7". Essa regra vive na
sua aplicação, não no banco de dados, então algo precisa estar no meio para
aplicá-la.

**Porque uma conexão com o banco de dados é cara.** Cada uma custa memória de
verdade para o banco de dados. Um servidor mantém um pool pequeno de conexões e
o compartilha entre milhares de chamadores. Dez mil navegadores abrindo cada
um sua própria conexão derrubariam tudo imediatamente.

Então o backend fica no meio. Ele é a única coisa que guarda a senha, a única
coisa que sabe quem é quem está chamando, e a única coisa autorizada a decidir
o que essa pessoa pode ver.

```
browser  ---- request ---->  backend  ---- query ---->  database
         <--- response ----           <--- rows -----
```

O navegador pergunta ao backend. O backend decide. O backend pergunta ao banco
de dados. Ninguém pula uma etapa.

## O que você está prestes a construir

Uma lista de tarefas. Ao longo das próximas páginas ela vai crescer assim:

- **Página 2:** uma rota que retorna uma lista fixa de tarefas
- **Página 3:** pedir uma tarefa por id, filtrar a lista e criar uma tarefa
- **Página 4:** responder corretamente quando algo dá errado

As tarefas vivem em uma tabela Lua simples por enquanto, o que significa que
elas desaparecem quando você para o servidor. Um banco de dados de verdade vem
depois, mais adiante no guia. Tudo o que você escrever antes disso continua
funcionando quando ele chegar.

## Checkpoint

Você deve conseguir responder a estas perguntas agora sem consultar o texto:

- Quais são as duas partes de uma resposta que importam? (um código de status
  e um corpo)
- O que é uma rota? (um caminho mais um método)
- Por que o backend existe em vez de deixar o navegador falar direto com o
  banco de dados? (o navegador não consegue guardar segredo, não pode ser
  confiável para aplicar regras, e haveria conexões demais)

Se isso ficou claro, vá para [2. Sua primeira rota](02-your-first-route.md).
