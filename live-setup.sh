#!/usr/bin/env bash
#
# live-setup.sh — Prepara un Arch Linux live (archiso) para trabajar en consola:
#
#   · kmscon en todas las TTY, en lugar de agetty
#   · Fuente JetBrains Mono en kmscon (DejaVu Sans Mono como respaldo)
#   · tmux
#   · Teclado en español en la consola y en kmscon
#     (el idioma del sistema NO se toca: sigue en inglés)
#
# Uso (como root, que en el live ya lo eres):
#   bash live-setup.sh [--dry-run] [--font-size N] [--allow-installed]
#
#   --dry-run          Comprueba todo y enseña lo que haría, sin cambiar nada.
#   --font-size N      Tamaño de letra de kmscon (8-48, por defecto 16).
#   --allow-installed  Permite usarlo en un Arch instalado (no usa 'pacman -Sy').
#
# Garantías:
#   · No cambia ninguna configuración hasta haber comprobado que todo está en
#     orden y que lo instalado funciona.
#   · Escribe los archivos de forma atómica y guarda copia de cada uno
#     (*.bak-live-setup-FECHA).
#   · Si algo falla: dice qué comando falló, en qué línea y por qué, deshace
#     los cambios de configuración y deja el registro completo en /tmp.
#   · Los paquetes que llegue a instalar se quedan (no rompen nada).
#   · Nunca ejecuta 'pacman -Syu' en el live: actualizaría el kernel y el live
#     se quedaría sin módulos.
#   · Nunca para una TTY en la que haya una sesión abierta.

# ---------------------------------------------------------------------------
# Guardas iniciales (sintaxis POSIX: tienen que funcionar aunque no sea bash)
# ---------------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: este script necesita bash. Ejecútalo así: bash $0" >&2
    exit 1
fi

# Cargado con 'source', el 'set -e' de abajo podría cerrarte la terminal.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
    echo "ERROR: no lo cargues con 'source'; ejecútalo: bash ${BASH_SOURCE[0]}" >&2
    # shellcheck disable=SC2317  # 'exit' solo se alcanza si 'return' no es válido aquí
    return 1 2>/dev/null || exit 1
fi

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "ERROR: se necesita bash 4.4 o superior (tienes $BASH_VERSION)" >&2
    exit 1
fi

set -Eeuo pipefail          # para ante errores, variables sin definir y fallos en tuberías
shopt -s inherit_errexit    # ... también dentro de $( )
shopt -s nullglob           # un patrón sin coincidencias da lista vacía, no el texto literal
umask 022
export LC_ALL=C             # salida de los comandos estable para poder analizarla
export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin
cd / || exit 1

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME=live-setup
readonly KEYMAP=es                      # teclado de la consola del kernel (agetty)
readonly XKB_LAYOUT=es                  # teclado dentro de kmscon
readonly FONT_NAME="JetBrains Mono"
readonly -a PACKAGES=(tmux kmscon fontconfig pango ttf-jetbrains-mono ttf-dejavu)
readonly COW_MIN_FREE_MIB=1024          # espacio libre mínimo en la capa de escritura del live
readonly RAM_RESERVE_MIB=768            # RAM que nunca se cede al ampliar esa capa
readonly KMSCON_CONF=/etc/kmscon/kmscon.conf
readonly AUTOVT_LINK=/etc/systemd/system/autovt@.service
readonly COWSPACE=/run/archiso/cowspace
TS=$(date +%Y%m%d-%H%M%S)
readonly TS

KMSCON_UNIT=/usr/lib/systemd/system/kmsconvt@.service   # se confirma tras instalar
FONT_SIZE=16
DRY_RUN=0
ALLOW_INSTALLED=0
IS_LIVE=0
COMMITTED=0
FONT_ENGINE=""
TEST_VT=""
LOG_FILE=""
TEE_PID=""
LOCK_FD=""
declare -a RB_ACTION=() RB_ARG1=() RB_ARG2=()   # pila de cambios para deshacer
declare -a TMP_PATHS=() BACKUPS=()
declare -A BACKED_UP=()

# ---------------------------------------------------------------------------
# Mensajes
# ---------------------------------------------------------------------------
log()  { local tag=$1; shift; printf '%s %s\n' "$tag" "$*" >&2; }
info() { log '[INFO]' "$@"; }
ok()   { log '[ OK ]' "$@"; }
warn() { log '[WARN]' "$@"; }
err()  { log '[FAIL]' "$@"; }
die()  { err "$@"; exit 1; }

# Ejecuta un comando enseñándolo antes; en --dry-run solo lo enseña.
run() {
    if (( DRY_RUN )); then
        printf '[DRY ]' >&2; printf ' %q' "$@" >&2; printf '\n' >&2
        return 0
    fi
    printf '[ RUN]' >&2; printf ' %q' "$@" >&2; printf '\n' >&2
    "$@"
}

usage() {
    cat <<'EOF'
Uso: bash live-setup.sh [opciones]

Configura el live de Arch con kmscon en todas las TTY, la fuente JetBrains Mono,
tmux y el teclado en español. El idioma del sistema no se toca.

Opciones:
  --dry-run          Comprueba todo y enseña lo que haría, sin cambiar nada.
  --font-size N      Tamaño de letra de kmscon (8-48, por defecto 16).
  --allow-installed  Permite usarlo en un Arch instalado (no usa 'pacman -Sy').
  -h, --help         Muestra esta ayuda.
EOF
}

# ---------------------------------------------------------------------------
# Errores, salida y deshacer cambios
# ---------------------------------------------------------------------------
on_err() {
    local rc=$1 line=$2 cmd=$3
    err "Ha fallado un comando (código de salida $rc) en la línea $line del script:"
    err "    $cmd"
    if (( ${#FUNCNAME[@]} > 1 )); then
        err "    dentro de: ${FUNCNAME[*]:1}"
    fi
}

rb_push() { RB_ACTION+=("$1"); RB_ARG1+=("${2:-}"); RB_ARG2+=("${3:-}"); }

rollback() {
    local n=${#RB_ACTION[@]} i a p b
    if (( n == 0 )); then
        return 0
    fi
    warn "Deshaciendo los cambios de configuración…"
    for (( i = n - 1; i >= 0; i-- )); do
        a=${RB_ACTION[i]}; p=${RB_ARG1[i]}; b=${RB_ARG2[i]}
        case $a in
            restore)
                if [[ $p == /* && $b == /* ]] && mv -fT -- "$b" "$p"; then
                    ok "Restaurado $p"
                else
                    err "No pude restaurar $p (la copia sigue en $b)"
                fi ;;
            remove)
                if [[ $p == /* && ( -f $p || -L $p ) ]]; then
                    if rm -f -- "$p"; then ok "Eliminado $p"; else err "No pude eliminar $p"; fi
                fi ;;
            enable)
                if systemctl enable -- "$p" >/dev/null 2>&1; then ok "Reactivado $p"; else err "No pude reactivar $p"; fi ;;
            disable)
                if systemctl disable -- "$p" >/dev/null 2>&1; then ok "Desactivado $p"; else err "No pude desactivar $p"; fi ;;
            stop)
                systemctl stop -- "$p" >/dev/null 2>&1 || true
                systemctl reset-failed -- "$p" >/dev/null 2>&1 || true
                ok "Parado $p" ;;
        esac
    done
    systemctl daemon-reload >/dev/null 2>&1 || err "Falló 'systemctl daemon-reload'"
    RB_ACTION=(); RB_ARG1=(); RB_ARG2=()
}

cleanup_tmp() {
    local p
    for p in "${TMP_PATHS[@]}"; do
        if [[ -n $p && $p == /* && ( -f $p || -L $p ) ]]; then
            rm -f -- "$p" || true
        fi
    done
}

on_exit() {
    local rc=$?
    trap - ERR
    trap '' INT TERM HUP    # que un segundo Ctrl+C no corte el deshacer a medias
    set +e
    local pending=${#RB_ACTION[@]}
    if (( rc != 0 && ! COMMITTED && ! DRY_RUN )); then
        rollback
    fi
    cleanup_tmp
    if (( rc != 0 )); then
        err "El script ha terminado con errores (código $rc)."
        if (( DRY_RUN || pending == 0 )); then
            err "No se había cambiado ninguna configuración."
        else
            err "Los cambios de configuración se han deshecho; el sistema queda como estaba."
        fi
    fi
    if [[ -n $LOG_FILE ]]; then
        info "Registro completo: $LOG_FILE"
    fi
    # Cierra la salida y espera a que 'tee' termine de escribir el registro.
    if [[ -n $TEE_PID ]]; then
        exec 1>&- 2>&-
        wait "$TEE_PID" 2>/dev/null || true
    fi
    exit "$rc"
}

trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT
trap 'die "Interrumpido (Ctrl+C)"' INT
trap 'die "Recibida la señal TERM"' TERM
trap 'die "Recibida la señal HUP (¿se ha cerrado la terminal?)"' HUP

# ---------------------------------------------------------------------------
# Archivos: copia de seguridad, escritura atómica y enlaces
# ---------------------------------------------------------------------------
# Guarda una copia de $1 (si existe) y anota cómo deshacer el cambio.
backup_path() {
    local path=${1:?backup_path: falta la ruta}
    if [[ $path != /* ]]; then die "backup_path: la ruta no es absoluta: '$path'"; fi
    if (( DRY_RUN )) || [[ -n ${BACKED_UP[$path]:-} ]]; then
        return 0
    fi
    if [[ -d $path && ! -L $path ]]; then die "$path es un directorio; no lo toco"; fi
    if [[ -e $path || -L $path ]]; then
        local bak="${path}.bak-${SCRIPT_NAME}-${TS}"
        if [[ -e $bak || -L $bak ]]; then die "Ya existe $bak; no lo sobrescribo"; fi
        cp -a --no-dereference -- "$path" "$bak"
        rb_push restore "$path" "$bak"
        BACKUPS+=("$bak")
    else
        rb_push remove "$path"
    fi
    BACKED_UP[$path]=1
}

# Escribe el contenido $2 en $1 de forma atómica (archivo temporal + mv).
write_file() {
    local path=${1:?write_file: falta la ruta} content=${2?write_file: falta el contenido} mode=${3:-644}
    local dir=${path%/*} name=${path##*/}
    if [[ $path != /* || -z $dir || -z $name ]]; then die "write_file: ruta no válida '$path'"; fi
    if [[ -d $path && ! -L $path ]]; then die "$path es un directorio; no lo toco"; fi
    if [[ -f $path && ! -L $path ]] && cmp -s -- "$path" <(printf '%s\n' "$content"); then
        ok "$path ya estaba correcto"
        return 0
    fi
    if (( DRY_RUN )); then
        info "[DRY ] Escribiría $path con este contenido:"
        printf '%s\n' "$content" | sed 's/^/        /' >&2
        return 0
    fi
    if [[ ! -d $dir ]]; then
        mkdir -p -- "$dir"
    fi
    local tmp
    tmp=$(mktemp "${dir}/.${name}.XXXXXX")
    TMP_PATHS+=("$tmp")
    printf '%s\n' "$content" >"$tmp"
    chmod -- "$mode" "$tmp"
    backup_path "$path"
    mv -fT -- "$tmp" "$path"
    ok "Escrito $path"
}

# Hace que $2 sea un enlace simbólico a $1, de forma atómica.
set_symlink() {
    local target=${1:?set_symlink: falta el destino} link=${2:?set_symlink: falta el enlace}
    if [[ $target != /* || $link != /* ]]; then die "set_symlink: las rutas deben ser absolutas"; fi
    if [[ -L $link && $(readlink -- "$link") == "$target" ]]; then
        ok "$link ya apuntaba a $target"
        return 0
    fi
    if [[ -d $link && ! -L $link ]]; then die "$link es un directorio; no lo toco"; fi
    if (( DRY_RUN )); then
        info "[DRY ] Enlazaría $link -> $target"
        return 0
    fi
    local tmp="${link}.tmp-${SCRIPT_NAME}-$$"
    if [[ -e $tmp || -L $tmp ]]; then die "Ya existe $tmp; no lo toco"; fi
    ln -s -- "$target" "$tmp"
    TMP_PATHS+=("$tmp")
    backup_path "$link"
    mv -fT -- "$tmp" "$link"
    ok "Enlace $link -> $target"
}

# ---------------------------------------------------------------------------
# Pasos
# ---------------------------------------------------------------------------
parse_args() {
    while (( $# > 0 )); do
        case $1 in
            --dry-run)         DRY_RUN=1 ;;
            --allow-installed) ALLOW_INSTALLED=1 ;;
            --font-size)
                if (( $# < 2 )); then die "--font-size necesita un número"; fi
                FONT_SIZE=$2; shift ;;
            --font-size=*)     FONT_SIZE=${1#*=} ;;
            -h|--help)         usage; exit 0 ;;
            *)                 die "Opción desconocida: '$1' (usa --help)" ;;
        esac
        shift
    done
}

require_root() {
    if (( EUID != 0 )); then
        die "Hay que ejecutarlo como root (en el live ya lo eres; si no: sudo bash $0)"
    fi
}

acquire_lock() {
    local dir=/run/lock
    if [[ ! -d $dir ]]; then dir=/run; fi
    local f="$dir/${SCRIPT_NAME}.lock"
    if [[ -L $f ]]; then die "$f es un enlace simbólico; no lo uso por seguridad"; fi
    exec {LOCK_FD}>>"$f"
    if ! flock -n "$LOCK_FD"; then
        die "Ya hay otra ejecución de este script en marcha"
    fi
}

setup_log() {
    LOG_FILE=$(mktemp --tmpdir --suffix=.log "${SCRIPT_NAME}.XXXXXX")
    exec > >(tee -a -- "$LOG_FILE") 2>&1
    TEE_PID=$!
}

preflight() {
    info "Comprobaciones previas…"

    if [[ ! -f /etc/arch-release ]]; then die "Esto no parece Arch Linux (no existe /etc/arch-release)"; fi

    local -a need=(pacman systemctl localectl journalctl systemd-detect-virt findmnt
                   mountpoint df flock mktemp ldd awk grep sed cmp readlink timeout
                   getent who pgrep find date cp mv ln rm chmod mkdir tail tee)
    local -a missing=()
    local c
    for c in "${need[@]}"; do
        if ! command -v "$c" >/dev/null 2>&1; then missing+=("$c"); fi
    done
    if (( ${#missing[@]} > 0 )); then die "Faltan comandos imprescindibles: ${missing[*]}"; fi

    if [[ ! -d /run/systemd/system ]]; then die "El sistema no ha arrancado con systemd; este script lo necesita"; fi
    if systemd-detect-virt --chroot >/dev/null 2>&1; then die "Estás dentro de un chroot; ejecútalo en el sistema arrancado"; fi

    if [[ -d /run/archiso ]] && mountpoint -q "$COWSPACE"; then
        IS_LIVE=1
        ok "Live de Arch detectado"
    elif (( ALLOW_INSTALLED )); then
        warn "No es un live: modo sistema instalado (no se ejecutará 'pacman -Sy')"
    else
        die "Esto no parece el live de Arch (no existe $COWSPACE). Si es un Arch instalado y lo quieres igualmente, usa --allow-installed"
    fi

    # Valida las opciones antes de escribirlas en ningún archivo.
    if [[ ! $FONT_SIZE =~ ^[0-9]{1,2}$ ]] || (( 10#$FONT_SIZE < 8 || 10#$FONT_SIZE > 48 )); then
        die "Tamaño de letra no válido: '$FONT_SIZE' (usa un número entre 8 y 48)"
    fi
    FONT_SIZE=$(( 10#$FONT_SIZE ))
    local v re_layout='^[A-Za-z0-9_-]+$' re_font='^[A-Za-z0-9 ._-]+$'
    for v in "$KEYMAP" "$XKB_LAYOUT"; do
        if [[ ! $v =~ $re_layout ]]; then die "Distribución de teclado no válida: '$v'"; fi
    done
    if [[ ! $FONT_NAME =~ $re_font ]]; then die "Nombre de fuente no válido: '$FONT_NAME'"; fi

    # Que la distribución de teclado exista de verdad.
    local keymaps="" found=""
    keymaps=$(localectl list-keymaps --no-pager 2>/dev/null) || keymaps=""
    if [[ -n $keymaps ]]; then
        if ! grep -Fxq -- "$KEYMAP" <<<"$keymaps"; then
            die "La distribución de teclado '$KEYMAP' no existe en este sistema"
        fi
    else
        found=$(find /usr/share/kbd/keymaps -name "${KEYMAP}.map*" -print -quit 2>/dev/null) || found=""
        if [[ -z $found ]]; then die "La distribución de teclado '$KEYMAP' no existe en este sistema"; fi
    fi
    ok "Opciones válidas (teclado '$KEYMAP', fuente '$FONT_NAME' a $FONT_SIZE pt)"

    # Hora: con el reloj mal fallan las firmas de pacman y los certificados.
    local ntp=""
    ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null) || ntp=""
    if [[ $ntp == no ]]; then
        warn "El reloj aún no está sincronizado; si pacman da errores de firma o de certificado, espera un minuto y repite"
    fi

    # Conexión.
    if timeout 15 getent hosts archlinux.org >/dev/null 2>&1; then
        ok "Hay conexión a internet"
    elif (( DRY_RUN )); then
        warn "No resuelvo archlinux.org: sin conexión, la instalación fallaría"
    else
        die "No hay conexión a internet (no resuelvo archlinux.org). Por cable debería ir solo; para wifi usa 'iwctl'."
    fi
}

# En el live todo lo que se escribe va a una capa en RAM (256 MiB por defecto):
# se amplía si hace falta, sin pasar nunca de la RAM disponible.
ensure_cowspace() {
    local line size used avail
    line=$(df --output=size,used,avail -B1 "$COWSPACE" | tail -n 1)
    read -r size used avail <<<"$line"
    if [[ ! $size =~ ^[0-9]+$ || ! $used =~ ^[0-9]+$ || ! $avail =~ ^[0-9]+$ ]]; then
        die "No pude leer el tamaño de $COWSPACE (df devolvió: '$line')"
    fi
    local mib=$(( 1024 * 1024 ))
    local need_bytes=$(( COW_MIN_FREE_MIB * mib ))
    info "Capa de escritura del live: $(( avail / mib )) MiB libres de $(( size / mib )) MiB"
    if (( avail >= need_bytes )); then
        ok "Espacio suficiente para instalar"
        return 0
    fi

    local mem_kb
    mem_kb=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
    if [[ ! $mem_kb =~ ^[0-9]+$ ]]; then die "No pude leer la RAM disponible de /proc/meminfo"; fi
    local mem_avail=$(( mem_kb * 1024 ))
    local grow=$(( need_bytes - avail ))
    local reserve=$(( RAM_RESERVE_MIB * mib ))
    if (( grow + reserve > mem_avail )); then
        die "No hay RAM suficiente: hacen falta $(( grow / mib )) MiB más para la capa de escritura y solo hay $(( mem_avail / mib )) MiB disponibles (se reservan $RAM_RESERVE_MIB MiB para el sistema)"
    fi
    local new_mib=$(( (size + grow + mib - 1) / mib ))
    if ! run mount -o "remount,size=${new_mib}m" "$COWSPACE"; then
        die "No se pudo ampliar $COWSPACE a ${new_mib} MiB"
    fi
    ok "Capa de escritura ampliada a ${new_mib} MiB"
}

# Espera a que una unidad termine de arrancar; devuelve su estado.
wait_unit_settled() {
    local unit=${1:?} timeout_s=${2:?} state="" waited=0
    if ! systemctl cat -- "$unit" >/dev/null 2>&1; then
        return 0
    fi
    while :; do
        state=$(systemctl is-active -- "$unit" 2>/dev/null) || true
        case $state in
            activating|deactivating|reloading|refreshing) ;;
            *) break ;;
        esac
        if (( waited >= timeout_s )); then break; fi
        if (( waited == 0 )); then info "Esperando a que termine $unit…"; fi
        sleep 2
        waited=$(( waited + 2 ))
    done
    printf '%s' "$state"
}

wait_boot_services() {
    local st
    st=$(wait_unit_settled pacman-init.service 120)
    case $st in
        failed)     die "pacman-init.service ha fallado: las claves de pacman no están listas. Míralo con: journalctl -u pacman-init" ;;
        activating) die "pacman-init.service sigue en marcha tras 2 minutos; espera un poco y vuelve a ejecutar el script" ;;
    esac
    st=$(wait_unit_settled reflector.service 90)
    case $st in
        failed)     warn "reflector.service ha fallado; se usa la lista de mirrors que haya" ;;
        activating) warn "reflector.service sigue en marcha; continúo con la lista de mirrors actual" ;;
    esac
}

wait_pacman_lock() {
    local lck=/var/lib/pacman/db.lck waited=0
    while [[ -e $lck ]]; do
        if ! pgrep -x pacman >/dev/null 2>&1; then
            die "Existe $lck pero no hay ningún pacman en marcha. Si estás seguro, bórralo con: rm $lck"
        fi
        if (( waited >= 180 )); then die "Otro pacman lleva más de 3 minutos ocupando la base de datos"; fi
        if (( waited == 0 )); then info "Hay otro pacman en marcha; espero a que termine…"; fi
        sleep 3
        waited=$(( waited + 3 ))
    done
}

install_packages() {
    local -a todo=()
    local p
    for p in "${PACKAGES[@]}"; do
        if ! pacman -Qq -- "$p" >/dev/null 2>&1; then todo+=("$p"); fi
    done
    if (( ${#todo[@]} == 0 )); then
        ok "Todos los paquetes ya estaban instalados"
        return 0
    fi
    info "Paquetes a instalar: ${todo[*]}"
    wait_pacman_lock

    if (( IS_LIVE )); then
        # Sincroniza y actualiza solo el anillo de claves (evita errores de firma con
        # ISOs algo antiguas). Nunca -Syu: actualizaría el kernel del live.
        if ! run pacman -Sy --noconfirm --needed archlinux-keyring; then
            die "No se pudo sincronizar con los repositorios ni actualizar archlinux-keyring. Revisa la conexión y /etc/pacman.d/mirrorlist."
        fi
        if ! run pacman -S --noconfirm --needed -- "${todo[@]}"; then
            die "pacman no pudo instalar: ${todo[*]}. El motivo está justo encima."
        fi
    else
        # Sistema instalado: sin -y, para no provocar una actualización parcial.
        if ! run pacman -S --noconfirm --needed -- "${todo[@]}"; then
            die "pacman no pudo instalar: ${todo[*]}. Si el error es 'not found' o 404, ejecuta antes 'pacman -Syu'."
        fi
    fi
    ok "Paquetes instalados"
}

# Librerías que le faltan al binario $1, separadas por '; ' (vacío si no falta ninguna).
missing_libs() {
    local out=""
    out=$(ldd -- "${1:?missing_libs: falta el archivo}" 2>&1) || true
    awk '/not found/ { sub(/^[ \t]+/, ""); printf "%s; ", $0 }' <<<"$out"
}

# Comprueba que lo instalado funciona ANTES de cambiar ninguna configuración.
# Solo es obligatorio lo que kmscon necesita para arrancar y dibujar texto: los
# módulos de aceleración 3D (mod-drm3d, mod-gltex) piden libGL/EGL, que en un
# live sin mesa no existen; kmscon avisa al arrancar y dibuja por software.
verify_install() {
    if (( DRY_RUN )); then
        info "[DRY ] Aquí se comprobaría que tmux y kmscon tienen todas sus librerías"
        FONT_ENGINE=freetype
        return 0
    fi
    info "Comprobando que lo instalado funciona…"
    local -a problems=() bins=() optional=()
    local p f libs engine unit_path=""

    for p in "${PACKAGES[@]}"; do
        if ! pacman -Qq -- "$p" >/dev/null 2>&1; then problems+=("el paquete $p no está instalado"); fi
    done

    unit_path=$(systemctl show -p FragmentPath --value kmsconvt@tty1.service 2>/dev/null) || unit_path=""
    if [[ $unit_path == /usr/lib/systemd/system/* && -f $unit_path ]]; then
        KMSCON_UNIT=$unit_path
    fi
    if [[ ! -f $KMSCON_UNIT ]]; then problems+=("no encuentro la unidad kmsconvt@.service"); fi

    if ! tmux -V >/dev/null 2>&1; then problems+=("tmux no se ejecuta"); fi

    # Imprescindibles: el ejecutable de kmscon y tmux.
    for f in /usr/lib/kmscon/kmscon /usr/bin/kmscon; do
        if [[ -f $f ]]; then bins+=("$f"); fi
    done
    if (( ${#bins[@]} == 0 )); then problems+=("no encuentro el ejecutable de kmscon"); fi
    bins+=(/usr/bin/tmux)
    for f in "${bins[@]}"; do
        libs=$(missing_libs "$f")
        if [[ -n $libs ]]; then problems+=("$f necesita: $libs"); fi
    done

    # Motor de fuentes: freetype primero (el predeterminado de kmscon y el que más se
    # mejora: suavizado, sustitución de glifos que faltan); pango, de respaldo.
    FONT_ENGINE=""
    for engine in freetype pango; do
        f=/usr/lib/kmscon/mod-${engine}.so
        if [[ ! -f $f ]]; then continue; fi
        libs=$(missing_libs "$f")
        if [[ -z $libs ]]; then
            FONT_ENGINE=$engine
            break
        fi
        warn "El motor de fuentes '$engine' no se puede usar (le falta: $libs)"
    done
    if [[ -z $FONT_ENGINE ]]; then
        warn "No hay motor de fuentes escalables; kmscon usará su fuente de mapa de bits"
    fi

    # Opcionales: si les falta algo, solo se informa.
    for f in /usr/lib/kmscon/mod-*.so; do
        case ${f##*/} in
            mod-pango.so|mod-freetype.so) continue ;;
            *) ;;
        esac
        libs=$(missing_libs "$f")
        if [[ -n $libs ]]; then optional+=("${f##*/}"); fi
    done
    if (( ${#optional[@]} > 0 )); then
        info "Módulos opcionales de kmscon sin sus librerías: ${optional[*]}"
        info "  Es la aceleración por GPU: no hace falta para la consola. kmscon avisará de ello al arrancar; se puede ignorar."
    fi

    if (( ${#problems[@]} > 0 )); then
        for p in "${problems[@]}"; do err "  $p"; done
        die "Lo instalado no funciona: arriba tienes qué falta. No se ha cambiado ninguna configuración."
    fi
    ok "tmux y kmscon instalados y con todo lo que necesitan (fuentes con '${FONT_ENGINE:-mapa de bits}')"
}

configure_fonts() {
    local fams=""
    if command -v fc-list >/dev/null 2>&1; then
        fams=$(fc-list : family 2>/dev/null) || fams=""
        if ! grep -Fqi -- "$FONT_NAME" <<<"$fams" && (( ! DRY_RUN )); then
            fc-cache -f >/dev/null 2>&1 || true
            fams=$(fc-list : family 2>/dev/null) || fams=""
        fi
    fi
    if grep -Fqi -- "$FONT_NAME" <<<"$fams"; then
        ok "Fuente '$FONT_NAME' disponible"
    elif (( DRY_RUN )); then
        info "[DRY ] La fuente '$FONT_NAME' se instalaría con ttf-jetbrains-mono"
    else
        warn "No encuentro la fuente '$FONT_NAME'; kmscon usará otra monoespaciada"
    fi
}

write_kmscon_conf() {
    local -a lines=(
        "# Generado por ${SCRIPT_NAME}.sh. Todas las opciones: man kmscon"
        "xkb-layout=${XKB_LAYOUT}"
    )
    if [[ -n $FONT_ENGINE ]]; then
        lines+=("font-engine=${FONT_ENGINE}" "font-name=${FONT_NAME}" "font-size=${FONT_SIZE}")
    fi
    local content
    content=$(printf '%s\n' "${lines[@]}")
    write_file "$KMSCON_CONF" "$content" 644
}

# Teclado en español en la consola del kernel y en el ajuste X11 de localed
# (kmscon puede leerlo de ahí). El idioma (LANG) no se toca.
configure_keymap() {
    local status="" vc="" x11=""
    status=$(localectl status --no-pager 2>/dev/null) || status=""
    vc=$(awk -F': ' '/VC Keymap:/ { print $2 }' <<<"$status")
    x11=$(awk -F': ' '/X11 Layout:/ { print $2 }' <<<"$status")
    vc=${vc//[[:space:]]/}
    x11=${x11//[[:space:]]/}
    if [[ $vc == "$KEYMAP" && $x11 == "$XKB_LAYOUT" ]]; then
        ok "El teclado ya estaba en '$KEYMAP'"
        return 0
    fi
    if (( DRY_RUN )); then
        info "[DRY ] Pondría el teclado en '$KEYMAP' con localectl (ahora: consola '${vc:-?}', X11 '${x11:-?}')"
        return 0
    fi

    backup_path /etc/vconsole.conf
    backup_path /etc/X11/xorg.conf.d/00-keyboard.conf

    if run localectl set-keymap -- "$KEYMAP"; then
        x11=$(localectl status --no-pager 2>/dev/null | awk -F': ' '/X11 Layout:/ { print $2 }') || x11=""
        x11=${x11//[[:space:]]/}
        if [[ $x11 != "$XKB_LAYOUT" ]]; then
            run localectl set-x11-keymap -- "$XKB_LAYOUT" || warn "No se pudo fijar la distribución X11 (kmscon la toma igualmente de su configuración)"
        fi
        ok "Teclado en '$KEYMAP'"
        return 0
    fi

    warn "localectl ha fallado; escribo /etc/vconsole.conf directamente"
    local rest="" content=""
    rest=$(grep -v '^[[:space:]]*KEYMAP=' /etc/vconsole.conf 2>/dev/null) || rest=""
    if [[ -n $rest ]]; then
        content=$(printf '%s\nKEYMAP=%s' "$rest" "$KEYMAP")
    else
        content="KEYMAP=$KEYMAP"
    fi
    write_file /etc/vconsole.conf "$content" 644
    if run loadkeys -- "$KEYMAP"; then
        ok "Teclado en '$KEYMAP'"
    else
        warn "No se pudo aplicar ya con loadkeys; se aplicará en las TTY nuevas"
    fi
}

enable_kmscon() {
    info "Activando kmscon en todas las TTY…"
    set_symlink "$KMSCON_UNIT" "$AUTOVT_LINK"

    # tty1 en los próximos arranques (en el live no persiste, pero queda coherente).
    local st=""
    st=$(systemctl is-enabled getty@tty1.service 2>/dev/null) || st=""
    if [[ $st == enabled ]]; then
        if ! run systemctl disable getty@tty1.service; then die "No se pudo desactivar getty@tty1.service"; fi
        rb_push enable getty@tty1.service
    fi
    st=$(systemctl is-enabled kmsconvt@tty1.service 2>/dev/null) || st=""
    if [[ $st != enabled ]]; then
        if ! run systemctl enable kmsconvt@tty1.service; then die "No se pudo activar kmsconvt@tty1.service"; fi
        rb_push disable kmsconvt@tty1.service
    fi
    if ! run systemctl daemon-reload; then die "Falló 'systemctl daemon-reload'"; fi
}

# Primera TTY (de la 6 a la 2) que no esté en primer plano ni tenga sesión abierta.
pick_free_vt() {
    local fg="" sessions="" n
    fg=$(fgconsole 2>/dev/null) || fg=""
    sessions=$(who 2>/dev/null | awk '{ print $2 }') || sessions=""
    for n in 6 5 4 3 2; do
        if [[ $n == "$fg" ]]; then continue; fi
        if grep -Fxq -- "tty$n" <<<"$sessions"; then continue; fi
        printf 'tty%s' "$n"
        return 0
    done
    return 1
}

show_unit_log() {
    local unit=$1
    err "Últimas líneas del registro de $unit:"
    journalctl -b -u "$unit" -n 30 --no-pager -o cat 2>&1 | sed 's/^/        /' >&2 || true
}

# Arranca kmscon de verdad en una TTY libre; si no aguanta, se deshace todo.
smoke_test_kmscon() {
    if (( DRY_RUN )); then
        info "[DRY ] Aquí se probaría kmscon en una TTY libre"
        return 0
    fi
    local vt="" fg_before="" fg_after="" state=""
    if ! vt=$(pick_free_vt); then
        warn "No hay ninguna TTY libre para probar kmscon; me salto la prueba"
        return 0
    fi
    local unit="kmsconvt@${vt}.service"
    fg_before=$(fgconsole 2>/dev/null) || fg_before=""
    info "Probando kmscon en $vt…"
    rb_push stop "$unit"
    if ! systemctl start -- "$unit"; then
        show_unit_log "$unit"
        die "kmscon no ha podido arrancar en $vt"
    fi
    sleep 3
    state=$(systemctl is-active -- "$unit" 2>/dev/null) || true
    if [[ $state != active ]]; then
        show_unit_log "$unit"
        die "kmscon se ha cerrado nada más arrancar en $vt (estado: ${state:-desconocido})"
    fi
    # Si la prueba ha cambiado la pantalla de TTY, vuelve a la que estabas.
    fg_after=$(fgconsole 2>/dev/null) || fg_after=""
    if [[ -n $fg_before && -n $fg_after && $fg_before != "$fg_after" ]] && command -v chvt >/dev/null 2>&1; then
        chvt "$fg_before" || true
    fi
    TEST_VT=$vt
    ok "kmscon funciona (está esperando en $vt)"
}

# Las TTY con agetty pero sin sesión se paran: al volver a ellas arrancará kmscon.
refresh_idle_gettys() {
    if (( DRY_RUN )); then
        return 0
    fi
    local fg="" sessions="" units="" u vt
    fg=$(fgconsole 2>/dev/null) || fg=""
    sessions=$(who 2>/dev/null | awk '{ print $2 }') || sessions=""
    units=$(systemctl list-units --type=service --state=running --plain --no-legend 'getty@tty*.service' 2>/dev/null | awk '{ print $1 }') || units=""
    while IFS= read -r u; do
        if [[ -z $u ]]; then continue; fi
        vt=${u#getty@}
        vt=${vt%.service}
        if [[ ! $vt =~ ^tty[0-9]+$ ]]; then continue; fi
        if [[ ${vt#tty} == "$fg" ]] || grep -Fxq -- "$vt" <<<"$sessions"; then
            info "$vt tiene una sesión abierta: sigue con agetty hasta que salgas"
            continue
        fi
        run systemctl stop -- "$u" || warn "No se pudo parar $u (no es grave)"
    done <<<"$units"
}

summary() {
    local onfail=""
    printf '\n' >&2
    if (( DRY_RUN )); then
        ok "Modo prueba terminado: no se ha cambiado nada."
        return 0
    fi
    ok "Todo listo."
    info "kmscon: cambia a otra TTY (Ctrl+Alt+F2 … F6) para usarlo."
    if [[ -n $TEST_VT ]]; then
        info "  Ya hay uno esperando en $TEST_VT (Ctrl+Alt+F${TEST_VT#tty})."
    fi
    info "tty1 sigue con agetty mientras tengas la sesión abierta ahí. Para pasarla a kmscon,"
    info "  desde otra TTY: systemctl start kmsconvt@tty1.service   (cierra la sesión de tty1)"
    info "Tamaño de letra: Ctrl y + / Ctrl y - dentro de kmscon, o --font-size N al ejecutar el script."
    onfail=$(systemctl show -p OnFailure --value kmsconvt@tty2.service 2>/dev/null) || onfail=""
    if [[ $onfail == *getty@* ]]; then
        info "Si kmscon fallara en alguna TTY, systemd arranca agetty en su lugar automáticamente."
    fi
    info "Para volver a agetty: rm $AUTOVT_LINK && systemctl daemon-reload"
    info "El idioma del sistema no se ha tocado."
    if (( ${#BACKUPS[@]} > 0 )); then
        info "Copias de seguridad de lo modificado:"
        printf '        %s\n' "${BACKUPS[@]}" >&2
    fi
}

main() {
    parse_args "$@"
    require_root
    acquire_lock
    setup_log
    if (( DRY_RUN )); then info "MODO PRUEBA: no se cambiará nada"; fi

    preflight
    if (( IS_LIVE )); then
        ensure_cowspace
        wait_boot_services
    fi
    install_packages
    verify_install          # si algo no funciona, se para aquí sin haber tocado la configuración
    configure_fonts
    write_kmscon_conf
    configure_keymap
    enable_kmscon
    smoke_test_kmscon       # si kmscon no aguanta, se deshace todo lo anterior
    refresh_idle_gettys

    COMMITTED=1
    summary
}

main "$@"
