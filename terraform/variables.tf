#############################################################################
# variables.tf — los valores que cambian según quién corra el laboratorio
#############################################################################
# Los valores reales los pones en terraform.tfvars (que NO se sube a git).
# Copia terraform.tfvars.example y llénalo.

variable "lab_account_id" {
  description = "ID (12 dígitos) de la cuenta AWS de LABORATORIO. Terraform se niega a correr en cualquier otra."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.lab_account_id))
    error_message = "Debe ser un ID de cuenta AWS de 12 dígitos."
  }
}

variable "admin_cidr" {
  description = "Tu IP pública en formato CIDR (ej. 187.190.10.20/32). Solo esa IP podrá hablar con el API de EKS."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "Debe ser un CIDR válido y NO 0.0.0.0/0 (eso abriría el cluster a todo internet)."
  }
}

variable "region" {
  description = "Región de AWS donde vive todo el laboratorio."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Prefijo para nombrar todos los recursos."
  type        = string
  default     = "forensics-lab"
}

variable "vpc_cidr" {
  description = "Rango de IPs privado de la VPC."
  type        = string
  default     = "10.42.0.0/16"
}
