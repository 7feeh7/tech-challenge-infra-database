# Rotação de credenciais dos usuários de aplicação (RDS)

O Job administrativo em `administracao` é **idempotente para estrutura** (databases, donos, `REVOKE`/`GRANT`, `CONNECTION LIMIT`), mas **não reaplica senha** quando o papel já existe. Trocar o valor no Secrets Manager e reexecutar o Job **não** altera a senha no PostgreSQL.

## Limitação

- Na primeira criação do papel, o `entrypoint.sh` define a senha uma vez.
- Execuções seguintes mantêm a senha existente, mesmo que o JSON no Secrets Manager mude (comportamento intencional para evitar expor senha em SQL de provisionamento).

## Procedimento operacional (produção)

Ordem recomendada; não imprima nem registre o valor da nova senha em ticket, chat ou log.

1. **Gerar** nova senha forte e **gravar** no segredo do usuário no Secrets Manager (`db-user-oficina` ou `db-user-billing`), mantendo o mesmo JSON (`username`, `password`, `host`, `port`, `dbname`, `engine`).
2. **No RDS**, com credencial master (fora dos pipelines de aplicação), executar apenas:
   ```sql
   ALTER ROLE oficina PASSWORD '<nova-senha>';
   ```
   ou o papel `billing`, conforme o caso. Use sessão administrativa segura; não copie o comando com senha para logs do cliente.
3. **Reiniciar** os pods que usam o usuário afetado para renovar pools e variáveis montadas pelo deploy:
   - OS: namespace `oficina`
   - Billing: namespace `billing`
4. **Validar** conectividade (`/health/ready` ou migration de leitura) antes de escalar ou seguir o runbook.
5. **Não** depender da reexecução do Job administrativo para rotação de senha de aplicação.

## Master (`tcadmin`)

Rotação do master segue o mesmo princípio: alteração no segredo master **e** `ALTER ROLE` no RDS; Job administrativo não substitui esse fluxo.

## Referência

- Job: `scripts/db-admin/entrypoint.sh`, workflow `Database Admin Job` (`.github/workflows/db-admin-job.yml`).
- Runbook: fase 5.2 em `tech-challenge/spec/fase-4/13-deployment-runbook.md` (após complemento E09 integrado).