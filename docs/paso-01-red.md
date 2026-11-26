# Paso 1 · Guardas de seguridad y la red

**Objetivo:** dejar listo tu acceso a la cuenta de laboratorio, blindado para
que nunca toques otra cuenta, y crear la red donde vivirá todo.

**Costo de este paso:** prácticamente 0. VPC, subredes, tablas de rutas e
Internet Gateway no cobran por hora.

---

## 1.1 · Un perfil de AWS solo para el laboratorio

### Por qué
Si en tu máquina hay credenciales de otro trabajo, el riesgo número uno de este
laboratorio es **desplegar infraestructura vulnerable en la cuenta
equivocada**. Lo evitamos con dos guardas:

1. Un **perfil con nombre** (`forense-lab`) que usas a propósito.
2. `allowed_account_ids` en el provider de Terraform (ver
   `terraform/versions.tf`): si las credenciales no son de la cuenta del
   laboratorio, Terraform **se niega a correr**.

### Cómo
Crea en la cuenta de laboratorio un usuario o rol con `AdministratorAccess`
(lo ideal es usar IAM Identity Center/SSO). Luego configura el perfil:

```bash
# Opción A: SSO (recomendada)
aws configure sso --profile forense-lab

# Opción B: access keys de un usuario IAM del laboratorio
aws configure --profile forense-lab
```

Actívalo **en cada terminal** donde trabajes con el laboratorio:

```bash
export AWS_PROFILE=forense-lab
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

> ¿Por qué el `unset`? Las variables de entorno `AWS_ACCESS_KEY_ID` y
> compañía **le ganan** al perfil. Si tu terminal las trae de otro trabajo,
> estarías usando esa cuenta sin darte cuenta.

### Verifica
```bash
aws sts get-caller-identity
```
Revisa que el campo `Account` sea el de tu cuenta de laboratorio. **Anota ese
número**, lo necesitas abajo.

---

## 1.2 · Llenar tus variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

> Este `terraform.tfvars` es **solo para tus pruebas locales** (`plan`,
> `output`). En GitHub Actions los mismos valores salen de las Variables del
> repo (`TF_LAB_ACCOUNT_ID`, `TF_ADMIN_CIDR`, `AWS_REGION`), ver paso 0.

Edita `terraform.tfvars`:

| Variable | De dónde sale | Para qué |
|----------|---------------|----------|
| `lab_account_id` | `aws sts get-caller-identity --query Account --output text` | Guarda contra cuentas equivocadas |
| `admin_cidr` | `curl -s https://checkip.amazonaws.com` y le agregas `/32` | Solo tu IP podrá hablar con el API de EKS (paso 2) |
| `region` | La que prefieras, `us-east-1` por defecto | Todo vive aquí |

> `/32` significa "exactamente esta IP, ninguna otra". Si tu IP de casa
> cambia, actualízala aquí y corre `terraform apply` otra vez.

---

## 1.3 · Entender la red antes de crearla

Lee `terraform/network.tf`. Los conceptos clave:

- **VPC:** tu red privada dentro de AWS (`10.42.0.0/16` = 65,536 IPs).
- **Subred:** un pedazo de la VPC que vive en **una sola** zona de
  disponibilidad (AZ). EKS exige al menos 2 AZ.
- **Pública o privada:** no lo define el nombre, sino **la tabla de rutas**.
  Si tiene una ruta `0.0.0.0/0 → Internet Gateway`, es pública.
- **Dónde va cada cosa:**
  - El **nodo de EKS** va en una subred pública. Así nos ahorramos el NAT
    Gateway, pero también queda más expuesto. En producción iría en una privada.
  - **RDS** va en las privadas: nadie de internet llega a la base. Por eso, más
    adelante, el atacante tendrá que entrar a la base **desde dentro del
    cluster**. Eso deja un rastro que vas a buscar.

### Pregunta para pensar (la retomamos en el forense)
Si RDS no es accesible desde internet, ¿desde qué IP verías una conexión
maliciosa en los logs de Postgres? ¿La del atacante o una interna? ¿Qué te
diría eso?

---

## 1.4 · Desplegar

El despliegue lo hace **GitHub Actions** (paso 0.6: Run workflow → apply →
aprobar). Pero antes conviene que corras el plan en tu Mac para aprender a
leerlo sin prisa. El `init` apunta al **mismo state en S3** que usa GitHub:

```bash
cd terraform
BUCKET=$(cd ../bootstrap && terraform output -json github_variables | python3 -c 'import sys,json;print(json.load(sys.stdin)["TF_STATE_BUCKET"])')

terraform init -backend-config="bucket=$BUCKET" -backend-config="region=us-east-1"
terraform fmt -check  # revisa el formato (no cambia nada)
terraform validate    # revisa la sintaxis
terraform plan        # te muestra QUÉ va a crear, sin crear nada
```

Lee el `plan` con calma. Debe decir **`Plan: 12 to add, 0 to change, 0 to
destroy`**:

| Recurso | Cantidad |
|---------|----------|
| `aws_vpc` | 1 |
| `aws_internet_gateway` | 1 |
| `aws_subnet` (2 públicas + 2 privadas) | 4 |
| `aws_route_table` (1 pública + 1 privada) | 2 |
| `aws_route_table_association` (una por subred) | 4 |

Busca cada uno en la salida del plan: leer planes es una habilidad que vas a
usar mucho. **Si ves cualquier `destroy`, detente y revisa.**

Cuando estés conforme, despliega **desde GitHub**: Actions → terraform → Run
workflow → `apply` → aprueba en el environment `lab`. Compara el log del job
con el plan que viste en tu Mac: deben coincidir.

> No hagas `terraform apply` desde tu Mac: la idea es que todo cambio quede
> registrado en GitHub (quién, cuándo, qué commit) y en CloudTrail con el rol
> `forensics-lab-gha-apply`. Si aplicas a mano, ese rastro se mezcla con tu
> usuario, y en el forense te va a costar separar qué cambio fue legítimo.

Cuando el job termine, en tu Mac:

```bash
terraform output      # lee el state de S3 que acaba de escribir GitHub
```

---

## 1.5 · Verifica que quedó bien

```bash
VPC=$(terraform output -raw vpc_id)

# Las 4 subredes, con su zona y si asignan IP pública:
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' \
  --output table

# Las rutas: la pública debe tener 0.0.0.0/0 -> igw-..., la privada solo "local":
aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC \
  --query 'RouteTables[].[Tags[?Key==`Name`]|[0].Value,Routes[].[DestinationCidrBlock,GatewayId]]' \
  --output json
```

Prueba también la guarda: pon temporalmente un `lab_account_id` falso en
`terraform.tfvars` y corre `terraform plan`. Debe fallar con un error como
`AWS account ID not allowed`. Regrésalo a su valor correcto.

---

## ✅ Checklist del paso 1

- [ ] `aws sts get-caller-identity` muestra la cuenta de laboratorio
- [ ] `terraform.tfvars` lleno (y fuera de git: `git status` no lo muestra)
- [ ] Leíste el `plan` local y el `apply` de GitHub Actions creó la red
- [ ] Verificaste subredes y rutas con los comandos de 1.5
- [ ] Probaste que la guarda de `allowed_account_ids` bloquea otra cuenta

Cuando termines, avísame y seguimos con el **paso 2: el cluster EKS y sus
fallas sembradas**.
