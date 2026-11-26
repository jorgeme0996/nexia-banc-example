#############################################################################
# bootstrap/ — lo que se crea UNA sola vez, a mano, desde tu Mac
#############################################################################
# Problema del huevo y la gallina: GitHub Actions necesita permiso para entrar
# a AWS y un lugar donde guardar el state de Terraform... pero eso mismo hay
# que crearlo antes de que GitHub pueda desplegar. Por eso este directorio se
# aplica localmente (con tu perfil forense-lab) y después ya no se toca.
#
# Crea:
#   1. Bucket S3 para el state de Terraform (versionado y cifrado).
#   2. Proveedor OIDC de GitHub: AWS confía en los tokens que emite GitHub.
#   3. Rol "plan": solo lectura. Lo usan los Pull Requests.
#   4. Rol "apply": administrador. SOLO lo puede usar el environment "lab"
#      de TU repo, que tendrá aprobación manual.
#
# Sin access keys guardadas en GitHub: cada job pide credenciales temporales
# (~1 h) con su token OIDC. Si alguien roba un log del job, no se lleva nada
# reutilizable por mucho tiempo.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # El state del bootstrap se queda LOCAL a propósito (es diminuto y no
  # cambia). No lo subas a git: el .gitignore ya lo excluye.
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.lab_account_id] # misma guarda que en terraform/
  default_tags {
    tags = {
      Project   = "k8s-forensics-lab"
      ManagedBy = "terraform-bootstrap"
    }
  }
}

variable "lab_account_id" {
  type        = string
  description = "ID de 12 dígitos de la cuenta de LABORATORIO."
}

variable "github_repo" {
  type        = string
  description = "Tu repo en formato owner/nombre, ej. jorge/nexia-banc-example."
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "Formato owner/nombre."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "forensics-lab"
}

#############################################################################
# 1. Bucket del state
#############################################################################
# El state es la "memoria" de Terraform: qué recursos existen y sus valores.
# Contiene SECRETOS (la contraseña de RDS que generaremos en el paso 3), así
# que va cifrado, privado y versionado (si se corrompe, recuperas la anterior).
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.name}-tfstate-${var.lab_account_id}"
  # Lab: permite que terraform destroy lo borre aunque tenga objetos.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#############################################################################
# 2. Proveedor OIDC de GitHub
#############################################################################
# "AWS: confía en los tokens firmados por token.actions.githubusercontent.com
#  cuando el destinatario (audience) sea sts.amazonaws.com".
# Ojo: esto SOLO no da acceso a nadie. El acceso lo dan las trust policies de
# los roles de abajo, que dicen QUÉ repo y QUÉ contexto puede entrar.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  oidc_arn = aws_iam_openid_connect_provider.github.arn
}

#############################################################################
# 3. Rol PLAN — Pull Requests, solo lectura
#############################################################################
# El "sub" (subject) del token dice de dónde viene el job:
#   repo:owner/nombre:pull_request          -> un job disparado por un PR
#   repo:owner/nombre:environment:lab       -> un job del environment "lab"
# Restringir el sub es LO que impide que otro repo de GitHub use tu rol.
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${var.name}-gha-plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess NO incluye leer valores de secretos. Pero "terraform plan"
# refresca el secreto de RDS que crearemos, así que le damos lectura SOLO a
# los secretos del laboratorio. Además necesita escribir el lock del state.
resource "aws_iam_role_policy" "plan_extra" {
  name = "plan-state-and-lab-secrets"
  role = aws_iam_role.plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StateReadWriteForLock"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
      },
      {
        Sid      = "ReadOnlyLabSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.region}:${var.lab_account_id}:secret:${var.name}/*"
      }
    ]
  })
}

#############################################################################
# 4. Rol APPLY — solo el environment "lab" (con aprobación manual)
#############################################################################
data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:lab"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name                 = "${var.name}-gha-apply"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

# Administrador porque crea IAM, EKS, RDS, etc. En una empresa esto se acota
# con permission boundaries; en una cuenta de lab desechable es aceptable.
resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

#############################################################################
# Salidas: las pegas como Variables del repo en GitHub
#############################################################################
output "github_variables" {
  description = "Crea estas Variables en GitHub: Settings > Secrets and variables > Actions > Variables."
  value = {
    AWS_REGION         = var.region
    AWS_PLAN_ROLE_ARN  = aws_iam_role.plan.arn
    AWS_APPLY_ROLE_ARN = aws_iam_role.apply.arn
    TF_STATE_BUCKET    = aws_s3_bucket.tfstate.id
    TF_LAB_ACCOUNT_ID  = var.lab_account_id
  }
}
