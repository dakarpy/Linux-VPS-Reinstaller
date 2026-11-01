# Multi-Arch Reinstaller PRO

Reinstala **Ubuntu 20.04 / 22.04 / 24.04 / 26.04 LTS** desde la terminal en VPS **ARM64 (Oracle Ampere A1)** y **AMD64/x86_64 (AMD EPYC, Ryzen y también Intel)**. Prepara y optimiza el servidor para instalar tu panel.

> ⚠️ **La reinstalación BORRA TODO EL DISCO** (paneles, bases de datos, usuarios, archivos). Haz copia de seguridad antes. El script te ofrece hacerla.

---

## ¿Qué lo hace mejor que el original?

| | Original (vps-reinstaller) | Multi-Arch Reinstaller PRO |
|---|---|---|
| Código | Binario cerrado (no se puede revisar) | Script Bash abierto y legible |
| Contraseña | Usa una contraseña **pública** conocida por todos (`LeitboGi0ro`) | Genera una **única** de 20 caracteres, o la eliges tú, o usas solo clave SSH |
| Verificaciones previas | No | Arquitectura, UEFI, RAM, disco, espacio libre, internet, tipo de VM, Secure Boot |
| Copia de seguridad | No | Archivos + volcado MySQL, con el comando `scp` listo para descargarla |
| Confirmación | Sí/No | Hay que escribir **BORRAR**; 15 s para cancelar el reinicio |
| Si algo falla | — | El sistema actual queda intacto y se anula todo automáticamente |
| Modo de prueba | No | `--dry-run` ejecuta preflight sin backup, descarga del motor ni cambios de sistema |
| Después de instalar | Nada | Actualiza, optimiza la red (BBR), crea swap, ajusta límites, instala Docker/Go y ejecuta tu panel |

Motor de reinstalación: [bin456789/reinstall](https://github.com/bin456789/reinstall) (GPL-3.0). Su documentación contempla ARM Server y el script detecta ARM64 y AMD64/x86_64. El motor se descarga en el momento desde su repositorio oficial y se valida sintácticamente antes de ejecutarse. La descarga desde `main` es mutable; esta versión aún no fija un commit ni checksum del motor.

---

## Requisitos

- **ARM64:** Oracle Cloud Ampere A1 (VM.Standard.A1.Flex) y otras VPS ARM64 compatibles.
- **AMD64/x86_64:** VPS y dedicados con AMD EPYC, AMD Ryzen o Intel Xeon/Core. AMD64 es el nombre de la arquitectura x86-64, no una limitación a CPU AMD.
- Acceso **root** (`sudo -i`).
- Al menos 1 GB de RAM y 10 GB de disco.
- Cualquier sistema actual: Oracle Linux, Ubuntu, Debian, CentOS, etc.

### Importante en Oracle: Security List
En Oracle los puertos se abren en **Networking → Virtual Cloud Networks → tu VCN → Security Lists** (o NSG).
Antes de reinstalar, deja abiertos:

- **TCP 22** (o el puerto SSH que elijas) — si no, no podrás entrar.
- **TCP 80** si quieres ver el progreso de la instalación desde el navegador (opcional).
- Los puertos que use tu panel.

En Oracle debes revisar la Security List / NSG. En otros proveedores, revisa el firewall de red o las reglas de seguridad del proveedor.

---

## Uso

Sube `oracle-reinstaller.sh` a tu repositorio de GitHub y ejecútalo así en la VPS:

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/TU_USUARIO/TU_REPO/main/oracle-reinstaller.sh)
```

O copiándolo a mano:

```bash
sudo -i
nano oracle-reinstaller.sh      # pega el contenido y guarda
bash oracle-reinstaller.sh
```

### Menú

```
1) Reinstalar Ubuntu 24.04 LTS   (borra todo)
2) Preparar servidor (post-instalación)
3) Instalar mi panel
4) Diagnóstico del sistema
5) Cancelar una reinstalación pendiente
0) Salir
```

### Paso a paso

1. **Opción 1** → revisa los datos, haz la copia si la necesitas, elige contraseña y puerto.
2. **Guarda la contraseña** que aparece en pantalla y escribe `BORRAR`.
3. La VPS se reinicia y se instala sola (5 a 20 min). Puedes seguirla en `http://TU_IP` o desde **Consola → Console connection** en Oracle.
4. En tu PC borra la huella vieja del servidor (si no, SSH dirá "host key changed"):
   ```bash
   ssh-keygen -R TU_IP
   ```
5. Entra como `root` con la nueva contraseña y vuelve a correr el script → **opción 2** (Preparar servidor) → **opción 3** (Instalar mi panel).

---

## Configurar tu panel

Edita esta línea al principio del script con el comando que instala tu panel:

```bash
PANEL_INSTALL_CMD='bash <(curl -fsSL https://raw.githubusercontent.com/TU_USUARIO/TU_PANEL/main/install.sh)'
```

Si la dejas vacía, el script te pedirá el comando cuando elijas "Instalar mi panel".

---

## Qué hace "Preparar servidor"

- Espera a que termine el primer arranque (cloud-init) y las actualizaciones automáticas.
- `apt update` + `full-upgrade` sin preguntas.
- Herramientas base: curl, wget, git, jq, htop, unzip, build-essential, sqlite3, socat, screen, tmux, cron, chrony…
- Zona horaria (por defecto `America/Asuncion`).
- Swap de 2 GB si no existe.
- Red: **BBR**, colas y buffers grandes, `tcp_mtu_probing` (ayuda en túneles), 1 millón de archivos abiertos, conntrack alto — pensado para paneles SSH/proxy con muchas conexiones.
- SSH: keep-alive y más logins simultáneos permitidos.
- Opcional: **Docker** (para Evolution API), **Go** última versión (arm64), firewall **UFW**.

---

## Modo automático (sin preguntas)

```bash
# Preflight sin backup, descarga del motor ni cambios de sistema
bash oracle-reinstaller.sh reinstall --dry-run

# Reinstalar con clave SSH de tu GitHub, puerto 22, sin confirmación (¡cuidado!)
bash oracle-reinstaller.sh reinstall --ssh-key github:TU_USUARIO --yes --yes-wipe-disk

# Preparar el servidor con Docker, sin Go, sin UFW
bash oracle-reinstaller.sh post --yes --docker --no-go --no-ufw

# Ver todas las opciones
bash oracle-reinstaller.sh --help
```

---

## Problemas comunes

**Me arrepentí antes de que reinicie** → `bash oracle-reinstaller.sh cancel` (o `bash /root/oracle-reinstaller/reinstall.sh reset`). Mientras no reinicies, no se borra nada.

**Pasaron 30 min y no puedo entrar** → abre la consola web/serial del proveedor para ver en qué paso está. Revisa que el puerto SSH esté permitido tanto en el firewall del servidor como en el firewall de red del proveedor.

**"REMOTE HOST IDENTIFICATION HAS CHANGED"** → es normal tras reinstalar: `ssh-keygen -R TU_IP`.

**No arranca tras reinstalar** → revisa el modo UEFI/BIOS y, si *Secure Boot* está activado, prueba desactivarlo desde el panel del proveedor.

**Registros** → `/var/log/oracle-reinstaller.log` (post-instalación) y `/root/oracle-reinstaller/engine.log` (preparación de la reinstalación, antes de borrar).

---

Uso bajo tu propia responsabilidad.


## Estado de validación de esta versión candidata

- Auditoría estática y pruebas de sintaxis Bash: pendientes de completar para esta revisión.
- No se ha ejecutado una reinstalación real en hardware ARM64 ni AMD64/Intel.
- `--dry-run` valida preflight y no crea respaldos ni descarga el motor; no equivale a una prueba integral del motor.
- Si eliges crear un respaldo, debes descargarlo fuera de la VPS antes de reinstalar. Escribir `SALTAR` cancela el proceso.
- No uses esta versión candidata para reinstalar servidores con datos importantes hasta completar pruebas reales y una copia externa verificada.
