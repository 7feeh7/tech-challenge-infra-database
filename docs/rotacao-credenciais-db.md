# Rotação de credenciais dos usuários de aplicação (RDS)

O Job administrativo em `administracao` é **idempotente para estrutura** (databases, donos, `REVOKE`/`GRANT`, `CONNECTION LIMIT`), mas **não reaplica senha** quando o papel já existe. Trocar o valor no Secrets Manager e reexecutar o Job **não** altera a senha no PostgreSQL.

## Como o Job define a senha

O parameter group mantém `log_statement = ddl` (auditoria de DDL), e `CREATE ROLE`/`ALTER ROLE ... PASSWORD` é DDL: o servidor registraria o comando, com a senha ou o verificador, no log exportado ao CloudWatch. Por isso o Job usa uma sessão própria do master, só para senhas (`scripts/db-admin/create-role-with-password.sql`):

1. A sessão suprime o registro **só nela** com `SET` de sessão: `log_statement`, `log_min_error_statement`, `log_min_duration_statement`, `log_min_duration_sample`, `log_statement_sample_rate`, `log_transaction_sample_rate`, `log_parameter_max_length`, `log_parameter_max_length_on_error`, `debug_print_*` e, se carregadas, `pgaudit.*`, `auto_explain` e `pg_stat_statements` (`track_utility = off`, `track = none`, porque a view guarda o texto de comandos utilitários como `ALTER USER ... PASSWORD`, sem normalizar). Nenhum `ALTER SYSTEM`, `ALTER ROLE ... SET` ou `ALTER DATABASE ... SET`; as demais sessões continuam auditadas. No RDS o master não tem permissão de `SET` em `log_parameter_max_length`; por isso o parameter group fixa esse valor em `0` para todas as sessões, e o Job só confere o valor.
2. Ainda na mesma sessão, `current_setting` confere cada valor. Se um `SET` for negado ou o valor não conferir, o Job aborta **antes** de enviar qualquer credencial; a mensagem cita só o nome da configuração.
3. A senha chega ao `\password` do `psql` pela entrada padrão (sem terminal no Job). A libpq do cliente gera o verificador SCRAM-SHA-256 (`PQencryptPasswordConn`); o servidor recebe só o verificador. A senha não vai para argumento de linha de comando, arquivo ou variável exportada.
4. `CREATE ROLE` e `\password` rodam na mesma transação: sem senha gravada, o papel também não existe. Uma nova tentativa depois de qualquer falha cria o papel com senha ou o encontra já completo.

O Job exige `psql` 10 ou superior (cliente que gera SCRAM) e rejeita senha com quebra de linha.

## Risco residual

- `pg_stat_activity`: enquanto o `ALTER USER` do `\password` executa, o texto com o verificador (nunca a senha) fica visível por instantes na coluna `query`, só para o próprio papel e para quem tem `pg_read_all_stats`. O Job não altera `track_activities` (não é registro e o `SET` pode ser negado no RDS); o risco é aceito.
- `pg_stat_statements`: coberto pela supressão acima quando a extensão está carregada. Se o master do RDS não puder fazer `SET` de `pg_stat_statements.*`, o Job aborta antes de enviar credenciais.

## Limitação

- Na primeira criação do papel, o Job define a senha uma vez.
- Execuções seguintes mantêm a senha existente, mesmo que o JSON no Secrets Manager mude (comportamento intencional: o Job só envia senha na criação).

## Procedimento operacional (produção)

Ordem recomendada; não imprima nem registre o valor da nova senha em ticket, chat ou log.

1. **Gerar** nova senha forte, só com letras, números e `-_.~` (a `DATABASE_URL` dos serviços é montada sem codificação), e **gravar** no segredo do usuário no Secrets Manager (`db-user-oficina` ou `db-user-billing`), mantendo o mesmo JSON (`username`, `password`, `host`, `port`, `dbname`, `engine`).
2. **No RDS**, com credencial master (fora dos pipelines de aplicação), numa sessão interativa do `psql` que suprime o registro e usa `\password`, que envia só o verificador:
   ```sql
   SET log_statement = 'none';
   SET log_min_error_statement = 'panic';
   SET log_min_duration_statement = -1;
   SET log_min_duration_sample = -1;
   SET log_statement_sample_rate = 0;
   SET log_transaction_sample_rate = 0;
   SET log_parameter_max_length = 0;
   SET log_parameter_max_length_on_error = 0;
   \password oficina
   ```
   (ou `billing`). Confira com `SHOW` cada valor antes do `\password`. **Não** use `ALTER ROLE ... PASSWORD '<senha>'`: com `log_statement = ddl` o texto vai para o log do PostgreSQL.
3. **Reiniciar** os pods que usam o usuário afetado para renovar pools e variáveis montadas pelo deploy:
   - OS: namespace `oficina`
   - Billing: namespace `billing`
4. **Validar** conectividade (`/health/ready` ou migration de leitura) antes de escalar ou seguir o runbook.
5. **Não** depender da reexecução do Job administrativo para rotação de senha de aplicação.

## Master (`tcadmin`)

Rotação do master segue o mesmo princípio: alteração no segredo master **e** troca da senha no RDS pelo mesmo procedimento (sessão sem registro e `\password`); Job administrativo não substitui esse fluxo.

## Validação no RDS

O comportamento local (PostgreSQL 16 em Docker) está coberto por `scripts/db-admin/test-senha-fora-do-log-local.sh`. Só o RDS real prova que o master (`rds_superuser`) pode fazer `SET` de cada configuração acima, inclusive `pg_stat_statements.track` e `pg_stat_statements.track_utility` se a extensão estiver em `shared_preload_libraries`. Na E37, antes de credenciais reais, validar com dados descartáveis: se algum `SET` for negado, o Job aborta e a implantação fica bloqueada até nova decisão.

## Referência

- Job: `scripts/db-admin/entrypoint.sh`, `scripts/db-admin/create-role-with-password.sql`, workflow `Database Admin Job` (`.github/workflows/db-admin-job.yml`).
- Runbook: fase 5.2 em `tech-challenge/spec/fase-4/13-deployment-runbook.md` (após complemento E09 integrado).
