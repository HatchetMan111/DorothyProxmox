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

  # Claude Code CLI (Web-Mode-Agents laufen headless: spawn('claude', --print)).
  if ! command -v claude >/dev/null 2>&1; then
    info "Installiere Claude Code CLI (global)…"
    npm i -g --no-audit --no-fund @anthropic-ai/claude-code || warn "claude-CLI fehlgeschlagen – Web-Mode-Agents brauchen sie (ggf. später: npm i -g @anthropic-ai/claude-code)."
  else
    info "claude-CLI bereits vorhanden ($(claude --version 2>/dev/null || echo ok))."
  fi

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

  msg "[4/6] Browser-Patch + Abhängigkeiten + Production-Build…"

  # PATCH (DorothyProxmox): crypto.randomUUID() existiert nur in Secure Contexts
  # (https / localhost). Im LAN über http://<LXC-IP> ist es undefined und die
  # Web UI crasht sofort ("client-side exception", useTabManager/useState).
  # -> Helper mit getRandomValues-Fallback + alle direkten Aufrufe ersetzen.
  # Idempotent: läuft bei jedem Update erneut, ändert nichts wenn schon gepatcht.
  HELPER_FILE="$INSTALL_DIR/src/lib/safe-uuid.ts"
  mkdir -p "$INSTALL_DIR/src/lib"
  if [ ! -f "$HELPER_FILE" ]; then
    cat > "$HELPER_FILE" <<'HELPER_EOF'
// Proxmox-LXC-Patch (DorothyProxmox): sichere UUID-Erzeugung im Browser.
// crypto.randomUUID() gibt es nur in Secure Contexts (https/localhost).
// Im LAN ueber http://<LXC-IP> waere es undefined -> Client-Crash.
// Fallback: crypto.getRandomValues (auch insecure verfuegbar), Reserve: Math.random.
export function safeRandomUUID(): string {
  const c = globalThis.crypto as Crypto | undefined;
  if (c && typeof c.randomUUID === 'function') {
    return c.randomUUID();
  }
  const bytes = new Uint8Array(16);
  if (c && typeof c.getRandomValues === 'function') {
    c.getRandomValues(bytes);
  } else {
    for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  return (
    hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' +
    hex.slice(16, 20) + '-' + hex.slice(20)
  );
}
HELPER_EOF
    info "Helper src/lib/safe-uuid.ts angelegt."
  fi
  while IFS= read -r patchfile; do
    case "$patchfile" in "$HELPER_FILE") info "übersprungen (Helper): $patchfile"; continue;; esac
    grep -q "safe-uuid" "$patchfile" || sed -i "0,/^import .*$/s//&\nimport { safeRandomUUID } from '@\/lib\/safe-uuid';/" "$patchfile"
    sed -i 's/crypto\.randomUUID()/safeRandomUUID()/g' "$patchfile"
    info "gepatcht: $patchfile"
  done < <(grep -rl "crypto\.randomUUID()" "$INSTALL_DIR/src" --include='*.ts' --include='*.tsx' 2>/dev/null || true)

  # PATCH (DorothyProxmox) Web-Mode: /agents + /templates sind upstream hinter
  # "Desktop App Required" verriegelt. Dahinter liegt REST-fähiger Code, nur die
  # IPC-Brücke fehlt im Browser. -> useWebAgents-Hook (REST statt Electron-IPC)
  # + Output-Dialog statt PTY-Terminal + Gate aus agents/page.tsx entfernen.
  # Idempotent: Dateien werden nur geschrieben wenn neu/unser Marker fehlt,
  # Seiten-Patch läuft nur wenn noch ungepatcht.
  msg "[4/6] Web-Mode-Patch (Agents-Seite ohne Desktop-App)…"
  WEBHOOK_FILE="$INSTALL_DIR/src/hooks/useWebAgents.ts"
  WEBDIALOG_FILE="$INSTALL_DIR/src/components/AgentList/WebAgentOutputDialog.tsx"
  for target in "$WEBHOOK_FILE" "$WEBDIALOG_FILE"; do
    if [ -f "$target" ] && ! grep -q "DorothyProxmox" "$target" 2>/dev/null; then
      cp "$target" "$target.dorothyproxmox-bak"
      warn "$target existierte (upstream?) – Backup: $target.dorothyproxmox-bak"
    fi
  done
  cat > "$WEBHOOK_FILE" <<'WEBHOOK_EOF'
'use client';

// Proxmox-LXC Web-Mode (DorothyProxmox): Agent-Verwaltung ueber die Next.js
// REST-API statt Electron-IPC. Wird von useAgentsWebOrElectron() genau dann
// verwendet, wenn kein window.electronAPI existiert (reiner Browser, z. B.
// http://<LXC-IP>:3000). Signatur identisch zu useElectronAgents, damit
// src/app/agents/page.tsx unveraendert weiter funktioniert.

import { useState, useEffect, useCallback } from 'react';
import { useElectronAgents } from './useElectron';
import type { AgentStatus as ElectronAgentStatus } from '@/types/electron';

type EA = ReturnType<typeof useElectronAgents>;

// Wichtig: trailing Slash (next.config: trailingSlash:true), sonst 308.
const API = '/api/agents/';

async function req(path: string, init?: RequestInit): Promise<any> {
  const res = await fetch(path, init);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error((data && data.error) || `Request failed (${res.status})`);
  }
  return data;
}

export function useWebAgents(enabled = true): EA {
  const [agents, setAgents] = useState<ElectronAgentStatus[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const fetchAgents = useCallback(async () => {
    try {
      const data = await req(API);
      setAgents(((data && data.agents) || []) as ElectronAgentStatus[]);
    } catch (error) {
      console.error('Web-Mode: failed to fetch agents:', error);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!enabled) {
      setIsLoading(false);
      return;
    }
    fetchAgents();
    const t = setInterval(fetchAgents, 3000);
    return () => clearInterval(t);
  }, [enabled, fetchAgents]);

  // NOTE: Rueckgabe bewusst Promise<any> – der Electron-Typ verlangt ein
  // Pflichtfeld ptyId, das es im Web-Mode nicht gibt (wird synthetisiert).
  const createAgent = useCallback<EA['createAgent']>(async (config: any): Promise<any> => {
    if (!config || !config.projectPath) {
      throw new Error('Web-Modus: projectPath ist erforderlich.');
    }
    const data = await req(API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        projectPath: config.projectPath,
        skills: config.skills || [],
      }),
    });
    await fetchAgents();
    const agent = data.agent || {};
    return { ...agent, ptyId: agent.ptyId || `web-${agent.id || 'new'}` };
  }, [fetchAgents]);

  const updateAgent = useCallback<EA['updateAgent']>(async () => {
    throw new Error('Bearbeiten wird im Web-Modus noch nicht unterstützt (Start/Stop/Löschen gehen).');
  }, []);

  const startAgent = useCallback<EA['startAgent']>(async (id: string, prompt: string, options?: any) => {
    if (!prompt) {
      throw new Error('Web-Modus: bitte einen Prompt angeben (Agent läuft headless mit --print).');
    }
    await req(`${API}${id}/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'start', prompt, model: options && options.model ? options.model : undefined }),
    });
    await fetchAgents();
  }, [fetchAgents]);

  const stopAgent = useCallback<EA['stopAgent']>(async (id: string) => {
    await req(`${API}${id}/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'stop' }),
    });
    await fetchAgents();
  }, [fetchAgents]);

  const removeAgent = useCallback<EA['removeAgent']>(async (id: string) => {
    await req(`${API}${id}/`, { method: 'DELETE' });
    setAgents((prev) => prev.filter((a) => a.id !== id));
  }, []);

  const sendInput = useCallback<EA['sendInput']>(async (id: string, input: string) => {
    await req(`${API}${id}/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'input', input }),
    });
  }, []);

  return {
    agents,
    isLoading,
    isElectron: false,
    createAgent,
    updateAgent,
    startAgent,
    stopAgent,
    removeAgent,
    sendInput,
    refresh: fetchAgents,
  };
}

// Bruecken-Hook fuer src/app/agents/page.tsx: im Electron unveraendert,
// im Browser (kein window.electronAPI) die REST-Variante. Beide Hooks werden
// immer aufgerufen (Rules of Hooks), zurueckgegeben wird der passende.
export function useAgentsWebOrElectron(): EA {
  const electron = useElectronAgents();
  const webEnabled = typeof window !== 'undefined' && !electron.isElectron;
  const web = useWebAgents(webEnabled);
  if (typeof window !== 'undefined' && !electron.isElectron) {
    return web;
  }
  return electron;
}
WEBHOOK_EOF
  cat > "$WEBDIALOG_FILE" <<'WEBDIALOG_EOF'
'use client';

// Proxmox-LXC Web-Mode (DorothyProxmox): einfacher Output-Dialog als Ersatz
// fuer AgentTerminalDialog (der braucht Electron-PTY). Pollt den Agent-Status
// ueber GET /api/agents/[id]/ und erlaubt Start/Stop. Kein interaktives
// Terminal (headless --print), kein Edit.

import { useState, useEffect } from 'react';

interface Props {
  agentId: string | null;
  open: boolean;
  onClose: () => void;
  onStart: (id: string, prompt: string) => void;
  onStop: (id: string) => void;
}

export function WebAgentOutputDialog({ agentId, open, onClose, onStart, onStop }: Props) {
  const [output, setOutput] = useState<string[]>([]);
  const [status, setStatus] = useState<string>('');
  const [name, setName] = useState<string>('');
  const [prompt, setPrompt] = useState<string>('');

  useEffect(() => {
    if (!open || !agentId) return;
    let alive = true;
    const load = async () => {
      try {
        const res = await fetch(`/api/agents/${agentId}/`);
        if (!res.ok) return;
        const data = await res.json();
        if (!alive || !data.agent) return;
        setOutput(data.agent.output || []);
        setStatus(data.agent.status || '');
        setName(data.agent.name || data.agent.currentTask || agentId);
      } catch {
        /* offline/noch ladend – still weitermachen */
      }
    };
    load();
    const t = setInterval(load, 2000);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [open, agentId]);

  if (!open || !agentId) return null;

  return (
    <div
      style={{ position: 'fixed', inset: 0, zIndex: 100, background: 'rgba(0,0,0,0.7)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}
      onClick={onClose}
    >
      <div
        style={{ width: '100%', maxWidth: 760, maxHeight: '85vh', display: 'flex', flexDirection: 'column', background: '#14161c', color: '#fff', border: '1px solid #333', borderRadius: 8 }}
        onClick={(e) => e.stopPropagation()}
      >
        <div style={{ padding: '12px 16px', borderBottom: '1px solid #333', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <strong style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{name} <span style={{ color: '#888', fontWeight: 'normal' }}>({status || '…'})</span></strong>
          <button onClick={onClose} style={{ background: 'transparent', color: '#fff', border: '1px solid #555', borderRadius: 4, padding: '2px 10px', cursor: 'pointer' }}>✕</button>
        </div>
        <pre style={{ flex: 1, overflow: 'auto', margin: 0, padding: 12, fontSize: 12, whiteSpace: 'pre-wrap', wordBreak: 'break-word', minHeight: 200 }}>
          {output.length > 0 ? output.join('\n') : '(noch keine Ausgabe – Agent ggf. starten)'}
        </pre>
        <div style={{ padding: 12, borderTop: '1px solid #333', display: 'flex', gap: 8 }}>
          <input
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
            placeholder="Prompt für diesen Agent…"
            style={{ flex: 1, background: '#0d0e12', color: '#fff', border: '1px solid #555', borderRadius: 4, padding: '6px 10px' }}
          />
          <button onClick={() => { if (prompt.trim()) { onStart(agentId, prompt); setPrompt(''); } }} style={{ background: '#2f81f7', color: '#fff', border: 0, borderRadius: 4, padding: '6px 14px', cursor: 'pointer' }}>Start</button>
          <button onClick={() => onStop(agentId)} style={{ background: 'transparent', color: '#fff', border: '1px solid #555', borderRadius: 4, padding: '6px 14px', cursor: 'pointer' }}>Stop</button>
        </div>
      </div>
    </div>
  );
}
WEBDIALOG_EOF
  info "Web-Mode-Dateien geschrieben (useWebAgents, WebAgentOutputDialog)."

  PAGE_FILE="$INSTALL_DIR/src/app/agents/page.tsx"
  if grep -q "useAgentsWebOrElectron" "$PAGE_FILE"; then
    info "agents/page.tsx bereits im Web-Mode – übersprungen."
  else
    grep -q "DesktopRequiredMessage" "$PAGE_FILE" || die "agents/page.tsx enthält kein DesktopRequiredMessage – Upstream-Struktur geändert, Web-Mode-Patch bitte anpassen."
    python3 - "$PAGE_FILE" <<'PAGEPATCH_EOF'
import sys
path = sys.argv[1]
p = open(path).read()
def rep(old, new):
    global p
    n = p.count(old)
    assert n == 1, 'Web-Mode-Patch passt nicht auf diese Dorothy-Version (%dx: %r).' % (n, old[:60])
    p = p.replace(old, new)
rep("import { useElectronAgents, useElectronFS, useElectronSkills, isElectron } from '@/hooks/useElectron';",
    "import { useElectronAgents, useElectronFS, useElectronSkills, isElectron } from '@/hooks/useElectron';\nimport { useAgentsWebOrElectron } from '@/hooks/useWebAgents';")
rep("import AgentTerminalDialog from '@/components/AgentWorld/AgentTerminalDialog';",
    "import AgentTerminalDialog from '@/components/AgentWorld/AgentTerminalDialog';\nimport { WebAgentOutputDialog } from '@/components/AgentList/WebAgentOutputDialog';")
rep("  DesktopRequiredMessage,\n", "")
rep("} = useElectronAgents();",
    "} = useAgentsWebOrElectron();")
rep("  // Early returns\n  if (!hasElectron && typeof window !== 'undefined') {\n    return <DesktopRequiredMessage />;\n  }\n",
    "  // Web-Mode-Patch (DorothyProxmox): kein Desktop-Gate – Browser nutzt REST-Bruecke.\n  const inWebMode = typeof window !== 'undefined' && !hasElectron;\n\n  // Early returns\n")
rep("      {/* Terminal Dialog — click card body to view */}\n      <AgentTerminalDialog\n",
    "      {/* Terminal Dialog — click card body to view (Web-Modus: Output-Dialog) */}\n      {inWebMode ? (\n        <WebAgentOutputDialog\n          agentId={viewAgentId}\n          open={!!viewAgentId}\n          onClose={() => setViewAgentId(null)}\n          onStart={(id, prompt) => handleStartAgent(id, prompt)}\n          onStop={stopAgent}\n        />\n      ) : (\n      <AgentTerminalDialog\n")
rep("        onBrowseFolder={isElectron() ? openFolderDialog : undefined}\n      />\n    </div>",
    "        onBrowseFolder={isElectron() ? openFolderDialog : undefined}\n      />\n      )}\n    </div>")
open(path, 'w').write(p)
print('Web-Mode-Patch auf agents/page.tsx angewendet.')
PAGEPATCH_EOF
  fi

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

  # ANTHROPIC_API_KEY für headless Agents (claude --print braucht ihn; im LXC
  # kein Browser-Login möglich). Priorität: Env > bestehender Eintrag > Prompt.
  # Der Key wird nie geloggt (set +x rundherum, kein echo).
  set +x
  EXISTING_KEY="$(grep -m1 '^Environment=ANTHROPIC_API_KEY=' "/etc/systemd/system/${APP_NAME}.service" 2>/dev/null | cut -d= -f3- || true)"
  API_KEY=""
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    API_KEY="$ANTHROPIC_API_KEY"
    info "ANTHROPIC_API_KEY aus Umgebung übernommen (maskiert gespeichert)."
  elif [ -n "$EXISTING_KEY" ]; then
    API_KEY="$EXISTING_KEY"
    info "Bestehender ANTHROPIC_API_KEY im Service wird beibehalten."
  elif [ -t 0 ]; then
    echo "Anthropic API-Key für Web-Mode-Agents (https://console.anthropic.com/, Enter=überspringen):"
    read -rsp "> " API_KEY || API_KEY=""
    echo ""
    [ -z "$API_KEY" ] && info "Kein Key eingegeben – Agents starten später nicht, Rest der UI geht. Nachtragen: Service-Environment + restart."
  else
    info "Kein Terminal: ANTHROPIC_API_KEY später via Service-Environment nachtragen (sonst starten keine Agents)."
  fi
  if [ "$DEBUG" = "1" ]; then set -x; fi
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
  # Key maskiert in den Service übernehmen (nie loggen).
  set +x
  if [ -n "${API_KEY:-}" ]; then
    API_KEY_ESC="${API_KEY//&/\\&}"
    sed -i "/^Environment=HOSTNAME=/a Environment=ANTHROPIC_API_KEY=${API_KEY_ESC}" "/etc/systemd/system/${APP_NAME}.service"
    info "ANTHROPIC_API_KEY im Service hinterlegt."
  fi
  unset API_KEY API_KEY_ESC EXISTING_KEY
  if [ "$DEBUG" = "1" ]; then set -x; fi
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
  AGENTS_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://localhost:${PORT}/api/agents/" || echo 000)"
  info "Agents-API (/api/agents/): HTTP $AGENTS_CODE $([ "$AGENTS_CODE" = "200" ] && echo "(Web-Mode-Backend bereit)" || echo "(WARNUNG: Web-Mode-Agents evtl. nicht nutzbar)")"
  if command -v claude >/dev/null 2>&1; then info "claude-CLI: $(claude --version 2>/dev/null || echo vorhanden)"; else warn "claude-CLI fehlt – Agents können nicht starten (npm i -g @anthropic-ai/claude-code)."; fi

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
