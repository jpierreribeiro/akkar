# Por que o akkar é mais lento que o OpenResty e o que pode ser feito

> **Português (Brasil)** | [Original em inglês](../../why/slower-than-openresty.md)

A posição honesta, em uma única página, porque antes ela estava espalhada por sete arquivos que discordavam entre si.

O akkar é **8,75x mais lento que o OpenResty em `/ping`** (`bench/runtime/RESULTS.md`, terceira execução, 19 de agosto de 2026). Esse é o número atual, e o restante desta página explica o que existe dentro dele.

Três afirmações logo de início, porque cada uma é o oposto do que as pessoas imaginam ao ouvir "framework Lua":

1. **A linguagem não é o teto.** Um servidor HTTP/1.1 real escrito em PUC Lua 5.4 alcança **1,69x o desempenho do Gin** nos mesmos dois núcleos.
2. **O parsing não é o custo.** Parsing e roteamento consomem 0,2 µs de uma requisição de 103 µs. Todas as propostas de parser em C deste repositório foram recusadas por causa disso.
3. **A diferença é maior justamente onde o trabalho é menor.** Em `/ping`, o akkar alcança 0,17x o Gin; em uma rota de banco de dados com duzentas linhas, alcança 0,48x e tem um p99 *menor que o do próprio Gin*.

---

## 1. A velocidade do OpenResty vem do nginx, não do LuaJIT

Esta é a primeira coisa que precisa ficar clara, porque determina se a resposta é "trocar a VM" ou "trocar o servidor".

O handler inteiro de `/ping` do candidato OpenResty está em
`bench/runtime/openresty/nginx.conf:57-61`:

```nginx
location = /ping {
    content_by_lua_block {
        ngx.print('{"pong":true}')
    }
}
```

Uma chamada Lua interpretada para uma função C. Tudo antes e depois dela —
aceitar, ler, fazer o parsing, montar a tabela de cabeçalhos, escrever e manter
a conexão viva — é nginx em C. Não seria esperado que trocar a VM sob um
handler com esse formato produzisse diferença; outros trabalhos relatam que
trocar Lua 5.1, Lua 5.4 e LuaJIT sob o nginx realmente não produz. **Esse
controle não foi executado neste repositório**, portanto aparece aqui como
corroboração, não como um dos números desta página. A medição feita aqui
resolve a mesma pergunta pelo outro lado.

`bench/study/COST-OF-A-REQUEST.md` divide a diferença:

| | |
|---|---:|
| diferença inteira para o OpenResty | **9,4x** |
| a linguagem (LuaJIT, medido) | 1,62x |
| o restante, o event loop e o parsing em C do nginx | **5,8x** |

Em throughput absoluto, a diferença é ainda mais desigual: das aproximadamente 92.000 req/s de diferença, a linguagem recupera cerca de 7.500 (**8%**) e o servidor em C responde por aproximadamente 84.700 (**92%**). Um akkar inteiramente em LuaJIT chegaria perto de 19.600 req/s, com o OpenResty ainda 5,3x à frente.

Portanto, "tornar o akkar tão rápido quanto o OpenResty" não é um problema de Lua. É uma proposta para escrever o nginx.

---

## 2. Para onde o tempo realmente vai

`bench/study/WHERE-THE-GAP-IS.md` é a medição central deste repositório e a referência para interpretar todas as outras. Quatro servidores, mais um quinto, respondendo os mesmos treze bytes, fixados nos mesmos dois núcleos, com o mesmo gerador e a mesma execução:

| camada | req/s | µs/req/core |
|---|---:|---:|
| cqueues, sem parsing | 169.960 | 11,5 |
| **um servidor HTTP real e mínimo em Lua puro** | **171.330** | **11,7** |
| lua-http, sem akkar | 34.173 | 58,5 |
| akkar `/ping` | 19.408 | 103,0 |
| Gin, limitado aos mesmos dois núcleos | 101.584 | 19,7 |

A linha `minimal` é a que muda o enquadramento da discussão. Não é um echo de socket: ela interpreta a linha da requisição em método e caminho, percorre os cabeçalhos em busca de `content-length`, consome um corpo declarado, roteia pelo caminho e escreve uma resposta. **11,5 µs sem parsing e roteamento, 11,7 µs com eles.** Parsing e roteamento saem de graça, e um servidor HTTP real em Lua interpretado supera o Gin em 1,69x no mesmo hardware.

Isso significa que os 47 µs entre as linhas `minimal` e `lua-http` não representam o custo do HTTP em Lua. Representam o custo do **design do lua-http**: um objeto de stream por requisição, objetos de cabeçalho que mantêm uma lista e um índice, uma camada de abstração que também precisa servir HTTP/2 e uma máquina de estados da conexão.

Decompondo os 103 µs do akkar:

| | µs/req | parcela |
|---|---:|---:|
| cqueues, o event loop | 11,6 | 11% |
| **lua-http, parsing e escrita** | **47,1** | **46%** |
| akkar, roteador, cadeia, tabela da requisição, deadline, capacidades e JSON | 44,6 | 43% |

**Esta tabela é de 16 de agosto de 2026 e é o número obsoleto mais citado da árvore.** O trabalho posterior de alocações no HTTP vendorizado removeu entre 12,3% e 12,8% de `/ping` e reduziu a CPU de 99,0 para 87,8 µs por requisição em 2,00 núcleos fixos (`bench/study/HTTP-OPTIMISATION.md`); quase tudo saiu da linha do lua-http. As *parcelas* mudaram a favor do akkar e ninguém refez a decomposição. Leia 46/43 como a ordem das parcelas, não como a conta de hoje.

### E não é o coletor

Antes de propor uma reescrita dos 44,6 µs, a seção 4 de `bench/study/WHERE-THE-GAP-IS.md` calculou o preço da alternativa. Com a coleta de lixo **inteiramente parada**, usando 10,9 GB de memória residente, o akkar ganha **3,5%**. Esse é o teto do que qualquer ajuste do coletor poderia oferecer, e mostra que os 44,6 µs são trabalho, não recuperação de memória. Uma melhoria gratuita apareceu: o coletor geracional é 2,5% mais rápido e reduz o p99 de 7,50 ms para 5,66 ms usando 2 MB a menos.

### E não é o harness, embora uma parte fosse

`bench/study/cpu-parity.sh` descobriu o Gin usando o dobro de threads de hardware, a mesma assimetria que levou à retratação de `bench/compare/RESULTS.md`. Limitado aos mesmos dois núcleos, o Gin cai de 116.822 para 102.885 e a proporção passa de 6,08x para 5,35x. **Cerca de 12% da discrepância vinha do harness. O restante não.**

---

## 3. Ser mais lento é um problema?

Não onde normalmente se procura a resposta.

**`/ping` é o pior caso do akkar.** É overhead puro do framework, sem nada por baixo para amortizá-lo, e a única rota em que a comparação é puramente entre código interpretado e compilado. Em uma rota que faz o que aplicações realmente fazem, `/rows/200`, com duzentas linhas do Postgres e o driver em C (`bench/study/RESULTS.md`, seção 2.1):

```
gin              7206.08     1.99ms     7.04ms     1.1%      1.00x
akkar-pq         3482.56     4.57ms     6.53ms     2.0%      0.48x
fastapi           880.59    17.92ms    23.94ms     1.9%      0.12x
```

**0,48x o Gin, 3,95x o FastAPI e p99 de 6,53 ms contra 7,04 ms do próprio Gin**, a primeira linha do estudo em que a cauda do akkar não é a pior. A diferença é maior justamente onde o trabalho é menor. Isso é uma propriedade real do formato, não uma mudança de assunto: quanto mais uma requisição realmente faz, menor é o custo relativo do framework.

O segundo motivo para não interpretar demais o número de throughput é que **a diferença de latência é a diferença de throughput em outras unidades**. `bench/runtime/RESULTS.md` mede o tempo de serviço do próprio akkar em **117 µs** com uma conexão; o throughput satura com dezesseis conexões e tudo acima disso é fila. Com cem conexões, o p50 é 81 vezes o tempo de serviço, e três dos quatro candidatos ficam exatamente sobre a lei de Little. 91.829/10.038 é 9,15x e 9,78/1,08 é 9,06x, o mesmo número duas vezes. Um plano que trata "fechar a diferença de latência" como projeto separado de "fechar a diferença de throughput" está contando a mesma coisa duas vezes.

Isso não significa que defeitos de cauda não existam. Um foi encontrado e corrigido na mesma semana: um pool que acordava todos os clientes à espera produziu p99 de 5,42 s contra p50 de 5,9 ms, uma proporção de 900. As proporções saudáveis acima ficam entre 1,2 e 2,7.

---

## 4. Qual número da diferença é atual e por que a mudança não é progresso

`bench/runtime/RESULTS.md` contém **três números principais diferentes** para a diferença do OpenResty. Eles não formam uma tendência.

| execução | data | número | máquina | fixture |
|---|---|---:|---|---|
| primeira | 17/08/2026 | 11,2x | c5.2xlarge, **perdida** | `bare`, dois cabeçalhos, aposentada |
| primeira, medida de novo | 18/08/2026 | 9,15x | mesma máquina, **perdida** | `browser`, seis cabeçalhos |
| segunda | 18/08/2026 | (9,39x, não publicado como principal) | c5.2xlarge nova, **perdida** | `browser` |
| **terceira** | **19/08/2026** | **8,75x** | máquina reconstruída, receita de CI | `browser` |

**8,75x é o número atual.** O arquivo explica claramente a mudança, e vale repetir: os três números vieram de máquinas diferentes, e dois usaram uma fixture que já foi aposentada. Nada no akkar fechou a diferença de 11,2x para 8,75x.

A fixture aposentada é o maior dos dois efeitos. Todas as medições deste repositório usavam três cabeçalhos curtos e idênticos até 18 de agosto de 2026, e `bench/study/COST-OF-A-REQUEST.md` mediu o que isso escondia: cabeçalhos de navegador custam mais 17%, uma rota validada custa mais 10%, e os dois **juntos** custam 1,64x, quando efeitos independentes preveriam 1,29x. `bench/study/lib.sh` e `bench/runtime/run.sh` agora usam `SHAPE=browser` por padrão e **imprimem o formato em cada execução**, porque uma execução com um formato não é comparável com outra, e a única defesa contra uma comparação acidental é ambas declararem o formato usado. `SHAPE=bare` restaura a forma antiga para comparação com o que foi publicado antes de 18 de agosto de 2026.

A tabela de pisos da seção 2 usa `bare`, na primeira máquina, em 16 de agosto de 2026. Suas comparações internas usam condições iguais e continuam válidas; seus números absolutos não são comparáveis com 8,75x.

---

## 5. O que foi tentado e o que foi recusado

Cada recusa abaixo traz a medição que a determinou e o limite usado na decisão. Quando dois documentos discordam sobre uma recusa, ambos são citados.

### LuaJIT: 1,62x, e dois documentos discordam sobre o significado

`docs/substrate/LUAJIT.md` é a única autoridade para esse número, publicado no `README.md`. Mesma árvore, mesmo arquivo de serviço, mesmas versões dos rocks, mesmo commit fixado do cqueues, repetições alternadas e zero respostas que não fossem 2xx:

| | req/s | variação | p99 | µs/req |
|---|---:|---:|---:|---:|
| Lua 5.4, um processo | 12.083 | 1,9% | 9,75 ms | 82,8 |
| **LuaJIT, um processo** | **19.603** | 2,1% | 6,65 ms | **51,0** |
| Lua 5.4, dois processos | 24.122 | 3,5% | 4,60 ms | 82,9 |
| **LuaJIT, dois processos** | **39.736** | 4,1% | 3,98 ms | **50,3** |

**1,62x a 1,65x**, maior variação de 4,1%, reproduzido com diferença de até 0,7% em duas topologias. `docs/PLAN.md` F3 definiu previamente o limite de 2x, portanto o LuaJIT foi recusado com um número.

Três coisas precisam estar claras antes de considerar a questão encerrada:

- **A página contradiz a si mesma.** A abertura diz que *"a metade de throughput ainda não foi medida e a decisão continua aberta"*, e o encerramento lista *"ainda falta fazer, e precisa da máquina de estudo: ... então executar `/ping`"*, enquanto a seção central se chama **"A RESPOSTA: 1,62x, RECUSADO"** e contém a tabela acima. A medição é a parte atual; o texto ao redor nunca foi atualizado. As seções 2 e 6 de `docs/RUNTIME-1.0.md` também descrevem o experimento como não executado.
- **As duas regras de decisão discordam.** `docs/PLAN.md` F3 diz que menos de 2x significa recusar. A seção 2 de `docs/RUNTIME-1.0.md` diz que menos de 1,5x encerra o experimento, 2x significa adotar, e **qualquer valor intermediário o mantém em `experiments/luajit`, sem suporte**. 1,62x é intermediário. A medição recusa o LuaJIT como *alvo com suporte*, mas, pela regra posterior, não o encerra.
- **O número foi obtido com uma mentira.** O braço LuaJIT precisou de um shim de compatibilidade de 31 linhas cujo `math.type` retorna `"integer"` para doubles inteiros, porque `db.lua:57` precisa disso para continuar vinculando `int8`, a "correção de 3,91x". LuaJIT não tem subtipo inteiro; todo número é double. Assim, `v.integer` vira apenas uma recomendação no LuaJIT, uma propriedade do runtime, não do shim. A medição é real; a configuração usada não poderia ser distribuída como está.

### Um tokenizador HTTP em C: recusado por 152 bytes e pelo limite que não atingiu

`docs/PERFORMANCE-PLAN.md` A4 contém a proposta: picohttpparser para a linha da requisição e o bloco de cabeçalhos, framing em Lua, distribuído como rock opcional separado, como `akkar.pq`. Ela foi **recusada com evidência**:

> **todo o parsing da requisição**, linha, cabeçalhos e framing, usa **152 bytes**, **1,3%** de uma requisição.

A conta de CPU aponta para o mesmo lado. O parsing mede de 6,5 a 6,7 µs de uma requisição de 83 µs na fixture do repositório (8%), e de 37 a 41 µs em uma com formato de produção (45% a 49%). Porém, o segundo valor foi obtido **antes** da correção de uma linha descrita abaixo, que removeu a maior parte desse custo. O restante representa cerca de 13% a 15% de `/ping`, então um tokenizador que o eliminasse por completo valeria aproximadamente **1,15x** na rota mais barata do akkar. No exemplo do próprio README, um endpoint que passa quatro milissegundos no Postgres, isso representa cerca de **meio por cento** de uma resposta real.

A seção 3 de `docs/RUNTIME-1.0.md` definiu o limite previamente: **um componente só merece C quando uma medição mostra que ele representa pelo menos 30% da CPU de uma rota, e a versão em C devolve resultados idênticos byte a byte antes de ser cronometrada.** `akkar.pq` ultrapassou esse limite: materializar linhas era 55% de uma query com mil linhas. Um tokenizador não o ultrapassa em nenhuma das rotas.

**E a própria tabela de `docs/RUNTIME-1.0.md` parece dizer o contrário, o único ponto em que os documentos realmente conflitam.** A lista de candidatos da seção 3 diz *"parsing + escrita da requisição HTTP | 46% de `/ping` | sim, e é o maior item aberto"*. Esses 46% representam toda a **camada** lua-http, objetos de stream, objetos de cabeçalho, máquina de estados e caminho de escrita, não o tokenizador. A camada ultrapassa o limite de 30%; o parser dentro dela usa 1,3% dos bytes. Ler essa linha como defesa de um parser em C é o mesmo erro que a linha JSON da mesma página existe para impedir.

O custo é a outra metade da recusa. Framing é onde request smuggling acontece, uma classe de defeito publicada em 2005 e que ainda produzia CVEs no llhttp em 2022 (`CVE-2022-32213/32214/32215`). Um tokenizador em C oferece cerca de 1,15x na rota mais barata em troca da responsabilidade por uma fronteira relevante para segurança em uma linguagem sem segurança de memória.

Uma ideia contida sobrevive à A4: `read_headers` executa um `Connection:match` do lpeg em cada requisição, valendo **72 bytes**. Um caminho rápido para as duas strings `keep-alive` e `close`, com lpeg como fallback, exige uma hora de trabalho e tem risco baixo.

### Validadores gerados: recusados por zero bytes

`bench/study/HTTP-OPTIMISATION.md`, 20.000 iterações, coletor parado:

```
validate, 4 fields, all present    152.0 bytes
just the cleaned output table      152.0 bytes
```

Idênticos. Expandir os schemas no registro da rota já tinha removido todas as alocações que a validação fazia, e o que resta é a tabela pedida pelo chamador. **Codegen economizaria zero bytes.** Seu caso restante é CPU, removendo a passagem de `pairs(schema)` e o dispatch por campo. Esse custo é real, mas este instrumento não o enxerga, então precisa de uma medição de CPU antes de justificar a implementação.

Duas mudanças menores mediram zero pelo mesmo motivo e ficam registradas para que ninguém as repita: `string.match` para `string.find` na validação de cabeçalhos e `v:sub(-1,-1)` para `v:byte(-1)`. **Lua interna strings de até 40 bytes**, então, em um parser de cabeçalhos, "isso aloca uma cópia" geralmente é falso. Um índice preguiçoso de cabeçalhos mediu **7 bytes** e foi revertido porque acrescentava uma indireção a seis leitores.

### A maior melhoria de parsing deste repositório foi uma linha de Lua

Em `bench/study/COST-OF-A-REQUEST.md`, o padrão de uma linha de cabeçalho era `^([^%s:]+):[ \t]*(.-)[ \t]*$`. O `(.-)` preguiçoso diante de um `[ \t]*$` ancorado faz o matcher de Lua avançar um caractere por vez e tentar novamente a cauda em cada posição. Assim, o custo crescia com o **valor**, não com a procura pelos dois-pontos:

| linha | antigo | novo | |
|---|---:|---:|---:|
| 17 bytes | 1.186 ns | 717 ns | 1,65x |
| 68 bytes, preenchida | 3.636 ns | 1.606 ns | 2,3x |
| **113 bytes** | **6.693 ns** | **1.436 ns** | **4,7x** |

Um `(.*)` guloso, com o espaço final removido byte a byte. Em uma requisição com formato de produção, isso representa cerca de **23 µs de 83, ou 27% da CPU**; no benchmark do projeto, vale 1,7%, por isso ninguém havia encontrado.

Foi descoberto por acidente, e o acidente é o argumento: a fixture que escondia o problema estava sob suspeita, não o parser. Equivalência era toda a afirmação e está fixada por `spec/vendor_header_parse_spec.lua`: o padrão antigo é mantido como referência e comparado em 36 formatos escritos à mão e 200.000 strings de bytes aleatórias. Um parsing mais rápido que discorda cria um diferencial entre parsers, e diferenças entre duas implementações do mesmo protocolo são como request smuggling acontece.

### O que foi aceito, não recusado: o driver em C

O único módulo C que vale a pena ter é `akkar.pq`, e ele existe. `bench/driver/RESULTS.md`:

| | pgmoon | akkar.pq | |
|---|---:|---:|---|
| `/ping` @100 | 19.241 | 19.392 | **SOBREPOSTOS**, o controle |
| `/users/42` @16 | 7.040 | **8.969** | 1,27x |
| `/rows/100` @16 | 2.392 | **5.031** | 2,10x |
| `/rows/1000` @16 | 333 | **928** | 2,79x |
| p99, `/rows/1000` @100 | 1300 ms | **475 ms** | −63% |

`/ping` aparece primeiro de propósito: não toca no banco, e as duas variantes serem idênticas mostra que a variável do driver não vazou para as outras linhas. **Essa linha também resume o modelo: C onde está o trabalho mecânico, Lua em todo o resto e custo zero onde não há nada para acelerar.**

Duas correções dessa página sustentam a conclusão. A primeira execução aconteceu em uma máquina com vinte e dois servidores travados consumindo CPU, e a contaminação **inflou** o resultado divulgado, de 3,01x para 3,91x. A objeção da seção 5.4, *"o driver C é mais rápido e menos consistente"*, foi investigada e **retratada**: na mesma configuração, pq volta com variação de 1,8% e nenhuma janela anômala. A irregularidade era do harness, em que `SO_REUSEPORT` distribuindo seis conexões entre dois processos prejudica **mais o pgmoon** (37,3% contra 30,5%).

Ainda assim, pgmoon continua sendo o padrão por um motivo que não envolve velocidade: `akkar.pq_native` é um rock separado, então usar `pq` por padrão falharia na primeira query de quem instalou somente `akkar`.

---

## 6. O akkar é dono dos 47 µs e nunca os redesenhou

Este é o item aberto mais importante e aquele que os documentos antigos interpretam errado, porque foram escritos sob outro enquadramento.

`akkar/vendor/http/` não é uma dependência que o akkar contorna. **O akkar
assumiu o fork.** `akkar/vendor/http/README.md` declara a posição sem rodeios:
*"A última versão upstream é a v0.4 (2021), e o último commit é de
08/09/2024; portanto, não há uma versão pela qual esperar."* O akkar incorporou
cerca de 10.100 linhas, divergiu no caminho crítico, portou manualmente duas
correções upstream posteriores à release e carrega ali seus próprios reparos
contra negação de serviço. Isso é um órfão adotado, não uma dependência
fixada numa versão.

Isso muda a conclusão tirada do mesmo número. Quando os 47 µs pertencem a uma dependência, são **um fato a contornar**, como lê a seção 6 de `docs/RUNTIME-1.0.md`, que coloca "escrever um caminho rápido HTTP" em quarto lugar e o apresenta como escrever e depois manter um parser. Quando pertencem ao seu fork, são **um design que pode ser mudado**. A formulação honesta da pergunta aberta não é *"o akkar deveria escrever um parser C para ficar abaixo do lua-http?"*. É:

> **O akkar é dono da camada que custa 47 µs e nunca a redesenhou.**

Reestruturar código já controlado é mais barato que reescrever em C, não
cria uma nova fronteira sem segurança de memória e mira **47,1 µs, contra os
13–15 µs que um tokenizador atacaria**: três vezes mais da requisição, sem
nenhuma fronteira nova. A prova de que o redesenho é viável já está na página:
o trabalho de alocações reduziu uma requisição de 14.610 bytes para **5.376**,
e as duas coroutines por requisição que antes representavam 55% agora
representam 5,7% juntas, tudo mudando formatos em código controlado pelo akkar.

### O contrapeso, que é real

Ser dono do fork significa ser responsável por todo defeito futuro em **cerca
de 10.100 linhas** de Lua incorporado, sem um upstream do qual herdar
correções. Isso não é hipotético, e o custo já apareceu da menor forma
possível: **o registro de proveniência apodreceu, e apodreceu em um dia.** O
antigo `akkar/vendor/http/README.md` mantinha em prosa a tabela de divergências
e certificava como intocados os dois arquivos que contêm os reparos do akkar
contra negação de serviço em HTTP/2 e WebSocket. Ao mesmo tempo,
`akkar/vendor/http/h2_connection.lua` continha vinte linhas comentadas do
reparo para o cabeçalho de frame três bytes curto que matava o loop de
aceitação, em `read_http2_frame`. Reincorporar o upstream confiando naquela
tabela teria revertido silenciosamente todos os reparos, com a suíte inteira
ainda verde.

Vale dar nome à correção, porque ela usa o mesmo método defendido pelo restante
desta página: o registro foi movido para
`akkar/vendor/http/PROVENANCE.md`, e `spec/vendor_provenance_spec.lua` agora
falha na CI, citando o commit, se um patch desaparecer do arquivo em que o
registro afirma que ele está. **Foi a prosa que nada executa que permitiu o
erro da primeira vez.** Esse é o custo do fork: não o apodrecimento, que foi
corrigido, mas a obrigação permanente de construir um instrumento para cada
promessa feita pelo fork.

As duas metades pertencem à decisão. O fork torna os 47 µs tratáveis; também torna o akkar o único mantenedor do código que os produz.

---

## 7. O que continua em aberto

**O experimento do caminho rápido HTTP está em execução, ainda sem número.** Um protótipo interpreta o formato comum de requisição diretamente sobre cqueues, usando lua-http como fallback para todo o resto. A pergunta é estreita: *quanto dos 47 µs entre as linhas `minimal` e `lua-http` pode ser recuperado por um caminho rápido sobre o qual um framework real consiga se apoiar?* O servidor `minimal` é um piso, não uma proposta: não tem TLS, HTTP/2, codificação chunked, trailers nem máquina de estados da conexão. O número do experimento dirá quanto da distância entre 11,7 e 58,5 µs sobrevive ao contato com esses recursos. **O resultado ainda não existe, e esta seção o receberá quando existir.** A seção 5 de `bench/study/WHERE-THE-GAP-IS.md` calcula um teto de aproximadamente 56 µs/req, 35.700 req/s, **0,35x o Gin**, e o chama corretamente de aritmética, não de resultado.

**Os 44,6 µs do próprio akkar nunca foram decompostos.** O estudo de desempenho atacou o caminho do banco e encontrou problemas reais; ninguém perfilou o caminho do framework desde então. Existe um dado: `akkar-lean`, que desativa o deadline por requisição, é 9% mais rápido em `/ping` (21.415 contra 19.454). Um recurso representa um décimo do custo do próprio framework, e os demais nunca foram precificados.

**A validação também nunca foi decomposta.** A seção 3 de `docs/RUNTIME-1.0.md` a lista como *"desconhecido, medir antes de decidir"*, e ela continua assim. É o único candidato daquela página a que o limite ainda não pode ser aplicado, e `bench/study/COST-OF-A-REQUEST.md` descobriu que validação e cabeçalhos de navegador interagem de forma **superlinear** (1,64x juntos contra 1,29x previsto), portanto não é uma incógnita pequena.

**Três formatos de requisição nunca apareceram em nenhum número desta página.** Ler o corpo custa **2,47x**, abrir uma conexão custa **1,88x**, e uma resposta JSON de 64 KB custa **5,26x** e aloca 105 KB. Todo benchmark desta página usa um GET keep-alive com resposta de 13 bytes. O caminho de escrita e o encoder JSON escalam pior que linearmente sem qualquer monitoramento.

**O déficit de hyperthread ainda é distribuído.** `PROCS` usa núcleos físicos por padrão, então o akkar deixa cerca de 15% do throughput disponível sem uso em máquinas com SMT. Isso é uma recomendação de dimensionamento em `docs/RUNTIME.md`, não uma mudança de código, e é o item mais barato da página. Também não é gratuito: o quarto processo cai no hyperthread irmão, e o throughput por núcleo *diminui* de 9.612 para 5.544.

**A CI nunca compilou `src/akkar_pq.c`.** O único módulo C que o projeto
decidiu valer a pena é justamente o que a integração contínua não compila.
Nenhum workflow chama `src/build.sh`, nenhum referencia
`akkar-pq-0.1.0-1.rockspec`, e a própria `.github/workflows/ci.yml:437` diz:
*"Nenhum dos jobs compila `pq_native.so`, então o driver C é pulado nos
dois"* — inclusive no job `integration`, que tem um Postgres real ao lado. A
proteção que mantém o C honesto em `src/build.sh` é `-Wall -Wextra`, e ela só
roda no laptop de alguém. Assim, o módulo que sustenta o argumento mais forte
desta página a favor de usar C não tem cobertura automatizada em plataforma
alguma, e todos os números de driver citados aqui vieram de um rock instalado
manualmente.

**Nada monitora regressões.** O akkar perdeu 6,7% de `/ping` com duas correções de segurança, e isso só foi percebido porque o Gin por acaso reproduziu com diferença de 0,2% na mesma tabela. Metade era recuperável: uma closure com dois upvalues e um `table.pack` por requisição, em uma proteção que só importa quando resta algo para drenar. A recuperação deixou HEAD a 0,3% da árvore anterior ao reparo. A outra metade evita um slot de pool vazado por conexão descartada, o que não é uma troca. **A lição útil não é sobre o Gin: um framework pode perder 4% por causa de uma alocação em um patch que ninguém considerava crítico para desempenho.** Isso pertence à CI, não à curiosidade de alguém.

---

## 8. O que esta página não diz

- **Três repetições, não cinco**, nas medições de piso. Bastam para enxergar uma diferença de 5x; não para afirmar uma de 5%. As variações estão impressas nas páginas-fonte.
- **Duas das três máquinas não existem mais.** Os números absolutos das seções 2 e 5 vieram de máquinas perdidas. Suas comparações internas usam condições iguais e continuam válidas; comparar um valor absoluto de uma com o de outra não.
- **O piso do cqueues não é um servidor web.** Ele lê até a linha vazia e descarta. Ele limita o custo do event loop. Não prova que um servidor real possa ser construído em 11,5 µs; para isso existe a linha `minimal`, que por sua vez não é um framework.
- **Os tetos são aritmética, não resultados.** Aproximadamente 56 µs, 0,35x o Gin e cerca de 1,15x para um tokenizador dizem o que os custos medidos permitem, não o que alguém alcançou.
- **Uma rota, sem TLS, em loopback, com uma conexão keep-alive.** Uma rede real, um payload real e um handshake TLS real mudam esses números, e nenhum deles foi medido.
- **A divisão 46/43 é de 16 de agosto de 2026 e antecede uma redução de 12,5%**, cuja maior parte saiu do lado do lua-http. Ela não foi medida novamente.
- **A seção 8 de `bench/study/RESULTS.md` retratou sua própria varredura de saturação**, uma tabela rotulada como mediana que era o melhor de três. A retratação determina quais conclusões sobrevivem; esta página não cita nenhuma delas.
- **Ninguém construiu uma aplicação com akkar.** Todo defeito citado nesta página foi descoberto criando deliberadamente uma exposição. Essa é a maior lacuna nas evidências, e nenhum benchmark a fecha.

## O que ler em seguida e o que está vencido nesses documentos

- `bench/study/WHERE-THE-GAP-IS.md` — os pisos, a decomposição e o limite do
  coletor. A medição central.
- `bench/study/COST-OF-A-REQUEST.md` — a divisão de CPU e bytes por requisição,
  o censo de custo do parsing e a auditoria da fixture que encontrou diferenças
  de 1,6x a 5x escondidas no formato da requisição.
- `bench/study/HTTP-OPTIMISATION.md` — o que foi tentado no caminho HTTP
  incorporado, incluindo as três mudanças que mediram exatamente zero.
- `bench/runtime/RESULTS.md` — a comparação entre quatro candidatos, seus três
  números principais e a explicação de quais foram retirados.
- `bench/driver/RESULTS.md` — o driver em C e duas retratações que valem a
  leitura pelo método.
- `docs/substrate/LUAJIT.md` — a medição do LuaJIT e o inventário sintático que
  a sustenta. **A abertura e o parágrafo final ainda dizem que a parte de
  throughput não foi medida**; a seção entre eles é a resposta.
- `docs/PERFORMANCE-PLAN.md` — as recusas, item por item, com o valor de cada
  uma. Observe o aviso do próprio documento: cada número de alocação ali é um
  **limite inferior** para produção, porque a fixture internava todos os valores
  de cabeçalho.
- `docs/RUNTIME-1.0.md` — o limite de 30%, o modelo de camadas e a ordem de
  execução. **Escrito em 16/08/2026 e não editado desde então; quatro de suas
  premissas venceram.** Ainda vale a leitura pelo limite e pelo modelo de
  camadas, mas não é uma declaração atual do estado do projeto:

| premissa | estado |
|---|---|
| seção 2 e seção 6, item 3 — o experimento LuaJIT não foi executado e seu valor esperado aumentou | **vencida.** Executado e recusado em 1,62x, `docs/substrate/LUAJIT.md` |
| seção 6, item 1 — a inconsistência do `akkar.pq` não foi explicada e é "a única coisa entre o projeto e 2,79x" | **vencida nas duas partes.** Explicada em `bench/driver/ANOMALY.md` como `SO_REUSEPORT` dividindo as conexões no harness, o que afeta mais o pgmoon. O que mantém o pgmoon como padrão é o empacotamento: `akkar-pq` é um rock separado |
| seção 2 — o inventário do shim LuaJIT e "aproximadamente uma semana" | **vencida.** O trabalho sintático foi concluído, atrás de `akkar/bitwise.lua`; as contagens da tabela nunca estiveram certas, e os bloqueios restantes são semânticos, não sintáticos |
| seção 4, item 3 — "a CI é `ubuntu-24.04` e nada mais, e ARM64 foi medido exatamente uma vez à mão" | **vencida.** `.github/workflows/ci.yml` tem uma matriz de plataformas: `ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-14`. Cross-compilation ainda não está na CI |
| seção 4, item 1 — `akkar run` está ausente | **parcialmente vencida e agora ambígua.** O subcomando da CLI foi entregue em 16/08/2026. O que a seção 4 realmente pede — o binário compilado hospedando um arquivo-fonte lido na inicialização — continua listado como próximo passo em `docs/RUNTIME.md` |
