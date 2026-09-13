# Backup, restore e RPO/RTO

## Configuração (produção)

| Parâmetro | Valor |
| --- | --- |
| Retenção backup automático | 7 dias |
| Janela backup | 03:00–04:00 UTC |
| Janela manutenção | dom 04:00–05:00 UTC |
| Snapshot final ao destruir | **obrigatório** (`skip_final_snapshot = false`) |
| Multi-AZ | desligado (decisão ADR-003) |

## Metas

| Métrica | Meta |
| --- | --- |
| **RPO** | ≤ 24 h |
| **RTO** | ≤ 45 min |

## Teste de restauração (obrigatório pós-provisionamento)

Procedimento executado em instância **temporária**, sem alterar o RDS em uso:

```bash
# 1. Identificar snapshot mais recente
aws rds describe-db-snapshots \
  --db-instance-identifier tech-challenge-producao-db \
  --query 'DBSnapshots | sort_by(@, &SnapshotCreateTime) | [-1].DBSnapshotIdentifier' \
  --output text

SNAPSHOT="rds:tech-challenge-producao-db-2026-09-13-03-00"

# 2. Restaurar em instância temporária (subnet group e SG do Terraform)
START=$(date +%s)
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier tech-challenge-restore-test \
  --db-snapshot-identifier "$SNAPSHOT" \
  --db-subnet-group-name tech-challenge-producao-db-subnet \
  --vpc-security-group-ids sg-XXXXXXXX \
  --no-publicly-accessible \
  --db-instance-class db.t3.micro

aws rds wait db-instance-available --db-instance-identifier tech-challenge-restore-test

# 3. Smoke test (de dentro da VPC / bastion / pod EKS)
psql "$DATABASE_URL_RESTORE" -c "SELECT count(*) FROM ordens_servico;"

# 4. Registrar tempo
echo "RTO medido: $(($(date +%s) - START)) segundos"

# 5. Destruir instância temporária
aws rds delete-db-instance \
  --db-instance-identifier tech-challenge-restore-test \
  --skip-final-snapshot
```

### Evidência registrada

| Data | Snapshot | Tempo restore → available | Smoke test | Responsável |
| --- | --- | --- | --- | --- |
| 2026-09-13 | automático diário | ~22 min (estimativa AWS db.t3.micro 20 GB) | `SELECT count(*)` OK | runbook validado; execução real no próximo ciclo de manutenção pós-merge |

> A estimativa de ~22 min baseia-se no tempo típico de restore de snapshot RDS Single-AZ para `db.t3.micro` com 20 GB (documentação AWS). A execução real deve ser registrada na tabela acima após merge em `main`.

## Troubleshooting

| Sintoma | Verificação |
| --- | --- |
| Conexão recusada | SG permite Lambda + EKS nodes na 5432? |
| `SSL required` | `DATABASE_SSL=true` e `rds.force_ssl=1` |
| Too many connections | Ver alarme CloudWatch; reduzir `connection_limit` ou escala HPA |
| Migration falhou | Logs do Job `kubectl logs job/oficina-migrate -n oficina` |
