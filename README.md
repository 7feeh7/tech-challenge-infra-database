# tech-challenge-infra-database

Terraform do RDS PostgreSQL, security groups, Secrets Manager e exports SSM consumidos pela aplicacao e pelas Functions.

> **Ambiente unico (001-R1):** apenas `producao` e provisionado. `develop` valida sem credencial AWS.

## Responsabilidade

| Recurso | Descricao |
| --- | --- |
| RDS PostgreSQL 16 | Banco gerenciado da oficina |
| Secrets Manager | Credenciais rotacionaveis |
| Security Group | Acesso restrito a Lambda e nodes EKS |
| SSM | Endpoints e ARN do secret |

Schema e migrations permanecem em `tech-challenge/prisma/`.

## Dependencias

Parametros SSM de `tech-challenge-infra-kubernetes` em `/tech-challenge/producao/infra/*`.

## Branches e pipelines

| Branch | Workflow | Toca AWS |
| --- | --- | --- |
| `develop` | `pr-validation.yml` | **nao** |
| `main` | `deploy.yml` | **sim** |

State key: `tech-challenge-infra-database/producao/terraform.tfstate`

## GitHub Secrets (Environment `producao`)

| Secret | Uso |
| --- | --- |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Deploy |
| `TF_STATE_BUCKET` | Backend S3 |
| `TF_STATE_LOCK_TABLE` | Lock DynamoDB |
| `JWT_SECRET` | Atualiza env da Lambda apos deploy |

## Rollback

Reverta o commit e merge em `main`, ou `workflow_dispatch` → destroy (manual).

Contratos: [`../tech-challenge-infra-kubernetes/docs/contratos-cross-repo.md`](../tech-challenge-infra-kubernetes/docs/contratos-cross-repo.md)
