#!/usr/bin/env bash
#
# DATEI: install/dorothy.sh
# ZWECK: Dorothy (https://github.com/Charlie85270/Dorothy) als LXC auf Proxmox VE
#        installieren – im Stil der Proxmox VE Community Scripts.
#
# EINZEILER (auf dem Proxmox-Host als root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DorothyProxmox/main/install/dorothy.sh)"
#   CTID=150 MEMORY_MB=4096 CORES=2 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DorothyProxmox/main/install/dorothy.sh)"
#   DEBUG=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DorothyProxmox/main/install/dorothy.sh)"  # bash -x Debug-Log
#
# MODI (automatisch erkannt):
#   * Host-Modus : pct vorhanden  -> erstellt LXC, installiert darin (per pct exec)
#   * Container-Modus: kein pct   -> installiert Dorothy direkt (auch manuell im LXC nutzbar)
#   * Erzwingen: HOST_MODE=1 / CONTAINER_MODE=1
#
set -euo pipefail

# ============================================================================
# KONFIGURATION – alles per Umgebungsvariable überschreibbar (Variablen oben)
# ============================================================================
APP_NAME="${APP_NAME:-dorothy}"
REPO_URL="${REPO_URL:-https://github.com/Charlie85270/Dorothy.git}"
REPO_REF="${REPO_REF:-main}"                    # Branch/Tag, z. B. main oder v1.2.9
INSTALL_DIR="${INSTALL_DIR:-/opt/dorothy}"
PORT="${PORT:-3000}"                            # Dorothy Web-UI (Next.js)
BIND_HOST="${BIND_HOST:-0.0.0.0}"               # 0.0.0.0 = im LAN erreichbar
NODE_MAJOR="${NODE_MAJOR:-22}"                  # laut .nvmrc: Node 22

# LXC-Defaults (Dorothy baut Next.js + native Module -> etwas größer wählen)
CTID="${CTID:-}"                                # leer = nächste freie ID (pvesh /cluster/nextid)
CT_HOSTNAME="${CT_HOSTNAME:-dorothy}"
CT_PASSWORD="${CT_PASSWORD:-}"                  # leer = kein Passwort (Zugriff via pct enter)
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
DISK_SIZE_GB="${DISK_SIZE_GB:-12}"
MEMORY_MB="${MEMORY_MB:-4096}"
CORES="${CORES:-2}"
SWAP_MB="${SWAP_MB:-512}"

# URL dieses Scripts (für den Download *in* den Container).
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/HatchetMan111/DorothyProxmox/main/install/dorothy.sh}"

HOST_MODE="${HOST_MODE:-0}"
CONTAINER_MODE="${CONTAINER_MODE:-0}"
DEBUG="${DEBUG:-0}"
LOG_FILE="${LOG_FILE:-/var/log/${APP_NAME}-install.log}"

[ "$DEBUG" = "1" ] && set -x

# ============================================================================
# Helpers + volle Fehlermeldungskette (Anforderung #4)
# ============================================================================
msg()  { echo -e "\n\033[1;32m▶ $*\033[0m"; }
info() { echo -e "\033[1;34mℹ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }
die()  { echo -e "\033[1;31m✖ FEHLER: $*\033[0m" >&2; exit 1; }

# Bei jedem Fehler: komplette Kette (Exit-Code, Zeile, Befehl, Stack, Logs).
error_trap() {
  local rc=$?
  local line="${1:-?}" cmd="${2:-?}"
  echo "" >&2
  echo "==================================================================" >&2
  echo "✖ INSTALLATION FEHLGESCHLAGEN (Exit-Code: $rc)" >&2
  echo "  Datei   : $0" >&2
  echo "  Zeile   : $line" >&2
  echo "  Befehl  : $cmd" >&2
  echo "------------------------------------------------------------------" >&2
  echo "Stacktrace (Aufrufkette):" >&2
  local i=0
  while caller $i >&2 2>/dev/null; do i=$((i + 1)); done || true
  echo "------------------------------------------------------------------" >&2
  echo "Letzte 40 Log-Zeilen ($LOG_FILE):" >&2
  tail -n 40 "$LOG_FILE" 2>/dev/null >&2 || echo "(kein Log verfügbar)" >&2
  echo "------------------------------------------------------------------" >&2
  if systemctl list-units --full --all 2>/dev/null | grep -q "${APP_NAME}.service"; then
    echo "Service-Status + letzte 60 Journal-Zeilen:" >&2
    systemctl --no-pager status "${APP_NAME}.service" >&2 || true
    journalctl -u "${APP_NAME}.service" --no-pager -n 60 >&2 || true
  fi
  echo "==================================================================" >&2
  echo "Debug-Tipp: erneut mit bash -x starten:" >&2
  echo "  DEBUG=1 bash -c \"\$(wget -qLO - $SCRIPT_URL)\"" >&2
  echo "  oder: bash -x $0" >&2
  exit "$rc"
}
trap 'error_trap "$LINENO" "$BASH_COMMAND"' ERR

in_lxc() { [ -f /.dockerenv ] && return 1; grep -qa "container=lxc" /proc/1/environ 2>/dev/null; }

# Modus entscheiden
if [ "$HOST_MODE" = "1" ]; then MODE="host";
elif [ "$CONTAINER_MODE" = "1" ]; then MODE="container";
elif command -v pct >/dev/null 2>&1 && ! in_lxc; then MODE="host";
else MODE="container";
fi

# ============================================================================
# HOST-MODUS: LXC erstellen + Installation darin anstoßen
# ============================================================================
host_mode() {
  [ "$(id -u)" -eq 0 ] || die "Host-Modus bitte als root auf dem Proxmox-Host ausführen."
  command -v pct >/dev/null 2>&1 || die "pct nicht gefunden – dieses Script im Host-Modus nur auf Proxmox VE nutzen."
  command -v pvesh >/dev/null 2>&1 || die "pvesh nicht gefunden – kein Proxmox-Host?"

  echo "========================================================"
  echo "   Dorothy – Proxmox LXC Installer (Host-Modus)"
  echo "========================================================"

  # CT-ID bestimmen
  if [ -z "$CTID" ]; then
    CTID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
    if [ -z "$CTID" ]; then
      CTID=100
      while pct status "$CTID" >/dev/null 2>&1 || qm status "$CTID" >/dev/null 2>&1; do CTID=$((CTID + 1)); done
    fi
  fi
  pct status "$CTID" >/dev/null 2>&1 && die "CT-ID $CTID ist bereits belegt. CTID=<frei> setzen."
  info "CT-ID: $CTID | Hostname: $CT_HOSTNAME | ${CORES}vCPU / ${MEMORY_MB}MB RAM / ${DISK_SIZE_GB}GB Disk"

  # Storage prüfen / fallback auf ersten rootdir-fähigen Storage
  if ! pvesm status --content rootdir 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$STORAGE"; then
    FALLBACK="$(pvesm status --content rootdir 2>/dev/null | awk 'NR==2{print $1}')"
    [ -n "$FALLBACK" ] || die "Kein Storage mit Content 'rootdir' gefunden."
    warn "Storage '$STORAGE' nicht gefunden – verwende '$FALLBACK'."
    STORAGE="$FALLBACK"
  fi

  msg "Lade Debian-12-Template (falls nötig)…"
  pveam update >/dev/null
  TEMPLATE="$(pveam available --section system 2>/dev/null | grep debian-12-standard | awk '{print $2}' | sort -rV | head -n1)"
  [ -n "$TEMPLATE" ] || die "Kein debian-12-standard Template gefunden."
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  else
    info "Template $TEMPLATE bereits vorhanden."
  fi

  msg "Erstelle LXC '$CT_HOSTNAME' (ID $CTID)…"
  # shellcheck disable=SC2086
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    ${CT_PASSWORD:+--password "$CT_PASSWORD"} \
    --unprivileged 1 \
    --features nesting=1 \
    --memory "$MEMORY_MB" \
    --cores "$CORES" \
    --swap "$SWAP_MB" \
    --rootfs "${STORAGE}:${DISK_SIZE_GB}" \
    --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
    --onboot 1 \
    --start 1

  msg "Warte auf Netzwerk im Container…"
  IP=""
  for _ in $(seq 1 30); do
    IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [ -n "$IP" ] && break
    sleep 2
  done
  [ -n "$IP" ] || die "Container hat keine IP (DHCP prüfen: pct exec $CTID -- ip a)."
  info "Container-IP: $IP"

  msg "Installiere Dorothy im Container (dauert einige Minuten: npm install + build)…"
  pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null"
  # Script in den Container laden (Exakt diese Datei, inkl. aller Env-Overrides)
  pct exec "$CTID" -- bash -c "curl -fsSL '${SCRIPT_URL}?v='\"\$(date +%s)\" -o /root/dorothy-install.sh && chmod +x /root/dorothy-install.sh"
  pct exec "$CTID" -- env CONTAINER_MODE=1 APP_NAME="$APP_NAME" REPO_URL="$REPO_URL" \
    REPO_REF="$REPO_REF" INSTALL_DIR="$INSTALL_DIR" PORT="$PORT" BIND_HOST="$BIND_HOST" \
    NODE_MAJOR="$NODE_MAJOR" DEBUG="$DEBUG" bash /root/dorothy-install.sh

  cat <<EOF

========================================================
      ✅ FERTIG! Dorothy läuft im LXC (ID $CTID).
========================================================
  Web UI : http://$IP:$PORT
  (Bind: $BIND_HOST:$PORT – im LXC bewusst netzwerkweit,
   nur in vertrauenswürdigen Netzen betreiben!)

Nützliches (auf dem Proxmox-Host):
  pct enter $CTID                  # in den Container
  pct exec $CTID -- systemctl status dorothy
  pct exec $CTID -- journalctl -u dorothy -n 50
  pct stop $CTID / pct start $CTID # Stop/Start (Autostart: onboot=1)

Update im Container:
  pct enter $CTID
  REPO_REF=main bash /root/dorothy-install.sh   # idempotent: pull + rebuild

Deinstallieren:
  pct stop $CTID && pct destroy $CTID
========================================================
EOF
}

# ============================================================================
# CONTAINER-MODUS: Dorothy installieren (idempotent)
# ============================================================================
container_mode() {
  [ "$(id -u)" -eq 0 ] || die "Container-Modus bitte als root ausführen."
  echo "========================================================"
  echo "   Dorothy – Installation im Container"
  echo "   Repo: $REPO_URL @ $REPO_REF -> $INSTALL_DIR :$PORT"
  echo "========================================================"
  echo "Log: $LOG_FILE (Tee: Konsole + Datei)"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "--- Dorothy-Setup $(date -u +%FT%TZ) | DEBUG=$DEBUG ---"

  export DEBIAN_FRONTEND=noninteractive

  msg "[1/6] System-Abhängigkeiten…"
  apt-get update
  apt-get install -y curl git ca-certificates sudo procps iproute2 \
    build-essential python3 locales
  grep -q "^en_US.UTF-8" /etc/locale.gen 2>/dev/null || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
  locale-gen >/dev/null 2>&1 || true

  msg "[2/6] Node.js $NODE_MAJOR…"
  CUR_MAJOR="$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/' || echo 0)"
  if [ "$CUR_MAJOR" != "$NODE_MAJOR" ]; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
  else
    info "Node $(node -v) bereits passend."
  fi
  node -v; npm -v

  msg "[3/6] Repository (idempotent klonen/updaten)…"
  export GIT_TERMINAL_PROMPT=0
  if [ -d "$INSTALL_DIR/.git" ]; then
    info "Bestehendes Repo gefunden – aktualisiere…"
    git -C "$INSTALL_DIR" fetch --all --tags
    git -C "$INSTALL_DIR" checkout -q "$REPO_REF" || warn "checkout $REPO_REF fehlgeschlagen, bleibe auf aktuellem Stand."
    git -C "$INSTALL_DIR" pull --ff-only || info "pull nicht möglich (evtl. detached) – weiter."
  else
    [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ] && die "$INSTALL_DIR existiert und ist kein Git-Repo. Bitte leeren/umbenennen."
    git clone "$REPO_URL" "$INSTALL_DIR"
    git -C "$INSTALL_DIR" checkout -q "$REPO_REF" || warn "checkout $REPO_REF fehlgeschlagen."
  fi
  git -C "$INSTALL_DIR" rev-parse --short HEAD | xargs -I{} echo "Checkout: {} ($(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached))"

  msg "[4/6] Abhängigkeiten + Production-Build…"
  cd "$INSTALL_DIR"
  if [ -f package-lock.json ] && command -v npm >/dev/null; then
    npm ci --no-audit --no-fund || npm install --no-audit --no-fund
  else
    npm install --no-audit --no-fund
  fi
  npm run build

  msg "[5/6] systemd-Service '$APP_NAME' (reboot-sicher)…"
  NEXT_BIN="$INSTALL_DIR/node_modules/.bin/next"
  [ -x "$NEXT_BIN" ] || die "next-Binary fehlt: $NEXT_BIN (Build fehlgeschlagen?)"
  cat > "/etc/systemd/system/${APP_NAME}.service" <<EOF
[Unit]
Description=Dorothy – AI Agent Orchestrator Web UI (Port $PORT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
Environment=NODE_ENV=production
Environment=PORT=$PORT
Environment=HOSTNAME=$BIND_HOST
ExecStart=$NEXT_BIN start -H $BIND_HOST -p $PORT
Restart=always
RestartSec=5
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF
  # Port in LXC-Firewall öffnen (nur wenn ufw aktiv vorhanden)
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PORT"/tcp || true
  fi
  systemctl daemon-reload
  systemctl enable "$APP_NAME"
  systemctl restart "$APP_NAME"

  msg "[6/6] Verifikation (Service + HTTP)…"
  systemctl is-active --quiet "$APP_NAME" || {
    journalctl -u "$APP_NAME" --no-pager -n 60 || true
    die "Service $APP_NAME ist nicht aktiv."
  }
  info "Service aktiv: $(systemctl is-active "$APP_NAME")"
  OK=0
  for i in $(seq 1 30); do
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${PORT}/" || echo 000)"
    if [ "$CODE" != "000" ] && [ "$CODE" -lt 500 ]; then OK=1; echo "HTTP-Check OK (Versuch $i): $CODE"; break; fi
    echo "Warte auf Web UI… Versuch $i/30 (Code: $CODE)"; sleep 5
  done
  [ "$OK" = "1" ] || {
    journalctl -u "$APP_NAME" --no-pager -n 60 || true
    die "Web UI antwortet nicht auf http://localhost:${PORT}/ (30 Versuche)."
  }

  IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)"
  cat <<EOF

========================================================
      ✅ DOROTHY INSTALLIERT & VERIFIZIERT
========================================================
Service : systemctl status $APP_NAME (enabled, Restart=always)
Build   : $(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null)
Web UI  :
EOF
  if [ "$BIND_HOST" = "127.0.0.1" ]; then
    echo "  http://localhost:${PORT}/  (nur lokal)"
  else
    # shellcheck disable=SC2086
    for ip in $IPS; do echo "  http://$ip:${PORT}/"; done
    [ -z "$IPS" ] && echo "  http://<LXC-IP>:${PORT}/ (IP via 'hostname -I' prüfen)"
  fi
  cat <<EOF
Logs    : journalctl -u $APP_NAME -f
Reboot  : Container startet automatisch (onboot=1), App via systemd
Hinweis : Electron-Features (PTY-Terminals) laufen nur in der Desktop-
          App; im LXC steht die Web UI (Kanban, Automations, Vault,
          Settings, MCP-Config) bereit. API-Keys/Token (Telegram, Slack,
          SocialData) optional unter Settings eintragen – alles lokal.
========================================================
EOF
}

# --- Dispatch ---
if [ "$MODE" = "host" ]; then host_mode; else container_mode; fi
