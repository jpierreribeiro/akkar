# Gate de prontidão para produção

O akkar é um **candidato a produção**, ainda não um runtime publicamente
certificado para carga crítica. Os controles de código e CI estão implementados;
a evidência ambiental precisa ser produzida no commit exato de cada release.

Antes de promover, são bloqueantes: CI completo verde; 20 suítes consecutivas
em ARM64; soak local de 24 horas com `SOAK_ASSERT=1`; uma hora multiprocesso;
testes sob perda e recuperação de PostgreSQL, Redis e serviço Python; drenagem
com SIGTERM; restauração real de backup; alertas exercitados; rotação de
segredos; e rollback do runtime e do alias `champion` do MLflow.

```sh
SOAK_ASSERT=1 \
MAX_RSS_GROWTH_PERCENT=20 MAX_RSS_GROWTH_KB=131072 \
MAX_HEAP_GROWTH_PERCENT=20 MAX_HEAP_GROWTH_KB=32768 \
bash bench/soak.sh 1440 1
```

Isso roda sem AWS. Guarde TSV, saída do `wrk`, SHA, versões do sistema/Lua/
cqueues, hardware e thresholds como evidência. Um benchmark curto não substitui
um soak.

Fora do repositório ainda é preciso proteger `main` com PR, CODEOWNERS e todos
os jobs obrigatórios; impedir force-push/exclusão; ativar atualizações de
segurança do Dependabot e relato privado de vulnerabilidade; e proteger o
environment `release` com aprovação. Isso não foi aplicado automaticamente
para não bloquear o único mantenedor.

Python fica em processo separado. O padrão suportado está em
[`examples/mlops/`](../../examples/mlops/): FastAPI para inferência online,
Celery para batch, PostgreSQL para estado, Redis para fila, S3/MinIO para dados
e MLflow para versões imutáveis. O serving verifica digest e só carrega
`sklearn + skops`; pickle, cloudpickle, código empacotado e Python arbitrário
são recusados. O gateway agora autentica chaves servidor a servidor, deriva o
tenant da credencial e aplica permissões/modelos autorizados. O status é
consultado pelo mesmo tenant; batches usam outbox, leases com proteção contra
workers antigos e versões/digests fixados. Isso não substitui os gates acima.
Veja o [registro de consolidação](CONSOLIDATION.md) e a migração no exemplo.

Os critérios completos e o fluxo de release estão na versão em inglês em
[`docs/PRODUCTION-READINESS.md`](../PRODUCTION-READINESS.md) e em
[`RELEASE.md`](../../RELEASE.md).
