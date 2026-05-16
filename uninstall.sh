#!/bin/bash
# Uninstall script for SSH Panel + Xray-core
# Usage: sudo bash uninstall.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[x]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}──────────────────────────────────────────${NC}"; \
            echo -e "${CYAN}  $*${NC}"; \
            echo -e "${CYAN}──────────────────────────────────────────${NC}"; }

# ── config (deve bater com o install.sh) ─────────────────────────────────────
INSTALL_DIR="/opt/sshpanel"
SERVICE_NAME="sshpanel"
DNSTT_SERVICE="sshpanel-dnstt-redirect"
DNSTT_SCRIPT="/usr/local/sbin/sshpanel-dnstt-redirect.sh"
DNSTT_UNIT="/etc/systemd/system/${DNSTT_SERVICE}.service"
MAIN_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
DB_NAME="sshpanel"
DB_USER="sshpanel"
# ─────────────────────────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && error "Execute como root: sudo bash $0"

echo -e "\n${RED}══════════════════════════════════════════${NC}"
echo -e "${RED}   SSH Panel + Xray-core  ·  Uninstaller   ${NC}"
echo -e "${RED}══════════════════════════════════════════${NC}\n"

warn "Este script irá remover PERMANENTEMENTE:"
echo -e "  • Serviços systemd: ${SERVICE_NAME}, ${DNSTT_SERVICE}"
echo -e "  • Diretório de instalação: ${INSTALL_DIR}"
echo -e "  • Banco de dados PostgreSQL: ${DB_NAME} e usuário ${DB_USER}"
echo -e "  • Script de redirecionamento DNS: ${DNSTT_SCRIPT}"
echo -e "  • Regras iptables/nftables adicionadas pelo instalador"
echo -e "  • Restauração do systemd-resolved (se foi desativado)"
echo ""

# Confirmação interativa (pular com -y)
if [[ "${1:-}" != "-y" ]]; then
  read -r -p "$(echo -e "${YELLOW}Tem certeza? Digite 'sim' para continuar: ${NC}")" CONFIRM
  [[ "$CONFIRM" == "sim" ]] || { echo "Cancelado."; exit 0; }
fi

SYSTEMCTL_BIN="$(command -v systemctl 2>/dev/null || true)"

# ── 1. Parar e desabilitar serviços ──────────────────────────────────────────
section "[1/7] Parando e removendo serviços systemd"

for svc in "$SERVICE_NAME" "$DNSTT_SERVICE"; do
  if [[ -n "$SYSTEMCTL_BIN" ]]; then
    if "$SYSTEMCTL_BIN" is-active --quiet "$svc" 2>/dev/null; then
      "$SYSTEMCTL_BIN" stop "$svc" && info "  Serviço '$svc' parado" || warn "  Não foi possível parar '$svc'"
    else
      info "  Serviço '$svc' já estava inativo"
    fi
    if "$SYSTEMCTL_BIN" is-enabled --quiet "$svc" 2>/dev/null; then
      "$SYSTEMCTL_BIN" disable "$svc" && info "  Serviço '$svc' desabilitado" || true
    fi
  fi
done

for unit_file in "$MAIN_UNIT" "$DNSTT_UNIT"; do
  if [[ -f "$unit_file" ]]; then
    rm -f "$unit_file"
    info "  Unit file removido: $unit_file"
  fi
done

[[ -n "$SYSTEMCTL_BIN" ]] && "$SYSTEMCTL_BIN" daemon-reload && info "  systemd recarregado"

# ── 2. Remover regras de firewall/NAT ────────────────────────────────────────
section "[2/7] Removendo regras iptables/nftables (DNS redirect)"

DNSTT_PORT="${DNSTT_PORT:-5300}"

remove_ipt_rule() {
  local bin="$1" chain="$2"
  while "$bin" -t nat -C "$chain" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT" 2>/dev/null; do
    "$bin" -t nat -D "$chain" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT" \
      && info "  Regra iptables ($bin $chain) removida" || break
  done
}

if command -v iptables >/dev/null 2>&1; then
  remove_ipt_rule iptables  PREROUTING
fi
if command -v ip6tables >/dev/null 2>&1; then
  remove_ipt_rule ip6tables PREROUTING
fi

if command -v nft >/dev/null 2>&1; then
  if nft list table inet sshpanel_nat >/dev/null 2>&1; then
    nft delete table inet sshpanel_nat 2>/dev/null \
      && info "  Tabela nftables 'sshpanel_nat' removida" \
      || warn "  Não foi possível remover tabela nftables 'sshpanel_nat'"
  fi
fi

# Regra UFW (apenas remove se aplicável)
if command -v ufw >/dev/null 2>&1; then
  ufw delete allow 53/udp >/dev/null 2>&1 && info "  Regra UFW 53/udp removida" || true
fi

# Regra firewalld
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --remove-port=53/udp >/dev/null 2>&1 \
    && firewall-cmd --reload >/dev/null 2>&1 \
    && info "  Regra firewalld 53/udp removida" || true
fi

# ── 3. Remover script DNSTT ──────────────────────────────────────────────────
section "[3/7] Removendo script DNSTT"

if [[ -f "$DNSTT_SCRIPT" ]]; then
  rm -f "$DNSTT_SCRIPT"
  info "  Removido: $DNSTT_SCRIPT"
fi

# ── 4. Restaurar DNS (systemd-resolved) ──────────────────────────────────────
section "[4/7] Restaurando resolução de DNS"

if [[ -n "$SYSTEMCTL_BIN" ]] && "$SYSTEMCTL_BIN" list-unit-files systemd-resolved.service >/dev/null 2>&1; then
  "$SYSTEMCTL_BIN" enable --now systemd-resolved.service >/dev/null 2>&1 \
    && info "  systemd-resolved reativado" \
    || warn "  Não foi possível reativar systemd-resolved; verifique manualmente"

  # Restaurar symlink padrão do resolv.conf
  if [[ ! -L /etc/resolv.conf ]]; then
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null \
      && info "  /etc/resolv.conf restaurado para symlink systemd-resolved" \
      || warn "  Não foi possível restaurar /etc/resolv.conf; verifique manualmente"
  fi
else
  warn "  systemd-resolved não encontrado; verifique /etc/resolv.conf manualmente"
fi

# ── 5. Limpar entrada do /etc/fstab ──────────────────────────────────────────
section "[5/7] Limpando /etc/fstab (entrada tmpfs de logs)"

LOG_DIR="${INSTALL_DIR}/logs"

if [[ -f /etc/fstab ]]; then
  # Desmontar o tmpfs dos logs se ainda estiver montado
  if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$LOG_DIR" 2>/dev/null; then
    umount -l "$LOG_DIR" 2>/dev/null && info "  tmpfs de logs desmontado ($LOG_DIR)" || warn "  Não foi possível desmontar $LOG_DIR"
  fi

  # Remover entrada do fstab
  TMP_FSTAB="$(mktemp)"
  awk -v mp="$LOG_DIR" '!($1 == "tmpfs" && $2 == mp && $3 == "tmpfs") {print}' /etc/fstab > "$TMP_FSTAB"
  cat "$TMP_FSTAB" > /etc/fstab
  rm -f "$TMP_FSTAB"
  info "  Entrada tmpfs removida de /etc/fstab"

  # Remover backup gerado pelo instalador (mais recente apenas)
  find /etc -maxdepth 1 -name 'fstab.sshpanel.bak.*' -delete 2>/dev/null && \
    info "  Backups fstab.sshpanel.bak.* removidos" || true
fi

[[ -n "$SYSTEMCTL_BIN" ]] && "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true

# ── 6. Remover banco de dados PostgreSQL ─────────────────────────────────────
section "[6/7] Removendo banco de dados PostgreSQL"

if command -v psql >/dev/null 2>&1; then
  # Encerrar conexões ativas antes de dropar
  su -c "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();\" postgres" postgres 2>/dev/null || true

  # Drop do banco
  if su -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\" | grep -q 1" postgres 2>/dev/null; then
    su -c "psql -c \"DROP DATABASE ${DB_NAME};\"" postgres \
      && info "  Banco de dados '${DB_NAME}' removido" \
      || warn "  Não foi possível remover o banco '${DB_NAME}'"
  else
    info "  Banco '${DB_NAME}' não existe, nada a remover"
  fi

  # Drop do usuário
  if su -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\" | grep -q 1" postgres 2>/dev/null; then
    su -c "psql -c \"DROP USER ${DB_USER};\"" postgres \
      && info "  Usuário '${DB_USER}' removido" \
      || warn "  Não foi possível remover o usuário '${DB_USER}'"
  else
    info "  Usuário '${DB_USER}' não existe, nada a remover"
  fi
else
  warn "  psql não encontrado; banco/usuário PostgreSQL não foram removidos"
  warn "  Remova manualmente: DROP DATABASE ${DB_NAME}; DROP USER ${DB_USER};"
fi

# ── 7. Remover diretório de instalação ───────────────────────────────────────
section "[7/7] Removendo ${INSTALL_DIR}"

if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
  info "  Diretório removido: $INSTALL_DIR"
else
  info "  Diretório '${INSTALL_DIR}' não encontrado, nada a remover"
fi

# ── Resumo ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}   Desinstalação concluída!                ${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
echo -e "  Removidos:"
echo -e "    • Serviços systemd: ${SERVICE_NAME}, ${DNSTT_SERVICE}"
echo -e "    • Diretório: ${INSTALL_DIR}"
echo -e "    • Banco PostgreSQL: ${DB_NAME} / usuário: ${DB_USER}"
echo -e "    • Regras iptables/nftables de DNS redirect"
echo -e "    • Entrada tmpfs em /etc/fstab"
echo ""
echo -e "  ${YELLOW}Não removidos (opcionais — podem ser usados por outros serviços):${NC}"
echo -e "    • Go  (/usr/local/go)  →  rm -rf /usr/local/go"
echo -e "    • PostgreSQL (pacote)  →  apt remove postgresql  (ou equivalente)"
echo ""
