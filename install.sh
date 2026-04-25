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
echo -e "${CYAN}║              WSSH-VPN — INSTALL / UPDATE                  ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

UPDATE_MODE=0

# ── DETECÇÃO DE INSTALAÇÃO EXISTENTE ────────────────────────────
if [ -d "/etc/wssh" ]; then
  echo -e "${YELLOW}[!] Instalação existente detectada em /etc/wssh${NC}"
  read -p "Deseja atualizar mantendo configurações? (s/n): " CONFIRM < /dev/tty
  
  if [[ "$CONFIRM" =~ ^[Ss]$ ]]; then
    UPDATE_MODE=1
    echo -e "${GREEN}[✓] Modo UPDATE ativado${NC}"
  else
    echo -e "${RED}[!] Instalação cancelada pelo usuário${NC}"
    exit 0
  fi
fi

# ── DETECÇÃO DE ARQUITETURA ─────────────────────────────────────
MACHINE=$(uname -m)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

case "$MACHINE" in
  x86_64) ARCH="amd64" ;;
  i386|i686) ARCH="386" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  armv7l|armv7) ARCH="armv7" ;;
  armv6l|armv6) ARCH="armv6" ;;
  *) echo -e "${RED}[ERROR] Arquitetura não suportada${NC}"; exit 1 ;;
esac

if [ -d "/data/data/com.termux" ]; then
  OS="android"
fi

BINARY_NAME="wssh-vpn_${OS}_${ARCH}"

echo -e "${BLUE}[i] Sistema: ${GREEN}${OS}/${ARCH}${NC}"
echo -e "${BLUE}[i] Binário: ${GREEN}${BINARY_NAME}${NC}"
echo ""

DB_NAME="wssh_db"

# ── INPUTS SOMENTE SE NÃO FOR UPDATE ────────────────────────────
if [ "$UPDATE_MODE" -eq 0 ]; then

  echo -e "${GREEN}[?] Banco de Dados${NC}"
  read -p "Usuário: " DB_USER < /dev/tty
  read -s -p "Senha: " DB_PASS < /dev/tty; echo ""

  echo -e "${GREEN}[?] Painel${NC}"
  read -p "Admin: " PANEL_USER < /dev/tty
  read -s -p "Senha: " PANEL_PASS < /dev/tty; echo ""

else
  echo -e "${BLUE}[i] Mantendo configuração existente${NC}"

  DB_USER=$(jq -r '.db_user_b64' /etc/wssh/config.json | base64 -d)
  DB_PASS=$(jq -r '.db_pass_b64' /etc/wssh/config.json | base64 -d)
fi

echo ""
echo -e "${CYAN}⇨ Executando...${NC}\n"

# ── LIMPEZA ─────────────────────────────────────────────────────
echo -e "${YELLOW}[1/5] Removendo versão antiga...${NC}"

systemctl stop wssh-vpn 2>/dev/null || true
systemctl disable wssh-vpn 2>/dev/null || true
rm -f /etc/systemd/system/wssh-vpn.service
systemctl daemon-reload

pkill -f wssh-vpn 2>/dev/null || true
rm -f /usr/local/bin/wssh-vpn

# ── BANCO (somente install) ─────────────────────────────────────
if [ "$UPDATE_MODE" -eq 0 ]; then
  echo -e "${YELLOW}[2/5] Configurando PostgreSQL...${NC}"

  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq postgresql jq >/dev/null 2>&1

  systemctl start postgresql
  sleep 2

  sudo -u postgres psql -c "CREATE USER $DB_USER SUPERUSER PASSWORD '$DB_PASS';" 2>/dev/null || true
  sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null || true

  mkdir -p /etc/wssh

  DB_USER_B64=$(echo -n "$DB_USER" | base64 -w 0)
  DB_PASS_B64=$(echo -n "$DB_PASS" | base64 -w 0)

  cat <<EOF > /etc/wssh/config.json
{
  "db_user_b64": "$DB_USER_B64",
  "db_pass_b64": "$DB_PASS_B64"
}
EOF
fi

# ── DOWNLOAD ────────────────────────────────────────────────────
echo -e "${YELLOW}[3/5] Baixando nova versão...${NC}"

wget -qO /tmp/wssh.tar.gz "https://install.mtwtech.shop/"

mkdir -p /tmp/wssh
tar -xzf /tmp/wssh.tar.gz -C /tmp/wssh

if [ ! -f "/tmp/wssh/${BINARY_NAME}" ]; then
  echo -e "${RED}[ERROR] Binário não encontrado${NC}"
  exit 1
fi

mv "/tmp/wssh/${BINARY_NAME}" /usr/local/bin/wssh-vpn
chmod +x /usr/local/bin/wssh-vpn

rm -rf /tmp/wssh*

# ── SYSTEMD ─────────────────────────────────────────────────────
echo -e "${YELLOW}[4/5] Criando serviço...${NC}"

cat <<EOF > /etc/systemd/system/wssh-vpn.service
[Unit]
Description=WSSH VPN
After=network.target postgresql.service

[Service]
WorkingDirectory=/etc/wssh
ExecStart=/usr/local/bin/wssh-vpn server
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# ── START ───────────────────────────────────────────────────────
echo -e "${YELLOW}[5/5] Iniciando serviço...${NC}"

systemctl daemon-reload
systemctl enable wssh-vpn
systemctl restart wssh-vpn

echo ""
echo -e "${GREEN}✔ Concluído!${NC}"

if [ "$UPDATE_MODE" -eq 1 ]; then
  echo -e "${CYAN}Sistema atualizado com sucesso 🚀${NC}"
else
  echo -e "${CYAN}Sistema instalado com sucesso 🚀${NC}"
fi
