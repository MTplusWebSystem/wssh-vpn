#!/usr/bin/env bash
# =============================================================================
#  WSSH-VPN — Installer / Updater / Uninstaller
#  Usage (pipe-safe):
#    curl  -fsSL https://raw.githubusercontent.com/MTplusWebSystem/wssh-vpn/refs/heads/main/install.sh | sudo bash
#    wget  -qO-  https://raw.githubusercontent.com/MTplusWebSystem/wssh-vpn/refs/heads/main/install.sh | sudo bash
#    # Modo não-interativo:
#    curl -fsSL ... | sudo bash -s -- install --auto
# =============================================================================
set -euo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

# ── Versão do installer ───────────────────────────────────────────────────────
readonly INSTALLER_VERSION="2.0.0"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/wssh"
readonly DB_NAME="wssh_db"
readonly BINARY_TARGET="${INSTALL_DIR}/wssh-vpn"
readonly BACKUP_BINARY="${INSTALL_DIR}/wssh-vpn.bak"
readonly UPDATE_API="https://update.mtwtech.shop"
readonly LOG_FILE="/var/log/wssh-vpn-install.log"

# ── Flags de controle ─────────────────────────────────────────────────────────
AUTO_MODE=false       # --auto: usa defaults sem perguntar
QUIET=false           # --quiet: suprime banner

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
info()    { echo -e "${BLUE}[·]${NC} $*"          >&2; log "$*"; }
ok()      { echo -e "${GREEN}[✓]${NC} $*"        >&2; log "OK: $*"; } >&2
warn()    { echo -e "${YELLOW}[!]${NC} $*"        >&2; logw "$*"; }
step()    { echo -e "${CYAN}[→]${NC} ${BOLD}$*${NC}" >&2; log "STEP: $*"; } >&2
die()     { echo -e "${RED}[✗] ERRO:${NC} $*"    >&2; loge "$*"; echo -e "${DIM}    Log completo: ${LOG_FILE}${NC}" >&2; exit 1; } >&2
sep()     { echo -e "${DIM}────────────────────────────────────────────────────────────${NC}" >&2; } >&2

# ── Cleanup de arquivos temporários ──────────────────────────────────────────
_TMP_FILES=()
_tmp() { local f; f=$(mktemp); _TMP_FILES+=("$f"); echo "$f"; }
_cleanup() {
    local f
    for f in "${_TMP_FILES[@]:-}"; do
        [[ -f "$f" ]] && rm -f "$f" 2>/dev/null || true
    done
    rm -rf /tmp/wssh-extract 2>/dev/null || true
}
trap _cleanup EXIT

# ── Wrappers curl com fallback SSL ───────────────────────────────────────────
#
# Tenta com verificação SSL; se falhar por certificado inválido/expirado,
# repete com -k e emite um aviso visível.
#
_CURL_INSECURE=false   # definido como true na primeira vez que usamos -k

_curl_get() {
    # _curl_get [extra_flags...] <url>  → stdout = corpo da resposta
    local out ec
    out=$(curl -fsSL \
        --connect-timeout 15 --max-time 30 \
        --retry 3 --retry-delay 2 \
        -A "wssh-installer/${INSTALLER_VERSION}" \
        "$@" 2>/dev/null) && { printf '%s' "$out"; return 0; }

    # Fallback: desabilita verificação SSL
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

_curl_download() {
    # _curl_download <output_file> <url>  → salva em arquivo
    local output_file="$1"; shift
    curl -fL \
        --connect-timeout 15 --max-time 300 \
        --retry 2 --retry-delay 3 \
        -A "wssh-installer/${INSTALLER_VERSION}" \
        -o "$output_file" "$@" 2>/dev/null && return 0

    # Fallback SSL
    curl -fL -k \
        --connect-timeout 15 --max-time 300 \
        --retry 2 --retry-delay 3 \
        -A "wssh-installer/${INSTALLER_VERSION}" \
        -o "$output_file" "$@" 2>/dev/null && {
        if [[ "$_CURL_INSECURE" == false ]]; then
            warn "Certificado SSL do servidor expirado — download com SSL desabilitado."
            _CURL_INSECURE=true
        fi
        return 0
    }

    return 1
}

# ── Parse de argumentos ───────────────────────────────────────────────────────
_ACTION=""
_EXTRA_ARGS=()

_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|update|uninstall) _ACTION="$1" ;;
            --auto|-y)   AUTO_MODE=true ;;
            --quiet|-q)  QUIET=true ;;
            --help|-h)
                echo "Uso: install.sh [install|update|uninstall] [--auto] [--quiet]"
                exit 0
                ;;
            *) _EXTRA_ARGS+=("$1") ;;
        esac
        shift
    done
}

# ── Leitura de input (pipe-safe: sempre via /dev/tty) ─────────────────────────
#
# _ask VAR "Prompt" "default"           → leitura normal
# _ask_secret VAR "Prompt" "default"   → leitura oculta (senha)
# _ask_confirm "Mensagem"              → retorna 0=sim 1=não
#
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

    # Systemd
    if ! command -v systemctl &>/dev/null; then
        die "systemd não encontrado. O WSSH-VPN requer systemd."
    fi

    # Espaço em disco (mínimo 200 MB em /usr)
    local free_kb
    free_kb=$(df -k /usr/local/bin | awk 'NR==2{print $4}')
    if [[ "$free_kb" -lt 204800 ]]; then
        die "Espaço insuficiente em /usr (disponível: $((free_kb / 1024)) MB, mínimo: 200 MB)."
    fi

    # Dependências críticas
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

    # Android via Termux
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

# ── Versão instalada (se houver) ──────────────────────────────────────────────
get_installed_version() {
    # Suporta versões como 1.2.3, 1.2.3.alpha.70, 1.2.3-beta.4
    if [[ -x "$BINARY_TARGET" ]]; then
        "$BINARY_TARGET" --version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([.a-zA-Z0-9-]*)?' \
        | head -1 \
        || echo ""
    else
        echo "" >&2
    fi
}

# ── Obtém versão mais recente da API ─────────────────────────────────────────
fetch_latest_version() {
    # Retorna APENAS a versão no stdout. Toda mensagem vai para stderr via info/warn.
    local version=""

    info "Consultando versão mais recente em ${UPDATE_API}..."

    version=$(
        _curl_get "${UPDATE_API}/latest" \
        | jq -r '.data.version // empty' 2>/dev/null \
        || true
    )

    # Sanitiza: remove espaços, newlines e caracteres de controle
    version=$(printf '%s' "$version" | tr -d '[:space:][:cntrl:]')

    if [[ -z "$version" || "$version" == "null" ]]; then
        warn "API indisponível. Informe a versão manualmente."
        _ask version "Versão (ex: 1.2.3)" ""
        [[ -n "$version" ]] || die "Versão não informada."
        # Sanitiza input do usuário também
        version=$(printf '%s' "$version" | tr -d '[:space:][:cntrl:]')
    fi

    info "Versão obtida: ${version}"
    printf '%s' "$version"
}

# ── Compara versões (A < B → retorna 0; A >= B → retorna 1) ──────────────────
#
# Suporta: 1.2.3  1.2.3.alpha.70  1.2.3-beta.4
# Estratégia: compara segmento a segmento; segmentos não-numéricos (alpha, beta)
# são tratados como 0 (versão de pré-release < release do mesmo número).
#
_version_lt() {
    [[ "$1" == "$2" ]] && return 1

    # Normaliza separadores (. e -) e converte para array
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

        # Se segmento não for numérico puro, usa 0 (alpha < release)
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
download_package() {
    local version="$1"
    local url="${UPDATE_API}/${version}/download"
    local package_file; package_file=$(_tmp)
    local extract_dir="/tmp/wssh-extract"

    info "Baixando wssh-vpn v${version} (${BINARY_NAME})..."
    log "URL: ${url}"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    local attempt downloaded=false
    for attempt in 1 2 3; do
        info "Download — tentativa ${attempt}/3..."
        if _curl_download "$package_file" "$url" && [[ -s "$package_file" ]]; then
            downloaded=true
            break
        fi
        warn "Tentativa ${attempt} falhou."
        rm -f "$package_file"
        [[ "$attempt" -lt 3 ]] && sleep 3
    done

    [[ "$downloaded" == true ]] || die "Falha no download após 3 tentativas. URL: ${url}"

    ok "Download concluído."

    # Validação do pacote
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

    # Verifica binário
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

    # Mata processos residuais
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

    # Cria ou atualiza o usuário
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

    # Host key Ed25519 (mais compacta e segura que RSA-2048)
    if [[ ! -f "${CONFIG_DIR}/ssh_host_key" ]]; then
        ssh-keygen -q -t ed25519 -f "${CONFIG_DIR}/ssh_host_key" -N "" \
            || die "Falha ao gerar a host key SSH."
    fi

    # Inicializa config.json se necessário
    [[ -f "${CONFIG_DIR}/config.json" ]] || echo '{}' > "${CONFIG_DIR}/config.json"

    # Grava credenciais em base64 (evita problemas com chars especiais no JSON)
    local tmp_cfg; tmp_cfg=$(_tmp)
    jq \
        --arg db_user_b64   "$(printf '%s' "$DB_USER"   | base64 -w0)" \
        --arg db_pass_b64   "$(printf '%s' "$DB_PASS"   | base64 -w0)" \
        --arg admin_user_b64 "$(printf '%s' "$PANEL_USER" | base64 -w0)" \
        --arg admin_pass_b64 "$(printf '%s' "$PANEL_PASS" | base64 -w0)" \
        '
          .db_user_b64    = $db_user_b64    |
          .db_pass_b64    = $db_pass_b64    |
          .admin_user_b64 = $admin_user_b64 |
          .admin_pass_b64 = $admin_pass_b64
        ' "${CONFIG_DIR}/config.json" > "$tmp_cfg" \
    && mv "$tmp_cfg" "${CONFIG_DIR}/config.json"

    # snapshot.json (auditoria de instalação)
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

    # Copia licença existente, se houver
    mkdir -p "${CONFIG_DIR}/.license"
    for OLD_DIR in ".license" "cmd/build/.license" "../.license"; do
        if [[ -d "$OLD_DIR" && -f "$OLD_DIR/uuid" ]]; then
            cp -a "${OLD_DIR}/." "${CONFIG_DIR}/.license/"
            break
        fi
    done

    ok "Configuração criada em ${CONFIG_DIR}."

    # ── [4/6] Binário ────────────────────────────────────────────────────────
    echo -e "${YELLOW}[4/6]${NC} Baixando binário..." >&2

    local LATEST_VERSION
    LATEST_VERSION=$(fetch_latest_version) \
        || die "Não foi possível obter a versão mais recente."

    download_package "$LATEST_VERSION" \
        || die "Falha ao obter o pacote v${LATEST_VERSION}."

    mv "/tmp/wssh-extract/${BINARY_NAME}" "$BINARY_TARGET"
    chmod +x "$BINARY_TARGET"
    ok "Binário instalado em ${BINARY_TARGET} (v${LATEST_VERSION})."

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

    # Substitui placeholders de forma segura (sem risco de injeção)
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

    # Aguarda inicialização (até 15 s)
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
    printf  "${GREEN}║${NC}  Versão    : %-43s${GREEN}║${NC}\n" "v${LATEST_VERSION}" >&2
    printf  "${GREEN}║${NC}  Serviço   : %-43s${GREEN}║${NC}\n" "$(systemctl is-active wssh-vpn 2>/dev/null || echo 'verificar')" >&2
    printf  "${GREEN}║${NC}  Log       : %-43s${GREEN}║${NC}\n" "${LOG_FILE}" >&2
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════╣${NC}" >&2
    echo -e "${GREEN}║${NC}  Acesse o menu CLI a qualquer momento:                   ${GREEN}║${NC}" >&2
    echo -e "${GREEN}║${NC}    ${BOLD}wssh-vpn${NC}                                              ${GREEN}║${NC}" >&2
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}" >&2
    echo "" >&2

    log "Instalação concluída. Versão: ${LATEST_VERSION}"
}

# =============================================================================
#  ATUALIZAÇÃO
# =============================================================================
update_vpn() {
    step "Iniciando atualização do WSSH-VPN..."
    sep

    [[ -x "$BINARY_TARGET" ]] \
        || die "WSSH-VPN não está instalado em ${BINARY_TARGET}. Execute a instalação primeiro."

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

    rm -f "$BACKUP_BINARY"
    cp -a "$BINARY_TARGET" "$BACKUP_BINARY" \
        || { systemctl start wssh-vpn 2>/dev/null; die "Falha ao criar backup do binário."; }

    cp -a "$NEW_BINARY" "$BINARY_TARGET" \
        || {
            warn "Falha ao instalar novo binário. Restaurando versão anterior..."
            cp -a "$BACKUP_BINARY" "$BINARY_TARGET"
            chmod +x "$BINARY_TARGET"
            systemctl start wssh-vpn 2>/dev/null
            die "Atualização falhou. Versão anterior restaurada."
        }

    chmod +x "$BINARY_TARGET"
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

    # Lê usuário do config (com fallback)
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
#  MENU INTERATIVO
# =============================================================================
show_menu() {
    while true; do
        {
            echo -e "${CYAN}  O que você deseja fazer?${NC}" >&2
            echo "" >&2
            echo -e "    ${YELLOW}[1]${NC} Instalar   WSSH-VPN" >&2
            echo -e "    ${YELLOW}[2]${NC} Atualizar  WSSH-VPN" >&2
            echo -e "    ${YELLOW}[3]${NC} Desinstalar WSSH-VPN" >&2
            echo -e "    ${YELLOW}[0]${NC} Sair" >&2
            echo "" >&2
        } >&2

        local option
        read -r -p "$(echo -e "  ${BOLD}→${NC} Opção: " >&2; echo -n "")" option < /dev/tty >&2

        echo "" >&2
        case "$option" in
            1) install_vpn;   break ;;
            2) update_vpn;    break ;;
            3) uninstall_vpn; break ;;
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

    case "${_ACTION:-}" in
        install)   install_vpn   ;;
        update)    update_vpn    ;;
        uninstall) uninstall_vpn ;;
        *)         show_menu     ;;
    esac
}

main "$@"
