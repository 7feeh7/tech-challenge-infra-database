-- Sessao exclusiva de senha do papel (variavel do psql: role). A senha chega pela entrada padrao
-- ao \password, que gera o verificador SCRAM-SHA-256 com a libpq do cliente; o servidor nunca recebe
-- o valor original. Esta sessao e a unica com o registro de comandos suprimido (log_statement = ddl
-- continua valendo no parameter group e nas demais sessoes).

-- Uma unica lista para configurar e conferir. Falha de permissao no SET ou valor divergente aborta a
-- sessao (ON_ERROR_STOP) antes de qualquer credencial ser transmitida; as mensagens citam so o nome.
DO $suprimir_registro$
DECLARE
  configuracao record;
BEGIN
  -- Extensoes primeiro, para pararem de registrar antes das demais instrucoes da sessao.
  FOR configuracao IN
    SELECT nome, valor, obrigatoria
    FROM (VALUES
      ('pgaudit.log', 'none', false),
      ('pgaudit.log_parameter', 'off', false),
      ('pgaudit.log_statement', 'off', false),
      ('pgaudit.role', '', false),
      ('auto_explain.log_min_duration', '-1', false),
      ('pg_stat_statements.track_utility', 'off', false),
      ('pg_stat_statements.track', 'none', false),
      ('log_statement', 'none', true),
      ('log_min_error_statement', 'panic', true),
      ('log_min_duration_statement', '-1', true),
      ('log_min_duration_sample', '-1', true),
      ('log_statement_sample_rate', '0', true),
      ('log_transaction_sample_rate', '0', true),
      ('log_parameter_max_length', '0', true),
      ('log_parameter_max_length_on_error', '0', true),
      ('debug_print_parse', 'off', true),
      ('debug_print_rewritten', 'off', true),
      ('debug_print_plan', 'off', true),
      ('password_encryption', 'scram-sha-256', true)
    ) AS lista(nome, valor, obrigatoria)
  LOOP
    -- Extensao nao carregada na instancia: nao ha o que suprimir.
    CONTINUE WHEN NOT configuracao.obrigatoria AND current_setting(configuracao.nome, true) IS NULL;

    -- So altera o que difere: configuracao ja no valor esperado nao exige permissao de SET.
    IF current_setting(configuracao.nome) IS DISTINCT FROM configuracao.valor THEN
      PERFORM set_config(configuracao.nome, configuracao.valor, false);
    END IF;

    IF current_setting(configuracao.nome) IS DISTINCT FROM configuracao.valor THEN
      RAISE EXCEPTION 'Configuracao de registro nao confirmada na sessao: %', configuracao.nome;
    END IF;
  END LOOP;
END
$suprimir_registro$;

SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'role') AS criar_papel \gset

-- Papel e senha na mesma transacao: sem senha gravada, o papel tambem nao existe.
\if :criar_papel
  BEGIN;
  CREATE ROLE :"role" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  \password :"role"
  COMMIT;
\endif
