#!/bin/bash

# ══════════════════════════════════════════════════════════════
#   WSSH-VPN • MENU DE MANUTENÇÃO / SINCRONIZAÇÃO
#   Compatível: SSHPlus
#   Versão: 2.0
# ══════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

USERS_DB="/root/usuarios.db"
SENHA_DIR="/etc/SSHPlus/senha"
OUTPUT_JSON="/root/usuarios_export.json"
APP="wssh-vpn"
BIN_URL="https://github.com/MTplusWebSystem/wssh-vpn/raw/refs/heads/main/wssh-vpn-linux-amd64"
BIN_PATH="/usr/local/bin/${APP}"
DECRYPT_URL="https://github.com/MTplusWebSystem/wssh-vpn/raw/refs/heads/main/decrypt_backup"
DECRYPT_PATH="/usr/local/bin/decrypt_backup"
CHECKUSER_SERVICE="checkuser"
CHECKUSER_FILE="/etc/systemd/system/${CHECKUSER_SERVICE}.service"
CHECKUSER_BIN="/usr/local/bin/${CHECKUSER_SERVICE}"
LOG_FILE="/var/log/wssh-vpn-manutencao.log"

log_ok()     { echo -e "${GREEN}  ✔  $1${NC}";             _log "OK"    "$1"; }
log_warn()   { echo -e "${YELLOW}  ⚠  $1${NC}";            _log "WARN"  "$1"; }
log_err()    { echo -e "${RED}  ✘  $1${NC}";               _log "ERROR" "$1"; }
log_info()   { echo -e "${CYAN}  ➤  $1${NC}";              _log "INFO"  "$1"; }
log_step()   { echo -e "${MAGENTA}  ▸  $1${NC}";           _log "STEP"  "$1"; }
_log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" >> "$LOG_FILE"; }

separator()  { echo -e "${BLUE}  ────────────────────────────────────────${NC}"; }

pause() {
  echo
  read -rp "  Pressione ENTER para continuar..." </dev/tty
}

need_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}  ✘  Execute como root: sudo $0${NC}"
    exit 1
  fi
}

banner() {
  clear
  echo
  echo -e "${CYAN}  ╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}  ║${WHITE}      WSSH-VPN • MENU DE MANUTENÇÃO       ${CYAN}║${NC}"
  echo -e "${CYAN}  ║${WHITE}      Compatível: SSHPlus  │  v2.0        ${CYAN}║${NC}"
  echo -e "${CYAN}  ╚══════════════════════════════════════════╝${NC}"
  echo -e "  ${YELLOW}Log: ${LOG_FILE}${NC}"
  echo
}

gerar_json() {
  need_root
  echo
  echo -e "${CYAN}  ╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}  ║${WHITE}     Gerar Arquivo de Sincronização       ${CYAN}║${NC}"
  echo -e "${CYAN}  ╚══════════════════════════════════════════╝${NC}"
  echo
  log_info "Banco de dados : $USERS_DB"
  log_info "Dir. de senhas : $SENHA_DIR"
  log_info "Saída JSON     : $OUTPUT_JSON"
  separator

  if [ ! -f "$USERS_DB" ]; then
    log_err "Arquivo não encontrado: $USERS_DB"
    pause; return 1
  fi

  if [ ! -d "$SENHA_DIR" ]; then
    log_err "Diretório não encontrado: $SENHA_DIR"
    pause; return 1
  fi

  local total=0 erros=0

  echo "[" > "$OUTPUT_JSON"
  local first=true

  while read -r username limit; do
    [[ -z "$username" || -z "$limit" ]] && continue

    log_step "Processando usuário: $username"

    local pass_file="${SENHA_DIR}/${username}"
    local password=""
    if [ -f "$pass_file" ]; then
      password=$(cat "$pass_file")
    else
      log_warn "Senha não encontrada para: $username"
      (( erros++ ))
    fi

    local expire_raw expire_text expire_sql=""
    expire_raw=$(chage -l "$username" 2>/dev/null | grep "Account expires" || true)
    expire_text=$(echo "$expire_raw" | cut -d: -f2- | xargs)

    if [[ -z "$expire_text" || "$expire_text" == "never" || "$expire_text" == "never." ]]; then
      expire_sql=""
    else
      expire_sql=$(date -d "$expire_text" +"%Y-%m-%d 00:00:00" 2>/dev/null || true)
    fi

    [ "$first" = true ] && first=false || echo "," >> "$OUTPUT_JSON"

    cat >> "$OUTPUT_JSON" <<EOF
  {
    "username": "$username",
    "limit": $limit,
    "password": "$password",
    "expires": "$expire_sql"
  }
EOF
    (( total++ ))
  done < "$USERS_DB"

  echo "]" >> "$OUTPUT_JSON"

  separator
  log_ok "JSON gerado com sucesso!"
  log_info "Total de usuários : $total"
  [ "$erros" -gt 0 ] && log_warn "Senhas ausentes   : $erros"
  log_info "Arquivo           : $OUTPUT_JSON"
  pause
}

atualizar_sistema() {
  need_root
  echo
  echo -e "${CYAN}  ╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}  ║${WHITE}    Instalar / Atualizar / Reinstalar     ${CYAN}║${NC}"
  echo -e "${CYAN}  ║${WHITE}              ${APP}                  ${CYAN}║${NC}"
  echo -e "${CYAN}  ╚══════════════════════════════════════════╝${NC}"
  echo

  if ! command -v curl >/dev/null 2>&1; then
    log_err "curl não encontrado. Instale com: apt install curl"
    pause; return 1
  fi

  log_step "Verificando dependência: screen"
  if ! command -v screen >/dev/null 2>&1; then
    log_info "Instalando screen..."
    apt install -y screen >/dev/null 2>&1 && log_ok "screen instalado." || log_warn "Falha ao instalar screen."
  else
    log_ok "screen já instalado."
  fi

  separator

  log_step "Removendo serviço: ${CHECKUSER_SERVICE}"

  if systemctl is-active --quiet "$CHECKUSER_SERVICE" 2>/dev/null; then
    systemctl stop "$CHECKUSER_SERVICE" 2>/dev/null \
      && log_ok "Serviço ${CHECKUSER_SERVICE} parado." \
      || log_warn "Não foi possível parar ${CHECKUSER_SERVICE}."
  else
    log_warn "Serviço ${CHECKUSER_SERVICE} já estava inativo."
  fi

  if systemctl is-enabled --quiet "$CHECKUSER_SERVICE" 2>/dev/null; then
    systemctl disable "$CHECKUSER_SERVICE" 2>/dev/null \
      && log_ok "Serviço ${CHECKUSER_SERVICE} desabilitado." \
      || log_warn "Não foi possível desabilitar ${CHECKUSER_SERVICE}."
  else
    log_warn "Serviço ${CHECKUSER_SERVICE} já estava desabilitado."
  fi

  if [ -f "$CHECKUSER_FILE" ]; then
    rm -f "$CHECKUSER_FILE" \
      && log_ok "Arquivo de serviço removido: $CHECKUSER_FILE" \
      || log_err "Falha ao remover: $CHECKUSER_FILE"
  else
    log_warn "Arquivo não encontrado: $CHECKUSER_FILE"
  fi

  if [ -f "$CHECKUSER_BIN" ]; then
    rm -f "$CHECKUSER_BIN" \
      && log_ok "Binário removido: $CHECKUSER_BIN" \
      || log_err "Falha ao remover: $CHECKUSER_BIN"
  else
    log_warn "Binário não encontrado: $CHECKUSER_BIN"
  fi

  log_step "Recarregando systemd daemon..."
  systemctl daemon-reload \
    && log_ok "Daemon recarregado." \
    || log_err "Falha ao recarregar daemon."

  separator

  log_step "Verificando portas 80, 81, 443 e 7300..."
  for PORT in 80 81 443 7300; do
    local PID
    PID=$(lsof -t -i:"$PORT" 2>/dev/null || true)
    if [ -n "$PID" ]; then
      log_warn "Porta $PORT em uso (PID: $PID) — finalizando processo..."
      kill -9 "$PID" 2>/dev/null && log_ok "Processo finalizado na porta $PORT." \
        || log_err "Falha ao finalizar processo na porta $PORT."
    else
      log_ok "Porta $PORT livre."
    fi
  done

  sleep 1
  separator

  # ── Download do binário principal ────────────────────────
  log_step "Baixando wssh-vpn de: $BIN_URL"
  if curl -fsSL "$BIN_URL" -o "$BIN_PATH"; then
    chmod +x "$BIN_PATH"
    log_ok "wssh-vpn instalado: $BIN_PATH"
  else
    log_err "Falha no download do wssh-vpn. Verifique a URL ou conexão."
    pause; return 1
  fi

  separator

  # ── Download do decrypt_backup ────────────────────────────
  log_step "Baixando decrypt_backup de: $DECRYPT_URL"
  if curl -fsSL "$DECRYPT_URL" -o "$DECRYPT_PATH"; then
    chmod +x "$DECRYPT_PATH"
    log_ok "decrypt_backup instalado: $DECRYPT_PATH"
  else
    log_warn "Falha no download do decrypt_backup (não crítico)."
  fi

  separator

  echo
  echo -e "${GREEN}  ╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}  ║        ✔  Instalação Concluída!          ║${NC}"
  echo -e "${GREEN}  ╚══════════════════════════════════════════╝${NC}"
  echo
  echo -e "${WHITE}  ▸ Para iniciar e configurar via CLI:${NC}"
  echo -e "    ${YELLOW}${APP}${NC}"
  echo
  echo -e "${WHITE}  ▸ Credenciais padrão de acesso:${NC}"
  echo -e "    ${CYAN}Usuário : ${WHITE}admin${NC}"
  echo -e "    ${CYAN}Senha   : ${WHITE}admin123${NC}"
  echo
  echo -e "${WHITE}  ▸ Rotas disponíveis:${NC}"
  echo -e "    ${CYAN}🌐  http://<SEU-IP>:81${NC}"
  echo -e "    ${CYAN}🌐  http://<SEU-IP>:81/clientes${NC}"
  echo -e "    ${CYAN}🌐  http://<SEU-IP>:81/revenda${NC}"
  echo
  echo -e "${WHITE}  ▸ Restaurar backup:${NC}"
  echo -e "    ${CYAN}decrypt_backup <arquivo.db.enc> <senha>${NC}"
  echo
  echo -e "  ${YELLOW}ℹ  A configuração é feita diretamente na dashboard.${NC}"
  echo -e "  ${YELLOW}ℹ  Nenhum arquivo de config foi criado.${NC}"
  echo

  pause
}

remover_checkuser() {
  need_root
  echo
  echo -e "${CYAN}  ╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}  ║${WHITE}      Remoção do Serviço: checkuser       ${CYAN}║${NC}"
  echo -e "${CYAN}  ╚══════════════════════════════════════════╝${NC}"
  echo

  log_step "Parando serviço..."
  if systemctl is-active --quiet "$CHECKUSER_SERVICE" 2>/dev/null; then
    systemctl stop "$CHECKUSER_SERVICE" \
      && log_ok "Serviço parado." \
      || log_err "Falha ao parar o serviço."
  else
    log_warn "Serviço já estava inativo."
  fi

  log_step "Desabilitando serviço..."
  if systemctl is-enabled --quiet "$CHECKUSER_SERVICE" 2>/dev/null; then
    systemctl disable "$CHECKUSER_SERVICE" \
      && log_ok "Serviço desabilitado." \
      || log_err "Falha ao desabilitar."
  else
    log_warn "Serviço já estava desabilitado."
  fi

  log_step "Removendo arquivo de serviço..."
  if [ -f "$CHECKUSER_FILE" ]; then
    rm -f "$CHECKUSER_FILE" \
      && log_ok "Removido: $CHECKUSER_FILE" \
      || log_err "Falha: $CHECKUSER_FILE"
  else
    log_warn "Não encontrado: $CHECKUSER_FILE"
  fi

  log_step "Removendo binário..."
  if [ -f "$CHECKUSER_BIN" ]; then
    rm -f "$CHECKUSER_BIN" \
      && log_ok "Removido: $CHECKUSER_BIN" \
      || log_err "Falha: $CHECKUSER_BIN"
  else
    log_warn "Não encontrado: $CHECKUSER_BIN"
  fi

  log_step "Recarregando daemon..."
  systemctl daemon-reload \
    && log_ok "Daemon recarregado." \
    || log_err "Falha ao recarregar daemon."

  separator
  log_ok "Remoção do checkuser concluída!"
  pause
}

menu() {
  banner
  echo -e "  ${WHITE}Escolha uma opção:${NC}"
  echo
  echo -e "  ${GREEN}1)${NC}  🔄  Gerar arquivo de sincronização (SSHPlus)"
  echo -e "  ${GREEN}2)${NC}  ⬆️   Instalar / Atualizar / Reinstalar wssh-vpn"
  echo -e "  ${GREEN}3)${NC}  🗑️   Remover serviço checkuser"
  echo -e "  ${RED}0)${NC}  ❌  Sair"
  echo
  separator
  read -rp "  Opção: " op </dev/tty
  echo

  case "$op" in
    1) gerar_json ;;
    2) atualizar_sistema ;;
    3) remover_checkuser ;;
    0)
      echo -e "${CYAN}  Até logo!${NC}"
      echo
      exit 0
      ;;
    *)
      log_warn "Opção inválida: '$op'"
      pause
      ;;
  esac
}

need_root
touch "$LOG_FILE" 2>/dev/null || true

while true; do
  menu
done
