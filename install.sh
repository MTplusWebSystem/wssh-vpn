#!/bin/bash
set -e

APP="wssh-vpn"
BIN_URL="https://github.com/MTplusWebSystem/wssh-vpn/raw/refs/heads/main/wssh-vpn-linux-amd64"
BIN_PATH="/usr/local/bin/${APP}"

CONF_DIR="/etc/wssh-vpn"
CONF_FILE="${CONF_DIR}/config.yaml"
DATA_DIR="/var/lib/wssh-vpn"

SERVICE="/etc/systemd/system/${APP}.service"

echo "🚀 Instalador do ${APP}"
echo

# root check
if [ "$EUID" -ne 0 ]; then
  echo "❌ Execute como root (sudo)"
  exit 1
fi

# deps mínimas
command -v curl >/dev/null || {
  echo "❌ curl não encontrado"
  exit 1
}

echo "📁 Criando diretórios..."
mkdir -p "$CONF_DIR" "$DATA_DIR"

echo "⬇️ Baixando binário..."
curl -fsSL "$BIN_URL" -o "$BIN_PATH"
chmod +x "$BIN_PATH"

# ===============================
# CLI INTERATIVA (SETUP)
# ===============================
if [ ! -f "$CONF_FILE" ]; then
  echo
  echo "🔧 Configuração inicial"
  echo "----------------------------------"
  echo "👉 Agora será aberta a CLI interativa"
  echo

  # garante TTY
  if [ ! -t 0 ]; then
    echo "❌ Este instalador precisa de um terminal interativo"
    exit 1
  fi

  ${BIN_PATH} init

  if [ ! -f "$CONF_FILE" ]; then
    echo "❌ Configuração não criada. Abortando."
    exit 1
  fi
else
  echo "ℹ️ Configuração já existe, pulando init"
fi

# ===============================
# SYSTEMD
# ===============================
echo
echo "⚙️ Criando serviço systemd..."

cat > "$SERVICE" <<EOF
[Unit]
Description=WSSH VPN Server
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} run --config ${CONF_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${APP}
systemctl restart ${APP}

echo
echo "✅ Instalação concluída com sucesso!"
echo
echo "📌 Comandos úteis:"
echo "  systemctl status ${APP}"
echo "  journalctl -u ${APP} -f"
echo "  nano ${CONF_FILE}"
