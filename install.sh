#!/usr/bin/env bash
# =============================================================================
#  WSSH-VPN — Installer / Updater / Uninstaller
#  Usage (pipe-safe):
#    curl  -fsSL https://raw.githubusercontent.com/MTplusWebSystem/wssh-vpn/refs/heads/main/install.sh | sudo bash
#    wget  -qO-  https://raw.githubusercontent.com/MTplusWebSystem/wssh-vpn/refs/heads/main/install.sh | sudo bash
#    # Modo não-interativo:
#    curl -fsSL ... | sudo bash -s -- install --auto
#    # Instalar de arquivo local:
#    sudo bash install.sh local --file /root/wssh-vpn.tar.gz
# =============================================================================
set -euo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

# ── Versão do installer ───────────────────────────────────────────────────────
readonly INSTALLER_VERSION="2.1.2"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/wssh"
readonly DB_NAME="wssh_db"
readonly BINARY_TARGET="${INSTALL_DIR}/wssh-vpn"
readonly BACKUP_BINARY="${INSTALL_DIR}/wssh-vpn.bak"
readonly UPDATE_API="https://update.mtwtech.shop"
readonly LOG_FILE="/var/log/wssh-vpn-install.log"

# Nome canônico do pacote — todos os arquivos são normalizados para este nome
readonly PKG_FILENAME="wssh-vpn.tar.gz"

# ── Flags de controle ─────────────────────────────────────────────────────────
AUTO_MODE=false       # --auto: usa defaults sem perguntar
QUIET=false           # --quiet: suprime banner

# ── Estado global ─────────────────────────────────────────────────────────────
_MANUAL_PKG_PATH=""   # --file <path>: usa arquivo local em vez de baixar
_PROG_PID=""          # PID do monitor de progresso (para cleanup no trap)
_CURL_INSECURE=false  # ativa na primeira vez que cai no fallback -k

# ── Cores (ativadas apenas se stdout for TTY real) ────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' BLUE='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
fi

# ── Logging ───────────────────────────────────────────────────────────────────
_log_file_init() {
    mkdir -p "$(dirname "$LOG_FILE")"
    : >> "$LOG_FILE"
}

log()  { local ts; ts=$(date +"%Y-%m-%dT%H:%M:%S"); echo "${ts}  INFO  $*" >> "$LOG_FILE"; }
logw() { local ts; ts=$(date +"%Y-%m-%dT%H:%M:%S"); echo "${ts}  WARN  $*" >> "$LOG_FILE"; }
loge() { local ts; ts=$(date +"%Y-%m-%dT%H:%M:%S"); echo "${ts}  ERROR $*" >> "$LOG_FILE"; }

# ── Saída formatada ───────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[·]${NC} $*"               >&2; log "$*"; }
ok()      { echo -e "${GREEN}[✓]${NC} $*"             >&2; log "OK: $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"             >&2; logw "$*"; }
step()    { echo -e "${CYAN}[→]${NC} ${BOLD}$*${NC}"  >&2; log "STEP: $*"; }
die()     { echo -e "${RED}[✗] ERRO:${NC} $*"         >&2; loge "$*"
            echo -e "${DIM}    Log completo: ${LOG_FILE}${NC}" >&2; exit 1; }
sep()     { echo -e "${DIM}────────────────────────────────────────────────────────────${NC}" >&2; }

# ── Cleanup de arquivos temporários ──────────────────────────────────────────
_TMP_FILES=()
_tmp() { local f; f=$(mktemp); _TMP_FILES+=("$f"); echo "$f"; }
_cleanup() {
    local f
    for f in "${_TMP_FILES[@]:-}"; do
        [[ -f "$f" ]] && rm -f "$f" 2>/dev/null || true
    done
    rm -rf /tmp/wssh-extract 2>/dev/null || true
    # Garante que o monitor de progresso é encerrado
    [[ -n "${_PROG_PID:-}" ]] && kill "$_PROG_PID" 2>/dev/null || true
}
trap _cleanup EXIT

# ── Wrappers curl com fallback SSL ───────────────────────────────────────────
_curl_get() {
    local out ec
    out=$(curl -fsSL \
        --connect-timeout 15 --max-time 30 \
        --retry 3 --retry-delay 2 \
        -A "wssh-installer/${INSTALLER_VERSION}" \
        "$@" 2>/dev/null) && { printf '%s' "$out"; return 0; }

    out=$(curl -fsSL -k \
        --connect-timeout 15 --max-time 30 \
        --retry 3 --retry-delay 2 \
        -A "wssh-installer/${INSTALLER_VERSION}" \
        "$@" 2>/dev/null) && {
        if [[ "$_CURL_INSECURE" == false ]]; then
            warn "Certificado SSL do servidor expirado ou inválido — conexão insegura habilitada."
            _CURL_INSECURE=true
        fi
        printf '%s' "$out"
        return 0
    }
    return 1
}

# ── Obtém tamanho do arquivo remoto via HEAD (best-effort) ───────────────────
_get_remote_size() {
    local url="$1"
    local size
    size=$(curl -fsSLI \
        --connect-timeout 10 --max-time 15 \
        -k \
        -A "wssh-installer/${INSTALLER_VERSION}" \
        "$url" 2>/dev/null \
        | grep -i "^content-length:" \
        | tail -1 \
        | awk '{print $2}' \
        | tr -d '[:space:][:cntrl:]')
    [[ "$size" =~ ^[0-9]+$ ]] && echo "$size" || echo 0
}

# ── Monitor de progresso de download ─────────────────────────────────────────
_progress_bar() {
    local file="$1" total="${2:-0}"
    local start=$SECONDS size elapsed speed_bps speed_kbps mb_int mb_dec pct filled bar i

    local -a spin=("▹▹▹▹▹" "▸▹▹▹▹" "▸▸▹▹▹" "▸▸▸▹▹" "▸▸▸▸▹" "▸▸▸▸▸")

    while true; do
        sleep 0.8
        [[ -f "$file" ]] || continue
        size=$(stat -c%s "$file" 2>/dev/null || echo 0)
        elapsed=$(( SECONDS - start + 1 ))
        speed_bps=$(( size / elapsed ))
        speed_kbps=$(( speed_bps / 1024 ))
        mb_int=$(( size / 1048576 ))
        mb_dec=$(( (size * 10 / 1048576) % 10 ))

        if [[ "$total" -gt 0 ]]; then
            pct=$(( size * 100 / total ))
            [[ "$pct" -gt 100 ]] && pct=100
            filled=$(( pct * 28 / 100 ))
            bar=""
            for (( i=0; i<28; i++ )); do
                (( i < filled )) && bar+="█" || bar+="░"
            done
            local total_mb=$(( total / 1048576 ))
            printf "\r    [%s] %3d%%  %d.%dMB / %dMB  %d KB/s  " \
                "$bar" "$pct" "$mb_int" "$mb_dec" "$total_mb" "$speed_kbps" >&2
        else
            local spin_idx=$(( (elapsed - 1) % 6 ))
            printf "\r    [%s]  %d.%d MB baixados  %d KB/s  " \
                "${spin[$spin_idx]}" "$mb_int" "$mb_dec" "$speed_kbps" >&2
        fi
    done
}

# ── Download com progresso + fallback SSL ────────────────────────────────────
_curl_download_progress() {
    local output_file="$1" url="$2" total_size="${3:-0}"

    _progress_bar "$output_file" "$total_size" &
    _PROG_PID=$!

    local dl_ok=false

    curl -fL \
        --connect-timeout 15 --max-time 300 \
        --retry 0 \
        -A "wssh-installer/${INSTALLER_VERSION}" \
        -o "$output_file" "$url" 2>/dev/null && dl_ok=true

    if [[ "$dl_ok" == false ]]; then
        curl -fL -k \
            --connect-timeout 15 --max-time 300 \
            --retry 0 \
            -A "wssh-installer/${INSTALLER_VERSION}" \
            -o "$output_file" "$url" 2>/dev/null && dl_ok=true && {
            if [[ "$_CURL_INSECURE" == false ]]; then
                warn "Download sem verificação SSL (certificado expirado)."
                _CURL_INSECURE=true
            fi
        }
    fi

    kill "$_PROG_PID" 2>/dev/null
    wait "$_PROG_PID" 2>/dev/null || true
    _PROG_PID=""
    printf "\r%80s\r" "" >&2

    [[ "$dl_ok" == true ]]
}

# =============================================================================
#  NORMALIZAÇÃO DO PACOTE — garante que _MANUAL_PKG_PATH aponta para
#  um arquivo chamado wssh-vpn.tar.gz.
#
#  Regras:
#    1. Se o arquivo já se chama wssh-vpn.tar.gz → usa direto.
#    2. Se o arquivo tem outro nome (ex: "download") → copia/renomeia
#       para o mesmo diretório com o nome wssh-vpn.tar.gz e atualiza
#       _MANUAL_PKG_PATH para o novo caminho.
# =============================================================================
_normalize_pkg_path() {
    local src="$_MANUAL_PKG_PATH"

    [[ -f "$src" ]] || die "Arquivo não encontrado: ${src}"

    local src_dir src_base canonical

    src_dir=$(dirname "$src")
    src_base=$(basename "$src")
    canonical="${src_dir}/${PKG_FILENAME}"

    if [[ "$src_base" == "$PKG_FILENAME" ]]; then
        # Já tem o nome correto — nada a fazer
        return 0
    fi

    # Arquivo com nome diferente → copia para wssh-vpn.tar.gz no mesmo dir
    info "Renomeando '${src_base}' → '${PKG_FILENAME}'..."
    cp -a "$src" "$canonical" \
        || die "Não foi possível renomear o arquivo para ${PKG_FILENAME}."

    _MANUAL_PKG_PATH="$canonical"
    ok "Arquivo normalizado: ${_MANUAL_PKG_PATH}"
    log "Pacote normalizado: ${src} → ${_MANUAL_PKG_PATH}"
}

# ── Parse de argumentos ───────────────────────────────────────────────────────
_ACTION=""
_EXTRA_ARGS=()

_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|update|uninstall|local)
                _ACTION="$1" ;;
            --auto|-y)
                AUTO_MODE=true ;;
            --quiet|-q)
                QUIET=true ;;
            --file|-f)
                shift
                _MANUAL_PKG_PATH="${1:-}"
                [[ -n "$_MANUAL_PKG_PATH" ]] || die "--file requer um caminho de arquivo."
                ;;
            --help|-h)
                echo "Uso: install.sh [install|update|uninstall|local] [--auto] [--quiet] [--file <caminho>]"
                echo ""
                echo "  install    Instala o WSSH-VPN"
                echo "  update     Atualiza para a versão mais recente"
                echo "  uninstall  Remove o WSSH-VPN"
                echo "  local      Instala/atualiza usando arquivo local (sem download)"
                echo ""
                echo "  --file <caminho>  Arquivo baixado manualmente (ex: wssh-vpn.tar.gz ou download)"
                echo "  --auto            Usa valores padrão sem perguntar"
                echo "  --quiet           Suprime banner"
                echo ""
                echo "Exemplo:"
                echo "  wget ${UPDATE_API}/1.2.3/download -O wssh-vpn.tar.gz"
                echo "  sudo bash install.sh local --file ./wssh-vpn.tar.gz"
                exit 0
                ;;
            *) _EXTRA_ARGS+=("$1") ;;
        esac
        shift
    done
}

# ── Leitura de input (pipe-safe: sempre via /dev/tty) ─────────────────────────
_ask() {
    local var="$1" prompt="$2" default="${3:-}"
    if [[ "$AUTO_MODE" == true ]]; then
        printf -v "$var" '%s' "$default"
        return
    fi
    local val
    local full_prompt="    ${prompt}"
    [[ -n "$default" ]] && full_prompt+=" ${DIM}[${default}]${NC}"
    full_prompt+=": "
    read -r -p "$(echo -e "$full_prompt")" val < /dev/tty || die "Não foi possível ler do terminal."
    printf -v "$var" '%s' "${val:-$default}"
}

_ask_secret() {
    local var="$1" prompt="$2" default="${3:-}"
    if [[ "$AUTO_MODE" == true ]]; then
        printf -v "$var" '%s' "$default"
        return
    fi
    local val
    read -r -s -p "$(echo -e "    ${prompt}: ")" val < /dev/tty || die "Não foi possível ler do terminal."
    echo "" >&2
    printf -v "$var" '%s' "${val:-$default}"
}

_ask_confirm() {
    local prompt="$1" default="${2:-n}"
    if [[ "$AUTO_MODE" == true ]]; then
        [[ "$default" == "s" || "$default" == "S" ]] && return 0 || return 1
    fi
    local val
    read -r -p "$(echo -e "    ${prompt} ${DIM}(s/n)${NC}: ")" val < /dev/tty || return 1
    [[ "$val" == "s" || "$val" == "S" ]]
}

# ── Validações de input ───────────────────────────────────────────────────────
_validate_min_len() {
    local value="$1" min="$2" label="$3"
    if [[ "${#value}" -lt "$min" ]]; then
        die "${label} deve ter no mínimo ${min} caracteres (recebido: ${#value})."
    fi
}

# ── Pré-requisitos ────────────────────────────────────────────────────────────
require_root() {
    [[ "$EUID" -eq 0 ]] || die "Este script deve ser executado como root: sudo bash install.sh"
}

require_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        info "Instalando dependência: ${pkg}..."
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq "$pkg" >/dev/null 2>&1 \
            || die "Não foi possível instalar: ${pkg}. Instale manualmente e tente novamente."
    fi
}

preflight_check() {
    info "Verificando pré-requisitos do sistema..."

    if ! command -v systemctl &>/dev/null; then
        die "systemd não encontrado. O WSSH-VPN requer systemd."
    fi

    local free_kb
    free_kb=$(df -k /usr/local/bin | awk 'NR==2{print $4}')
    if [[ "$free_kb" -lt 204800 ]]; then
        die "Espaço insuficiente em /usr (disponível: $((free_kb / 1024)) MB, mínimo: 200 MB)."
    fi

    for dep in jq curl; do
        require_cmd "$dep"
    done

    ok "Pré-requisitos satisfeitos."
}

# ── Detecção de arquitetura e OS ──────────────────────────────────────────────
detect_platform() {
    local machine os_raw arch

    machine=$(uname -m)
    os_raw=$(uname -s | tr '[:upper:]' '[:lower:]')

    if [[ -d "/data/data/com.termux" ]]; then
        os_raw="android"
    fi

    case "$machine" in
        x86_64)              arch="amd64"   ;;
        i386|i686)           arch="386"     ;;
        aarch64|arm64)       arch="aarch64" ;;
        armv7l|armv7)        arch="armv7"   ;;
        armv6l|armv6)        arch="armv6"   ;;
        armv5l|armv5tel)     arch="armv5"   ;;
        riscv64)             arch="riscv64" ;;
        ppc64le)             arch="ppc64le" ;;
        s390x)               arch="s390x"   ;;
        *) die "Arquitetura não suportada: ${machine}" ;;
    esac

    PLATFORM_OS="$os_raw"
    PLATFORM_ARCH="$arch"
    BINARY_NAME="wssh-vpn_${os_raw}_${arch}"

    log "Plataforma: ${PLATFORM_OS}/${PLATFORM_ARCH} → binário: ${BINARY_NAME}"
}

# ── Versão instalada ──────────────────────────────────────────────────────────
get_installed_version() {
    if [[ -x "$BINARY_TARGET" ]]; then
        "$BINARY_TARGET" --version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([.a-zA-Z0-9-]*)?' \
        | head -1 \
        || echo ""
    else
        echo ""
    fi
}

# ── Obtém versão mais recente da API ─────────────────────────────────────────
fetch_latest_version() {
    local version=""
    info "Consultando versão mais recente em ${UPDATE_API}..."

    version=$(
        _curl_get "${UPDATE_API}/latest" \
        | jq -r '.data.version // empty' 2>/dev/null \
        || true
    )
    version=$(printf '%s' "$version" | tr -d '[:space:][:cntrl:]')

    if [[ -z "$version" || "$version" == "null" ]]; then
        warn "API indisponível. Informe a versão manualmente."
        _ask version "Versão (ex: 1.2.3)" ""
        [[ -n "$version" ]] || die "Versão não informada."
        version=$(printf '%s' "$version" | tr -d '[:space:][:cntrl:]')
    fi

    info "Versão obtida: ${version}"
    printf '%s' "$version"
}

# ── Compara versões ───────────────────────────────────────────────────────────
_version_lt() {
    [[ "$1" == "$2" ]] && return 1

    local IFS=.
    local va vb
    va=$(printf '%s' "$1" | tr '-' '.')
    vb=$(printf '%s' "$2" | tr '-' '.')

    local a=($va) b=($vb)
    local max=$(( ${#a[@]} > ${#b[@]} ? ${#a[@]} : ${#b[@]} ))
    local i av bv

    for (( i=0; i<max; i++ )); do
        av="${a[$i]:-0}"
        bv="${b[$i]:-0}"
        [[ "$av" =~ ^[0-9]+$ ]] || av=0
        [[ "$bv" =~ ^[0-9]+$ ]] || bv=0
        av=$((10#$av))
        bv=$((10#$bv))
        (( av < bv )) && return 0
        (( av > bv )) && return 1
    done
    return 1
}

# ── Download e extração do pacote ─────────────────────────────────────────────
#
# Se _MANUAL_PKG_PATH estiver definido, usa o arquivo local sem baixar.
# Caso contrário, faz download com barra de progresso salvando como wssh-vpn.tar.gz.
#
download_package() {
    local version="$1"
    local extract_dir="/tmp/wssh-extract"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    # ── Modo arquivo local ────────────────────────────────────────────────────
    if [[ -n "$_MANUAL_PKG_PATH" ]]; then
        info "Usando pacote local: ${_MANUAL_PKG_PATH}"
        local fsize
        fsize=$(stat -c%s "$_MANUAL_PKG_PATH" 2>/dev/null || echo 0)
        info "Tamanho: $(( fsize / 1024 / 1024 )) MB"

        info "Validando integridade..."
        tar -tzf "$_MANUAL_PKG_PATH" >/dev/null 2>&1 \
            || die "Arquivo inválido: não é um tar.gz válido: ${_MANUAL_PKG_PATH}"

        info "Extraindo pacote..."
        tar -xzf "$_MANUAL_PKG_PATH" -C "$extract_dir" \
            || die "Falha ao extrair: ${_MANUAL_PKG_PATH}"

        if [[ ! -f "${extract_dir}/${BINARY_NAME}" ]]; then
            local available
            available=$(find "$extract_dir" -maxdepth 2 -type f | head -10 | tr '\n' ' ')
            die "Binário '${BINARY_NAME}' não encontrado no pacote. Arquivos disponíveis: ${available}"
        fi

        chmod +x "${extract_dir}/${BINARY_NAME}"
        ok "Pacote local extraído — binário '${BINARY_NAME}' pronto."
        return 0
    fi

    # ── Modo download ─────────────────────────────────────────────────────────
    local url="${UPDATE_API}/${version}/download"

    # Salva sempre como wssh-vpn.tar.gz no diretório de trabalho atual
    local package_file
    if [[ -w "$(pwd)" ]]; then
        package_file="$(pwd)/${PKG_FILENAME}"
    else
        package_file="/tmp/${PKG_FILENAME}"
    fi
    # Registra para cleanup automático
    _TMP_FILES+=("$package_file")

    info "Baixando wssh-vpn v${version} → ${PKG_FILENAME} (${BINARY_NAME})..."
    log "URL: ${url}"

    info "Consultando tamanho do arquivo..."
    local total_size
    total_size=$(_get_remote_size "$url")

    if [[ "$total_size" -gt 0 ]]; then
        local total_mb=$(( total_size / 1024 / 1024 ))
        info "Tamanho: ${total_mb} MB — progresso com % habilitado"
    else
        info "Tamanho: não informado pelo servidor — mostrando bytes baixados"
    fi

    echo "" >&2

    local attempt downloaded=false
    for attempt in 1 2 3; do
        [[ $attempt -gt 1 ]] && info "Tentativa ${attempt}/3..."

        if _curl_download_progress "$package_file" "$url" "$total_size" \
                && [[ -s "$package_file" ]]; then
            downloaded=true
            local final_size
            final_size=$(stat -c%s "$package_file" 2>/dev/null || echo 0)
            ok "Download concluído → ${PKG_FILENAME} ($(( final_size / 1024 / 1024 )) MB)"
            break
        fi

        warn "Tentativa ${attempt} falhou."
        rm -f "$package_file"
        [[ "$attempt" -lt 3 ]] && sleep 3
    done

    echo "" >&2
    [[ "$downloaded" == true ]] || {
        warn "Download falhou após 3 tentativas."
        warn "Você pode baixar manualmente e usar a opção 4 do menu:"
        echo -e "    ${DIM}wget ${url} -O ${PKG_FILENAME}${NC}" >&2
        echo -e "    ${DIM}sudo bash install.sh local --file ./${PKG_FILENAME}${NC}" >&2
        die "Falha no download. URL: ${url}"
    }

    # Validação
    info "Validando integridade do pacote..."
    if ! tar -tzf "$package_file" >/dev/null 2>&1; then
        local type=""
        command -v file &>/dev/null && type=$(file -b "$package_file" 2>/dev/null)
        die "Pacote inválido (não é um tar.gz válido).${type:+ Tipo detectado: ${type}}"
    fi

    # Extração
    info "Extraindo pacote..."
    tar -xzf "$package_file" -C "$extract_dir" \
        || die "Falha ao extrair o pacote."

    if [[ ! -f "${extract_dir}/${BINARY_NAME}" ]]; then
        local available
        available=$(find "$extract_dir" -maxdepth 2 -type f | head -10 | tr '\n' ' ')
        die "Binário '${BINARY_NAME}' não encontrado no pacote. Arquivos disponíveis: ${available}"
    fi

    chmod +x "${extract_dir}/${BINARY_NAME}"
    ok "Binário '${BINARY_NAME}' pronto."
}

# ── Banner principal ───────────────────────────────────────────────────────────
show_banner() {
    [[ "$QUIET" == true ]] && return

    local installed_ver
    installed_ver=$(get_installed_version)

    {
        echo "" >&2
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}" >&2
        echo -e "${CYAN}║        ${BOLD}WSSH-VPN  —  Setup & Management${NC}${CYAN}                  ║${NC}" >&2
        echo -e "${CYAN}╠═══════════════════════════════════════════════════════════╣${NC}" >&2
        printf "${CYAN}║${NC}  Installer : %-43s${CYAN}║${NC}\n" "v${INSTALLER_VERSION}" >&2
        printf "${CYAN}║${NC}  Sistema   : %-43s${CYAN}║${NC}\n" "${PLATFORM_OS}/${PLATFORM_ARCH}" >&2
        if [[ -n "$installed_ver" ]]; then
            printf "${CYAN}║${NC}  Instalado : %-43s${CYAN}║${NC}\n" "v${installed_ver}" >&2
        else
            printf "${CYAN}║${NC}  Status    : %-43s${CYAN}║${NC}\n" "não instalado" >&2
        fi
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}" >&2
        echo "" >&2
    } >&2
}

# =============================================================================
#  INSTALAÇÃO
# =============================================================================
install_vpn() {
    step "Iniciando instalação do WSSH-VPN..."
    sep

    # ── Parâmetros de Banco de Dados ─────────────────────────────────────────
    echo -e "\n${BOLD}  Banco de Dados (PostgreSQL)${NC}" >&2
    local DB_USER DB_PASS

    _ask    DB_USER "Usuário do banco (mín. 6 chars)"    "wssh_user"
    _validate_min_len "$DB_USER" 6 "Usuário do banco"

    _ask_secret DB_PASS "Senha do banco (mín. 8 chars)" "senha123"
    _validate_min_len "$DB_PASS" 8 "Senha do banco"

    echo "" >&2

    # ── Parâmetros do Painel ─────────────────────────────────────────────────
    echo -e "${BOLD}  Painel Administrativo${NC}" >&2
    local PANEL_USER PANEL_PASS

    _ask    PANEL_USER "Usuário admin (mín. 6 chars)"    "admin"
    _validate_min_len "$PANEL_USER" 6 "Usuário admin"

    _ask_secret PANEL_PASS "Senha admin (mín. 8 chars)"  "admin123"
    _validate_min_len "$PANEL_PASS" 8 "Senha admin"

    echo "" >&2
    sep
    step "Iniciando deployment da infraestrutura..."
    sep
    echo "" >&2

    # ── [1/6] Limpeza ────────────────────────────────────────────────────────
    echo -e "${YELLOW}[1/6]${NC} Limpeza de instalação anterior..." >&2
    log "Iniciando limpeza"

    systemctl stop    wssh-vpn 2>/dev/null || true
    systemctl disable wssh-vpn 2>/dev/null || true
    rm -f /etc/systemd/system/wssh-vpn.service
    systemctl daemon-reload 2>/dev/null || true

    local pids
    pids=$(pgrep -x wssh-vpn 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        kill "$pids" 2>/dev/null || true
        sleep 2
        pids=$(pgrep -x wssh-vpn 2>/dev/null || true)
        [[ -n "$pids" ]] && kill -9 "$pids" 2>/dev/null || true
    fi

    rm -f "$BINARY_TARGET" "${BINARY_TARGET}.bak"
    ok "Limpeza concluída."

    # ── [2/6] PostgreSQL ─────────────────────────────────────────────────────
    echo -e "${YELLOW}[2/6]${NC} Configurando PostgreSQL..." >&2
    log "Configurando PostgreSQL: db=${DB_NAME} user=${DB_USER}"

    if ! command -v psql &>/dev/null; then
        info "Instalando PostgreSQL..."
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq postgresql postgresql-contrib >/dev/null 2>&1 \
            || die "Falha ao instalar PostgreSQL."
    fi

    systemctl enable postgresql >/dev/null 2>&1 || true
    systemctl start  postgresql >/dev/null 2>&1 || die "Não foi possível iniciar o PostgreSQL."
    sleep 2

    sudo -u postgres psql -qc "CREATE USER \"${DB_USER}\" SUPERUSER PASSWORD '${DB_PASS}';" \
        >/dev/null 2>&1 \
    || sudo -u postgres psql -qc "ALTER  USER \"${DB_USER}\" SUPERUSER PASSWORD '${DB_PASS}';" \
        >/dev/null 2>&1 \
    || warn "Não foi possível criar/atualizar o usuário do banco."

    sudo -u postgres psql -qc "DROP   DATABASE IF EXISTS ${DB_NAME};"          >/dev/null 2>&1 || true
    sudo -u postgres psql -qc "CREATE DATABASE ${DB_NAME} OWNER \"${DB_USER}\";" >/dev/null 2>&1 || true
    sudo -u postgres psql -qc "GRANT  ALL PRIVILEGES ON DATABASE ${DB_NAME} TO \"${DB_USER}\";" \
        >/dev/null 2>&1 || true

    systemctl restart postgresql >/dev/null 2>&1 || true
    ok "PostgreSQL configurado."

    # ── [3/6] Diretório de configuração ──────────────────────────────────────
    echo -e "${YELLOW}[3/6]${NC} Criando configuração..." >&2
    log "Criando ${CONFIG_DIR}"

    mkdir -p "${CONFIG_DIR}"

    if [[ ! -f "${CONFIG_DIR}/ssh_host_key" ]]; then
        ssh-keygen -q -t ed25519 -f "${CONFIG_DIR}/ssh_host_key" -N "" \
            || die "Falha ao gerar a host key SSH."
    fi

    [[ -f "${CONFIG_DIR}/config.json" ]] || echo '{}' > "${CONFIG_DIR}/config.json"

    local tmp_cfg; tmp_cfg=$(_tmp)
    jq \
        --arg db_user_b64    "$(printf '%s' "$DB_USER"    | base64 -w0)" \
        --arg db_pass_b64    "$(printf '%s' "$DB_PASS"    | base64 -w0)" \
        --arg admin_user_b64 "$(printf '%s' "$PANEL_USER" | base64 -w0)" \
        --arg admin_pass_b64 "$(printf '%s' "$PANEL_PASS" | base64 -w0)" \
        '
          .db_user_b64    = $db_user_b64    |
          .db_pass_b64    = $db_pass_b64    |
          .admin_user_b64 = $admin_user_b64 |
          .admin_pass_b64 = $admin_pass_b64
        ' "${CONFIG_DIR}/config.json" > "$tmp_cfg" \
    && mv "$tmp_cfg" "${CONFIG_DIR}/config.json"

    if [[ ! -f "${CONFIG_DIR}/snapshot.json" ]]; then
        local db_pass_hash
        db_pass_hash=$(printf '%s' "$DB_PASS" | sha256sum | awk '{print $1}')
        jq -n \
            --arg db_user    "$DB_USER" \
            --arg hash       "$db_pass_hash" \
            --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '{ db_user: $db_user, db_pass_hash: $hash, created_at: $created_at }' \
        > "${CONFIG_DIR}/snapshot.json"
    fi

    mkdir -p "${CONFIG_DIR}/.license"
    for OLD_DIR in ".license" "cmd/build/.license" "../.license"; do
        if [[ -d "$OLD_DIR" && -f "$OLD_DIR/uuid" ]]; then
            cp -a "${OLD_DIR}/." "${CONFIG_DIR}/.license/"
            break
        fi
    done

    ok "Configuração criada em ${CONFIG_DIR}."

    # ── [4/6] Binário ────────────────────────────────────────────────────────
    echo -e "${YELLOW}[4/6]${NC} Obtendo binário..." >&2

    local LATEST_VERSION
    if [[ -n "$_MANUAL_PKG_PATH" ]]; then
        LATEST_VERSION="local"
        info "Usando arquivo local: ${_MANUAL_PKG_PATH}"
    else
        LATEST_VERSION=$(fetch_latest_version) \
            || die "Não foi possível obter a versão mais recente."
    fi

    download_package "$LATEST_VERSION" \
        || die "Falha ao obter o pacote."

    mv "/tmp/wssh-extract/${BINARY_NAME}" "$BINARY_TARGET"
    chmod +x "$BINARY_TARGET"

    local final_ver
    final_ver=$(get_installed_version 2>/dev/null || echo "$LATEST_VERSION")
    ok "Binário instalado em ${BINARY_TARGET} (v${final_ver})."

    # ── [5/6] Unit systemd ───────────────────────────────────────────────────
    echo -e "${YELLOW}[5/6]${NC} Criando serviço systemd..." >&2

    local tmp_unit; tmp_unit=$(_tmp)
    cat > "$tmp_unit" <<'UNIT_EOF'
[Unit]
Description=WSSH VPN Service
Documentation=https://github.com/MTplusWebSystem/wssh-vpn
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
WorkingDirectory=/etc/wssh
Environment=DB_NAME=__DB_NAME__
Environment=DB_USER=__DB_USER__
Environment=DB_PASSWORD=__DB_PASS__
ExecStart=/usr/local/bin/wssh-vpn server
Restart=on-failure
RestartSec=5
StartLimitInterval=60
StartLimitBurst=3
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wssh-vpn

[Install]
WantedBy=multi-user.target
UNIT_EOF

    sed -i \
        -e "s|__DB_NAME__|${DB_NAME}|g" \
        -e "s|__DB_USER__|${DB_USER}|g" \
        -e "s|__DB_PASS__|${DB_PASS}|g" \
        "$tmp_unit"

    mv "$tmp_unit" /etc/systemd/system/wssh-vpn.service
    ok "Unit systemd criada."

    # ── [6/6] Ativa e inicia o serviço ───────────────────────────────────────
    echo -e "${YELLOW}[6/6]${NC} Iniciando serviço..." >&2

    systemctl daemon-reload
    systemctl enable wssh-vpn >/dev/null 2>&1
    systemctl restart wssh-vpn 2>/dev/null || true

    local i ready=false
    for i in {1..15}; do
        if systemctl is-active --quiet wssh-vpn; then
            ready=true; break
        fi
        sleep 1
    done

    if [[ "$ready" != true ]]; then
        warn "O serviço não ficou ativo em 15 s. Verifique os logs:"
        echo -e "    ${DIM}journalctl -u wssh-vpn -n 50 --no-pager${NC}" >&2
        loge "Serviço wssh-vpn não iniciou após instalação."
    fi

    sep
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${GREEN}║           INSTALAÇÃO CONCLUÍDA COM SUCESSO!               ║${NC}" >&2
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════╣${NC}" >&2
    printf  "${GREEN}║${NC}  Versão    : %-43s${GREEN}║${NC}\n" "v${final_ver}" >&2
    printf  "${GREEN}║${NC}  Serviço   : %-43s${GREEN}║${NC}\n" "$(systemctl is-active wssh-vpn 2>/dev/null || echo 'verificar')" >&2
    printf  "${GREEN}║${NC}  Log       : %-43s${GREEN}║${NC}\n" "${LOG_FILE}" >&2
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════╣${NC}" >&2
    echo -e "${GREEN}║${NC}  Acesse o menu CLI a qualquer momento:                   ${GREEN}║${NC}" >&2
    echo -e "${GREEN}║${NC}    ${BOLD}wssh-vpn${NC}                                              ${GREEN}║${NC}" >&2
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}" >&2
    echo "" >&2

    log "Instalação concluída. Versão: ${final_ver}"
}

# =============================================================================
#  ATUALIZAÇÃO
# =============================================================================
update_vpn() {
    step "Iniciando atualização do WSSH-VPN..."
    sep

    if [[ ! -x "$BINARY_TARGET" ]]; then
        warn "WSSH-VPN não está instalado em ${BINARY_TARGET}."
        info "Redirecionando para instalação a partir de arquivo local..."
        echo "" >&2
        install_local_package
        return
    fi

    # ── [1/5] Verifica versão ────────────────────────────────────────────────
    echo -e "${YELLOW}[1/5]${NC} Verificando versão..." >&2

    local INSTALLED_VERSION LATEST_VERSION
    INSTALLED_VERSION=$(get_installed_version)
    LATEST_VERSION=$(fetch_latest_version) \
        || die "Não foi possível obter a versão mais recente."

    printf "    Instalada   : %s\n" "${INSTALLED_VERSION:-desconhecida}" >&2
    printf "    Disponível  : %s\n" "$LATEST_VERSION" >&2

    if [[ -n "$INSTALLED_VERSION" ]] && ! _version_lt "$INSTALLED_VERSION" "$LATEST_VERSION"; then
        ok "Já está na versão mais recente (v${LATEST_VERSION}). Nenhuma ação necessária."
        return 0
    fi

    # ── [2/5] Download ───────────────────────────────────────────────────────
    echo -e "${YELLOW}[2/5]${NC} Baixando e validando pacote..." >&2

    download_package "$LATEST_VERSION" \
        || die "Falha no download. O serviço atual não foi alterado."

    local NEW_BINARY="/tmp/wssh-extract/${BINARY_NAME}"
    [[ -f "$NEW_BINARY" ]] || die "Binário não encontrado após extração."
    chmod +x "$NEW_BINARY"

    # ── [3/5] Para serviço e faz backup ─────────────────────────────────────
    echo -e "${YELLOW}[3/5]${NC} Preparando substituição do binário..." >&2

    systemctl stop wssh-vpn \
        || die "Não foi possível parar o serviço. Abortando para preservar instalação atual."

    local pids
    pids=$(pgrep -x wssh-vpn 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
        sleep 2
        pids=$(pgrep -x wssh-vpn 2>/dev/null || true)
        [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null || true
        sleep 1
    fi

    rm -f "$BACKUP_BINARY"
    cp -a "$BINARY_TARGET" "$BACKUP_BINARY" \
        || { systemctl start wssh-vpn 2>/dev/null; die "Falha ao criar backup do binário."; }

    local tmp_new="${BINARY_TARGET}.new"
    cp -a "$NEW_BINARY" "$tmp_new" && chmod +x "$tmp_new" \
        || { rm -f "$tmp_new"; systemctl start wssh-vpn 2>/dev/null; die "Falha ao preparar novo binário."; }

    mv "$tmp_new" "$BINARY_TARGET" \
        || {
            rm -f "$tmp_new"
            warn "Falha ao instalar novo binário. Restaurando versão anterior..."
            cp -a "$BACKUP_BINARY" "$BINARY_TARGET"
            chmod +x "$BINARY_TARGET"
            systemctl start wssh-vpn 2>/dev/null
            die "Atualização falhou. Versão anterior restaurada."
        }

    ok "Novo binário instalado."

    # ── [4/5] Reinicia serviço ───────────────────────────────────────────────
    echo -e "${YELLOW}[4/5]${NC} Reiniciando serviço..." >&2

    if ! systemctl start wssh-vpn; then
        warn "Novo binário falhou ao iniciar. Restaurando versão anterior..."
        loge "Novo binário não iniciou (v${LATEST_VERSION}). Rollback para v${INSTALLED_VERSION}."
        cp -a "$BACKUP_BINARY" "$BINARY_TARGET"
        chmod +x "$BINARY_TARGET"
        systemctl start wssh-vpn 2>/dev/null || true
        die "Atualização revertida. Verifique: journalctl -u wssh-vpn -n 50 --no-pager"
    fi

    # ── [5/5] Confirma atualização ───────────────────────────────────────────
    echo -e "${YELLOW}[5/5]${NC} Verificando serviço..." >&2

    local i ready=false
    for i in {1..10}; do
        systemctl is-active --quiet wssh-vpn && { ready=true; break; }
        sleep 1
    done

    if [[ "$ready" == true ]]; then
        sep
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}" >&2
        echo -e "${GREEN}║           ATUALIZAÇÃO CONCLUÍDA COM SUCESSO!              ║${NC}" >&2
        echo -e "${GREEN}╠═══════════════════════════════════════════════════════════╣${NC}" >&2
        printf  "${GREEN}║${NC}  Versão anterior : %-39s${GREEN}║${NC}\n" "${INSTALLED_VERSION:-desconhecida}" >&2
        printf  "${GREEN}║${NC}  Versão atual    : %-39s${GREEN}║${NC}\n" "v${LATEST_VERSION}" >&2
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}" >&2
        echo "" >&2
        log "Atualização concluída: ${INSTALLED_VERSION} → ${LATEST_VERSION}"
    else
        loge "Serviço não ativou após update para v${LATEST_VERSION}."
        warn "Serviço não ficou ativo após a atualização."
        echo -e "    Logs: ${DIM}journalctl -u wssh-vpn -n 50 --no-pager${NC}" >&2
    fi
}

# =============================================================================
#  DESINSTALAÇÃO
# =============================================================================
uninstall_vpn() {
    step "Desinstalação do WSSH-VPN..."
    sep

    echo -e "${RED}  ATENÇÃO: Esta operação remove o WSSH-VPN do sistema.${NC}" >&2
    echo -e "${DIM}  Backups de banco de dados e configurações são recomendados antes de prosseguir.${NC}" >&2
    echo "" >&2

    _ask_confirm "Confirma a desinstalação?" "n" \
        || { warn "Desinstalação cancelada."; return 0; }

    local cfg_db_user cfg_db_name
    cfg_db_user=$(
        jq -r '.db_user_b64 // empty' "${CONFIG_DIR}/config.json" 2>/dev/null \
        | base64 -d 2>/dev/null \
        || echo "wssh_user"
    )
    cfg_db_name="$DB_NAME"

    # ── [1/4] Para serviços ──────────────────────────────────────────────────
    echo -e "${YELLOW}[1/4]${NC} Parando serviço..." >&2
    systemctl stop    wssh-vpn 2>/dev/null || true
    systemctl disable wssh-vpn 2>/dev/null || true
    ok "Serviço parado."

    # ── [2/4] Remove arquivos do sistema ────────────────────────────────────
    echo -e "${YELLOW}[2/4]${NC} Removendo arquivos do sistema..." >&2
    rm -f /etc/systemd/system/wssh-vpn.service
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$BINARY_TARGET" "${BINARY_TARGET}.bak"
    ok "Binário e unit systemd removidos."

    # ── [3/4] Banco de dados (opcional) ─────────────────────────────────────
    echo -e "${YELLOW}[3/4]${NC} Banco de dados..." >&2
    if _ask_confirm "Remover banco '${cfg_db_name}' e usuário '${cfg_db_user}'?" "n"; then
        sudo -u postgres psql -qc "DROP DATABASE IF EXISTS ${cfg_db_name};" >/dev/null 2>&1 || true
        sudo -u postgres psql -qc "DROP USER IF EXISTS \"${cfg_db_user}\";"  >/dev/null 2>&1 || true
        ok "Banco de dados e usuário removidos."
    else
        info "Banco de dados preservado."
    fi

    # ── [4/4] Configurações e licenças (opcional) ────────────────────────────
    echo -e "${YELLOW}[4/4]${NC} Configurações..." >&2
    if _ask_confirm "Remover configurações e licenças (${CONFIG_DIR})?" "n"; then
        rm -rf "${CONFIG_DIR}"
        ok "Diretório ${CONFIG_DIR} removido."
    else
        info "Configurações preservadas em ${CONFIG_DIR}."
    fi

    sep
    ok "Desinstalação concluída."
    log "Desinstalação executada."
    echo "" >&2
}

# =============================================================================
#  INSTALAÇÃO / ATUALIZAÇÃO A PARTIR DE ARQUIVO LOCAL  (opção 4)
#
#  Aceita tanto wssh-vpn.tar.gz quanto o nome "download" (legado).
#  Qualquer arquivo encontrado é normalizado para wssh-vpn.tar.gz antes
#  de prosseguir.
# =============================================================================
install_local_package() {
    step "Instalar / Atualizar a partir de arquivo local..."
    sep

    echo -e "${BOLD}  Use esta opção quando o download automático falhar.${NC}" >&2
    echo -e "${DIM}  Baixe o pacote e informe o caminho abaixo.${NC}" >&2
    echo -e "${DIM}  Exemplo: wget ${UPDATE_API}/<versão>/download -O ${PKG_FILENAME}${NC}" >&2
    echo "" >&2

    # Se ainda não foi fornecido via --file, procura automaticamente
    if [[ -z "$_MANUAL_PKG_PATH" ]]; then
        local default_path=""

        # Candidatos: wssh-vpn.tar.gz tem prioridade; "download" é fallback legado
        local -a candidates=(
            "./wssh-vpn.tar.gz"
            "${HOME}/wssh-vpn.tar.gz"
            "/root/wssh-vpn.tar.gz"
            "/tmp/wssh-vpn.tar.gz"
            "./download"
            "${HOME}/download"
            "/root/download"
            "/tmp/wssh-download"
        )

        for candidate in "${candidates[@]}"; do
            if [[ -f "$candidate" ]]; then
                local sz
                sz=$(stat -c%s "$candidate" 2>/dev/null || echo 0)
                info "Arquivo encontrado: ${candidate} ($(( sz / 1024 / 1024 )) MB)"
                default_path="$candidate"
                break
            fi
        done

        local pkg_path=""
        _ask pkg_path "Caminho do arquivo baixado" "$default_path"
        [[ -n "$pkg_path" ]] || die "Caminho não informado."
        _MANUAL_PKG_PATH="$pkg_path"
    fi

    [[ -f "$_MANUAL_PKG_PATH" ]] \
        || die "Arquivo não encontrado: ${_MANUAL_PKG_PATH}"

    # Garante que o arquivo se chama wssh-vpn.tar.gz
    _normalize_pkg_path

    local fsize
    fsize=$(stat -c%s "$_MANUAL_PKG_PATH" 2>/dev/null || echo 0)
    info "Arquivo: ${_MANUAL_PKG_PATH}  ($(( fsize / 1024 / 1024 )) MB)"

    # Valida que é tar.gz antes de qualquer coisa
    info "Validando integridade do arquivo..."
    if ! tar -tzf "$_MANUAL_PKG_PATH" >/dev/null 2>&1; then
        die "Arquivo inválido: não parece ser um pacote tar.gz do WSSH-VPN." \
            "Verifique se o download foi concluído (tamanho esperado: ~148 MB)."
    fi
    ok "Arquivo válido."
    echo "" >&2

    # ── Decide fluxo: primeira instalação ou upgrade ──────────────────────
    if [[ -x "$BINARY_TARGET" ]]; then
        info "WSSH-VPN já instalado — substituindo binário (configuração preservada)."
        sep
        _local_upgrade
    else
        info "WSSH-VPN não instalado — iniciando instalação completa com arquivo local."
        sep
        install_vpn
    fi
}

# Substitui apenas o binário, preservando config/DB/systemd existentes
_local_upgrade() {
    step "Upgrade manual do binário..."

    download_package "local"

    local NEW_BINARY="/tmp/wssh-extract/${BINARY_NAME}"
    [[ -f "$NEW_BINARY" ]] || die "Binário '${BINARY_NAME}' não encontrado no pacote extraído."

    local prev_ver
    prev_ver=$(get_installed_version)

    info "Parando serviço..."
    systemctl stop wssh-vpn 2>/dev/null || true
    sleep 1

    local pids
    pids=$(pgrep -x wssh-vpn 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        info "Aguardando término dos processos residuais..."
        kill $pids 2>/dev/null || true
        sleep 2
        pids=$(pgrep -x wssh-vpn 2>/dev/null || true)
        [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null || true
        sleep 1
    fi

    rm -f "$BACKUP_BINARY"
    if [[ -f "$BINARY_TARGET" ]]; then
        cp -a "$BINARY_TARGET" "$BACKUP_BINARY" \
            || warn "Não foi possível criar backup do binário anterior."
    fi

    local tmp_new="${BINARY_TARGET}.new"
    cp "$NEW_BINARY" "$tmp_new" && chmod +x "$tmp_new" || {
        rm -f "$tmp_new"
        systemctl start wssh-vpn 2>/dev/null || true
        die "Falha ao preparar novo binário em ${tmp_new}."
    }

    mv "$tmp_new" "$BINARY_TARGET" || {
        rm -f "$tmp_new"
        warn "Falha ao instalar novo binário (mv). Restaurando versão anterior..."
        [[ -f "$BACKUP_BINARY" ]] && cp -a "$BACKUP_BINARY" "$BINARY_TARGET" && chmod +x "$BINARY_TARGET"
        systemctl start wssh-vpn 2>/dev/null || true
        die "Upgrade manual falhou. Versão anterior restaurada."
    }

    if ! systemctl start wssh-vpn 2>/dev/null; then
        warn "Novo binário não iniciou. Restaurando versão anterior..."
        [[ -f "$BACKUP_BINARY" ]] && cp -a "$BACKUP_BINARY" "$BINARY_TARGET" && chmod +x "$BINARY_TARGET"
        systemctl start wssh-vpn 2>/dev/null || true
        die "Rollback executado. Verifique: journalctl -u wssh-vpn -n 50 --no-pager"
    fi

    local i ready=false
    for i in {1..10}; do
        systemctl is-active --quiet wssh-vpn && { ready=true; break; }
        sleep 1
    done

    local new_ver
    new_ver=$(get_installed_version 2>/dev/null || echo "desconhecida")

    sep
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${GREEN}║        UPGRADE MANUAL CONCLUÍDO COM SUCESSO!              ║${NC}" >&2
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════╣${NC}" >&2
    printf  "${GREEN}║${NC}  Versão anterior : %-39s${GREEN}║${NC}\n" "${prev_ver:-desconhecida}" >&2
    printf  "${GREEN}║${NC}  Versão atual    : %-39s${GREEN}║${NC}\n" "${new_ver}" >&2
    printf  "${GREEN}║${NC}  Origem          : %-39s${GREEN}║${NC}\n" "$(basename "$_MANUAL_PKG_PATH")" >&2
    printf  "${GREEN}║${NC}  Serviço         : %-39s${GREEN}║${NC}\n" "$(systemctl is-active wssh-vpn 2>/dev/null || echo 'verificar')" >&2
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}" >&2
    echo "" >&2

    [[ "$ready" != true ]] && {
        warn "Serviço pode não estar totalmente ativo."
        echo -e "    ${DIM}journalctl -u wssh-vpn -n 30 --no-pager${NC}" >&2
    }

    log "Upgrade manual: ${_MANUAL_PKG_PATH} — v${prev_ver:-?} → v${new_ver}"
}

# =============================================================================
#  MENU INTERATIVO
# =============================================================================
show_menu() {
    while true; do
        echo -e "${CYAN}  O que você deseja fazer?${NC}" >&2
        echo "" >&2
        echo -e "    ${YELLOW}[1]${NC} Instalar    WSSH-VPN" >&2
        echo -e "    ${YELLOW}[2]${NC} Atualizar   WSSH-VPN" >&2
        echo -e "    ${YELLOW}[3]${NC} Desinstalar WSSH-VPN" >&2
        echo -e "    ${YELLOW}[4]${NC} Instalar / Atualizar a partir de ${BOLD}arquivo local${NC} (${PKG_FILENAME})" >&2
        echo -e "    ${DIM}      (instala ou atualiza sem precisar de download)${NC}" >&2
        echo -e "    ${YELLOW}[0]${NC} Sair" >&2
        echo "" >&2

        local option
        read -r -p "$(echo -e "  ${BOLD}→${NC} Opção: ")" option < /dev/tty

        echo "" >&2
        case "$option" in
            1) install_vpn;           break ;;
            2) update_vpn;            break ;;
            3) uninstall_vpn;         break ;;
            4) install_local_package; break ;;
            0) info "Saindo."; exit 0 ;;
            *) warn "Opção inválida: '${option}'. Tente novamente."; echo "" >&2 ;;
        esac
    done
}

# =============================================================================
#  ENTRYPOINT
# =============================================================================
main() {
    _parse_args "$@"
    _log_file_init
    require_root
    preflight_check
    detect_platform
    show_banner

    log "=== Installer v${INSTALLER_VERSION} iniciado. OS=${PLATFORM_OS} ARCH=${PLATFORM_ARCH} ==="
    [[ -n "$_MANUAL_PKG_PATH" ]] && log "Arquivo local informado: ${_MANUAL_PKG_PATH}"

    # Se foi passado --file na linha de comando, normaliza imediatamente
    if [[ -n "$_MANUAL_PKG_PATH" ]]; then
        [[ -f "$_MANUAL_PKG_PATH" ]] || die "Arquivo não encontrado: ${_MANUAL_PKG_PATH}"
        _normalize_pkg_path
    fi

    case "${_ACTION:-}" in
        install)   install_vpn            ;;
        update)    update_vpn             ;;
        uninstall) uninstall_vpn          ;;
        local)     install_local_package  ;;
        *)         show_menu              ;;
    esac
}

main "$@"
