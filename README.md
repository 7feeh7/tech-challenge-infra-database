# tech-challenge-infra-database

Terraform do banco relacional da oficina mecânica: RDS PostgreSQL, security group, Secrets Manager, alarmes e exports SSM. Projeto do Tech Challenge (FIAP).

Na **Fase 4** este repositório provisiona **uma única instância** RDS PostgreSQL 16 com **dois databases separados**: `oficina` (OS Service) e `billing` (Billing Service). O Execution não usa este banco: sua persistência é DynamoDB, provisionada no repositório `tech-challenge-execution`.

## Tecnologias

| Tecnologia                | Uso                                                       |
| ------------------------- | --------------------------------------------------------- |
| Terraform >= 1.5          | Provisionamento (estado remoto em S3)                     |
| Amazon RDS PostgreSQL 16  | Instância `db.t3.micro`, 20 GB gp3 (não é Aurora)         |
| AWS Secrets Manager / SSM | Credenciais e exports para os demais repositórios         |
| Kubernetes Job + `psql`   | Provisionamento dos databases e dos usuários da aplicação |
| GitHub Actions            | Validação em PR e deploy na `main`                        |

## Arquitetura

- **Instância:** privada (`publicly_accessible = false`), criptografada, com TLS obrigatório (`rds.force_ssl=1`, e as aplicações usam `DATABASE_SSL=true`). Single-AZ, `deletion_protection` e snapshot final em produção, backup de 7 dias (`terraform/rds.tf`).
- **Separação por serviço:** um Job administrativo (`k8s/db-admin-job.yaml`, `scripts/db-admin/`) cria os databases `oficina` e `billing`, cada um com usuário próprio, `CONNECTION LIMIT` por usuário e `REVOKE CONNECT ... FROM PUBLIC` (`scripts/db-admin/provision.sql.tpl`). Um serviço não acessa o database do outro.
- **Credenciais:** senhas geradas pelo Terraform e guardadas no Secrets Manager (nunca em output aberto). O OS e o Billing recebem a própria `DATABASE_URL` no deploy.
- **Rede:** o security group aceita a porta 5432 só dos nodes do EKS e do security group das Lambdas, ambos publicados pelo `tech-challenge-infra-kubernetes` (leitura em `data.tf`).
- **Monitoramento:** alarmes CloudWatch de CPU, conexões e armazenamento (`monitoring.tf`).
- **Schema:** migrations pertencem a cada serviço (`tech-challenge-oficina` e `tech-challenge-billing`), não a este repositório.
- **SAGA:** este repositório não participa diretamente da SAGA. Ele só guarda o estado transacional do OS e do Billing, incluindo as tabelas de outbox e de mensagens processadas.

Contrato SSM: consome `/tech-challenge/producao/infra/*` e publica `/tech-challenge/producao/database/*` (endpoint, ARNs dos segredos do OS, do Billing e do master, nomes dos databases e security group). Valores reais ficam só na AWS.

## Execução e desenvolvimento

Pré-requisitos: Terraform >= 1.5, AWS CLI, Docker (só para os testes locais do Job) e um `terraform.tfvars` baseado em [`terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example).

Validação local, a mesma do CI (`pr-validation.yml`), sem tocar a AWS:

```bash
cd terraform
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
cd ..
bash scripts/validate-password-charset.sh
```

Testes locais do Job administrativo, com um PostgreSQL 16 descartável em Docker:

```bash
bash scripts/db-admin/test-complemento-local.sh
bash scripts/db-admin/test-senha-fora-do-log-local.sh
bash scripts/db-admin/test-idempotencia-local.sh
```

Pipelines:

- `develop` e PR validam (`fmt`, `validate`, charset das senhas, tfsec, TruffleHog) sem tocar a AWS.
- Na `main`, o `deploy.yml` roda `plan` e `apply`. O `db-admin-job.yml` (`workflow_dispatch`, só na `main`) aplica o Job administrativo.
- `destroy` é manual e protegido por `deletion_protection` e snapshot final. Backup e restauração em [`docs/backup-restore.md`](docs/backup-restore.md).

## Documentação

- Backup, restore, RPO/RTO e troubleshooting: [`docs/backup-restore.md`](docs/backup-restore.md)
- Orçamento de conexões (pool por serviço e `CONNECTION LIMIT`): [`docs/orcamento-conexoes.md`](docs/orcamento-conexoes.md)
- Rotação de credenciais dos usuários de aplicação: [`docs/rotacao-credenciais-db.md`](docs/rotacao-credenciais-db.md)
- Contribuição: [`CONTRIBUTING.md`](CONTRIBUTING.md)

Repositórios relacionados, todos em `github.com/7feeh7/<repositório>`: `tech-challenge-infra-kubernetes` (rede e EKS), `tech-challenge-oficina`, `tech-challenge-billing`, `tech-challenge-execution` e `tech-challenge-serverless`.
