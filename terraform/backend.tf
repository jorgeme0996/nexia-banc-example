#############################################################################
# backend.tf — dónde guarda Terraform su state
#############################################################################
# En S3 (creado en el paso 0) para que GitHub Actions y tú vean el MISMO state.
#
# El nombre del bucket NO va aquí escrito: se pasa al hacer init
# ("configuración parcial"), así el repo no queda amarrado a una cuenta:
#   terraform init -backend-config="bucket=<TF_STATE_BUCKET>" -backend-config="region=us-east-1"
#
# use_lockfile = true: Terraform crea un archivo .tflock en S3 mientras corre,
# así dos jobs no pueden modificar la infraestructura al mismo tiempo.
# (Requiere Terraform >= 1.10; ya no hace falta una tabla de DynamoDB.)

terraform {
  backend "s3" {
    key          = "forensics-lab/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
