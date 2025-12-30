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

# deps
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
echo "👉 Agora será aberta a CLI interativa"
echo

# precisa de TTY
if [ ! -t 0 ]; then
  echo "❌ Este instalador precisa de um terminal interativo"
  exit 1
fi

# roda o wizard
${BIN_PATH} init

if [ ! -f "$CONF_FILE" ]; then
  echo "❌ Configuração não foi criada. Abortando."
  exit 1
fi

echo
echo "✅ Instalação concluída!"
echo
echo "▶️ Para iniciar o servidor:"
echo "   sudo wssh-vpn run --config ${CONF_FILE}"
echo
echo "📄 Editar configuração:"
echo "   nano ${CONF_FILE}"
echo
echo "⛔ Para parar: CTRL+C"
