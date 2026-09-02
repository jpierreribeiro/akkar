# Por que sessões ficam guardadas no servidor

> **Português (Brasil)** | [Original em inglês](../../why/sessions-not-jwt.md)

A resposta do akkar para "manter esse usuário logado" é um id aleatório opaco
em um cookie, com o estado no servidor. Não é um JWT, e `akkar/jwt.lua`
deliberadamente não tem como criar um.

Essa é uma posição forte, então esta página apresenta o argumento, reconhece o
valor do JWT e expõe o que essa escolha custa.

## A propriedade que decide tudo

`akkar/session.lua` abre com todo o design em uma frase:

> Uma sessão é um id em um cookie e estado no servidor. Não é um JWT.

O motivo é a revogação. **Um token assinado que carrega suas próprias claims
não pode ser revogado antes de expirar**, e revogação é exatamente o que uma
sessão mais precisa:

- logout
- troca de senha
- banir uma conta
- rotacionar após uma mudança de privilégio

Toda solução alternativa reintroduz exatamente aquilo que o token deveria
eliminar. Uma deny-list é uma consulta no servidor a cada requisição (request).
Uma expiração curta com um refresh token é uma consulta no servidor a cada
renovação, mais uma segunda credencial com seu próprio armazenamento e sua
própria história de roubo. Nos dois casos o sistema agora tem dois mecanismos
onde tinha um, e o segundo é justamente aquilo que o primeiro deveria
substituir.

Se você vai fazer a consulta de qualquer jeito, faça a consulta simples.

## A segunda metade: onde a credencial fica guardada no navegador

Um token no navegador precisa ficar armazenado em algum lugar. O
`localStorage` é legível por qualquer script na página, então **um único XSS
é o fim de todas as sessões**. Um cookie marcado como `HttpOnly` não é legível
por script nenhum.

`akkar/session.lua` é direto: "O navegador faz isso corretamente desde 1994 e
o akkar não vai tentar melhorar isso."

Por isso os padrões vêm ativados em vez de apenas disponíveis. `HttpOnly`,
`Secure` e `SameSite=Lax` são todos padrão verdadeiro em `akkar/session.lua`,
seguindo o princípio de que "uma opção que ninguém configura é a opção que
todo mundo recebe".

## O que o cookie realmente contém

O valor é `<id>.<hmac>`. O id são 32 bytes aleatórios e não significa nada por
si só.

A assinatura não está ali para esconder nada, porque não há nada nela para
esconder. Ela existe para que uma string forjada seja rejeitada por uma
comparação HMAC em vez de por uma ida e volta até o Redis. Essa é a diferença
entre um incômodo e uma negação de serviço. A comparação é de tempo constante,
via `akkar.crypto.equal`.

O segredo de assinatura precisa ter pelo menos 32 bytes, e o akkar se recusa a
iniciar sem um, porque "uma chave de assinatura digitada à mão por alguém é
uma chave de assinatura que um atacante adivinha".

```lua
local sessions = require "akkar.session"
local cache    = require("akkar.cache.memory").new()

local manager = sessions.new { secret = require("akkar.crypto").token(32) }

-- Primeira requisição: ainda ninguém está logado.
local first = manager:open(cache, nil)
first:set("user", "ada")
local set_cookie = first:commit()
print(set_cookie:find "HttpOnly" ~= nil)     --> true

-- Segunda requisição, trazendo o cookie que o navegador guardou.
local value  = set_cookie:match "^akkar_session=([^;]+)"
print(manager:open(cache, "akkar_session=" .. value):get "user")   --> ada

-- Fazer logout remove o estado no SERVIDOR, não só no navegador.
local out = manager:open(cache, "akkar_session=" .. value)
out:destroy()
out:commit()
print(manager:open(cache, "akkar_session=" .. value):get "user")   --> nil
```

Essa última linha é o argumento inteiro, colocado em prática. Com um token
autocontido, a linha equivalente continuaria mostrando o usuário até o token
expirar.

## Três detalhes que não são óbvios

**O logout limpa as duas metades.** Limpar apenas o cookie deixa o estado no
armazenamento, então um valor de cookie roubado continua funcionando mesmo
depois que o usuário clicou em "sair". `Session:destroy` remove também o
estado no servidor.

**O id é rotacionado no login.** Fixação de sessão é quando um atacante
consegue plantar um cookie no seu navegador antes de você fazer login, e
portanto sabe qual é o id da sua sessão depois que você loga. `:regenerate()`
gera um novo id e move os dados; `akkar.auth` chama isso automaticamente. Pelo
mesmo motivo, um cookie desconhecido recebe um id **novo** em vez do que o
cliente enviou, porque aceitar um id escolhido pelo atacante para uma sessão
vazia é fixação de sessão com passos extras.

**O cookie só é reescrito quando algo muda.** `Session:commit` retorna nil
quando a sessão está limpa. Isso não é uma otimização, é uma propriedade de
corretude: reescrever o cookie a cada resposta reinicia sua expiração a cada
consulta, e uma sessão que nunca expira enquanto uma aba está aberta é uma
sessão que sobrevive ao roubo do notebook.

## Sessões ficam no `cache`, não no banco de dados

Essa é uma troca real, e `akkar/session.lua` registra os dois lados dela.

Uma sessão é dado do tipo chave e valor com expiração, que é exatamente o que
um cache *é*. Colocar isso no Postgres transforma toda requisição que toca uma
sessão em uma ida e volta ao banco de dados.

- **Custo do cache**: um flush no cache desloga todo mundo. Incômodo, não
  perigoso.
- **Custo do banco de dados**: pago em cada requisição individual.

A escolha foi pelo incômodo.

## Sendo justo com o JWT

O JWT não é proibido, e fingir que ele não tem um uso honesto seria
desonesto.

Seu uso honesto é **uma afirmação de curta duração emitida por outra parte,
que você verifica**. Um provedor de identidade (Auth0, Okta, Keycloak, Google,
o SSO da sua empresa) declara quem é o solicitante, assina isso, e expira em
minutos. Você não emitiu esse token. Você não poderia revogá-lo mesmo se
quisesse, porque ele não é seu. Verificá-lo na sua borda é exatamente a coisa
certa a se fazer.

Chamadas de serviço para serviço têm o mesmo formato: vida curta, sem logout,
sem exigência de "banir esse token", e sem armazenamento de sessão
compartilhado entre os dois serviços.

Por isso o akkar entrega `akkar/jwt.lua` com `verify`, e **nada que assine**.
A própria docstring do módulo explica por que a metade que falta é o design:

> Uma função `issue` aqui seria adotada em uma semana por alguém que quisesse
> um login que não precisasse de Redis, e o argumento em `session.lua` se
> perderia por conveniência. A única forma de sustentar esse argumento é não
> entregar a função.

Você pode achar, com razão, que isso é paternalista. E é. Também é a única
versão da regra que sobrevive ao contato com um prazo apertado.

### O que verificar corretamente significa, já que o módulo existe

Dois ataques são mais antigos do que a maioria das bibliotecas que ainda caem
neles, e ambos vêm da mesma raiz: **um JWT informa qual algoritmo usar para
verificá-lo, e esse campo é preenchido pelo atacante.**

- **`alg: none`.** A especificação prevê um JWT não protegido cuja assinatura
  é a string vazia. Um verificador que decide o algoritmo com base no `alg` do
  cabeçalho reporta suas claims como verificadas. Todas elas foram escritas
  por quem enviou o token.
- **Confusão de RS256 para HS256.** Um serviço configurado para RS256 guarda
  a chave *pública* do emissor. Um atacante reescreve o cabeçalho para HS256
  e assina usando essa chave pública como segredo HMAC. Um verificador que
  decide o algoritmo com base no `alg` calcula o HMAC com a chave que possui,
  que é a mesma chave que o atacante usou, e a assinatura confere.

A correção é estrutural, não uma simples checagem: **quem chama a verificação
declara o algoritmo, e o cabeçalho precisa concordar com ele.** `alg` é uma
opção obrigatória, não um padrão. `spec/jwt_spec.lua` executa os dois ataques
contra um verificador configurado corretamente e garante a recusa.

Mais três recusas em vez de avisos, porque quem lê `claims.sub` depois de um
aviso já confiou no token:

- `exp` é obrigatório, já que uma afirmação portadora sem expiração é uma
  credencial permanente entregue a um sistema que não consegue revogá-la.
- `aud` precisa ser checado quando o token carrega um, ou você acaba aceitando
  um token que o usuário obteve para outro serviço.
- RSA e ECDSA são recusados com uma mensagem. Só HMAC. Cair para uma
  comparação HMAC *seria* o próprio ataque de confusão.

## O que a escolha pelo lado do servidor custa

**Você precisa de um armazenamento, e qual armazenamento você tem decide se
funciona.** `akkar.cache.memory` é por processo. A resposta do akkar para mais
CPU é mais processos. Então uma implantação com dois processos usando o cache
em memória entrega a um usuário uma sessão que só funciona no processo que
por acaso aceitar a próxima conexão. Para qualquer cenário além de um
processo, sessão significa Redis. É o mesmo limite que se aplica a rate
limiting e idempotência, e ele está descrito nas lacunas conhecidas do README
em vez de ser descoberto na marra.

**Toda requisição autenticada custa uma ida e volta ao armazenamento.** Esse
é justamente o custo que o JWT existe para eliminar, e ele é real. É um GET no
Redis, não um join no banco de dados, e a checagem HMAC no cookie garante que
ids forjados nunca cheguem ao armazenamento, mas ainda assim não é zero.

**Cookies trazem CSRF junto.** Uma API JSON baseada em bearer tokens não
precisa de defesa contra CSRF; uma autenticada por cookie precisa,
definitivamente. O `docs/ROADMAP.md` deixa isso claro: o módulo que introduz
cookies é o módulo responsável pela defesa. `akkar/csrf.lua` é essa defesa.

**Cenários entre domínios ficam mais difíceis.** `SameSite=Lax` e um cookie de
navegador combinam bem com o mesmo site. Um aplicativo mobile, um cliente de
terceiros ou uma API consumida de outra origem são casos em que um bearer
token é genuinamente mais conveniente. `akkar/auth.lua` traz três esquemas por
esse motivo, e sua estratégia bearer é verificada por uma função fornecida por
você: o akkar não decide o que o token significa. Se for um JWT de um provedor
de identidade, você o verifica lá; se for um token opaco, você faz a
consulta.

## O que ler a seguir

- `akkar/session.lua` e `akkar/jwt.lua`, que se explicam longamente por si só.
- `docs/pt-BR/guide/07-accounts.md`, que constrói um login em vez de apenas discutir
  um.
- `docs/pt-BR/why/adapters.md`, sobre por que `cache` é uma capability e não um
  `require`.
