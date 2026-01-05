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

# mata processos nas portas 80 e 7300
apt install screen -y

echo "🔪 Verificando portas 80 e 7300..."

for PORT in 80 7300; do
  PID=$(lsof -t -i:$PORT 2>/dev/null || true)
  if [ -n "$PID" ]; then
    echo "   Matando processo(s) na porta $PORT (PID: $PID)"
    kill -9 $PID 2>/dev/null || true
  else
    echo "   Porta $PORT livre"
  fi
done

# alternativa com fuser (descomente se preferir)
# fuser -k 80/tcp 2>/dev/null || true
# fuser -k 7300/tcp 2>/dev/null || true

sleep 1

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
