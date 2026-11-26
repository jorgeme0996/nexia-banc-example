# Laboratorio: forense de un nodo EKS con secretos comprometidos

Laboratorio para aprender **desde cero** a investigar un incidente en
Kubernetes. Primero construimos un ambiente vulnerable en AWS (EKS + RDS +
Secrets Manager), luego lo atacamos y al final hacemos el forense con
**Velociraptor** y los logs de AWS.

La parte del forense **no está escrita**: la vas a construir tú, paso a paso,
para poder repetirla en cualquier otro ambiente.

> ⚠️ **Esta infraestructura es insegura a propósito.**
> - Úsala solo en una **cuenta AWS de laboratorio**, nunca en una cuenta con
>   datos o cargas reales (ni la del trabajo).
> - Cuesta dinero mientras está encendida: aproximadamente 4-6 USD al día
>   (control plane de EKS, 1 nodo t3.medium y un RDS db.t3.micro).
> - Destrúyela con `terraform destroy` cuando termines cada sesión si no la
>   vas a usar.

---

## La historia que vamos a investigar

Una empresa corre una app de inventario en EKS. La app usa una base de datos
Postgres (RDS) y la contraseña vive en Secrets Manager y en un Secret de
Kubernetes. Un día alguien filtra el token de una ServiceAccount de CI. Con ese
token, el atacante:

1. Lee los Secrets de Kubernetes del namespace.
2. Lanza un pod privilegiado que monta el disco del nodo (escape al host).
3. Desde ese pod roba las credenciales AWS del rol del nodo (vía el IMDS).
4. Con esas credenciales vacía Secrets Manager desde fuera de AWS.
5. Entra a la base de datos.

Tu trabajo como investigador será **reconstruir esta historia a partir de la
evidencia**, sin saber de antemano qué pasó exactamente.

---

## Mapa de pasos

| Paso | Qué construimos | Estado |
|------|-----------------|--------|
| 1 | Guardas de seguridad + red (VPC, subredes) | ✅ este paso |
| 2 | Cluster EKS y node group (con sus fallas sembradas) | pendiente |
| 3 | RDS Postgres + Secrets Manager | pendiente |
| 4 | Las "cámaras": CloudTrail, audit logs de EKS, logs de RDS | pendiente |
| 5 | App víctima en Kubernetes + RBAC débil | pendiente |
| 6 | El ataque simulado | pendiente |
| 7+ | **El forense con Velociraptor** (lo haces tú, guiado) | pendiente |
| Final | Remediación y `terraform destroy` | pendiente |

Cada paso tiene su guía en `docs/paso-XX-*.md` con el **qué**, el **por qué** y
cómo **verificar** que quedó bien antes de seguir.

---

## Prerrequisitos (en la máquina donde vas a correr los comandos)

| Herramienta | Para qué | Verificar |
|-------------|----------|-----------|
| AWS CLI v2 | Hablar con tu cuenta de laboratorio | `aws --version` |
| Terraform ≥ 1.6 (u OpenTofu) | Crear la infraestructura | `terraform version` |
| kubectl | Hablar con el cluster | `kubectl version --client` |
| session-manager-plugin | Entrar al nodo sin SSH (paso 7) | `session-manager-plugin --version` |
| Velociraptor | El forense (lo bajamos en el paso 7) | — |

Y lo más importante: **un perfil de AWS CLI que apunte a tu cuenta de
laboratorio**. Ver `docs/paso-01-red.md`.

---

## Estructura del repo (va creciendo con cada paso)

```
terraform/   Infraestructura AWS
docs/        Una guía por paso
```
