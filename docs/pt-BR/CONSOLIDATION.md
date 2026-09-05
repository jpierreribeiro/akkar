# Consolidação técnica — setembro de 2026

Este é um registro de implementação e evidências, não certificação de produção.
A API pública Lua foi preservada. O exemplo MLOps tem mudanças incompatíveis
documentadas em seu README: autenticação por credencial, tenant derivado,
entrada versionada com digest e saída gerada pelo worker.

## Implementação

- Identidade servidor a servidor, permissões e modelos autorizados no gateway;
  status consultado por tenant no Python.
- Job e outbox na mesma transação Postgres; dispatcher separado, reconciliação,
  leases renováveis e finalização condicionada à posse da tentativa.
- Versão/digest do modelo fixados na aceitação; versão/digest da entrada
  verificados na execução; resultados publicados apenas pela tentativa vencedora.
- Cache LRU de dois modelos e arquivos temporários de download removidos.
- Instalação Linux isolada com fontes/rocks verificados e pin de cqueues
  compartilhado com CI; diagnóstico de divergência. OpenSSL continua do host.
- Normalização HTTP e validação de configuração extraídas para módulos privados.
- Testes reais de Postgres, smoke MLOps, script restrito de recuperação,
  dashboard e alertas de exemplo; soak com evidências persistidas.

## Evidências e limites

Baseline Lua: 3.655 sucessos, zero falhas/erros/pendentes. Baseline Python:
15 testes aprovados. Os resultados pós-alteração e os arquivos locais de
evidência estão no [registro principal](../CONSOLIDATION.md).

A primeira suíte Lua pós-refatoração teve 3.661 sucessos e um erro no fixture
de concorrência: a sondagem não comprovava conexão efetiva. Foi corrigida
para exigir resposta HTTP, com os testes de concorrência repetidos.

A suíte Lua final passou com 3.663 sucessos, zero falhas/erros/pendentes;
Python passou com 39 testes, incluindo Postgres real. Os contratos com as
bibliotecas da instalação controlada passaram em 168 testes. O smoke final
recuperou cinco serviços e restaurou um dump em banco temporário, conferindo
19 jobs; não comprova restauração conjunta do object store.

Passaram inferência online e batch reais em Compose, entrada sobrescrita após
aceitação, idempotência e recusa de consulta cruzada. O smoke de um minuto em
`/ping` teve zero erros HTTP/socket e RSS estável; não mede uma aplicação com
banco nem substitui 24 horas de carga.

Continuam pendentes os gates completos: CI no commit final, ARM, soak de
24 horas, uma hora multiprocesso, restauração conjunta de banco/object store,
rotação e rollback operacionais, alertas efetivamente entregues e configurações
externas do repositório. A rodada não publica release nem promove para 1.0.
