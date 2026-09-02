# Por que o akkar é assim

> **Português (Brasil)** | [Original em inglês](../../why/README.md)

Sete argumentos. Cada um trata de uma decisão que aparece na API, diz o que ela torna impossível, diz quanto ela custa e aponta para a medição ou a retratação por trás dela.

Estas páginas são para um leitor curioso ou cético, e ser cético é a postura correta. Elas **não** são o lugar para aprender akkar: se você quer construir algo, comece em `docs/pt-BR/guide/00-quickstart.md` e volte para cá quando uma página fizer você perguntar "por que raios isso é assim".

| Página | A pergunta |
|---|---|
| [handlers-return.md](handlers-return.md) | Por que um handler retorna um valor em vez de escrever uma resposta (response)? |
| [adapters.md](adapters.md) | Por que toda operação de I/O passa por um adaptador que o akkar possui? |
| [sessions-not-jwt.md](sessions-not-jwt.md) | Por que as sessões ficam guardadas no servidor, e por que o akkar não pode assinar um JWT? |
| [one-process-per-core.md](one-process-per-core.md) | Por que processos e `SO_REUSEPORT` em vez de threads? |
| [what-the-runtime-is-for.md](what-the-runtime-is-for.md) | O que o `akkar build` oferece, e por que velocidade não está na lista? |
| [what-akkar-does-not-do.md](what-akkar-does-not-do.md) | O que é deliberadamente excluído, e o que você deveria usar no lugar? |
| [slower-than-openresty.md](slower-than-openresty.md) | Por que o akkar é mais lento que o OpenResty, para onde vai o tempo e o que pode ser feito? |

## Como ler um número nestas páginas

Toda cifra aqui é rastreável até um arquivo no repositório, e o arquivo é citado ao lado dela. Essa é uma restrição deliberada, porque este projeto já publicou números errados mais de uma vez e, em cada caso, a correção continua na página ao lado da alegação.

Quatro dessas correções são importantes o bastante para você encontrá-las aqui:

- **Uma comparação inteira foi retratada.** `bench/compare/RESULTS.md` media o akkar contra Gin e FastAPI com quatro assimetrias rodando ao mesmo tempo, incluindo o Gin usando silenciosamente o dobro da CPU. A nova execução, `bench/study/RESULTS.md`, reverteu a conclusão: o akkar está em paridade com o FastAPI no caminho do framework e à frente dele em toda rota que toca o banco de dados.
- **Um benchmark feito numa máquina suja.** A primeira comparação de driver rodou com vinte e dois servidores travados girando na máquina, e a contaminação **inflou** o resultado que estava sendo divulgado, de 3.01x para 3.91x.
- **Uma tabela rotulada como mediana que na verdade era um máximo.** A varredura de saturação em `bench/study/RESULTS.md`, seção 8, mantinha o melhor de três execuções sob um comentário dizendo que se tratava da mediana. A retratação apura quais das suas conclusões sobrevivem.
- **Um benchmark que mediu um processo enquanto relatava oito.** Sete morreram com `EADDRINUSE` e o harness nunca verificou isso, e foi assim que o akkar descobriu que nunca tinha repassado `reuseport` para o lua-http.

Se uma alegação nestas páginas não tiver um arquivo ao lado, trate-a como opinião.

## O que falta nesta seção

Dito para que não seja confundido com completude. Não há página sobre o design do escopo (scope) de tenant, sobre o watchdog de bloqueio, ou sobre a fila de jobs, e os três carregam argumentos da mesma natureza. Por enquanto, eles vivem em `akkar/scope.lua`, `README.md` e `akkar/jobs.lua`.
