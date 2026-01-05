#!/bin/bash
set -e

APP="wssh-vpn"
GITHUB_REPO="MTplusWebSystem/wssh-vpn"
BIN_PATH="/usr/local/bin/${APP}"

# Função para verificar se o binário já existe
function check_installation() {
  if [ -f "$BIN_PATH" ]; then
    echo "ℹ️  ${APP} já está instalado. Atualizando..."
    return 0
  else
    return 1
  fi
}

# Função para obter a URL da última release
function get_latest_release_url() {
  echo "🔍 Buscando última versão..."
  
  # Tenta pegar a última release via API do GitHub
  LATEST_URL=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
    | grep "browser_download_url.*linux-amd64" \
    | cut -d '"' -f 4 \
    | head -n 1)
  
  if [ -z "$LATEST_URL" ]; then
    echo "⚠️  Não foi possível obter via releases, usando branch main..."
    LATEST_URL="https://github.com/${GITHUB_REPO}/raw/refs/heads/main/wssh-vpn-linux-amd64"
  else
    echo "✓ Última versão encontrada!"
  fi
  
  echo "$LATEST_URL"
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

# Verificar instalação
INSTALL_MSG=""
if check_installation; then
  INSTALL_MSG="Atualizando ${APP}..."
else
  INSTALL_MSG="Instalando ${APP}..."
fi

# Instalar screen e matar processos
apt install screen -y 2>/dev/null || true
killall screen 2>/dev/null || true

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

# Obter URL da última versão
BIN_URL=$(get_latest_release_url)

# Baixar e instalar/atualizar o binário
sleep 1
echo
echo "$INSTALL_MSG"
echo "⬇️  Baixando de: $BIN_URL"
echo

# Criar backup se já existir
if [ -f "$BIN_PATH" ]; then
  cp "$BIN_PATH" "${BIN_PATH}.backup"
  echo "💾 Backup criado: ${BIN_PATH}.backup"
fi

# Download com progress bar
curl -fL --progress-bar "$BIN_URL" -o "$BIN_PATH"

echo "🔐 Ajustando permissões..."
chmod +x "$BIN_PATH"

# Verificar versão se o binário suportar
echo
if "$BIN_PATH" --version 2>/dev/null; then
  echo
fi

if check_installation; then
  echo "✅ Atualização concluída!"
else
  echo "✅ Instalação concluída!"
fi

echo
echo "▶️  Para executar e configurar pela CLI:"
echo "   ${APP}"
echo
echo "ℹ️  A configuração é feita DIRETAMENTE NA CLI"
echo "   Nenhum arquivo foi criado"
echo

# Executar no screen
screen -S wssh-vpn ${APP}
