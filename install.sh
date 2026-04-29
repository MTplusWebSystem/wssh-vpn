#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              WSSH-VPN — SETUP DE INSTALAÇÃO               ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

MACHINE=$(uname -m)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

case "$MACHINE" in
  x86_64)             ARCH="amd64" ;;
  i386|i686)          ARCH="386" ;;
  aarch64|arm64)      ARCH="aarch64" ;;
  armv7l|armv7)       ARCH="armv7" ;;
  armv6l|armv6)       ARCH="armv6" ;;
  armv5l|armv5tel)    ARCH="armv5" ;;
  riscv64)            ARCH="riscv64" ;;
  ppc64le)            ARCH="ppc64le" ;;
  s390x)              ARCH="s390x" ;;
  *)
    echo -e "${RED}[ERROR] Arquitetura não suportada: $MACHINE${NC}"
    exit 1
    ;;
esac

# Android via Termux (root)
if [ -d "/data/data/com.termux" ]; then
  OS="android"
fi

BINARY_NAME="wssh-vpn_${OS}_${ARCH}"

echo -e "${BLUE}[i] Sistema detectado: ${GREEN}${OS}/${ARCH}${NC}"
echo -e "${BLUE}[i] Binário selecionado: ${GREEN}${BINARY_NAME}${NC}"
echo ""

# ── Dependências críticas ─────────────────────────────────────
for dep in jq curl wget; do
  if ! command -v "$dep" &>/dev/null; then
    echo -e "${YELLOW}[dep] Instalando $dep...${NC}"
    apt-get install -y -qq "$dep" >/dev/null 2>&1
  fi
done
# ─────────────────────────────────────────────────────────────

DB_NAME="wssh_db"

install_vpn() {
  echo -e "${GREEN}[?] Parâmetros de Banco de Dados${NC}"
  read -p "    Usuário mínimo 6 caracteres: " DB_USER < /dev/tty
  DB_USER=${DB_USER:-wssh_user}

  read -s -p "    Senha mínimo 8 caracteres: " DB_PASS < /dev/tty
  echo ""
  DB_PASS=${DB_PASS:-senha123}
  echo ""

  echo -e "${GREEN}[?] Parâmetros do Painel Administrativo${NC}"
  read -p "    Usuário Admin mínimo 6 caracteres: " PANEL_USER < /dev/tty
  PANEL_USER=${PANEL_USER:-admin}

  read -s -p "    Senha Admin mínimo 8 caracteres: " PANEL_PASS < /dev/tty
  echo ""
  PANEL_PASS=${PANEL_PASS:-admin123}
  echo ""

  echo -e "${CYAN}⇨ Iniciando deployment da infraestrutura...${NC}\n"

  echo -e "${YELLOW}[1/6] Realizando limpeza de cache de sistema...${NC}"
  systemctl stop wssh-vpn 2>/dev/null || true
  systemctl disable wssh-vpn 2>/dev/null || true
  rm -f /etc/systemd/system/wssh-vpn.service
  systemctl daemon-reload

  PIDS=$(pgrep -x wssh-vpn 2>/dev/null || true)
  if [ -n "$PIDS" ]; then
    kill $PIDS 2>/dev/null || true
    sleep 2
    PIDS=$(pgrep -x wssh-vpn 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
      kill -9 $PIDS 2>/dev/null || true
    fi
  fi
  rm -f /usr/local/bin/wssh-vpn
  rm -f /usr/local/bin/wssh-vpn.bak

  echo -e "${YELLOW}[2/6] Otimizando PostgreSQL e estruturando Database...${NC}"
  if ! command -v psql &>/dev/null; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq postgresql postgresql-contrib >/dev/null 2>&1
  fi

  systemctl enable postgresql >/dev/null 2>&1 || true
  systemctl start postgresql >/dev/null 2>&1 || true
  sleep 2

  sudo -u postgres psql -c "CREATE USER $DB_USER SUPERUSER PASSWORD '$DB_PASS';" >/dev/null 2>&1 || \
  sudo -u postgres psql -c "ALTER USER $DB_USER SUPERUSER PASSWORD '$DB_PASS';" >/dev/null 2>&1 || true

  sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;" >/dev/null 2>&1 || true
  sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" >/dev/null 2>&1 || true
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;" >/dev/null 2>&1 || true
  sudo -u postgres psql -c "ALTER DATABASE $DB_NAME OWNER TO $DB_USER;" >/dev/null 2>&1 || true
  systemctl restart postgresql >/dev/null 2>&1 || true

  echo -e "${YELLOW}[3/6] Arquitetando injeções de diretório JSON...${NC}"
  mkdir -p /etc/wssh

  if [ ! -f /etc/wssh/ssh_host_key ]; then
    ssh-keygen -q -t rsa -b 2048 -f /etc/wssh/ssh_host_key -N ""
  fi

  if [ ! -f /etc/wssh/config.json ]; then
    echo "{}" > /etc/wssh/config.json
  fi

  DB_USER_B64=$(echo -n "$DB_USER" | base64 -w 0)
  DB_PASS_B64=$(echo -n "$DB_PASS" | base64 -w 0)
  PANEL_USER_B64=$(echo -n "$PANEL_USER" | base64 -w 0)
  PANEL_PASS_B64=$(echo -n "$PANEL_PASS" | base64 -w 0)

  jq ".db_user_b64 = \"$DB_USER_B64\" | .db_pass_b64 = \"$DB_PASS_B64\" | .admin_user_b64 = \"$PANEL_USER_B64\" | .admin_pass_b64 = \"$PANEL_PASS_B64\"" /etc/wssh/config.json > /tmp/config.json.tmp && mv /tmp/config.json.tmp /etc/wssh/config.json

  if [ ! -f /etc/wssh/snapshot.json ]; then
    HASH=$(echo -n "$DB_PASS" | sha256sum | awk '{print $1}')
    cat <<SNAPSHOT > /etc/wssh/snapshot.json
{
  "db_user": "$DB_USER",
  "db_pass_hash": "$HASH",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SNAPSHOT
  fi

  mkdir -p /etc/wssh/.license
  for OLD_DIR in ".license" "cmd/build/.license" "../.license"; do
    if [ -d "$OLD_DIR" ] && [ -f "$OLD_DIR/uuid" ]; then
      cp -a "$OLD_DIR"/* /etc/wssh/.license/
      break
    fi
  done

  echo -e "${YELLOW}[4/6] Configurando binário do WSSH...${NC}"
  echo -e "${BLUE}[i] Obtendo versão mais recente em: https://update.mtwtech.shop/latest${NC}"
  LATEST_VERSION=$(curl -sL "https://update.mtwtech.shop/latest" | jq -r '.data.version')
  if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" == "null" ]; then
    echo -e "${RED}[ERROR] Falha ao obter a versão mais recente da API.${NC}"
    exit 1
  fi

  echo -e "${BLUE}[i] Baixando versão ${LATEST_VERSION}: https://update.mtwtech.shop/${LATEST_VERSION}/download${NC}"
  echo -e "${BLUE}[i] Binário alvo: ${BINARY_NAME}${NC}"

  DOWNLOAD_SUCCESS=0
  for i in 1 2 3; do
    if wget -qO /tmp/wssh-vpn.tar.gz "https://update.mtwtech.shop/${LATEST_VERSION}/download"; then
      if [ -s /tmp/wssh-vpn.tar.gz ]; then
        DOWNLOAD_SUCCESS=1
        break
      fi
    fi
    echo -e "${YELLOW}[!] Tentativa $i falhou, aguardando...${NC}"
    sleep 3
  done

  if [ "$DOWNLOAD_SUCCESS" -ne 1 ]; then
    echo -e "${RED}[ERROR] Falha ao baixar o pacote de https://update.mtwtech.shop/${LATEST_VERSION}/download${NC}"
    echo -e "${RED}[ERROR] Instalação abortada para evitar corromper o sistema.${NC}"
    exit 1
  fi

  mkdir -p /tmp/wssh-extract
  tar -xzf /tmp/wssh-vpn.tar.gz -C /tmp/wssh-extract

  if [ ! -f "/tmp/wssh-extract/${BINARY_NAME}" ]; then
    echo -e "${RED}[ERROR] Binário '${BINARY_NAME}' não encontrado no pacote.${NC}"
    echo -e "${RED}[ERROR] Arquiteturas disponíveis no pacote:${NC}"
    ls /tmp/wssh-extract/ | sed 's/^/    /'
    rm -rf /tmp/wssh-vpn.tar.gz /tmp/wssh-extract
    exit 1
  fi

  mv "/tmp/wssh-extract/${BINARY_NAME}" /usr/local/bin/wssh-vpn
  rm -rf /tmp/wssh-vpn.tar.gz /tmp/wssh-extract

  chmod +x /usr/local/bin/wssh-vpn 2>/dev/null || true

  echo -e "${YELLOW}[5/6] Formulando processos daemon...${NC}"
  cat <<EOF > /etc/systemd/system/wssh-vpn.service
[Unit]
Description=WSSH VPN Service
After=network.target postgresql.service

[Service]
Type=simple
WorkingDirectory=/etc/wssh
Environment=DB_USER=$DB_USER
Environment=DB_PASSWORD=$DB_PASS
Environment=DB_NAME=$DB_NAME
ExecStart=/usr/local/bin/wssh-vpn server
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  echo -e "${YELLOW}[6/6] Aplicando unidades Systemd...${NC}"
  systemctl daemon-reload
  systemctl enable wssh-vpn >/dev/null 2>&1
  systemctl restart wssh-vpn >/dev/null 2>&1 || true

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
  echo -e "${CYAN}⇨ Iniciando atualização do WSSH-VPN...${NC}\n"

  echo -e "${YELLOW}[1/3] Parando serviço...${NC}"
  systemctl stop wssh-vpn 2>/dev/null || true

  echo -e "${YELLOW}[2/3] Verificando versão mais recente...${NC}"
  LATEST_VERSION=$(curl -sL "https://update.mtwtech.shop/latest" | jq -r '.data.version')
  if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" == "null" ]; then
    echo -e "${RED}[ERROR] Falha ao obter a versão mais recente da API.${NC}"
    systemctl start wssh-vpn 2>/dev/null || true
    exit 1
  fi

  echo -e "${BLUE}[i] Baixando atualização versão ${LATEST_VERSION}: https://update.mtwtech.shop/${LATEST_VERSION}/download${NC}"
  DOWNLOAD_SUCCESS=0
  for i in 1 2 3; do
    if wget -qO /tmp/wssh-vpn.tar.gz "https://update.mtwtech.shop/${LATEST_VERSION}/download"; then
      if [ -s /tmp/wssh-vpn.tar.gz ]; then
        DOWNLOAD_SUCCESS=1
        break
      fi
    fi
    echo -e "${YELLOW}[!] Tentativa $i falhou, aguardando...${NC}"
    sleep 3
  done

  if [ "$DOWNLOAD_SUCCESS" -ne 1 ]; then
    echo -e "${RED}[ERROR] Falha ao baixar o pacote de atualização.${NC}"
    systemctl start wssh-vpn 2>/dev/null || true
    exit 1
  fi

  mkdir -p /tmp/wssh-extract
  tar -xzf /tmp/wssh-vpn.tar.gz -C /tmp/wssh-extract

  if [ ! -f "/tmp/wssh-extract/${BINARY_NAME}" ]; then
    echo -e "${RED}[ERROR] Binário '${BINARY_NAME}' não encontrado na atualização.${NC}"
    rm -rf /tmp/wssh-vpn.tar.gz /tmp/wssh-extract
    systemctl start wssh-vpn 2>/dev/null || true
    exit 1
  fi

  rm -f /usr/local/bin/wssh-vpn.bak
  mv /usr/local/bin/wssh-vpn /usr/local/bin/wssh-vpn.bak 2>/dev/null || true
  mv "/tmp/wssh-extract/${BINARY_NAME}" /usr/local/bin/wssh-vpn
  rm -rf /tmp/wssh-vpn.tar.gz /tmp/wssh-extract
  chmod +x /usr/local/bin/wssh-vpn

  echo -e "${YELLOW}[3/3] Reiniciando serviço...${NC}"
  systemctl start wssh-vpn 2>/dev/null || true

  echo -e "${GREEN}[OK] WSSH-VPN atualizado com sucesso para a versão ${LATEST_VERSION}!${NC}"
}

uninstall_vpn() {
  echo -e "${RED}ATENÇÃO: Isso irá remover o WSSH-VPN completamente do seu sistema!${NC}"
  read -p "Deseja continuar? (s/n): " CONFIRM < /dev/tty
  if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    echo -e "${YELLOW}Desinstalação cancelada.${NC}"
    return
  fi

  echo -e "${YELLOW}[1/4] Parando serviços...${NC}"
  systemctl stop wssh-vpn 2>/dev/null || true
  systemctl disable wssh-vpn 2>/dev/null || true

  echo -e "${YELLOW}[2/4] Removendo arquivos do sistema...${NC}"
  rm -f /etc/systemd/system/wssh-vpn.service
  systemctl daemon-reload
  rm -f /usr/local/bin/wssh-vpn
  rm -f /usr/local/bin/wssh-vpn.bak

  echo -e "${YELLOW}[3/4] Removendo banco de dados (Opcional)...${NC}"
  read -p "Deseja remover o banco de dados (wssh_db) e usuário? (s/n): " CONFIRM_DB < /dev/tty
  if [[ "$CONFIRM_DB" == "s" || "$CONFIRM_DB" == "S" ]]; then
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS wssh_db;" >/dev/null 2>&1 || true
    sudo -u postgres psql -c "DROP USER IF EXISTS wssh_user;" >/dev/null 2>&1 || true
    echo -e "${GREEN}Banco de dados removido.${NC}"
  fi

  echo -e "${YELLOW}[4/4] Removendo diretório de configuração...${NC}"
  read -p "Deseja remover configurações e licenças (/etc/wssh)? (s/n): " CONFIRM_CFG < /dev/tty
  if [[ "$CONFIRM_CFG" == "s" || "$CONFIRM_CFG" == "S" ]]; then
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
    read -p "Escolha uma opção: " OPTION < /dev/tty
    case $OPTION in
      1) install_vpn; break ;;
      2) update_vpn; break ;;
      3) uninstall_vpn; break ;;
      0) echo -e "${BLUE}Saindo...${NC}"; exit 0 ;;
      *) echo -e "${RED}Opção inválida!${NC}"; echo "";;
    esac
  done
}

if [ "$1" == "install" ]; then
  install_vpn
elif [ "$1" == "update" ]; then
  update_vpn
elif [ "$1" == "uninstall" ]; then
  uninstall_vpn
else
  menu
fi
