#############################################################################
# versions.tf — qué versión de Terraform y de los providers usamos
#############################################################################
# Un "provider" es el plugin que sabe hablar con una API (aquí, la de AWS).
# Fijar versiones hace que el laboratorio se comporte igual hoy y en 6 meses.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # cualquier 6.x, nunca un 7.0 con cambios incompatibles
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6" # para generar contraseñas y sufijos únicos
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # para leer el certificado del OIDC de EKS (paso 2)
    }
  }
}

provider "aws" {
  region = var.region

  # GUARDA DE SEGURIDAD #1 — la más importante del laboratorio.
  # Terraform se niega a hacer CUALQUIER cosa si las credenciales con las que
  # corre pertenecen a una cuenta distinta a esta. Así es imposible levantar
  # infra vulnerable por accidente en la cuenta del trabajo.
  allowed_account_ids = [var.lab_account_id]

  # Etiquetas que se ponen solas en todos los recursos. En el forense te
  # sirven para filtrar rápido "qué es del laboratorio" en la consola.
  default_tags {
    tags = {
      Project   = "k8s-forensics-lab"
      ManagedBy = "terraform"
      Danger    = "intentionally-vulnerable"
    }
  }
}
