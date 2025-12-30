#!/bin/bash
set -e

APP="wssh-vpn"
BIN_URL="https://github.com/MTplusWebSystem/wssh-vpn/raw/refs/heads/main/wssh-vpn-linux-amd64"
BIN_PATH="/usr/local/bin/${APP}"

echo "🚀 Instalando ${APP}"
echo

# precisa ser root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Execute como root (sudo)"
  exit 1
fi

# precisa de curl
command -v curl >/dev/null || {
  echo "❌ curl não encontrado"
  exit 1
}

echo "⬇️ Baixando binário..."
curl -fsSL "$BIN_URL" -o "$BIN_PATH"

echo "🔐 Ajustando permissões..."
chmod +x "$BIN_PATH"

echo
echo "✅ Instalação concluída!"
echo
echo "▶️ Para executar e configurar pela CLI:"
echo "   ${APP}"
echo
echo "ℹ️ A configuração é feita DIRETAMENTE NA CLI"
echo "   Nenhum arquivo foi criado"
