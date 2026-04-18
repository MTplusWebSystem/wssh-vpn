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

DB_NAME="wssh_db"

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

if ! command -v jq &>/dev/null; then
  apt-get install -y -qq jq >/dev/null 2>&1
fi

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

DOWNLOAD_SUCCESS=0
for i in 1 2 3; do
  if wget -qO /usr/local/bin/wssh-vpn.tmp https://install.mtwtech.shop/; then
    if [ -s /usr/local/bin/wssh-vpn.tmp ]; then
      mv /usr/local/bin/wssh-vpn.tmp /usr/local/bin/wssh-vpn
      DOWNLOAD_SUCCESS=1
      break
    fi
  fi
  sleep 3
done

if [ "$DOWNLOAD_SUCCESS" -ne 1 ]; then
  echo -e "${RED}[ERROR] Falha ao baixar o binário do WSSH-VPN de https://install.mtwtech.shop/${NC}"
  echo -e "${RED}[ERROR] Instalação abortada para evitar corromper o sistema.${NC}"
  exit 1
fi

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
