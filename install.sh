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
echo -e "${CYAN}║              WSSH-VPN — GERENCIADOR DO SISTEMA            ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── MENU PRINCIPAL ───────────────────────────────────────────────
INSTALLED=0
[ -d "/etc/wssh" ] && INSTALLED=1

echo -e "${BLUE}Selecione uma opção:${NC}"
echo ""
if [ "$INSTALLED" -eq 1 ]; then
  echo -e "  ${GREEN}[1]${NC} Atualizar sistema (mantém configurações)"
  echo -e "  ${RED}[2]${NC} Desinstalar sistema"
  echo -e "  ${YELLOW}[0]${NC} Cancelar"
  echo ""
  read -p "Opção: " MENU_OPT < /dev/tty
else
  echo -e "  ${GREEN}[1]${NC} Instalar sistema"
  echo -e "  ${YELLOW}[0]${NC} Cancelar"
  echo ""
  read -p "Opção: " MENU_OPT < /dev/tty
fi

echo ""

case "$MENU_OPT" in
  0)
    echo -e "${YELLOW}[!] Operação cancelada.${NC}"
    exit 0
    ;;
  2)
    if [ "$INSTALLED" -eq 0 ]; then
      echo -e "${RED}[!] Opção inválida.${NC}"
      exit 1
    fi
    # ── DESINSTALAÇÃO ────────────────────────────────────────────
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
      DB_USER=""
      if [ -f /etc/wssh/snapshot.json ]; then
        DB_USER=$(jq -r '.db_user // empty' /etc/wssh/snapshot.json 2>/dev/null || true)
      elif [ -f /etc/wssh/config.json ]; then
        DB_USER=$(jq -r '.db_user_b64 // empty' /etc/wssh/config.json 2>/dev/null | base64 -d 2>/dev/null || true)
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
    exit 0
    ;;
  1)
    # Continua para instalação/atualização abaixo
    ;;
  *)
    echo -e "${RED}[!] Opção inválida.${NC}"
    exit 1
    ;;
esac

# ── MODO: INSTALL ou UPDATE ──────────────────────────────────────
UPDATE_MODE=0
[ "$INSTALLED" -eq 1 ] && UPDATE_MODE=1

if [ "$UPDATE_MODE" -eq 1 ]; then
  echo -e "${GREEN}[✓] Modo UPDATE ativado — configurações serão mantidas${NC}"
else
  echo -e "${GREEN}[✓] Modo INSTALAÇÃO iniciado${NC}"
fi
echo ""

# ── DETECÇÃO DE ARQUITETURA ──────────────────────────────────────
MACHINE=$(uname -m)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

case "$MACHINE" in
  x86_64)       ARCH="amd64"   ;;
  i386|i686)    ARCH="386"     ;;
  aarch64|arm64) ARCH="aarch64" ;;
  armv7l|armv7) ARCH="armv7"   ;;
  armv6l|armv6) ARCH="armv6"   ;;
  *)
    echo -e "${RED}[ERROR] Arquitetura não suportada: $MACHINE${NC}"
    exit 1
    ;;
esac

[ -d "/data/data/com.termux" ] && OS="android"

BINARY_NAME="wssh-vpn_${OS}_${ARCH}"

echo -e "${BLUE}[i] Sistema: ${GREEN}${OS}/${ARCH}${NC}"
echo -e "${BLUE}[i] Binário: ${GREEN}${BINARY_NAME}${NC}"
echo ""

DB_NAME="wssh_db"

# ── INPUTS (somente install) ─────────────────────────────────────
if [ "$UPDATE_MODE" -eq 0 ]; then
  echo -e "${GREEN}[?] Banco de Dados${NC}"
  read -p "    Usuário: " DB_USER < /dev/tty
  read -s -p "    Senha:   " DB_PASS < /dev/tty; echo ""
  echo ""
  echo -e "${GREEN}[?] Painel${NC}"
  read -p "    Admin: " PANEL_USER < /dev/tty
  read -s -p "    Senha: " PANEL_PASS < /dev/tty; echo ""
  echo ""
else
  if [ ! -f /etc/wssh/config.json ]; then
    echo -e "${RED}[ERROR] /etc/wssh/config.json não encontrado. Execute uma instalação limpa.${NC}"
    exit 1
  fi
  DB_USER=$(jq -r '.db_user_b64' /etc/wssh/config.json | base64 -d)
  DB_PASS=$(jq -r '.db_pass_b64' /etc/wssh/config.json | base64 -d)
  echo -e "${BLUE}[i] Credenciais carregadas de /etc/wssh/config.json${NC}"
  echo ""
fi

echo -e "${CYAN}⇨ Executando...${NC}"
echo ""

# ── [1/5] LIMPEZA DO BINÁRIO ANTIGO ─────────────────────────────
echo -e "${YELLOW}[1/5] Parando e removendo versão anterior...${NC}"
systemctl stop wssh-vpn 2>/dev/null || true
systemctl disable wssh-vpn 2>/dev/null || true
rm -f /etc/systemd/system/wssh-vpn.service
systemctl daemon-reload 2>/dev/null || true
pkill -x wssh-vpn 2>/dev/null || true
sleep 1
rm -f /usr/local/bin/wssh-vpn
echo -e "${GREEN}    Concluído.${NC}"

# ── [2/5] BANCO (somente install) ───────────────────────────────
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
  echo -e "${GREEN}    PostgreSQL configurado.${NC}"
else
  echo -e "${YELLOW}[2/5] PostgreSQL — mantendo banco existente...${NC}"
  echo -e "${BLUE}    Pulado (modo update).${NC}"
fi

# ── [3/5] DOWNLOAD ───────────────────────────────────────────────
echo -e "${YELLOW}[3/5] Baixando nova versão...${NC}"

DOWNLOAD_URL="https://install.mtwtech.shop/"
TMP_TAR="/tmp/wssh_$$.tar.gz"
TMP_DIR="/tmp/wssh_$$"

if ! wget -q --timeout=30 --tries=3 -O "$TMP_TAR" "$DOWNLOAD_URL"; then
  echo -e "${RED}[ERROR] Falha no download. Verifique a conexão ou a URL.${NC}"
  rm -f "$TMP_TAR"
  exit 1
fi

mkdir -p "$TMP_DIR"
if ! tar -xzf "$TMP_TAR" -C "$TMP_DIR" 2>/dev/null; then
  echo -e "${RED}[ERROR] Falha ao extrair o arquivo baixado. Arquivo corrompido?${NC}"
  rm -rf "$TMP_TAR" "$TMP_DIR"
  exit 1
fi

if [ ! -f "$TMP_DIR/${BINARY_NAME}" ]; then
  echo -e "${RED}[ERROR] Binário '${BINARY_NAME}' não encontrado no pacote.${NC}"
  echo -e "${YELLOW}        Conteúdo do pacote:${NC}"
  ls -1 "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_TAR" "$TMP_DIR"
  exit 1
fi

mv "$TMP_DIR/${BINARY_NAME}" /usr/local/bin/wssh-vpn
chmod +x /usr/local/bin/wssh-vpn
rm -rf "$TMP_TAR" "$TMP_DIR"
echo -e "${GREEN}    Binário instalado em /usr/local/bin/wssh-vpn${NC}"

# ── [4/5] SYSTEMD ────────────────────────────────────────────────
echo -e "${YELLOW}[4/5] Criando serviço systemd...${NC}"

cat <<EOF > /etc/systemd/system/wssh-vpn.service
[Unit]
Description=WSSH VPN
After=network.target postgresql.service

[Service]
WorkingDirectory=/etc/wssh
ExecStart=/usr/local/bin/wssh-vpn server
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo -e "${GREEN}    Serviço criado.${NC}"

# ── [5/5] INICIAR ────────────────────────────────────────────────
echo -e "${YELLOW}[5/5] Iniciando serviço...${NC}"

systemctl daemon-reload
systemctl enable wssh-vpn
systemctl restart wssh-vpn
sleep 2

if systemctl is-active --quiet wssh-vpn; then
  echo -e "${GREEN}    Serviço rodando com sucesso.${NC}"
else
  echo -e "${RED}[AVISO] Serviço pode não ter iniciado corretamente.${NC}"
  echo -e "${YELLOW}        Verifique com: journalctl -u wssh-vpn -n 30${NC}"
fi

# ── RESUMO ───────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
if [ "$UPDATE_MODE" -eq 1 ]; then
  echo -e "${CYAN}║  Sistema atualizado com sucesso! 🚀                       ║${NC}"
else
  echo -e "${CYAN}║  Sistema instalado com sucesso!  🚀                       ║${NC}"
fi
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
