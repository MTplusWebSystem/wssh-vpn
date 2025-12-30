#!/bin/bash
set -e

APP="wssh-vpn"
BIN_URL="https://github.com/MTplusWebSystem/wssh-vpn/raw/refs/heads/main/wssh-vpn-linux-amd64"
BIN_PATH="/usr/local/bin/${APP}"

CONF_DIR="/etc/wssh-vpn"
CONF_FILE="${CONF_DIR}/config.yaml"
DATA_DIR="/var/lib/wssh-vpn"

echo "🚀 Instalador do ${APP}"
echo

# root check
if [ "$EUID" -ne 0 ]; then
  echo "❌ Execute como root (sudo)"
  exit 1
fi

# dependência mínima
command -v curl >/dev/null || {
  echo "❌ curl não encontrado"
  exit 1
}

echo "📁 Criando diretórios..."
mkdir -p "$CONF_DIR" "$DATA_DIR"

echo "⬇️ Baixando binário..."
curl -fsSL "$BIN_URL" -o "$BIN_PATH"
chmod +x "$BIN_PATH"

echo
echo "🔧 Configuração inicial"
echo "----------------------------------"
echo "👉 Executando CLI do ${APP}"
echo

# roda o wizard SEM verificar TTY
${BIN_PATH} init || true

# avisa se não criou config
if [ ! -f "$CONF_FILE" ]; then
  echo
  echo "⚠️ Configuração não encontrada em ${CONF_FILE}"
  echo "   Se necessário, execute manualmente:"
  echo "   sudo ${APP} init"
else
  echo
  echo "✅ Configuração criada em ${CONF_FILE}"
fi

echo
echo "✅ Instalação concluída!"
