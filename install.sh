#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

INSTALL_URL="https://install.mtwtech.shop/"
BIN_PATH="/usr/local/bin/wssh-vpn"
SERVICE_PATH="/etc/systemd/system/wssh-vpn.service"
CONFIG_DIR="/etc/wssh"
DB_NAME="wssh_db"

# ─── helpers ──────────────────────────────────────────────────────────────────

header() {
  clear
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║              WSSH-VPN — SETUP DE INSTALAÇÃO               ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ERRO] Este script precisa ser executado como root.${NC}"
    exit 1
  fi
}

# Detecta arquitetura e define sufixo de download.
# Adicione novos mapeamentos conforme o servidor disponibilizar builds.
detect_arch() {
  local machine
  machine=$(uname -m)
  case "$machine" in
    x86_64)            ARCH_SUFFIX="amd64"  ;;
    aarch64 | arm64)   ARCH_SUFFIX="arm64"  ;;
    armv7l)            ARCH_SUFFIX="armv7"  ;;
    i386 | i686)       ARCH_SUFFIX="386"    ;;
    *)
      echo -e "${RED}[ERRO] Arquitetura não suportada: $machine${NC}"
      exit 1
      ;;
  esac
  echo -e "${BLUE}[INFO] Arquitetura detectada: ${machine} → ${ARCH_SUFFIX}${NC}"
}

# Baixa o binário com retry e valida que é um ELF executável.
download_binary() {
  local url="${INSTALL_URL}?arch=${ARCH_SUFFIX}"
  local tmp="${BIN_PATH}.tmp"
  local attempt

  echo -e "${YELLOW}[↓] Baixando binário (${ARCH_SUFFIX}) de ${url}...${NC}"

  for attempt in 1 2 3; do
    rm -f "$tmp"
    if wget -q --timeout=30 -O "$tmp" "$url" && [ -s "$tmp" ]; then
      # Valida magic ELF antes de instalar
      if file "$tmp" 2>/dev/null | grep -q "ELF"; then
        mv "$tmp" "$BIN_PATH"
        chmod +x "$BIN_PATH"
        echo -e "${GREEN}[✓] Binário instalado com sucesso.${NC}"
        return 0
      else
        echo -e "${RED}[ERRO] Tentativa ${attempt}: arquivo baixado não é um binário ELF válido.${NC}"
        echo -e "${RED}       Tipo detectado: $(file "$tmp" 2>/dev/null || echo 'desconhecido')${NC}"
      fi
    else
      echo -e "${RED}[ERRO] Tentativa ${attempt}: falha no download.${NC}"
    fi
    sleep 3
  done

  rm -f "$tmp"
  echo -e "${RED}[ERRO] Impossível obter um binário válido após 3 tentativas.${NC}"
  echo -e "${RED}       Verifique se ${url} serve builds para ${ARCH_SUFFIX}.${NC}"
  exit 1
}

service_running() {
  systemctl is-active --quiet wssh-vpn 2>/dev/null
}

# ─── etapas reutilizáveis ─────────────────────────────────────────────────────

step_stop_service() {
  echo -e "${YELLOW}[→] Parando serviço existente...${NC}"
  systemctl stop wssh-vpn 2>/dev/null || true
  systemctl disable wssh-vpn 2>/dev/null || true

  local pids
  pids=$(pgrep -x wssh-vpn 2>/dev/null || true)
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    sleep 2
    pids=$(pgrep -x wssh-vpn 2>/dev/null || true)
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
  fi
}

step_setup_postgres() {
  echo -e "${YELLOW}[→] Configurando PostgreSQL...${NC}"
  if ! command -v psql &>/dev/null; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq postgresql postgresql-contrib >/dev/null 2>&1
  fi

  systemctl enable postgresql >/dev/null 2>&1 || true
  systemctl start  postgresql >/dev/null 2>&1 || true
  sleep 2

  sudo -u postgres psql -c "CREATE USER $DB_USER SUPERUSER PASSWORD '$DB_PASS';" >/dev/null 2>&1 || \
  sudo -u postgres psql -c "ALTER USER $DB_USER SUPERUSER PASSWORD '$DB_PASS';"  >/dev/null 2>&1 || true

  sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;"            >/dev/null 2>&1 || true
  sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"     >/dev/null 2>&1 || true
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;" >/dev/null 2>&1 || true
  sudo -u postgres psql -c "ALTER DATABASE $DB_NAME OWNER TO $DB_USER;"   >/dev/null 2>&1 || true
  systemctl restart postgresql >/dev/null 2>&1 || true
}

step_write_config() {
  echo -e "${YELLOW}[→] Gravando configurações em ${CONFIG_DIR}...${NC}"

  if ! command -v jq &>/dev/null; then
    apt-get install -y -qq jq >/dev/null 2>&1
  fi

  mkdir -p "$CONFIG_DIR"
  [ ! -f "$CONFIG_DIR/config.json" ] && echo "{}" > "$CONFIG_DIR/config.json"

  local db_user_b64 db_pass_b64 panel_user_b64 panel_pass_b64
  db_user_b64=$(echo -n "$DB_USER"    | base64 -w 0)
  db_pass_b64=$(echo -n "$DB_PASS"    | base64 -w 0)
  panel_user_b64=$(echo -n "$PANEL_USER" | base64 -w 0)
  panel_pass_b64=$(echo -n "$PANEL_PASS" | base64 -w 0)

  jq ".db_user_b64=\"$db_user_b64\" | .db_pass_b64=\"$db_pass_b64\" \
    | .admin_user_b64=\"$panel_user_b64\" | .admin_pass_b64=\"$panel_pass_b64\"" \
    "$CONFIG_DIR/config.json" > /tmp/wssh_cfg.tmp && mv /tmp/wssh_cfg.tmp "$CONFIG_DIR/config.json"

  if [ ! -f "$CONFIG_DIR/snapshot.json" ]; then
    local hash
    hash=$(echo -n "$DB_PASS" | sha256sum | awk '{print $1}')
    cat <<SNAPSHOT > "$CONFIG_DIR/snapshot.json"
{
  "db_user": "$DB_USER",
  "db_pass_hash": "$hash",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SNAPSHOT
  fi

  mkdir -p "$CONFIG_DIR/.license"
  for old_dir in ".license" "cmd/build/.license" "../.license"; do
    if [ -d "$old_dir" ] && [ -f "$old_dir/uuid" ]; then
      cp -a "$old_dir"/. "$CONFIG_DIR/.license/"
      break
    fi
  done
}

step_write_service() {
  echo -e "${YELLOW}[→] Criando unit systemd...${NC}"
  cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=WSSH VPN Service
After=network.target postgresql.service

[Service]
Type=simple
WorkingDirectory=$CONFIG_DIR
Environment=DB_USER=$DB_USER
Environment=DB_PASSWORD=$DB_PASS
Environment=DB_NAME=$DB_NAME
ExecStart=$BIN_PATH server
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable wssh-vpn >/dev/null 2>&1
  systemctl restart wssh-vpn 2>/dev/null || true
}

read_db_params() {
  echo -e "${GREEN}[?] Parâmetros de Banco de Dados${NC}"
  read -p "    Usuário (mín. 6 caracteres): " DB_USER < /dev/tty
  DB_USER=${DB_USER:-wssh_user}
  read -s -p "    Senha (mín. 8 caracteres):  " DB_PASS < /dev/tty
  echo ""
  DB_PASS=${DB_PASS:-senha123}
}

read_panel_params() {
  echo -e "${GREEN}[?] Parâmetros do Painel Administrativo${NC}"
  read -p "    Usuário Admin (mín. 6 caracteres): " PANEL_USER < /dev/tty
  PANEL_USER=${PANEL_USER:-admin}
  read -s -p "    Senha Admin  (mín. 8 caracteres):  " PANEL_PASS < /dev/tty
  echo ""
  PANEL_PASS=${PANEL_PASS:-admin123}
  echo ""
}

footer_ok() {
  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  Operação concluída com sucesso!                          ║${NC}"
  echo -e "${CYAN}╠═══════════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║  Menu CLI:  ${GREEN}wssh-vpn                                      ${CYAN}║${NC}"
  echo -e "${CYAN}║  Status:    ${GREEN}systemctl status wssh-vpn                     ${CYAN}║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ─── ações principais ─────────────────────────────────────────────────────────

action_install() {
  header
  read_db_params
  read_panel_params

  echo -e "${CYAN}⇨ Iniciando instalação...${NC}\n"
  echo -e "${YELLOW}[1/5] Parando instâncias antigas...${NC}"
  step_stop_service
  rm -f "$BIN_PATH" "$BIN_PATH.bak" "$SERVICE_PATH"
  systemctl daemon-reload

  echo -e "${YELLOW}[2/5] Configurando banco de dados...${NC}"
  step_setup_postgres

  echo -e "${YELLOW}[3/5] Gravando configurações...${NC}"
  step_write_config

  echo -e "${YELLOW}[4/5] Baixando binário...${NC}"
  detect_arch
  download_binary

  echo -e "${YELLOW}[5/5] Registrando serviço...${NC}"
  step_write_service

  footer_ok
}

action_update() {
  header
  echo -e "${CYAN}⇨ Atualizando binário wssh-vpn...${NC}\n"

  echo -e "${YELLOW}[1/3] Parando serviço...${NC}"
  step_stop_service

  # Faz backup do binário atual antes de substituir
  [ -f "$BIN_PATH" ] && cp -f "$BIN_PATH" "${BIN_PATH}.bak" && \
    echo -e "${BLUE}[INFO] Backup salvo em ${BIN_PATH}.bak${NC}"

  echo -e "${YELLOW}[2/3] Baixando nova versão...${NC}"
  detect_arch
  download_binary

  echo -e "${YELLOW}[3/3] Reiniciando serviço...${NC}"
  systemctl daemon-reload
  systemctl restart wssh-vpn 2>/dev/null || true

  # Valida que o serviço subiu; em caso de falha, restaura o backup
  sleep 2
  if ! service_running; then
    echo -e "${RED}[AVISO] Serviço não iniciou após atualização. Restaurando backup...${NC}"
    if [ -f "${BIN_PATH}.bak" ]; then
      mv "${BIN_PATH}.bak" "$BIN_PATH"
      systemctl restart wssh-vpn 2>/dev/null || true
      echo -e "${YELLOW}[INFO] Versão anterior restaurada.${NC}"
    fi
    exit 1
  fi

  rm -f "${BIN_PATH}.bak"
  footer_ok
}

action_delete() {
  header
  echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  ATENÇÃO: Esta operação é irreversível!                   ║${NC}"
  echo -e "${RED}║  Todos os dados do banco serão apagados.                  ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  read -p "  Digite CONFIRMAR para prosseguir: " confirm < /dev/tty
  if [ "$confirm" != "CONFIRMAR" ]; then
    echo -e "${YELLOW}[INFO] Operação cancelada.${NC}"
    exit 0
  fi

  echo -e "\n${CYAN}⇨ Removendo wssh-vpn...${NC}\n"

  echo -e "${YELLOW}[1/3] Parando e desativando serviço...${NC}"
  step_stop_service
  rm -f "$SERVICE_PATH"
  systemctl daemon-reload

  echo -e "${YELLOW}[2/3] Removendo binário e configurações...${NC}"
  rm -f "$BIN_PATH" "${BIN_PATH}.bak"
  rm -rf "$CONFIG_DIR"

  echo -e "${YELLOW}[3/3] Removendo banco de dados...${NC}"
  read -p "  Usuário do banco a remover (default: wssh_user): " db_user_del < /dev/tty
  db_user_del=${db_user_del:-wssh_user}

  sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;"   >/dev/null 2>&1 || true
  sudo -u postgres psql -c "DROP USER IF EXISTS $db_user_del;"   >/dev/null 2>&1 || true

  echo ""
  echo -e "${GREEN}[✓] wssh-vpn removido com sucesso.${NC}"
  echo ""
}

action_fix() {
  header
  echo -e "${CYAN}⇨ Corrigindo erro 'Exec format error'...${NC}\n"

  echo -e "${YELLOW}[1/3] Parando serviço...${NC}"
  step_stop_service

  echo -e "${YELLOW}[2/3] Detectando arquitetura e re-baixando binário...${NC}"
  detect_arch

  local cur_arch=""
  if [ -f "$BIN_PATH" ]; then
    cur_arch=$(file "$BIN_PATH" 2>/dev/null || echo "")
    echo -e "${BLUE}[INFO] Binário atual: ${cur_arch}${NC}"
  fi

  [ -f "$BIN_PATH" ] && mv "$BIN_PATH" "${BIN_PATH}.bak"
  download_binary

  echo -e "${YELLOW}[3/3] Reiniciando serviço...${NC}"
  systemctl daemon-reload
  systemctl restart wssh-vpn 2>/dev/null || true

  sleep 2
  if service_running; then
    rm -f "${BIN_PATH}.bak"
    echo -e "${GREEN}[✓] Serviço iniciado com sucesso.${NC}"
    footer_ok
  else
    echo -e "${RED}[ERRO] Serviço ainda falha após substituição do binário.${NC}"
    echo -e "${RED}       Verifique os logs: journalctl -u wssh-vpn -n 50${NC}"
    exit 1
  fi
}

# ─── menu principal ───────────────────────────────────────────────────────────

main_menu() {
  header
  echo -e "  ${CYAN}Selecione uma opção:${NC}\n"
  echo -e "  ${GREEN}1)${NC} Instalar wssh-vpn"
  echo -e "  ${GREEN}2)${NC} Atualizar binário"
  echo -e "  ${GREEN}3)${NC} Remover wssh-vpn"
  echo -e "  ${GREEN}4)${NC} Corrigir erro de formato (Exec format error)"
  echo -e "  ${RED}5)${NC} Sair"
  echo ""
  read -p "  Opção [1-5]: " opt < /dev/tty

  case "$opt" in
    1) action_install ;;
    2) action_update  ;;
    3) action_delete  ;;
    4) action_fix     ;;
    5) echo -e "${YELLOW}[INFO] Saindo.${NC}" && exit 0 ;;
    *) echo -e "${RED}[ERRO] Opção inválida.${NC}" && sleep 1 && main_menu ;;
  esac
}

# ─── entrypoint ───────────────────────────────────────────────────────────────

check_root

# Permite chamar direto: ./setup.sh install | update | delete | fix
case "${1:-}" in
  install) action_install ;;
  update)  action_update  ;;
  delete)  action_delete  ;;
  fix)     action_fix     ;;
  *)       main_menu      ;;
esac
