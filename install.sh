#!/usr/bin/env bash
set -e

# ================= CONFIG =================
USERS_DB="/root/usuarios.db"
SENHA_DIR="/etc/SSHPlus/senha"
OUTPUT_JSON="/root/usuarios_export.json"

APP="wssh-vpn"
BIN_URL="https://github.com/MTplusWebSystem/wssh-vpn/raw/refs/heads/main/wssh-vpn-linux-amd64"
BIN_PATH="/usr/local/bin/${APP}"
# =========================================

# --------- helpers ----------
pause() { read -rp "Pressione ENTER para continuar..."; }

need_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "❌ Execute como root (sudo)"
    exit 1
  fi
}

banner() {
  clear
  echo "===================================================="
  echo "   WSSH-VPN • MENU DE MANUTENÇÃO / SINCRONIZAÇÃO"
  echo "   Compatível: SSHPlus"
  echo "===================================================="
  echo
}

# --------- ação 1: gerar JSON ----------
gerar_json() {
  need_root

  echo "🔄 Gerando arquivo de sincronização..."
  echo "   DB: $USERS_DB"
  echo "   SENHAS: $SENHA_DIR"
  echo

  if [ ! -f "$USERS_DB" ]; then
    echo "❌ Arquivo $USERS_DB não encontrado"
    pause; return
  fi

  if [ ! -d "$SENHA_DIR" ]; then
    echo "❌ Diretório $SENHA_DIR não encontrado"
    pause; return
  fi

  echo "[" > "$OUTPUT_JSON"
  first=true

  while read -r username limit; do
      [[ -z "$username" || -z "$limit" ]] && continue

      # Senha
      pass_file="${SENHA_DIR}/${username}"
      if [[ -f "$pass_file" ]]; then
          password=$(cat "$pass_file")
      else
          password=""
      fi

      # Expiração (chage)
      expire_raw=$(chage -l "$username" 2>/dev/null | grep "Account expires" || true)
      expire_text=$(echo "$expire_raw" | cut -d: -f2- | xargs)

      # Converte para formato SQL datetime
      if [[ -z "$expire_text" || "$expire_text" == "never" || "$expire_text" == "never." ]]; then
          expire_sql=""
      else
          # Ex: "Jan 13, 2026" -> "2026-01-13 00:53:13"
          expire_sql=$(date -d "$expire_text" +"%Y-%m-%d 00:53:13" 2>/dev/null || true)
      fi

      [[ -z "$expire_sql" ]] && expire_sql=""

      if [ "$first" = true ]; then
          first=false
      else
          echo "," >> "$OUTPUT_JSON"
      fi

      cat >> "$OUTPUT_JSON" <<EOF
  {
    "username": "$username",
    "limit": $limit,
    "password": "$password",
    "expires": "$expire_sql"
  }
EOF

  done < "$USERS_DB"

  echo "]" >> "$OUTPUT_JSON"

  echo
  echo "✅ JSON gerado com sucesso:"
  echo "   $OUTPUT_JSON"
  pause
}

# --------- ação 2: atualizar sistema ----------
atualizar_sistema() {
  need_root

  echo "🚀 Atualizando ${APP}"
  echo

  # precisa de curl
  command -v curl >/dev/null || {
    echo "❌ curl não encontrado"
    pause; return
  }

  # screen (usado pelo seu ambiente)
  apt install -y screen >/dev/null 2>&1 || true

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

  sleep 1

  echo "⬇️ Baixando binário..."
  curl -fsSL "$BIN_URL" -o "$BIN_PATH"

  echo "🔐 Ajustando permissões..."
  chmod +x "$BIN_PATH"

  echo
  echo "✅ Atualização concluída!"
  echo
  echo "▶️ Para executar e configurar pela CLI:"
  echo "   ${APP}"
  echo
  echo "ℹ️ A configuração é feita DIRETAMENTE NA CLI"
  echo "   Nenhum arquivo foi criado"
  pause
}

# --------- menu ----------
pause() { read -rp "Pressione ENTER para continuar..." </dev/tty; }

menu() {
  banner
  echo "Escolha uma opção:"
  echo
  echo " 1) 🔄 Gerar arquivo de sincronização (SSHPlus)"
  echo " 2) ⬆️ Atualizar / Reinstalar wssh-vpn"
  echo " 0) ❌ Sair"
  echo
  read -rp "Opção: " op </dev/tty

  case "$op" in
    1) gerar_json ;;
    2) atualizar_sistema ;;
    0) exit 0 ;;
    *) echo "Opção inválida"; pause ;;
  esac
}

