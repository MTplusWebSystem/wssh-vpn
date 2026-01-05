#!/bin/bash
set -e

APP="wssh-vpn"
BIN_URL="https://github.com/MTplusWebSystem/wssh-vpn/raw/refs/heads/main/wssh-vpn-linux-amd64"
BIN_PATH="/usr/local/bin/${APP}"

# Função para verificar se o binário do aplicativo já existe
function check_installation() {
  if [ -f "$BIN_PATH" ]; then
    echo "ℹ️ ${APP} já está instalado. Atualizando..."
    return 0
  else
    return 1
  fi
}

echo "🚀 Iniciando processo de instalação do ${APP}"
echo

# Verificar se é root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Execute como root (sudo)"
  exit 1
fi

# Verificar a existência do comando curl
command -v curl >/dev/null || {
  echo "❌ curl não encontrado"
  exit 1
}

# Verificar instalação e mostrar mensagem apropriada
INSTALL_MSG=""
if check_installation; then
  INSTALL_MSG="Atualizando ${APP}..."
else
  INSTALL_MSG="Instalando ${APP}..."
fi

# Matar processos nas portas 80 e 7300
apt install screen -y
echo

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

killall screen

# Baixar e instalar/atualizar o binário
sleep 1
echo "$INSTALL_MSG"
echo "⬇️ Baixando binário..."
curl -fsSL "$BIN_URL" -o "$BIN_PATH"

echo "🔐 Ajustando permissões..."
chmod +x "$BIN_PATH"

echo
if check_installation; then
  echo "✅ Atualização concluída!"
else
  echo "✅ Instalação concluída!"
fi
echo

echo "▶️ Para executar e configurar pela CLI:"
echo "   ${APP}"
echo

echo "ℹ️ A configuração é feita DIRETAMENTE NA CLI"
echo "   Nenhum arquivo foi criado"

screen wssh-vpn
