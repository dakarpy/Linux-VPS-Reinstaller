#!/usr/bin/env bash
# ==============================================================================
#  MULTI-ARCH REINSTALLER PRO
#  Reinstala Ubuntu 20.04 / 22.04 / 24.04 / 26.04 LTS en ARM64 y x86_64
#  (AMD64: procesadores AMD e Intel), y deja el servidor listo para tu panel.
#
#  Motor de reinstalación: bin456789/reinstall (GPL-3.0), descargado en tiempo
#  de ejecución desde su repositorio oficial. Este script es una capa
#  interactiva con validaciones, respaldo previo y post-instalación.
#
#  Uso rápido:
#     bash oracle-reinstaller.sh            -> menú interactivo
#     bash oracle-reinstaller.sh reinstall  -> reinstalar Ubuntu (eliges versión)
#     bash oracle-reinstaller.sh post       -> preparar Ubuntu recién instalado
#     bash oracle-reinstaller.sh panel      -> instalar tu panel
#     bash oracle-reinstaller.sh info       -> diagnóstico
#     bash oracle-reinstaller.sh --help     -> todas las opciones
# ==============================================================================

VERSION="1.2.1-rc3"

# ------------------------------------------------------------------------------
#  CONFIGURACIÓN EDITABLE
# ------------------------------------------------------------------------------
# Comando que instala TU panel (se ejecuta en la opción "Instalar mi panel").
# Ejemplo:  PANEL_INSTALL_CMD='bash <(curl -fsSL https://raw.githubusercontent.com/TU_USUARIO/TU_REPO/main/install.sh)'
PANEL_INSTALL_CMD="${PANEL_INSTALL_CMD:-}"

# Zona horaria por defecto para la post-instalación
DEFAULT_TZ="${DEFAULT_TZ:-America/Asuncion}"

# Tamaño de swap por defecto (MB) si el servidor no tiene swap
DEFAULT_SWAP_MB="${DEFAULT_SWAP_MB:-2048}"

# Motor externo fijado a un commit inmutable y verificado por SHA-256.
REINSTALL_REF="c2cf88b3a583bef3d6ecee99ea21b6eb6f664968"
REINSTALL_SHA256="3ca358bf065ebd3ecb2f727e152a4b4fb9b154398abc1b9a5fe0b599f1027d7a"
# ------------------------------------------------------------------------------

set -o pipefail
umask 077
if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then export LC_ALL=C.UTF-8; fi

WORKDIR="/root/oracle-reinstaller"
LOG_FILE="/var/log/oracle-reinstaller.log"
REINSTALL_SH="$WORKDIR/reinstall.sh"
REINSTALL_URLS=(
    "https://raw.githubusercontent.com/bin456789/reinstall/${REINSTALL_REF}/reinstall.sh"
    "https://cnb.cool/bin456789/reinstall/-/git/raw/${REINSTALL_REF}/reinstall.sh"
)

# Opciones (se pueden pasar por línea de comandos)
OPT_PASSWORD=""
OPT_SSH_KEY=""
OPT_SSH_PORT=""
OPT_WEB_PORT=""
OPT_MINIMAL=""
OPT_UBU_VER=""
OPT_NO_REBOOT=0
OPT_DRY_RUN=0
OPT_YES=0
OPT_WIPE_CONFIRMED=0
OPT_SKIP_BACKUP=0
OPT_TZ=""
OPT_SWAP_MB=""
OPT_DOCKER=""
OPT_GO=""
OPT_UFW=""
OPT_PANEL_CMD=""

# ------------------------------------------------------------------------------
#  Utilidades de interfaz
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C0=$'\e[0m'; CB=$'\e[1m'; CR=$'\e[31m'; CG=$'\e[32m'; CY=$'\e[33m'
    CBL=$'\e[34m'; CC=$'\e[36m'; CD=$'\e[2m'
else
    C0=""; CB=""; CR=""; CG=""; CY=""; CBL=""; CC=""; CD=""
fi

HAS_TTY=0
{ : </dev/tty; } 2>/dev/null && HAS_TTY=1

log()  { (( OPT_DRY_RUN )) && return 0; printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
info() { printf '%s\n' "${CBL}[i]${C0} $*"; log "INFO $*"; }
ok()   { printf '%s\n' "${CG}[✓]${C0} $*"; log "OK   $*"; }
warn() { printf '%s\n' "${CY}[!]${C0} $*"; log "WARN $*"; }
err()  { printf '%s\n' "${CR}[✗]${C0} $*" >&2; log "ERR  $*"; }
die()  { err "$*"; exit 1; }
kv()   { local w=$1 k=$2 v=$3 pad; pad=$(( w - ${#k} )); (( pad < 1 )) && pad=1; printf '  %s%*s%b\n' "$k" "$pad" "" "$v"; }
line() { printf '%s\n' "${CD}──────────────────────────────────────────────────────────────${C0}"; }

to_tty() { if (( HAS_TTY )); then printf '%s' "$*" >/dev/tty; else printf '%s' "$*" >&2; fi; }

# ask "Pregunta" "valor_por_defecto"  -> imprime la respuesta
ask() {
    local q=$1 def=${2:-} ans=""
    if (( OPT_YES )) || (( ! HAS_TTY )); then printf '%s' "$def"; return; fi
    if [[ -n $def ]]; then to_tty "${CY}?${C0} $q [${CB}$def${C0}]: "; else to_tty "${CY}?${C0} $q: "; fi
    IFS= read -r ans </dev/tty || ans=""
    printf '%s' "${ans:-$def}"
}

# ask_secret "Pregunta" -> sin eco
ask_secret() {
    local q=$1 ans=""
    (( HAS_TTY )) || { printf ''; return; }
    to_tty "${CY}?${C0} $q: "
    IFS= read -rs ans </dev/tty || ans=""
    to_tty $'\n'
    printf '%s' "$ans"
}

# ask_yn "Pregunta" s|n  -> retorna 0 (sí) o 1 (no)
ask_yn() {
    local q=$1 def=${2:-n} ans hint
    [[ $def == s ]] && hint="S/n" || hint="s/N"
    if (( OPT_YES )) || (( ! HAS_TTY )); then [[ $def == s ]]; return; fi
    while :; do
        to_tty "${CY}?${C0} $q [$hint]: "
        IFS= read -r ans </dev/tty || ans=""
        ans=${ans:-$def}
        case ${ans,,} in
            s|si|sí|y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
    done
}

pause() { (( OPT_YES || ! HAS_TTY )) && return; to_tty "${CD}Presiona ENTER para continuar...${C0}"; read -r _ </dev/tty || true; }

banner() {
    (( OPT_YES )) || clear 2>/dev/null || true
    printf '%s\n' "${CC}${CB}"
    printf '%s\n' "  ╔══════════════════════════════════════════════════════════╗"
    printf '%s\n' "  ║           MULTI-ARCH REINSTALLER PRO  ·  v$VERSION          ║"
    printf '%s\n' "  ║       Ubuntu LTS  ·  ARM64  ·  AMD64 / Intel 64            ║"
    printf '%s\n' "  ╚══════════════════════════════════════════════════════════╝"
    printf '%s\n' "${C0}"
}

# ------------------------------------------------------------------------------
#  Detección del sistema
# ------------------------------------------------------------------------------
need_root() { [[ $EUID -eq 0 ]] || die "Ejecuta como root:  sudo -i  y luego vuelve a correr el script."; }

arch_raw()  { uname -m; }
is_arm64()  { [[ $(arch_raw) == aarch64 || $(arch_raw) == arm64 ]]; }
is_x86_64() { [[ $(arch_raw) == x86_64 || $(arch_raw) == amd64 ]]; }
is_supported_arch() { is_arm64 || is_x86_64; }

cpu_vendor() {
    local vendor=""
    if command -v lscpu >/dev/null 2>&1; then
        vendor=$(lscpu 2>/dev/null | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
    fi
    [[ -n $vendor ]] || vendor=$(awk -F: '/vendor_id/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    case $vendor in
        AuthenticAMD) echo "AMD" ;;
        GenuineIntel) echo "Intel" ;;
        *)
            if is_arm64; then echo "ARM / Ampere u otro ARM64";
            elif [[ -n $vendor ]]; then echo "$vendor";
            else echo "No identificado"; fi
            ;;
    esac
}

arch_label() {
    if is_arm64; then echo "ARM64 / AArch64";
    elif is_x86_64; then echo "AMD64 / x86_64 ($(cpu_vendor))";
    else echo "$(arch_raw) (no compatible)"; fi
}
boot_mode() { [[ -d /sys/firmware/efi ]] && echo UEFI || echo BIOS; }

virt_type() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt 2>/dev/null || echo none
    elif [[ -f /proc/user_beancounters ]]; then echo openvz
    else echo desconocido; fi
}

is_oracle_cloud() {
    grep -qi 'OracleCloud' /sys/class/dmi/id/chassis_asset_tag 2>/dev/null && return 0
    grep -qi 'Oracle' /sys/class/dmi/id/sys_vendor 2>/dev/null && return 0
    return 1
}

os_pretty() { ( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-desconocido}" ) || echo desconocido; }
os_id()     { ( . /etc/os-release 2>/dev/null && echo "${ID:-}" ); }
os_ver()    { ( . /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}" ); }
is_ubuntu_2404() { [[ $(os_id) == ubuntu && $(os_ver) == 24.04 ]]; }
is_ubuntu_lts()  { [[ $(os_id) == ubuntu && $(os_ver) =~ ^(20|22|24|26)\.04$ ]]; }

UBU_VERSIONS=(20.04 22.04 24.04 26.04)
ubu_label() {
    case $1 in
        20.04) echo "Ubuntu 20.04 LTS  (soporte estándar terminado en 2025 · solo si tu panel lo exige)" ;;
        22.04) echo "Ubuntu 22.04 LTS  (soporte hasta 2027 · muy compatible con paneles viejos)" ;;
        24.04) echo "Ubuntu 24.04 LTS  (soporte hasta 2029 · RECOMENDADO)" ;;
        26.04) echo "Ubuntu 26.04 LTS  (la más nueva · soporte hasta 2031)" ;;
    esac
}
valid_ubu_ver() { local v; for v in "${UBU_VERSIONS[@]}"; do [[ $1 == "$v" ]] && return 0; done; return 1; }

ram_mb()  { awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo; }
cpu_cnt() { nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo; }

disk_gb() {
    lsblk -bdno SIZE,TYPE 2>/dev/null | awk '$2=="disk"{ if ($1>m) m=$1 } END { printf "%d", m/1024/1024/1024 }'
}

private_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }

public_ip() {
    local u ipaddr
    for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ipaddr=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
        [[ $ipaddr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ipaddr"; return; }
    done
    echo "no-detectada"
}

current_ssh_port() {
    local p=""
    command -v sshd >/dev/null 2>&1 && p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    echo "${p:-22}"
}

secure_boot_on() {
    command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'
}

pkg_install() {
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=300 install "$@" >/dev/null 2>&1 || {
            apt-get -o DPkg::Lock::Timeout=300 update >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=300 install "$@" >/dev/null 2>&1
        }
    elif command -v dnf >/dev/null 2>&1; then dnf -y install "$@" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then yum -y install "$@" >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache "$@" >/dev/null 2>&1
    else return 1; fi
}

ensure_cmd() { # ensure_cmd comando paquete
    command -v "$1" >/dev/null 2>&1 && return 0
    info "Instalando dependencia: $2"
    pkg_install "$2" && command -v "$1" >/dev/null 2>&1
}

net_ok() { curl -fsS -o /dev/null --max-time 10 "$1" 2>/dev/null; }

show_system_info() {
    local oracle="no"; is_oracle_cloud && oracle="${CG}sí${C0}"
    line
    kv 19 "Sistema actual:" "$(os_pretty)"
    kv 19 "Kernel:" "$(uname -r)"
    kv 19 "Arquitectura:" "$(arch_label)"
    kv 19 "Fabricante CPU:" "$(cpu_vendor)"
    kv 19 "Arranque:" "$(boot_mode)"
    kv 19 "Virtualización:" "$(virt_type)"
    kv 19 "Oracle Cloud:" "$oracle"
    kv 19 "CPU / RAM:" "$(cpu_cnt) núcleos / $(ram_mb) MB"
    kv 19 "Disco mayor:" "$(disk_gb) GB"
    kv 19 "IP privada:" "$(private_ip)"
    kv 19 "IP pública:" "$PUBLIC_IP"
    kv 19 "Puerto SSH actual:" "$(current_ssh_port)"
    line
}

# ------------------------------------------------------------------------------
#  Contraseñas y validaciones
# ------------------------------------------------------------------------------
gen_password() {
    # 20 caracteres, sin caracteres confusos (0/O, 1/l/I), con mayúscula, minúscula y número
    local p
    while :; do
        p=$(LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom 2>/dev/null | head -c 20)
        [[ ${#p} -eq 20 && $p =~ [A-Z] && $p =~ [a-z] && $p =~ [0-9] ]] && { printf '%s' "$p"; return; }
    done
}

valid_password() {
    # Solo caracteres seguros para todos los pasos de instalación (sin espacios, comillas, $, \, `)
    [[ $1 =~ ^[A-Za-z0-9@#%_+=.!-]{10,64}$ ]] && [[ $1 =~ [A-Za-z] ]] && [[ $1 =~ [0-9] ]]
}

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

valid_ssh_key() {
    [[ $1 =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)\ [A-Za-z0-9+/=]{40,} ]] && return 0
    [[ $1 =~ ^(github|gh|gitlab|gl):[A-Za-z0-9._-]+$ ]] && return 0
    [[ $1 =~ ^https?://[^[:space:]]+$ ]] && return 0
    return 1
}

# ------------------------------------------------------------------------------
#  REINSTALACIÓN
# ------------------------------------------------------------------------------
preflight_reinstall() {
    info "Verificando requisitos..."
    local v; v=$(virt_type)
    case $v in
        openvz|lxc|lxc-libvirt|docker|podman|wsl)
            die "Virtualización '$v' no soportada (necesita KVM/máquina completa). Oracle Cloud usa KVM: si ves esto, no estás en una VM normal." ;;
    esac

    if is_arm64; then
        ok "Arquitectura ARM64 detectada ($(arch_raw)); CPU: $(cpu_vendor)"
    elif is_x86_64; then
        ok "Arquitectura AMD64/x86_64 detectada; fabricante CPU: $(cpu_vendor)"
        info "Compatibilidad para VPS y servidores AMD EPYC, Ryzen y AMD64; también Intel x86_64."
    else
        die "Arquitectura no compatible: $(arch_raw). Se requiere ARM64 (aarch64) o AMD64/x86_64."
    fi

    [[ $(boot_mode) == UEFI ]] && ok "Arranque UEFI" || warn "Arranque BIOS/Legacy detectado; verifica que el proveedor permita iniciar el entorno de reinstalación."

    if is_oracle_cloud; then ok "Oracle Cloud detectado"; else warn "No parece Oracle Cloud (se continuará igual)"; fi

    local r; r=$(ram_mb)
    (( r >= 1024 )) && ok "RAM: ${r} MB" || die "RAM insuficiente (${r} MB). Ubuntu necesita al menos 1024 MB para instalarse con este método."

    local d; d=$(disk_gb)
    (( d >= 10 )) && ok "Disco: ${d} GB" || die "Disco demasiado pequeño (${d} GB). Mínimo 10 GB."

    if secure_boot_on; then
        warn "Secure Boot está ACTIVADO. Puede impedir el arranque del entorno de reinstalación; desactívalo desde el panel del proveedor si fuera necesario."
    fi

    if ! command -v curl >/dev/null 2>&1; then
        (( OPT_DRY_RUN )) && die "Falta curl; --dry-run no instalará dependencias. Instala curl y repite."
        ensure_cmd curl curl || die "No se pudo instalar curl."
    fi
    (( OPT_DRY_RUN )) || ensure_cmd getopt util-linux || true

    net_ok "https://raw.githubusercontent.com" && ok "Conexión a GitHub" || warn "No hay conexión a GitHub (se probará el espejo)"
    net_ok "https://cloud-images.ubuntu.com"   && ok "Conexión a cloud-images.ubuntu.com" \
        || die "No hay conexión a cloud-images.ubuntu.com. Revisa DNS / salida a internet (Route Table e Internet Gateway de la VCN)."

    local free_mb; free_mb=$(df -Pm / | awk 'NR==2{print $4}')
    (( free_mb >= 1024 )) && ok "Espacio libre: ${free_mb} MB" || die "Se necesita al menos 1 GB libre en / para preparar la instalación (hay ${free_mb} MB)."
}

download_engine() {
    mkdir -p "$WORKDIR"; chmod 700 "$WORKDIR"
    command -v sha256sum >/dev/null 2>&1 || die "Falta sha256sum (coreutils); no se puede verificar el motor."
    local u actual
    for u in "${REINSTALL_URLS[@]}"; do
        info "Descargando motor fijado al commit ${REINSTALL_REF:0:12}..."
        if curl -fsSL --retry 3 --retry-delay 2 --max-time 60 -o "$REINSTALL_SH.tmp" "$u"; then
            actual=$(sha256sum "$REINSTALL_SH.tmp" | awk '{print $1}')
            if [[ $actual != "$REINSTALL_SHA256" ]]; then
                warn "SHA-256 incorrecto desde $u; se descarta el archivo."
                rm -f "$REINSTALL_SH.tmp"
                continue
            fi
            if ! head -c 2 "$REINSTALL_SH.tmp" | grep -q '#!' || ! grep -q 'bin456789' "$REINSTALL_SH.tmp" || ! bash -n "$REINSTALL_SH.tmp"; then
                warn "Motor no válido sintácticamente desde $u"
                rm -f "$REINSTALL_SH.tmp"
                continue
            fi
            # La suma autentica el upstream exacto. Adaptación local: password por entorno, no argv.
            if ! grep -q '^# MULTI_ARCH_REINSTALLER_PASSWORD_FD$' "$REINSTALL_SH.tmp"; then
                sed -i '/^# 第二遍扫描，处理参数$/i # MULTI_ARCH_REINSTALLER_PASSWORD_FD\nif [ "${REINSTALL_PASSWORD_FD:-}" = 3 ]; then IFS= read -r password <&3; unset REINSTALL_PASSWORD_FD; fi\n' "$REINSTALL_SH.tmp"
            fi
            bash -n "$REINSTALL_SH.tmp" || die "La adaptación local del motor no pasó bash -n."
            mv -f "$REINSTALL_SH.tmp" "$REINSTALL_SH"; chmod 700 "$REINSTALL_SH"
            ok "Motor autenticado por SHA-256 y adaptado ($(wc -l <"$REINSTALL_SH") líneas)"
            return 0
        fi
    done
    rm -f "$REINSTALL_SH.tmp"
    die "No se pudo descargar un motor con SHA-256 válido."
}

backup_menu() {
    if (( OPT_SKIP_BACKUP )); then warn "Copia omitida explícitamente (--skip-backup). Asegúrate de tener un respaldo externo."; return 0; fi
    ask_yn "¿Quieres hacer una COPIA DE SEGURIDAD antes de borrar todo?" s || return 0
    local ts dest paths=() p sugg=""
    ts=$(date +%Y%m%d-%H%M)
    mkdir -p "$WORKDIR/backups"
    dest="$WORKDIR/backups/backup-$ts.tar.gz"

    for p in /root /opt /etc/nginx /etc/x-ui /usr/local/etc /var/www /home /etc/ssh/sshd_config /etc/crontab /var/spool/cron; do
        [[ -e $p ]] && sugg+="$p "
    done
    info "Rutas detectadas: ${sugg:-ninguna}"
    local input; input=$(ask "Rutas a respaldar (separadas por espacio)" "$sugg")
    read -r -a paths <<<"$input"

    if command -v mysqldump >/dev/null 2>&1 && { systemctl is-active --quiet mysql || systemctl is-active --quiet mariadb; } 2>/dev/null; then
        if ask_yn "Se detectó MySQL/MariaDB. ¿Incluir volcado de TODAS las bases de datos?" s; then
            if mysqldump --all-databases --single-transaction --routines --events >"/var/tmp/mysql-$ts.sql" 2>>"$LOG_FILE"; then
                ok "Bases de datos volcadas"; paths+=("/var/tmp/mysql-$ts.sql")
            else
                warn "Falló el volcado de MySQL/MariaDB; no se continuará con un respaldo incompleto."
                rm -f "/var/tmp/mysql-$ts.sql"
                return 1
            fi
        fi
    fi

    (( ${#paths[@]} )) || { warn "No se eligieron rutas. Sin copia de seguridad."; return 0; }

    info "Creando $dest ..."
    if ! tar --exclude="$WORKDIR" --exclude='/root/.cache' --exclude='*.sock' \
           -czpf "$dest" "${paths[@]}" 2>>"$LOG_FILE"; then
        warn "Falló la creación del respaldo; se cancela para evitar borrar el único original."
        rm -f "$dest" "/var/tmp/mysql-$ts.sql"
        return 1
    fi
    if ! tar -tzf "$dest" >/dev/null 2>&1 || [[ ! -s $dest ]]; then
        warn "El respaldo no superó la verificación de integridad; se cancela la reinstalación."
        rm -f "$dest" "/var/tmp/mysql-$ts.sql"
        return 1
    fi
    ok "Copia creada y verificada: $dest ($(du -h "$dest" | cut -f1))"
    rm -f "/var/tmp/mysql-$ts.sql"

    printf '\n%s\n' "${CR}${CB}  ¡LA COPIA ESTÁ EN ESTE MISMO DISCO Y SE BORRARÁ AL REINSTALAR!${C0}"
    printf '%s\n'   "  Descárgala AHORA desde tu PC con:"
    printf '\n    %s\n\n' "${CC}scp -P $(current_ssh_port) root@${PUBLIC_IP}:${dest} .${C0}"
    printf '%s\n'   "  (o usa WinSCP / Termius / Bitvise SFTP con la misma ruta)"
    if (( OPT_YES )); then
        warn "Modo automático: el respaldo recién creado sigue en esta VPS. Descárgalo y vuelve a ejecutar, o usa --skip-backup si ya tienes una copia externa."
        return 1
    else
        local c=""
        while [[ ${c^^} != LISTO ]]; do
            c=$(ask "Escribe LISTO cuando hayas descargado la copia (SALTAR cancela la reinstalación)" "")
            if [[ ${c^^} == SALTAR ]]; then warn "Copia no confirmada; se cancela la reinstalación."; return 1; fi
        done
    fi
}

configure_reinstall() {
    line
    printf '%s\n\n' "${CB}  Configuración de la nueva instalación (Ubuntu $OPT_UBU_VER LTS)${C0}"

    # --- Autenticación ---
    local mode=""
    if [[ -n $OPT_SSH_KEY ]]; then mode=key
    elif [[ -n $OPT_PASSWORD ]]; then mode=manual
    elif (( OPT_YES )); then mode=auto
    else
        printf '%s\n' "  Acceso root:"
        printf '%s\n' "   1) Contraseña segura generada automáticamente (recomendado)"
        printf '%s\n' "   2) Contraseña manual"
        printf '%s\n' "   3) Solo clave SSH (sin contraseña)"
        case $(ask "Elige" "1") in 2) mode=manual ;; 3) mode=key ;; *) mode=auto ;; esac
    fi

    case $mode in
        auto) OPT_PASSWORD=$(gen_password); OPT_SSH_KEY="" ;;
        manual)
            while ! valid_password "$OPT_PASSWORD"; do
                [[ -n $OPT_PASSWORD ]] && err "Contraseña inválida."
                OPT_PASSWORD=""
                printf '%s\n' "  ${CD}10-64 caracteres, letras y números; símbolos permitidos: @ # % _ + = . ! -${C0}"
                (( HAS_TTY )) || die "Contraseña inválida y no hay terminal para pedir otra."
                local p1 p2
                p1=$(ask_secret "Nueva contraseña root")
                p2=$(ask_secret "Repite la contraseña")
                [[ $p1 == "$p2" ]] || { err "No coinciden, intenta de nuevo."; OPT_PASSWORD=""; continue; }
                OPT_PASSWORD=$p1
            done
            OPT_SSH_KEY="" ;;
        key)
            while ! valid_ssh_key "$OPT_SSH_KEY"; do
                [[ -n $OPT_SSH_KEY ]] && err "Clave SSH inválida."
                (( HAS_TTY )) || die "Clave SSH inválida."
                printf '%s\n' "  ${CD}Pega tu clave pública (ssh-ed25519 AAAA...), o github:usuario, o una URL${C0}"
                OPT_SSH_KEY=$(ask "Clave pública" "")
            done
            OPT_PASSWORD="" ;;
    esac

    # --- Puerto SSH ---
    while :; do
        [[ -z $OPT_SSH_PORT ]] && OPT_SSH_PORT=$(ask "Puerto SSH del nuevo sistema" "22")
        valid_port "$OPT_SSH_PORT" && break
        err "Puerto inválido: $OPT_SSH_PORT"; OPT_SSH_PORT=""; (( OPT_YES )) && die "Puerto SSH inválido."
    done
    [[ $OPT_SSH_PORT != 22 ]] && warn "Recuerda abrir el puerto TCP $OPT_SSH_PORT en la Security List / NSG de Oracle, o NO podrás entrar."

    # --- Puerto web de logs durante la instalación ---
    while :; do
        [[ -z $OPT_WEB_PORT ]] && OPT_WEB_PORT=$(ask "Puerto web para ver el progreso durante la instalación" "80")
        valid_port "$OPT_WEB_PORT" && break
        err "Puerto inválido"; OPT_WEB_PORT=""; (( OPT_YES )) && die "Puerto web inválido."
    done

    # --- Imagen ---
    # En ARM64 la imagen Minimal oficial solo existe desde Ubuntu 24.04
    if is_arm64 && [[ ${OPT_UBU_VER%%.*} -lt 24 ]]; then
        [[ $OPT_MINIMAL == 1 ]] && warn "Ubuntu $OPT_UBU_VER no tiene imagen Minimal para ARM64; se usará la estándar."
        OPT_MINIMAL=0
    fi
    if [[ -z $OPT_MINIMAL ]]; then
        printf '\n%s\n' "  Tipo de imagen:"
        printf '%s\n'   "   1) Ubuntu Server estándar (recomendado para paneles)"
        printf '%s\n'   "   2) Ubuntu Minimal (más liviana, menos herramientas)"
        [[ $(ask "Elige" "1") == 2 ]] && OPT_MINIMAL=1 || OPT_MINIMAL=0
    fi
}

choose_version() {
    if [[ -n $OPT_UBU_VER ]]; then
        valid_ubu_ver "$OPT_UBU_VER" || die "Versión no soportada: $OPT_UBU_VER (usa 20.04, 22.04, 24.04 o 26.04)"
    elif (( OPT_YES )); then
        OPT_UBU_VER=24.04
    else
        line
        printf '%s\n\n' "${CB}  ¿Qué versión de Ubuntu quieres instalar?${C0}"
        local i
        for i in "${!UBU_VERSIONS[@]}"; do
            printf '   %s) %s\n' "$((i+1))" "$(ubu_label "${UBU_VERSIONS[$i]}")"
        done
        echo
        local c
        while :; do
            c=$(ask "Elige" "3")
            [[ $c =~ ^[1-4]$ ]] && { OPT_UBU_VER=${UBU_VERSIONS[$((c-1))]}; break; }
            err "Opción inválida"
        done
    fi
    ok "Versión elegida: Ubuntu $OPT_UBU_VER LTS"
    [[ $OPT_UBU_VER == 20.04 ]] && warn "Ubuntu 20.04 ya no recibe actualizaciones de seguridad gratuitas. Úsalo solo si tu panel no funciona en 22.04/24.04."
    return 0
}

show_credentials() {
    printf '\n%s\n' "${CG}${CB}  ╔═══════════════════ GUARDA ESTOS DATOS ═══════════════════╗${C0}"
    kv 17 "IP:"       "$PUBLIC_IP"
    kv 17 "Usuario:"  "root"
    if [[ -n $OPT_PASSWORD ]]; then
        kv 17 "Contraseña:" "${CB}${CY}${OPT_PASSWORD}${C0}"
    else
        kv 17 "Acceso:" "solo clave SSH"
    fi
    kv 17 "Puerto SSH:" "$OPT_SSH_PORT"
    kv 17 "Sistema:"  "Ubuntu $OPT_UBU_VER LTS $([[ $OPT_MINIMAL == 1 ]] && echo Minimal || echo Server) ($(arch_raw))"
    kv 17 "Progreso:" "http://${PUBLIC_IP}:${OPT_WEB_PORT}  (solo durante la instalación)"
    printf '%s\n\n' "${CG}${CB}  ╚══════════════════════════════════════════════════════════╝${C0}"
}

run_reinstall() {
    need_root
    banner
    printf '%s\n' "${CR}${CB}  ⚠  ESTE PROCESO BORRA TODO EL DISCO DE LA VPS (todas las particiones).${C0}"
    printf '%s\n\n' "${CR}     Paneles, bases de datos, usuarios y archivos se perderán.${C0}"
    show_system_info
    preflight_reinstall
    echo
    choose_version
    if [[ $(os_id) == ubuntu && $(os_ver) == "$OPT_UBU_VER" ]]; then
        warn "Este servidor YA tiene Ubuntu $OPT_UBU_VER. Si solo quieres prepararlo, usa la opción 'Preparar servidor'."
        ask_yn "¿Reinstalar igualmente desde cero?" n || return 0
    fi
    if (( OPT_DRY_RUN )); then
        ok "Modo prueba: arquitectura, virtualización, RAM, disco, red y versión de Ubuntu verificados."
        info "No se creó backup, no se descargó el motor y no se preparó ni ejecutó la reinstalación."
        info "Este modo no valida credenciales, puertos ni disponibilidad real del motor."
        return 0
    fi
    backup_menu || { warn "Proceso cancelado: confirma que descargaste la copia externa antes de continuar."; return 0; }
    configure_reinstall
    download_engine

    local args=(ubuntu "$OPT_UBU_VER" --username root --ssh-port "$OPT_SSH_PORT" --web-port "$OPT_WEB_PORT")
    [[ -n $OPT_SSH_KEY  ]] && args+=(--ssh-key "$OPT_SSH_KEY")
    [[ $OPT_MINIMAL == 1 ]] && args+=(--minimal)

    show_credentials

    local shown="${args[*]}"
    [[ -n $OPT_PASSWORD ]] && shown=${shown//"$OPT_PASSWORD"/********}
    info "Comando: bash reinstall.sh $shown"

    if (( OPT_DRY_RUN )); then
        ok "Modo prueba (--dry-run): todo verificado, NO se ejecutó nada."
        return 0
    fi

    if (( ! OPT_WIPE_CONFIRMED )); then
        (( HAS_TTY )) || die "Se necesita confirmación en terminal (o usa --yes-wipe-disk)."
        echo
        printf '%s\n' "  Copia la contraseña y los datos de arriba en un lugar seguro."
        local c; c=$(ask "Para confirmar el BORRADO TOTAL escribe ${CR}BORRAR${C0}" "")
        [[ $c == BORRAR ]] || { warn "Cancelado. No se modificó nada."; return 0; }
    fi

    info "Preparando la instalación (esto todavía NO borra nada)..."
    log "Ejecutando reinstall.sh ${shown}"
    local rc=0
    if (( HAS_TTY )); then
        ( cd "$WORKDIR" && REINSTALL_PASSWORD_FD=3 bash "$REINSTALL_SH" "${args[@]}" 3<<<"$OPT_PASSWORD" </dev/tty ) 2>&1 | tee "$WORKDIR/engine.log"; rc=${PIPESTATUS[0]}
    else
        ( cd "$WORKDIR" && REINSTALL_PASSWORD_FD=3 bash "$REINSTALL_SH" "${args[@]}" 3<<<"$OPT_PASSWORD" ) 2>&1 | tee "$WORKDIR/engine.log"; rc=${PIPESTATUS[0]}
    fi
    chmod 600 "$WORKDIR/engine.log" 2>/dev/null

    if (( rc != 0 )); then
        err "El motor terminó con error (código $rc). Tu sistema actual NO fue modificado."
        err "Revisa el registro: $WORKDIR/engine.log"
        bash "$REINSTALL_SH" reset >/dev/null 2>&1 || true
        exit 1
    fi

    ok "Todo listo. Al reiniciar empieza la instalación automática."
    show_credentials
    printf '%s\n' "  ${CB}Qué pasa ahora:${C0}"
    printf '%s\n' "   1. La VPS se reinicia y descarga Ubuntu $OPT_UBU_VER (5 a 20 min)."
    printf '%s\n' "   2. Puedes ver el progreso en http://${PUBLIC_IP}:${OPT_WEB_PORT} o en la Consola Serial de Oracle."
    printf '%s\n' "   3. En tu PC borra la huella vieja:  ${CC}ssh-keygen -R ${PUBLIC_IP}${C0}"
    printf '%s\n' "   4. Entra:  ${CC}ssh -p ${OPT_SSH_PORT} root@${PUBLIC_IP}${C0}"
    printf '%s\n' "   5. Corre de nuevo este script y elige 'Preparar servidor' y luego 'Instalar mi panel'."
    echo

    if (( OPT_NO_REBOOT )); then
        warn "No se reinició (--no-reboot). Reinicia con:  reboot"
        warn "Para CANCELAR antes de reiniciar:  bash $REINSTALL_SH reset"
        return 0
    fi

    trap 'echo; warn "Reinicio cancelado. Para anular la reinstalación ejecuta:  bash '"$REINSTALL_SH"' reset"; exit 0' INT
    local i
    for (( i=15; i>0; i-- )); do
        printf '\r  %s' "${CY}Reiniciando en ${i}s... (Ctrl+C para cancelar)${C0}  "
        sleep 1
    done
    trap - INT
    echo
    log "Reiniciando para reinstalar"
    sync; reboot
}

# ------------------------------------------------------------------------------
#  POST-INSTALACIÓN (en el Ubuntu recién instalado)
# ------------------------------------------------------------------------------
APT_OPTS=(-y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

apt_run() {
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 apt-get "${APT_OPTS[@]}" "$@"
}

wait_first_boot() {
    if command -v cloud-init >/dev/null 2>&1; then
        info "Esperando a que termine la configuración inicial del sistema (cloud-init)..."
        timeout 600 cloud-init status --wait >/dev/null 2>&1 || true
    fi
    local n=0
    while pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1 && (( n < 120 )); do
        (( n == 0 )) && info "Esperando a que terminen actualizaciones automáticas en segundo plano..."
        sleep 5; ((n++))
    done
}

post_update() {
    info "Actualizando el sistema (puede tardar unos minutos)..."
    apt_run update >>"$LOG_FILE" 2>&1 || die "Falló 'apt update'. Revisa la conexión. Log: $LOG_FILE"
    apt_run full-upgrade >>"$LOG_FILE" 2>&1 || warn "La actualización tuvo advertencias (ver $LOG_FILE)"
    ok "Sistema actualizado"
}

post_packages() {
    info "Instalando herramientas base..."
    local pk=(curl wget git unzip zip tar jq htop nano vim ca-certificates gnupg lsb-release
              software-properties-common net-tools dnsutils iproute2 iputils-ping cron socat
              build-essential sqlite3 bash-completion screen tmux rsync psmisc lsof iptables
              chrony)
    if ! apt_run install "${pk[@]}" >>"$LOG_FILE" 2>&1; then
        # Si falla el lote, se instala uno por uno para no perder los demás
        local x miss=()
        for x in "${pk[@]}"; do apt_run install "$x" >>"$LOG_FILE" 2>&1 || miss+=("$x"); done
        (( ${#miss[@]} )) && warn "No se pudieron instalar: ${miss[*]}"
    fi
    systemctl enable --now cron >/dev/null 2>&1 || true
    systemctl enable --now chrony >/dev/null 2>&1 || true
    ok "Herramientas base instaladas"
}

post_timezone() {
    local tz=${OPT_TZ:-$(ask "Zona horaria" "$DEFAULT_TZ")}
    if [[ -n $tz && -f /usr/share/zoneinfo/$tz ]]; then
        timedatectl set-timezone "$tz" 2>/dev/null || { ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime; echo "$tz" >/etc/timezone; }
        ok "Zona horaria: $tz ($(date '+%H:%M'))"
    else
        warn "Zona horaria '$tz' no existe; no se cambió"
    fi
}

post_swap() {
    if [[ -n $(swapon --show --noheadings 2>/dev/null) ]]; then ok "Swap ya existe"; return; fi
    local mb=${OPT_SWAP_MB:-$(ask "Tamaño de swap en MB (0 = no crear)" "$DEFAULT_SWAP_MB")}
    [[ $mb =~ ^[0-9]+$ ]] || { warn "Valor inválido, no se crea swap"; return; }
    (( mb == 0 )) && { info "Sin swap"; return; }
    local free_mb; free_mb=$(df -Pm / | awk 'NR==2{print $4}')
    (( free_mb > mb + 2048 )) || { warn "Poco espacio en disco, no se crea swap"; return; }
    fallocate -l "${mb}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    ok "Swap de ${mb} MB creada"
}

post_tuning() {
    info "Optimizando red y límites del kernel (BBR, conexiones, archivos abiertos)..."
    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true
    printf '%s\n' tcp_bbr nf_conntrack >/etc/modules-load.d/multi-arch-reinstaller.conf

    cat >/etc/sysctl.d/99-multi-arch-reinstaller.conf <<'EOF'
# --- Generado por Multi-Arch Reinstaller PRO ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_watches = 524288
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 1048576
vm.swappiness = 10
EOF
    sysctl --system >>"$LOG_FILE" 2>&1 || true

    cat >/etc/security/limits.d/99-multi-arch-reinstaller.conf <<'EOF'
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    mkdir -p /etc/systemd/system.conf.d
    printf '[Manager]\nDefaultLimitNOFILE=1048576\n' >/etc/systemd/system.conf.d/99-multi-arch-reinstaller.conf
    systemctl daemon-reexec 2>/dev/null || true

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; then ok "BBR activo"; else warn "BBR no se activó (se activará tras reiniciar)"; fi
    ok "Kernel optimizado para muchas conexiones"
}

post_ssh() {
    # Mantiene vivas las conexiones y acepta muchos logins simultáneos (paneles SSH)
    command -v sshd >/dev/null 2>&1 || { warn "OpenSSH server no encontrado, se omite"; return 0; }
    mkdir -p /etc/ssh/sshd_config.d
    cat >/etc/ssh/sshd_config.d/90-multi-arch-reinstaller.conf <<'EOF'
ClientAliveInterval 60
ClientAliveCountMax 5
MaxStartups 100:30:200
UseDNS no
EOF
    if sshd -t 2>>"$LOG_FILE"; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        ok "SSH optimizado (puerto $(current_ssh_port))"
    else
        rm -f /etc/ssh/sshd_config.d/90-multi-arch-reinstaller.conf
        warn "Configuración SSH revertida (no pasó la validación)"
    fi
}

post_docker() {
    local want=${OPT_DOCKER}
    if [[ -z $want ]]; then
        ask_yn "¿Instalar Docker? (necesario para Evolution API y muchos paneles)" s && want=1 || want=0
    fi
    [[ $want == 1 ]] || return 0
    if command -v docker >/dev/null 2>&1; then ok "Docker ya instalado: $(docker --version)"; return; fi
    info "Instalando Docker (repositorio oficial)..."
    if curl -fsSL https://get.docker.com -o "$WORKDIR/get-docker.sh" && sh "$WORKDIR/get-docker.sh" >>"$LOG_FILE" 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1
        ok "Docker instalado: $(docker --version 2>/dev/null)"
    else
        warn "No se pudo instalar Docker (ver $LOG_FILE)"
    fi
}

post_go() {
    local want=${OPT_GO}
    if [[ -z $want ]]; then
        ask_yn "¿Instalar Go (Golang) última versión? (para compilar paneles hechos en Go)" n && want=1 || want=0
    fi
    [[ $want == 1 ]] || return 0
    local garch
    case $(arch_raw) in aarch64|arm64) garch=arm64 ;; x86_64|amd64) garch=amd64 ;; *) warn "Arquitectura no soportada para Go"; return ;; esac
    local ver; ver=$(curl -fsSL --max-time 15 'https://go.dev/VERSION?m=text' 2>/dev/null | head -n1)
    [[ $ver =~ ^go[0-9]+\.[0-9]+ ]] || { warn "No se pudo obtener la versión de Go"; return; }
    local tmpdir; tmpdir=$(mktemp -d "$WORKDIR/go-install.XXXXXX") || { warn "No se pudo crear directorio temporal"; return; }
    info "Descargando y validando $ver ($garch)..."
    if ! curl -fsSL --retry 3 --max-time 180 -o "$tmpdir/go.tgz" "https://go.dev/dl/${ver}.linux-${garch}.tar.gz" ||
       ! tar -tzf "$tmpdir/go.tgz" >/dev/null 2>&1 ||
       ! tar -xzf "$tmpdir/go.tgz" -C "$tmpdir" ||
       [[ ! -x "$tmpdir/go/bin/go" ]]; then
        rm -rf "$tmpdir"
        warn "Descarga o validación de Go falló; se conservó la instalación anterior."
        return
    fi
    local olddir="$WORKDIR/go.previous"
    rm -rf "$olddir"
    if [[ -d /usr/local/go ]]; then
        mv /usr/local/go "$olddir" || { rm -rf "$tmpdir"; warn "No se pudo respaldar Go anterior"; return; }
    fi
    if mv "$tmpdir/go" /usr/local/go; then
        rm -rf "$olddir" "$tmpdir"
        printf 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin\n' >/etc/profile.d/golang.sh
        ok "Go instalado: $(/usr/local/go/bin/go version) (abre una nueva sesión SSH para usarlo)"
    else
        [[ -d "$olddir" ]] && mv "$olddir" /usr/local/go
        rm -rf "$tmpdir"
        warn "No se pudo activar la nueva versión; se restauró Go anterior."
    fi
}
post_firewall() {
    local want=${OPT_UFW}
    printf '\n%s\n' "  ${CD}Nota: en Oracle el bloqueo principal es la Security List / NSG de la VCN.${C0}"
    printf '%s\n'   "  ${CD}El Ubuntu instalado por este script NO trae reglas iptables que bloqueen puertos.${C0}"
    if [[ -z $want ]]; then
        ask_yn "¿Activar firewall UFW en el servidor? (si no estás seguro, responde NO)" n && want=1 || want=0
    fi
    [[ $want == 1 ]] || { ok "Firewall local sin activar (todos los puertos abiertos a nivel servidor)"; return 0; }
    apt_run install ufw >>"$LOG_FILE" 2>&1
    local sp; sp=$(current_ssh_port)
    ufw allow "${sp}/tcp" >/dev/null
    local ports; ports=$(ask "Puertos extra a abrir (ej: 80 443 8080 7300/udp)" "80 443")
    local p
    for p in $ports; do
        [[ $p =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]] && ufw allow "$p" >/dev/null && info "Abierto: $p"
    done
    ufw --force enable >/dev/null && ok "UFW activo (SSH $sp siempre permitido)"
}

run_post() {
    need_root
    banner
    is_ubuntu_lts || { warn "Este sistema es $(os_pretty), no un Ubuntu LTS soportado (20.04/22.04/24.04/26.04)."; ask_yn "¿Continuar igualmente?" n || return 0; }
    mkdir -p "$WORKDIR"
    show_system_info
    wait_first_boot
    post_update
    post_packages
    post_timezone
    post_swap
    post_tuning
    post_ssh
    post_docker
    post_go
    post_firewall
    echo; line
    ok "Servidor preparado."
    if [[ -f /var/run/reboot-required ]]; then
        warn "Se actualizó el kernel: conviene reiniciar antes de instalar el panel."
        if ask_yn "¿Reiniciar ahora?" n; then sync; reboot; exit 0; fi
    fi
    if ask_yn "¿Instalar tu panel ahora?" s; then run_panel || true; fi
}

# ------------------------------------------------------------------------------
#  INSTALAR PANEL
# ------------------------------------------------------------------------------
run_panel() {
    need_root
    local cmd=${OPT_PANEL_CMD:-$PANEL_INSTALL_CMD}
    if [[ -z $cmd ]]; then
        (( HAS_TTY )) || { warn "No hay comando de panel configurado (edita PANEL_INSTALL_CMD o usa --panel-cmd)."; return 1; }
        printf '\n%s\n' "  Pega el comando de instalación de tu panel"
        printf '%s\n'   "  ${CD}(ej: bash <(curl -fsSL https://raw.githubusercontent.com/usuario/repo/main/install.sh))${C0}"
        cmd=$(ask "Comando" "")
        [[ -n $cmd ]] || { warn "Sin comando, se omite."; return 0; }
    fi
    info "Ejecutando instalador del panel..."
    log "PANEL: $cmd"
    if (( HAS_TTY )); then bash -c "$cmd" </dev/tty; else bash -c "$cmd"; fi
    local rc=$?
    (( rc == 0 )) && ok "Instalador del panel terminó correctamente" || err "El instalador del panel terminó con código $rc"
    return $rc
}

# ------------------------------------------------------------------------------
#  DIAGNÓSTICO
# ------------------------------------------------------------------------------
run_info() {
    banner
    show_system_info
    kv 19 "Swap:" "$(free -m | awk '/^Swap:/{print $2" MB"}')"
    kv 19 "Control TCP:" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    kv 19 "Docker:" "$(docker --version 2>/dev/null || echo no)"
    local gov; gov=$( { /usr/local/go/bin/go version || go version; } 2>/dev/null | head -1)
    kv 19 "Go:" "${gov:-no}"
    kv 19 "UFW:" "$(ufw status 2>/dev/null | head -1 || echo no instalado)"
    kv 19 "Zona horaria:" "$(timedatectl show -p Timezone --value 2>/dev/null)"
    kv 19 "Uptime:" "$(uptime -p 2>/dev/null)"
    kv 19 "Puertos en uso:" "$(ss -Htlnp 2>/dev/null | awk '{split($4,a,":"); print a[length(a)]}' | sort -nu | tr '\n' ' ')"
    line
}

# ------------------------------------------------------------------------------
#  MENÚ / ARGUMENTOS
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Multi-Arch Reinstaller PRO v$VERSION

USO:  bash $0 [comando] [opciones]

COMANDOS
  (ninguno)      Menú interactivo
  reinstall      Reinstalar Ubuntu LTS a elección (BORRA TODO EL DISCO)
  post           Preparar el Ubuntu recién instalado (actualizar, optimizar, Docker...)
  panel          Ejecutar el instalador de tu panel
  info           Diagnóstico del servidor
  cancel         Anular una reinstalación preparada (antes de reiniciar)

OPCIONES DE REINSTALACIÓN
  --ubuntu VER         Versión: 20.04, 22.04, 24.04 o 26.04 (por defecto se pregunta)
  La contraseña se solicita sin eco; no se admite --password en argumentos CLI.
  --ssh-key CLAVE      Clave pública SSH, github:usuario o URL (sin contraseña)
  --ssh-port N         Puerto SSH del nuevo sistema (por defecto 22)
  --web-port N         Puerto web para ver el progreso (por defecto 80)
  --minimal            Usar Ubuntu Minimal
  --no-reboot          Preparar pero no reiniciar
  --dry-run            Solo preflight; no crea backup ni descarga el motor
  --yes                Aceptar valores por defecto en las preguntas
  --yes-wipe-disk      Saltar la confirmación BORRAR (¡peligroso!)
  --skip-backup        Omitir el backup local (solo si ya tienes copia externa)

OPCIONES DE POST-INSTALACIÓN
  --timezone ZONA      Ej: America/Asuncion
  --swap MB            Tamaño de swap (0 = sin swap)
  --docker | --no-docker
  --go | --no-go
  --ufw | --no-ufw
  --panel-cmd "CMD"    Comando de instalación de tu panel

EJEMPLOS
  bash $0 reinstall --ssh-port 22 --dry-run
  bash $0 reinstall --ubuntu 22.04
  bash $0 post --yes --docker --timezone America/Asuncion
EOF
}

main_menu() {
    while :; do
        banner
        printf '  %s\n' "Sistema: $(os_pretty) · $(arch_raw) · IP $PUBLIC_IP"
        echo
        if is_ubuntu_lts; then
            printf '  %s\n' "${CG}Ubuntu $(os_ver) detectado: si está recién instalado, siguiente paso → opción 2${C0}"
            echo
        fi
        printf '  %s\n' "${CB}1)${C0} Reinstalar Ubuntu (20.04 / 22.04 / 24.04 / 26.04)   ${CR}(borra todo)${C0}"
        printf '  %s\n' "${CB}2)${C0} Preparar servidor (post-instalación)"
        printf '  %s\n' "${CB}3)${C0} Instalar mi panel"
        printf '  %s\n' "${CB}4)${C0} Diagnóstico del sistema"
        printf '  %s\n' "${CB}5)${C0} Cancelar una reinstalación pendiente"
        printf '  %s\n' "${CB}0)${C0} Salir"
        echo
        case $(ask "Elige una opción" "") in
            1) run_reinstall; pause ;;
            2) run_post; pause ;;
            3) run_panel; pause ;;
            4) run_info; pause ;;
            5) run_cancel; pause ;;
            0|q|Q) exit 0 ;;
        esac
    done
}

run_cancel() {
    need_root
    if [[ -f $REINSTALL_SH ]]; then
        bash "$REINSTALL_SH" reset && ok "Reinstalación anulada. Puedes reiniciar sin peligro."
    else
        warn "No hay ninguna reinstalación preparada por este script."
    fi
}

parse_args() {
    CMD=""
    while (( $# )); do
        case $1 in
            reinstall|post|panel|info|cancel|menu) CMD=$1 ;;
            --password) die "Por seguridad, no pases contraseñas por argumentos CLI. Usa el menú interactivo." ;;
            --ssh-key)    OPT_SSH_KEY=${2:-}; shift ;;
            --ssh-port)   OPT_SSH_PORT=${2:-}; shift ;;
            --web-port)   OPT_WEB_PORT=${2:-}; shift ;;
            --minimal)    OPT_MINIMAL=1 ;;
            --ubuntu)     OPT_UBU_VER=${2:-}; shift ;;
            --no-reboot)  OPT_NO_REBOOT=1 ;;
            --dry-run)    OPT_DRY_RUN=1 ;;
            --yes|-y)     OPT_YES=1 ;;
            --yes-wipe-disk) OPT_WIPE_CONFIRMED=1 ;;
            --skip-backup) OPT_SKIP_BACKUP=1 ;;
            --timezone)   OPT_TZ=${2:-}; shift ;;
            --swap)       OPT_SWAP_MB=${2:-}; shift ;;
            --docker)     OPT_DOCKER=1 ;;
            --no-docker)  OPT_DOCKER=0 ;;
            --go)         OPT_GO=1 ;;
            --no-go)      OPT_GO=0 ;;
            --ufw)        OPT_UFW=1 ;;
            --no-ufw)     OPT_UFW=0 ;;
            --panel-cmd)  OPT_PANEL_CMD=${2:-}; shift ;;
            -h|--help)    usage; exit 0 ;;
            -v|--version) echo "$VERSION"; exit 0 ;;
            *) err "Opción desconocida: $1"; usage; exit 1 ;;
        esac
        shift
    done
    if [[ -n $OPT_PASSWORD && -n $OPT_SSH_KEY ]]; then
        die "Usa --password O --ssh-key, no ambos (el motor no permite los dos a la vez)."
    fi
    if [[ -n $OPT_PASSWORD ]] && ! valid_password "$OPT_PASSWORD"; then
        die "La contraseña de --password no es válida (10-64, letras+números, símbolos @#%_+=.!-)."
    fi
}

main() {
    parse_args "$@"
    if (( ! OPT_DRY_RUN )); then
        touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null
        command -v curl >/dev/null 2>&1 || { [[ $EUID -eq 0 ]] && ensure_cmd curl curl; }
    fi
    PUBLIC_IP=$(public_ip)
    case ${CMD:-menu} in
        reinstall) run_reinstall ;;
        post)      run_post ;;
        panel)     run_panel ;;
        info)      run_info ;;
        cancel)    run_cancel ;;
        menu)      (( HAS_TTY )) || { usage; exit 1; }; need_root; main_menu ;;
    esac
}

main "$@"
