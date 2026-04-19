#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              WSSH-VPN — REMOÇÃO DO SISTEMA                ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${RED}[!] Esta ação irá remover completamente o wssh-vpn do sistema.${NC}"
read -p "    Confirma a remoção? (s/N): " CONFIRM < /dev/tty
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
  echo -e "${YELLOW}[!] Remoção cancelada.${NC}"
  exit 0
fi
echo ""

echo -e "${YELLOW}[1/4] Parando e desabilitando serviço...${NC}"
systemctl stop wssh-vpn 2>/dev/null || true
systemctl disable wssh-vpn 2>/dev/null || true

PIDS=$(pgrep -x wssh-vpn 2>/dev/null || true)
if [ -n "$PIDS" ]; then
  kill $PIDS 2>/dev/null || true
  sleep 2
  PIDS=$(pgrep -x wssh-vpn 2>/dev/null || true)
  [ -n "$PIDS" ] && kill -9 $PIDS 2>/dev/null || true
fi

echo -e "${YELLOW}[2/4] Removendo arquivos do serviço...${NC}"
rm -f /etc/systemd/system/wssh-vpn.service
systemctl daemon-reload
rm -f /usr/local/bin/wssh-vpn
rm -f /usr/local/bin/wssh-vpn.bak
rm -f /usr/local/bin/wssh-vpn.tmp

echo -e "${YELLOW}[3/4] Removendo configurações...${NC}"
read -p "    Remover /etc/wssh (configs, licença, banco)? (s/N): " REMOVE_CONF < /dev/tty
if [[ "$REMOVE_CONF" == "s" || "$REMOVE_CONF" == "S" ]]; then
  rm -rf /etc/wssh
  echo -e "${GREEN}    /etc/wssh removido.${NC}"
else
  echo -e "${YELLOW}    /etc/wssh mantido.${NC}"
fi

echo -e "${YELLOW}[4/4] Removendo banco de dados PostgreSQL...${NC}"
read -p "    Remover banco 'wssh_db' e usuário do PostgreSQL? (s/N): " REMOVE_DB < /dev/tty
if [[ "$REMOVE_DB" == "s" || "$REMOVE_DB" == "S" ]]; then
  sudo -u postgres psql -c "DROP DATABASE IF EXISTS wssh_db;" 2>/dev/null || true

  # Descobre o usuário salvo no snapshot se existir
  DB_USER=""
  if [ -f /etc/wssh/snapshot.json ]; then
    DB_USER=$(jq -r '.db_user // empty' /etc/wssh/snapshot.json 2>/dev/null || true)
  fi

  if [ -n "$DB_USER" ]; then
    sudo -u postgres psql -c "DROP USER IF EXISTS $DB_USER;" 2>/dev/null || true
    echo -e "${GREEN}    Banco e usuário '$DB_USER' removidos.${NC}"
  else
    echo -e "${YELLOW}    Banco removido. Usuário não identificado — remova manualmente se necessário.${NC}"
  fi
else
  echo -e "${YELLOW}    Banco PostgreSQL mantido.${NC}"
fi

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  wssh-vpn removido com sucesso!                           ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
