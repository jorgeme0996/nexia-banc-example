#############################################################################
# outputs.tf — valores que Terraform te imprime al final y que usaremos después
#############################################################################
# Consúltalos cuando quieras con:  terraform output

output "account_id" {
  description = "Cuenta donde se desplegó (debe ser la de laboratorio)."
  value       = var.lab_account_id
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Donde vivirá el nodo de EKS."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Donde vivirá RDS."
  value       = aws_subnet.private[*].id
}
