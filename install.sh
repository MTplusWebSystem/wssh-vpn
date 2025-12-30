#!/bin/bash
set -e

APP_NAME="wssh-vpn"
BIN_URL="https://github.com/MTplusWebSystem/wssh-vpn/raw/refs/heads/main/wssh-vpn-linux-amd64"
BIN_PATH="/usr/local/bin/${APP_NAME}"
SERVICE_PATH="/etc/systemd/system/${APP_NAME}.service"

echo "🚀 Instalando ${APP_NAME}..."

# Verifica root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Execute como root"
  exit 1
fi

echo "⬇️ Baixando binário..."
curl -fsSL "$BIN_URL" -o "$BIN_PATH"

echo "🔐 Ajustando permissões..."
chmod +x "$BIN_PATH"

echo "⚙️ Criando service systemd..."
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=WSSH VPN Server
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo "🔄 Recarregando systemd..."
systemctl daemon-reexec
systemctl daemon-reload

echo "▶️ Habilitando serviço..."
systemctl enable ${APP_NAME}

echo "▶️ Iniciando serviço..."
systemctl restart ${APP_NAME}

echo "✅ Instalação concluída!"
echo
echo "📌 Comandos úteis:"
echo "  systemctl status ${APP_NAME}"
echo "  journalctl -u ${APP_NAME} -f"
