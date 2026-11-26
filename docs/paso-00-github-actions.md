# Paso 0 · Conectar GitHub Actions con AWS (bootstrap)

**Objetivo:** que GitHub Actions pueda desplegar en tu cuenta de laboratorio
**sin guardar access keys** en GitHub, igual que se hace en una empresa.

**Se hace una sola vez, desde tu Mac.** Después, todo cambio de infraestructura
pasa por un Pull Request.

**Costo:** prácticamente 0 (un bucket S3 casi vacío y unos roles IAM).

---

## 0.1 · Cómo funciona OIDC (lo que vas a construir)

```
 GitHub Actions (job)                         AWS (tu cuenta de lab)
 ────────────────────                         ──────────────────────
 1. "Soy el repo jorgeme0996/nexia-banc-example,
     environment lab" ── token OIDC firmado ──▶ 2. STS revisa la firma (proveedor OIDC)
                                                  y la trust policy del rol:
                                                  ¿el "sub" del token es el que permito?
 4. Corre terraform con ◀── credenciales temporales (1 h) ── 3. Sí → AssumeRoleWithWebIdentity
    esas credenciales
```

Lo que debes entender:

- **No hay secreto guardado.** GitHub firma un token que dice quién es el job.
  AWS confía en esa firma porque registramos a GitHub como proveedor OIDC.
- **El control está en el `sub` del token.** La trust policy de cada rol dice
  exactamente qué repo y qué contexto puede entrar:

  | Rol | Quién puede asumirlo (`sub`) | Permisos |
  |-----|------------------------------|----------|
  | `forensics-lab-gha-plan` | `repo:jorgeme0996/nexia-banc-example:pull_request` | Solo lectura |
  | `forensics-lab-gha-apply` | `repo:jorgeme0996/nexia-banc-example:environment:lab` | Administrador |

- **El environment `lab` con aprobación manual** es tu freno: aunque alguien
  haga merge a `main`, nada se aplica hasta que tú lo apruebas en GitHub.

> 🔎 **Esto importa para el forense.** En CloudTrail, cada cambio de
> infraestructura aparecerá hecho por
> `assumed-role/forensics-lab-gha-apply/gha-apply-<run_id>`. Con ese `run_id`
> encuentras el job exacto en GitHub. Eso es trazabilidad: separar "lo que hizo
> el pipeline" de "lo que hizo el atacante".

---

## 0.2 · Prepara tu Mac

```bash
cd ~/Documents/DEVSECOPS/nexia-banc-example

export AWS_PROFILE=forense-lab            # ver docs/paso-01-red.md §1.1
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sts get-caller-identity               # ¿es la cuenta de LABORATORIO?
```

Si aún no tienes el perfil `forense-lab`, haz primero la sección 1.1 de
`docs/paso-01-red.md` y regresa.

---

## 0.3 · Aplica el bootstrap

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
# edita lab_account_id (el github_repo ya viene con tu repo)

terraform init
terraform plan     # debe crear 10 recursos: bucket + 3 configs, OIDC, 2 roles, 3 permisos
terraform apply
terraform output github_variables
```

Guarda esa salida, la necesitas en 0.5.

> El state del bootstrap se queda en `bootstrap/terraform.tfstate`, en tu Mac.
> No se sube a git (el `.gitignore` lo excluye). Si lo pierdes no pasa nada
> grave: los recursos siguen en AWS y los puedes importar.

---

## 0.4 · Sube el código al repo

```bash
cd ~/Documents/DEVSECOPS/nexia-banc-example
git init -b main
git add -A
git status          # REVISA: no debe aparecer ningún terraform.tfvars ni .tfstate
git commit -m "Paso 0 y 1: bootstrap OIDC, workflow y red"
git remote add origin https://github.com/jorgeme0996/nexia-banc-example.git
git push -u origin main
```

Este primer push a `main` va a disparar el workflow, y **va a fallar** porque
todavía no configuras las Variables. Es normal; lo arreglas en 0.5.

---

## 0.5 · Configura GitHub

### Variables del repo
**Settings → Secrets and variables → Actions → pestaña Variables → New repository variable**

| Nombre | Valor |
|--------|-------|
| `AWS_REGION` | de `github_variables` |
| `AWS_PLAN_ROLE_ARN` | de `github_variables` |
| `AWS_APPLY_ROLE_ARN` | de `github_variables` |
| `TF_STATE_BUCKET` | de `github_variables` |
| `TF_LAB_ACCOUNT_ID` | de `github_variables` |
| `TF_ADMIN_CIDR` | tu IP + `/32` (`curl -s https://checkip.amazonaws.com`) |

> ¿Por qué Variables y no Secrets? Nada de esto es secreto: un ARN de rol no
> sirve sin el token OIDC del repo correcto. Los Secrets de GitHub se usan para
> valores que dan acceso por sí solos (y aquí no tenemos ninguno: ese es el
> punto de OIDC).

### Environment `lab` con aprobación
**Settings → Environments → New environment → `lab`**
- Marca **Required reviewers** y agrégate a ti.
- En **Deployment branches and tags**, elige **Selected branches** y agrega
  `main`.

### Protege `main` (recomendado)
**Settings → Branches → Add rule** para `main`: exige Pull Request antes de
hacer merge. Así todo cambio pasa por un `plan` revisado.

---

## 0.6 · Prueba el flujo completo

1. En GitHub: **Actions → terraform → Run workflow → action = apply**.
2. El job `apply` queda en **Waiting**. Revisa y dale **Approve**.
3. Debe aplicar la red del paso 1 (12 recursos).

Después, para cualquier cambio:

```bash
git checkout -b paso-02
# ... cambios en terraform/ ...
git push -u origin paso-02     # abre el PR en GitHub
```

En el PR, el job `plan` te deja el plan en **Summary**. Si te convence, haz
merge y aprueba el `apply`.

---

## ✅ Checklist del paso 0

- [ ] `terraform apply` del bootstrap sin errores
- [ ] Código en `jorgeme0996/nexia-banc-example` (sin tfvars ni tfstate)
- [ ] 6 Variables creadas en el repo
- [ ] Environment `lab` con Required reviewers y solo la rama `main`
- [ ] Un run manual de `apply` aprobado y exitoso
- [ ] En la consola de IAM ves los roles `forensics-lab-gha-plan` y `-apply`

Pregunta para pensar: si mañana alguien hace fork de tu repo y corre el mismo
workflow, ¿puede asumir tus roles? ¿Por qué no? (Pista: mira el `sub`.)
