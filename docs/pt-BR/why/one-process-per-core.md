# Por que um processo por núcleo, e não threads

> **Português (Brasil)** | [Original em inglês](../../why/one-process-per-core.md)

A resposta do akkar para "a máquina tem oito núcleos" é rodar várias cópias do
processo e deixar o kernel compartilhar a porta entre elas.

```lua no-run
app:run { port = 8080, reuseport = true }
```

Não existe pool de threads, não existe opção de worker, e não existe número para
ajustar que faça um processo usar dois núcleos. Esta página explica por que essa
é a única resposta honesta para Lua, o que ela mede e o que ela custa.

## A restrição que você não consegue contornar no design

**Uma VM Lua é um núcleo.** Um estado Lua não é thread safe, o Lua 5.4 não tem
threads próprias (`coroutine` é cooperativo, não paralelo), e o `akkar/vm.lua`
registra que o Lua 5.4 nem consegue criar um segundo estado isolado a partir do
próprio Lua: isso exige C ou um subprocesso.

Então a escolha não é "processos ou threads". É:

1. vários processos do sistema operacional, cada um com uma VM, ou
2. um processo com várias threads do sistema operacional compartilhando uma VM
   atrás de um lock.

A opção 2 não é hipotética, e o akkar já olhou de perto para um projeto que a
adotou. A seção 8 do `docs/BACKLOG.md` registra três afirmações sobre o Astra
(Rust + Tokio + Axum + SQLx, hospedando Lua através do mlua) verificadas contra
o código-fonte no commit `885586c`, v0.51.2. A relevante aqui:

> **Uma única VM Lua global serializa o trabalho de CPU.** O `ReentrantMutex`
> do mlua é tomado no início do `poll` e mantido durante todo o `resume_inner`,
> então um handler que nunca cede o controle o segura pela requisição inteira e
> os outros workers do Tokio ficam bloqueados nele. `thread_pool_size` é um
> pool de objetos coroutine, não paralelismo.

O backlog tem o cuidado de delimitar o que isso autoriza: as três descobertas
são defeitos de implementação corrigíveis com um patch, não consequências de
ter escolhido Rust, e "se posicionar contra eles como falhas permanentes
envelhece mal". O ponto aqui é mais restrito e sobrevive a um patch: um
parâmetro chamado `thread_pool_size` que não é paralelismo é exatamente o modo
de falha que o akkar tenta evitar ao simplesmente não ter esse parâmetro. O
próprio item de acompanhamento do backlog é auditar cada parâmetro de
concorrência que o akkar expõe em busca da mesma armadilha.

Escolher processos significa que o paralelismo é do sistema operacional, que é
o único lugar onde ele já foi verdadeiro para uma aplicação Lua.

## `SO_REUSEPORT` é o que faz funcionar sem um proxy

Sem ele, o segundo processo morre com `EADDRINUSE` e você precisa de nginx ou
HAProxy na frente para distribuir as conexões. Com ele, vários processos se
ligam à mesma porta e o kernel faz o balanceamento de carga das conexões
aceitas entre eles. O `akkar/init.lua` registra o raciocínio ao lado da flag:

> SO_REUSEPORT é como vários processos compartilham uma porta, que é como o
> akkar usa uma máquina: uma VM Lua é um núcleo, então capacidade é processos.
> O kernel faz o balanceamento de carga das conexões aceitas entre eles, e
> nenhum proxy é necessário na frente.

### A flag estava faltando, e um benchmark descobriu isso mentindo

Essa é a parte que vale a pena guardar. A primeira execução de escalabilidade
em uma c5.2xlarge relatou uma linha reta: **2.433 req/s com um processo, 2.424
com oito**. Reta, dentro do piso de ruído de 0,7%, inteiramente plausível. A
leitura óbvia era "o Postgres está saturado".

Sete dos oito processos tinham morrido instantaneamente com `EADDRINUSE`,
porque o akkar nunca repassava `reuseport` para o lua-http. O sobrevivente
respondia corretamente a cada requisição, então a execução passou no seu
próprio portão de *verificar cada resposta* e produziu um número plausível
rotulado como **8 processos**.

O `bench/RESULTS.md` extrai a lição duas vezes:

> uma configuração que não é a configuração também produz um número, e o mesmo
> vale para uma máscara de afinidade que só parece isolamento.

O harness agora se recusa a rodar quando há menos processos vivos do que os
solicitados. O mesmo defeito depois apareceu do outro lado de uma comparação:
no `bench/compare/RESULTS.md`, o Gin foi iniciado como três processos em uma
única porta, o `net.Listen` do Go não configura `SO_REUSEPORT`, dois
travaram instantaneamente, e o sobrevivente usou **6 vCPUs através de
goroutines enquanto akkar e FastAPI usaram 3**. Essa é uma das quatro
assimetrias que fizeram a página inteira ser retratada.

## A capacidade realmente acompanha os núcleos? Sim, no caminho de CPU

`bench/RESULTS.md`, `/ping`, sem banco de dados, em uma c5.2xlarge com os
servidores fixados em núcleos físicos inteiros e o gerador de carga em um
núcleo próprio:

```
processes        req/s        p50        p99   req/s/process   scaling
1              9003.81    10.97ms    14.12ms            9004     1.00x
2             18058.53     5.36ms     8.66ms            9029     1.00x
3             26901.55     3.71ms     5.48ms            8967     1.00x
6             31801.55     3.12ms     4.96ms            5300     0.59x
```

A vazão por processo varia 0,7%, que é exatamente o piso de ruído medido para
essa máquina (dez repetições de uma mesma configuração idêntica: mín. 2679,
p50 2688, máx. 2698 req/s, dispersão de 0,7%). **Qualquer diferença abaixo de
0,7% não é um resultado**, e 1,00x três vezes seguidas é a forma mais forte de
"linear" que esse harness consegue reportar.

A queda em seis processos é hyperthreading, não o framework. Seis processos
nos mesmos três núcleos físicos dão 31.802 contra 26.902, que é 1,18x para o
dobro dos processos: o retorno usual de uma segunda thread em um núcleo
ocupado.

O estudo de posicionamento posterior reproduz isso de forma independente
(`bench/study/RESULTS.md`, seção 3):

```
framework procs         req/s        p50        p99   per-proc
akkar    1          10024.38     9.72ms    12.80ms      10024
akkar    2          20534.50     4.84ms     5.81ms      10267
```

Ligeiramente superlinear ali, já que o segundo processo aproveita
irmãos de hyperthread que estavam ociosos.

Esse também é o enquadramento a usar ao comparar com o Gin. Um único processo
Gin distribui goroutines por todos os núcleos; uma VM Lua é um núcleo. Por
processo, o `bench/study/RESULTS.md` marca **10.267 contra cerca de 58.600,
que é 5,7x**, e chama isso de "o número que significa alguma coisa".

## Onde para de ser linear, dito com todas as letras

A rota de banco de dados não escala do mesmo jeito que `/ping`, e fingir o
contrário seria a mentira fácil desta página. Mesma máquina, mesma execução
(`bench/RESULTS.md`, seção 2), `/users/:id`:

```
processes        req/s        p50        p99   req/s/process   scaling
1              2393.14    40.62ms   190.88ms            2393     1.00x
2              2691.92    36.92ms   119.12ms            1346     0.56x
3              2705.63    36.03ms    99.96ms             902     0.38x
6              2651.42    34.98ms   107.72ms             442     0.18x
```

A vazão ganha 12% de um processo para dois, o que está acima do piso de ruído
e portanto é real, e depois estabiliza em cerca de 2.700 req/s. O p99 quase
cai pela metade.

Essa seção originalmente interpretava a lacuna como "o Postgres é o limite", e
o `bench/RESULTS.md` agora carrega a correção diretamente no texto em vez de
apagá-la: o Gin depois alcançou 26.212 req/s e o FastAPI 9.316 contra **esse
mesmo Postgres, nessa mesma máquina, com o mesmo pool e a mesma query**. O
Postgres nunca foi o limite em 2.700. O limite era o pgmoon interpretando o
protocolo de rede dentro do interpretador. O raciocínio foi deixado no lugar
porque é instrutivo: medir um sistema isolado não consegue dizer qual das suas
partes está saturada.

Então: processos oferecem CPU. Eles não oferecem um driver mais rápido, e não
oferecem um banco de dados maior.

## A outra coisa que processos oferecem: raio de explosão

A seção 3 de `bench/RESULTS.md` mede `/ping` enquanto uma rota vizinha queima
cerca de 200 ms de CPU por chamada:

| arranjo | processos | /ping req/s | p50 | p99 |
|---|---:|---:|---:|---:|
| nada bloqueando | 1 | 9.444 | 5,24 ms | 7,69 ms |
| bloqueando | 1 | 8.891 | 5,26 ms | **74,67 ms** |
| bloqueando | 8 | 34.964 | 1,26 ms | **38,07 ms** |
| `work.yielding` | 1 | 8.625 | 5,74 ms | **8,15 ms** |
| `work.yielding` | 8 | 34.429 | 1,23 ms | **4,28 ms** |

Um handler bloqueante multiplica por dez o p99 do vizinho, enquanto mal move o
p50 ou a vazão. Oito processos cortam essa cauda aproximadamente pela metade,
porque o dano é dividido entre eles.

Mas repare na quarta linha. **Um processo que cede o controle vence oito que
não cedem**, 8,15 ms contra 38,07 ms. Processos dividem o dano; ceder o
controle o elimina. Adicionar processos não substitui não bloquear o loop, e o
limite que sobrevive a tudo isso é que `work.yielding` precisa de um loop Lua:
uma função em C que roda por 250 ms não dá ao Lua nenhum ponto no qual retomar
o controle.

## O que isso custa

### Nada é compartilhado, e isso nem sempre é conveniente

Dois processos têm dois de tudo em memória.

- `akkar.cache.memory` é por processo. Com seis processos,
  `akkar.limit.rate { per_second = 10 }` aplica sessenta por segundo em toda a
  frota. O README diz isso sem suavizar: "Isso é um padrão de desenvolvimento,
  não limitação de taxa (rate limiting)."
- Chaves de idempotência mantidas no cache de memória são por processo, "o que
  não é deduplicação nenhuma".
- Sessões no cache de memória só funcionam no processo que as criou.
- Métricas são por processo, então algo precisa agregá-las.

O padrão geral: **tudo que precisa ser verdadeiro para a implantação, e não
apenas para o processo, tem que morar no Redis ou no Postgres.** Esse é um
custo real do modelo, e é o custo que um servidor com threads e heap
compartilhado não pagaria.

### A memória se multiplica

Cada processo carrega sua própria VM, seu próprio Lua compilado e seu próprio
pool. O soak test de oito horas em `bench/study/RESULTS.md`, seção 9, mede
dois processos em **28 MB residentes, inalterados em cada uma das 96 amostras
ao longo de 480 minutos**, e o `docs/DEPLOY.md` mede um único binário
compilado ocioso em 6,7 MiB. Números pequenos, mas são por processo, e o pool
se multiplica junto com eles: dois processos com `pool_size = 10` é uma
capacidade de 20 conexões Postgres, que é o que o Postgres vê.

### Descritores são o teto real, e o akkar precisa calculá-lo

Cada requisição em andamento mantém um controlador `cqueues` para seu prazo, e
um controlador custa exatamente dois descritores de arquivo. Medido em
`akkar/init.lua`:

```
concurrent      fds     per request
64              134            2.09
256             518            2.02
512            1030            2.01
```

Contra o padrão comum de `ulimit -n 1024`, isso é um muro em torno de 500
requisições concorrentes **por processo**, e atingi-lo não é uma falha limpa:
o `accept` começa a falhar, toda operação de socket começa a falhar, e o
processo se debate. Uma máquina foi perdida dessa forma durante uma varredura
de 512 conexões. O akkar lê o limite na inicialização e instrui o lua-http a
parar de aceitar antes de chegar nele, transformando o colapso em
contrapressão (backpressure).

### Mais processos não significa mais capacidade de aceitar

A varredura de saturação em `bench/study/RESULTS.md`, seção 8, mantém dois
processos com `pool_size = 10` cada, uma capacidade de 20 conexões, e varre a
concorrência oferecida da metade da capacidade até quatro vezes esse valor:

```
mult   conns         req/s       p50       p99   errors
1x     20          7315.41    2.71ms    3.74ms        0
2x     40          7768.32    5.18ms    6.22ms        0
3x     60          7181.37    6.65ms   37.70ms        0
4x     80          6941.36    9.28ms   82.38ms        0
```

A regra que isso produziu: **concorrência oferecida até o dobro do pool sai de
graça; além disso, é paga na cauda e não traz nada em troca.** Dimensione o
pool em cerca de metade do pico de concorrência que você pretende aceitar, e
use `akkar.limit.concurrent` para recusar o resto em vez de enfileirar.

Essa tabela carrega sua própria retratação, e vale a pena lê-la antes de
citá-la. O script dizia "três repetições, mediana por posição mais próxima
(nearest-rank)" e na prática mantinha a execução com a vazão **mais alta**,
então cada número é o melhor de três. A retratação examina o que isso causa: o
joelho entre 2x e 3x sobrevive, porque tomar um máximo não consegue fabricar
uma quebra de cinco vezes; o pico de 2x não sobrevive, porque +6% é da mesma
ordem de grandeza que a diferença entre um máximo e uma mediana; e os números
de cauda depois do joelho são otimistas, então o p99 real em 3x e 4x é pior do
que 37,70 ms e 82,38 ms. A tabela não foi remedida, porque a máquina
necessária não está ligada.

### Você precisa de um supervisor

Nada no akkar inicia os outros processos. Isso é trabalho do systemd, do
Docker, ou de um loop de shell, e o `docs/DEPLOY.md` mostra a forma com
systemd. A contribuição do framework é que a porta não precisa de um proxy na
frente.

## O que ler a seguir

- `bench/RESULTS.md`, incluindo as duas execuções que estavam erradas.
- `bench/study/RESULTS.md`, seções 3, 8 e 9.
- `docs/DEPLOY.md`, para rodar mais de um deles em um host real.
