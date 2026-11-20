# Orçamento de conexões RDS (D5.5)

Instância alvo: `db.t3.micro` (~87 `max_connections` na implantação — confirmar com `SHOW max_connections` na E37).

## Parâmetros por serviço

| Serviço | HPA | Pool/pod | CONNECTION LIMIT (usuário) |
| --- | --- | --- | --- |
| OS | 1–6 | 5 | 37 |
| Billing | 1–3 | 5 | 22 |

## Pico de conexões (04-database.md)

| Consumidor | Cálculo | Conexões |
| --- | --- | --- |
| OS | (6 réplicas + 1 `maxSurge`) × 5 | 35 |
| Billing | (3 + 1) × 5 | 20 |
| Jobs de migration (OS ou Billing, serializados com rolling) | 2 × ~1 | 2 |
| Job administrativo | 2 | 2 |
| Reservadas (superuser RDS + monitoramento) | — | 5 |
| **Total estimado** | — | **64** |

Margem sobre ~87: **~23** conexões (~26 %). Não aumentar `CONNECTION LIMIT` nem classe da instância sem revisão de D5.5.

## Coerência LIMIT × pool

| Usuário | LIMIT | Uso máximo previsto | Folga no LIMIT |
| --- | --- | --- | --- |
| `oficina` | 37 | 35 (6+surge)×5 | 2 |
| `billing` | 22 | 20 (3+surge)×5 | 2 |

Migrations: até 5 conexões por Job; rodar fora do pior surge (runbook Billing). Job administrativo: até 2 conexões, fora do deploy.

## Validação

- **Local:** `scripts/db-admin/test-idempotencia-local.sh`
- **AWS (E37):** `SHOW max_connections`; comparar com esta conta; `pg_stat_activity` por `usename`.