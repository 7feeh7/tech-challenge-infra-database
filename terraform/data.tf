data "aws_ssm_parameter" "vpc_id" {
  name = "${local.ssm_prefix}/infra/vpc_id"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "${local.ssm_prefix}/infra/private_subnet_ids"
}

data "aws_ssm_parameter" "lambda_sg_id" {
  name = "${local.ssm_prefix}/infra/lambda_security_group_id"
}

data "aws_ssm_parameter" "rds_access_sg_id" {
  name = "${local.ssm_prefix}/infra/rds_access_security_group_id"
}

data "aws_ssm_parameter" "eks_node_sg_id" {
  name = "${local.ssm_prefix}/infra/eks_node_security_group_id"
}

data "aws_vpc" "main" {
  id = data.aws_ssm_parameter.vpc_id.value
}

locals {
  vpc_id             = data.aws_ssm_parameter.vpc_id.value
  private_subnet_ids = split(",", data.aws_ssm_parameter.private_subnet_ids.value)
  lambda_sg_id       = data.aws_ssm_parameter.lambda_sg_id.value
  rds_access_sg_id   = data.aws_ssm_parameter.rds_access_sg_id.value
  eks_node_sg_id     = data.aws_ssm_parameter.eks_node_sg_id.value
  vpc_cidr           = data.aws_vpc.main.cidr_block
}
