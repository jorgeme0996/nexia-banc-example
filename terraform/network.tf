#############################################################################
# network.tf — la red donde vive todo
#############################################################################
#
#   VPC 10.42.0.0/16
#   ├── subred pública A  10.42.0.0/20   ← el nodo de EKS (tiene IP pública)
#   ├── subred pública B  10.42.16.0/20  ← (EKS exige 2 zonas)
#   ├── subred privada A  10.42.32.0/20  ← RDS (sin salida a internet)
#   └── subred privada B  10.42.48.0/20  ← RDS (réplica de zona)
#
# Decisión de laboratorio: el nodo va en subred PÚBLICA para no pagar un NAT
# Gateway (~32 USD/mes). En producción los nodos van en subredes privadas.
# Es otra "mala práctica" que anotaremos en la remediación.

# Las zonas de disponibilidad (AZ) que existen en la región. Tomamos 2.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # cidrsubnet(red, bits_extra, índice) parte la /16 en bloques /20 (4096 IPs).
  public_subnets  = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1)]
  private_subnets = [cidrsubnet(var.vpc_cidr, 4, 2), cidrsubnet(var.vpc_cidr, 4, 3)]
}

# --- La VPC -----------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # EKS necesita DNS dentro de la VPC para que los nodos encuentren el API
  # server y para que los pods resuelvan el endpoint de RDS.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

# --- Internet Gateway: la puerta de la VPC hacia internet -------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

# --- Subredes públicas (nodos) ---------------------------------------------
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnets[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true # todo lo que nazca aquí recibe IP pública

  tags = {
    Name = "${var.name}-public-${local.azs[count.index]}"
    # Etiquetas que EKS usa para saber dónde crear load balancers.
    "kubernetes.io/role/elb"            = "1"
    "kubernetes.io/cluster/${var.name}" = "shared"
  }
}

# --- Subredes privadas (RDS) -----------------------------------------------
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                                = "${var.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"   = "1"
    "kubernetes.io/cluster/${var.name}" = "shared"
  }
}

# --- Tablas de rutas --------------------------------------------------------
# Lo que hace "pública" a una subred NO es su nombre: es que su tabla de rutas
# manda 0.0.0.0/0 (todo internet) al Internet Gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# La privada solo conoce la ruta local de la VPC: RDS no puede salir a
# internet ni ser alcanzado desde internet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
