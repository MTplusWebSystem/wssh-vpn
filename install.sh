#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Verifica root ────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
  echo -e "${RED}[ERROR] Este script deve ser executado como root (sudo).${NC}" >&2
  exit 1
fi

clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              WSSH-VPN — SETUP DE INSTALAÇÃO               ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Detecção de arquitetura ──────────────────────────────────
MACHINE=$(uname -m)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

case "$MACHINE" in
  x86_64)          ARCH="amd64"   ;;
  i386|i686)       ARCH="386"     ;;
  aarch64|arm64)   ARCH="aarch64" ;;
  armv7l|armv7)    ARCH="armv7"   ;;
  armv6l|armv6)    ARCH="armv6"   ;;
  armv5l|armv5tel) ARCH="armv5"   ;;
  riscv64)         ARCH="riscv64" ;;
  ppc64le)         ARCH="ppc64le" ;;
  s390x)           ARCH="s390x"   ;;
  *)
    echo -e "${RED}[ERROR] Arquitetura não suportada: $MACHINE${NC}" >&2
    exit 1
    ;;
esac

# Android via Termux (root)
if [[ -d "/data/data/com.termux" ]]; then
  OS="android"
fi

BINARY_NAME="wssh-vpn_${OS}_${ARCH}"
DB_NAME="wssh_db"

echo -e "${BLUE}[i] Sistema detectado: ${GREEN}${OS}/${ARCH}${NC}"
echo -e "${BLUE}[i] Binário selecionado: ${GREEN}${BINARY_NAME}${NC}"
echo ""

# ── Pré-instala dependências críticas ───────────────────────
for dep in jq curl wget; do
  if ! command -v "$dep" &>/dev/null; then
    echo -e "${YELLOW}[dep] Instalando $dep...${NC}"
    apt-get install -y -qq "$dep" >/dev/null 2>&1
  fi
done

# ── Obtém versão com fallback manual ────────────────────────
# Imprime logs no stderr; ecoa apenas a versão no stdout
fetch_latest_version() {
  local version
  echo -e "${BLUE}[i] Consultando: https://update.mtwtech.shop/latest${NC}" >&2

  version=$(curl -sL \
    --connect-timeout 10 \
    --max-time 15 \
    "https://update.mtwtech.shop/latest" 2>/dev/null \
    | jq -r '.data.version // empty' 2>/dev/null || true)

  if [[ -z "$version" || "$version" == "null" ]]; then
    echo -e "${YELLOW}[!] API indisponível ou sem resposta.${NC}" >&2
    echo -e "${YELLOW}[?] Informe a versão manualmente (ex: 1.2.3):${NC}" >&2
    read -r -p "    Versão: " version < /dev/tty
    if [[ -z "$version" ]]; then
      echo -e "${RED}[ERROR] Versão não informada. Abortando.${NC}" >&2
      exit 1
    fi
  fi

  echo "$version"
}

# ── Baixa e extrai o pacote (3 tentativas) ──────────────────
# Uso: download_package <versão>
download_package() {
  local version="$1"
  local url="https://update.mtwtech.shop/${version}/download"

  echo -e "${BLUE}[i] Baixando versão ${version}: ${url}${NC}"
  echo -e "${BLUE}[i] Binário alvo: ${BINARY_NAME}${NC}"

  local attempt
  for attempt in 1 2 3; do
    if wget -qO /tmp/wssh-vpn.tar.gz \
         --connect-timeout=10 \
         --tries=1 \
         "$url" && [[ -s /tmp/wssh-vpn.tar.gz ]]; then
      break
    fi
    echo -e "${YELLOW}[!] Tentativa ${attempt} falhou, aguardando...${NC}"
    [[ "$attempt" -lt 3 ]] && sleep 3
    if [[ "$attempt" -eq 3 ]]; then
      echo -e "${RED}[ERROR] Falha ao baixar o pacote: ${url}${NC}" >&2
      return 1
    fi
  done

  rm -rf /tmp/wssh-extract
  mkdir -p /tmp/wssh-extract
  tar -xzf /tmp/wssh-vpn.tar.gz -C /tmp/wssh-extract
  rm -f /tmp/wssh-vpn.tar.gz

  if [[ ! -f "/tmp/wssh-extract/${BINARY_NAME}" ]]; then
    echo -e "${RED}[ERROR] Binário '${BINARY_NAME}' não encontrado no pacote.${NC}" >&2
    echo -e "${RED}[ERROR] Disponíveis:${NC}" >&2
    ls /tmp/wssh-extract/ | sed 's/^/    /' >&2
    rm -rf /tmp/wssh-extract
    return 1
  fi

  return 0
}

# ────────────────────────────────────────────────────────────

install_vpn() {
  # ── Coleta parâmetros ──
  echo -e "${GREEN}[?] Parâmetros de Banco de Dados${NC}"
  read -r -p "    Usuário (mín. 6 caracteres) [wssh_user]: " DB_USER < /dev/tty
  DB_USER="${DB_USER:-wssh_user}"

  local DB_PASS
  read -r -s -p "    Senha (mín. 8 caracteres) [senha123]: " DB_PASS < /dev/tty
  echo ""
  DB_PASS="${DB_PASS:-senha123}"
  echo ""

  echo -e "${GREEN}[?] Parâmetros do Painel Administrativo${NC}"
  read -r -p "    Usuário Admin (mín. 6 caracteres) [admin]: " PANEL_USER < /dev/tty
  PANEL_USER="${PANEL_USER:-admin}"

  local PANEL_PASS
  read -r -s -p "    Senha Admin (mín. 8 caracteres) [admin123]: " PANEL_PASS < /dev/tty
  echo ""
  PANEL_PASS="${PANEL_PASS:-admin123}"
  echo ""

  echo -e "${CYAN}⇨ Iniciando deployment da infraestrutura...${NC}"
  echo ""

  # ── [1/6] Limpeza ──
  echo -e "${YELLOW}[1/6] Realizando limpeza de cache de sistema...${NC}"
  systemctl stop wssh-vpn    2>/dev/null || true
  systemctl disable wssh-vpn 2>/dev/null || true
  rm -f /etc/systemd/system/wssh-vpn.service
  systemctl daemon-reload

  local pids
  pids=$(pgrep -x wssh-vpn 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    kill "$pids" 2>/dev/null || true
    sleep 2
    pids=$(pgrep -x wssh-vpn 2>/dev/null || true)
    [[ -n "$pids" ]] && kill -9 "$pids" 2>/dev/null || true
  fi
  rm -f /usr/local/bin/wssh-vpn /usr/local/bin/wssh-vpn.bak

  # ── [2/6] PostgreSQL ──
  echo -e "${YELLOW}[2/6] Otimizando PostgreSQL e estruturando Database...${NC}"
  if ! command -v psql &>/dev/null; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq postgresql postgresql-contrib >/dev/null 2>&1
  fi

  systemctl enable postgresql >/dev/null 2>&1 || true
  systemctl start  postgresql >/dev/null 2>&1 || true
  sleep 2

  sudo -u postgres psql -c "CREATE USER \"$DB_USER\" SUPERUSER PASSWORD '$DB_PASS';" >/dev/null 2>&1 || \
  sudo -u postgres psql -c "ALTER  USER \"$DB_USER\" SUPERUSER PASSWORD '$DB_PASS';" >/dev/null 2>&1 || true

  sudo -u postgres psql -c "DROP   DATABASE IF EXISTS $DB_NAME;"                       >/dev/null 2>&1 || true
  sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER \"$DB_USER\";"              >/dev/null 2>&1 || true
  sudo -u postgres psql -c "GRANT  ALL PRIVILEGES ON DATABASE $DB_NAME TO \"$DB_USER\";" >/dev/null 2>&1 || true
  sudo -u postgres psql -c "ALTER  DATABASE $DB_NAME OWNER TO \"$DB_USER\";"           >/dev/null 2>&1 || true
  systemctl restart postgresql >/dev/null 2>&1 || true

  # ── [3/6] Diretório de configuração ──
  echo -e "${YELLOW}[3/6] Arquitetando injeções de diretório JSON...${NC}"
  mkdir -p /etc/wssh

  # Ed25519 é mais compacto e mais rápido que RSA 2048
  if [[ ! -f /etc/wssh/ssh_host_key ]]; then
    ssh-keygen -q -t ed25519 -f /etc/wssh/ssh_host_key -N ""
  fi

  [[ ! -f /etc/wssh/config.json ]] && echo "{}" > /etc/wssh/config.json

  # Usa --arg para escapar valores corretamente (senhas com aspas/barras)
  local tmp_cfg
  tmp_cfg=$(mktemp)
  jq \
    --arg db_user_b64   "$(echo -n "$DB_USER"    | base64 -w0)" \
    --arg db_pass_b64   "$(echo -n "$DB_PASS"    | base64 -w0)" \
    --arg admin_user_b64 "$(echo -n "$PANEL_USER" | base64 -w0)" \
    --arg admin_pass_b64 "$(echo -n "$PANEL_PASS" | base64 -w0)" \
    '.db_user_b64      = $db_user_b64
   | .db_pass_b64      = $db_pass_b64
   | .admin_user_b64   = $admin_user_b64
   | .admin_pass_b64   = $admin_pass_b64' \
    /etc/wssh/config.json > "$tmp_cfg" \
  && mv "$tmp_cfg" /etc/wssh/config.json

  if [[ ! -f /etc/wssh/snapshot.json ]]; then
    local hash
    hash=$(echo -n "$DB_PASS" | sha256sum | awk '{print $1}')
    cat > /etc/wssh/snapshot.json <<'SNAPSHOT_EOF'
{
  "db_user": "__DB_USER__",
  "db_pass_hash": "__HASH__",
  "created_at": "__DATE__"
}
SNAPSHOT_EOF
    sed -i \
      -e "s|__DB_USER__|$DB_USER|g" \
      -e "s|__HASH__|$hash|g" \
      -e "s|__DATE__|$(date -u +"%Y-%m-%dT%H:%M:%SZ")|g" \
      /etc/wssh/snapshot.json
  fi

  mkdir -p /etc/wssh/.license
  for OLD_DIR in ".license" "cmd/build/.license" "../.license"; do
    if [[ -d "$OLD_DIR" && -f "$OLD_DIR/uuid" ]]; then
      cp -a "$OLD_DIR/"* /etc/wssh/.license/
      break
    fi
  done

  # ── [4/6] Binário ──
  echo -e "${YELLOW}[4/6] Configurando binário do WSSH...${NC}"
  local LATEST_VERSION
  LATEST_VERSION=$(fetch_latest_version)

  download_package "$LATEST_VERSION"

  mv "/tmp/wssh-extract/${BINARY_NAME}" /usr/local/bin/wssh-vpn
  rm -rf /tmp/wssh-extract
  chmod +x /usr/local/bin/wssh-vpn

  # ── [5/6] Unit systemd ──
  echo -e "${YELLOW}[5/6] Formulando processos daemon...${NC}"
  local tmp_unit
  tmp_unit=$(mktemp)
  cat > "$tmp_unit" <<UNIT_EOF
[Unit]
Description=WSSH VPN Service
After=network.target postgresql.service

[Service]
Type=simple
WorkingDirectory=/etc/wssh
Environment=DB_USER=${DB_USER}
Environment=DB_PASSWORD=${DB_PASS}
Environment=DB_NAME=${DB_NAME}
ExecStart=/usr/local/bin/wssh-vpn server
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT_EOF
  mv "$tmp_unit" /etc/systemd/system/wssh-vpn.service

  # ── [6/6] Systemd ──
  echo -e "${YELLOW}[6/6] Aplicando unidades Systemd...${NC}"
  systemctl daemon-reload
  systemctl enable  wssh-vpn >/dev/null 2>&1
  systemctl restart wssh-vpn 2>/dev/null || true

  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  Instalação concluída com sucesso!                        ║${NC}"
  echo -e "${CYAN}╠═══════════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║  Invoque o Menu CLI a qualquer hora digitando:            ║${NC}"
  echo -e "${CYAN}║  ${GREEN}wssh-vpn                                                 ${CYAN}║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

update_vpn() {
  echo -e "${CYAN}⇨ Iniciando atualização do WSSH-VPN...${NC}"
  echo ""

  echo -e "${YELLOW}[1/3] Parando serviço...${NC}"
  systemctl stop wssh-vpn 2>/dev/null || true

  echo -e "${YELLOW}[2/3] Verificando versão mais recente...${NC}"
  local LATEST_VERSION
  LATEST_VERSION=$(fetch_latest_version)

  download_package "$LATEST_VERSION" || {
    echo -e "${RED}[ERROR] Falha no download. Restaurando serviço...${NC}" >&2
    systemctl start wssh-vpn 2>/dev/null || true
    exit 1
  }

  rm -f /usr/local/bin/wssh-vpn.bak
  mv /usr/local/bin/wssh-vpn /usr/local/bin/wssh-vpn.bak 2>/dev/null || true
  mv "/tmp/wssh-extract/${BINARY_NAME}" /usr/local/bin/wssh-vpn
  rm -rf /tmp/wssh-extract
  chmod +x /usr/local/bin/wssh-vpn

  echo -e "${YELLOW}[3/3] Reiniciando serviço...${NC}"
  systemctl start wssh-vpn 2>/dev/null || true

  echo -e "${GREEN}[OK] WSSH-VPN atualizado com sucesso para a versão ${LATEST_VERSION}!${NC}"
}

uninstall_vpn() {
  echo -e "${RED}ATENÇÃO: Isso irá remover o WSSH-VPN completamente do seu sistema!${NC}"
  local confirm
  read -r -p "Deseja continuar? (s/n): " confirm < /dev/tty
  if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then
    echo -e "${YELLOW}Desinstalação cancelada.${NC}"
    return
  fi

  # Obtém usuário e banco reais do config para não depender de hardcode
  local cfg_db_user cfg_db_name
  cfg_db_user=$(jq -r '.db_user_b64 // empty' /etc/wssh/config.json 2>/dev/null \
    | base64 -d 2>/dev/null || echo "wssh_user")
  cfg_db_name="$DB_NAME"

  echo -e "${YELLOW}[1/4] Parando serviços...${NC}"
  systemctl stop    wssh-vpn 2>/dev/null || true
  systemctl disable wssh-vpn 2>/dev/null || true

  echo -e "${YELLOW}[2/4] Removendo arquivos do sistema...${NC}"
  rm -f /etc/systemd/system/wssh-vpn.service
  systemctl daemon-reload
  rm -f /usr/local/bin/wssh-vpn /usr/local/bin/wssh-vpn.bak

  echo -e "${YELLOW}[3/4] Removendo banco de dados (Opcional)...${NC}"
  local confirm_db
  read -r -p "Deseja remover o banco de dados (${cfg_db_name}) e usuário (${cfg_db_user})? (s/n): " confirm_db < /dev/tty
  if [[ "$confirm_db" == "s" || "$confirm_db" == "S" ]]; then
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${cfg_db_name};" >/dev/null 2>&1 || true
    sudo -u postgres psql -c "DROP USER IF EXISTS \"${cfg_db_user}\";" >/dev/null 2>&1 || true
    echo -e "${GREEN}Banco de dados removido.${NC}"
  fi

  echo -e "${YELLOW}[4/4] Removendo diretório de configuração...${NC}"
  local confirm_cfg
  read -r -p "Deseja remover configurações e licenças (/etc/wssh)? (s/n): " confirm_cfg < /dev/tty
  if [[ "$confirm_cfg" == "s" || "$confirm_cfg" == "S" ]]; then
    rm -rf /etc/wssh
    echo -e "${GREEN}Configurações removidas.${NC}"
  fi

  echo -e "${GREEN}[OK] Desinstalação concluída!${NC}"
}

menu() {
  while true; do
    echo -e "${CYAN}O que você deseja fazer?${NC}"
    echo -e "  ${YELLOW}[1]${NC} - Instalar WSSH-VPN"
    echo -e "  ${YELLOW}[2]${NC} - Atualizar WSSH-VPN"
    echo -e "  ${YELLOW}[3]${NC} - Desinstalar WSSH-VPN"
    echo -e "  ${YELLOW}[0]${NC} - Sair"
    echo ""
    local option
    read -r -p "Escolha uma opção: " option < /dev/tty
    case "$option" in
      1) install_vpn;   break ;;
      2) update_vpn;    break ;;
      3) uninstall_vpn; break ;;
      0) echo -e "${BLUE}Saindo...${NC}"; exit 0 ;;
      *) echo -e "${RED}Opção inválida!${NC}"; echo "" ;;
    esac
  done
}

# ── Entrypoint ───────────────────────────────────────────────
case "${1:-}" in
  install)   install_vpn   ;;
  update)    update_vpn    ;;
  uninstall) uninstall_vpn ;;
  *)         menu          ;;
esac
