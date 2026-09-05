# Dorothy – Proxmox LXC Installer

Installiert [Dorothy](https://github.com/Charlie85270/Dorothy) (AI-Agent-Orchestrator:
Claude Code, Codex, Gemini, Grok – parallele Agents, Kanban, Automations, Telegram/Slack,
Vault, MCP-Server) als **LXC-Container auf Proxmox VE** – im Stil der
**Proxmox VE Community Scripts**.

- **App:** Dorothy `main` (Version per `REPO_REF` wählbar, z. B. `v1.2.9`)
- **Stack:** Node.js 22 / Next.js 16 / React 19 (laut `.nvmrc` + `package.json`)
- **Web UI:** Port `3000`, Bind `0.0.0.0`
- **Lokal:** läuft vollständig lokal; Telegram-/Slack-/SocialData-Keys sind optional (Settings)
- **Reboot-sicher:** `dorothy.service` (`Restart=always`, `After=network-online.target`) + `onboot: 1`

> Hinweis: Dorothy ist primär eine **Electron-Desktop-App**. Im LXC läuft die
> **Web UI** (`npm run build` + `next start`): Kanban, Automations, Scheduled Tasks,
> Vault, Settings, Skills/Usage-Ansichten. Echte PTY-Terminals/Agent-Ausführung
> brauchen die Desktop-App oder zusätzlich installierte CLIs (`claude`, `gh`) im Container.

---

## 🚀 Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DorothyProxmox/main/install/dorothy.sh)"
```

Mit angepassten Ressourcen / Debug:

```bash
CTID=150 MEMORY_MB=8192 CORES=4 DISK_SIZE_GB=20 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DorothyProxmox/main/install/dorothy.sh)"
DEBUG=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DorothyProxmox/main/install/dorothy.sh)"
```

| Variable | Standard | Beschreibung |
|---|---|---|
| `CTID` | nächste freie ID | Container-ID |
| `CT_HOSTNAME` | `dorothy` | Hostname |
| `CT_PASSWORD` | *(leer)* | Root-Passwort (sonst `pct enter`) |
| `STORAGE` | `local-lvm` | Container-Disk-Storage |
| `TEMPLATE_STORAGE` | `local` | Template-Storage |
| `BRIDGE` | `vmbr0` | Netzwerk-Bridge |
| `DISK_SIZE_GB` | `12` | Root-Disk (Next-Build braucht Platz) |
| `MEMORY_MB` | `4096` | RAM (Build braucht ≥ 3 GB) |
| `CORES` | `2` | vCPU |
| `REPO_URL` | `https://github.com/Charlie85270/Dorothy.git` | App-Quelle |
| `REPO_REF` | `main` | Branch/Tag |
| `INSTALL_DIR` | `/opt/dorothy` | Installationspfad im Container |
| `PORT` | `3000` | Web-UI-Port |
| `BIND_HOST` | `0.0.0.0` | Bind-Adresse |
| `DEBUG` | `0` | `1` = `bash -x` + ausführliche Logs |

Direkt im LXC (ohne Proxmox-Host) geht auch:

```bash
CONTAINER_MODE=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DorothyProxmox/main/install/dorothy.sh)"
```

---

## ✅ Erwartete Ausgabe (Erfolg)

```
▶ [6/6] Verifikation (Service + HTTP)…
HTTP-Check OK (Versuch 4): 200

========================================================
      ✅ DOROTHY INSTALLIERT & VERIFIZIERT
========================================================
Service : systemctl status dorothy (enabled, Restart=always)
Web UI  :
  http://192.168.1.50:3000/
Logs    : journalctl -u dorothy -f
...
```

Host-Modus endet zusätzlich mit:

```
========================================================
      ✅ FERTIG! Dorothy läuft im LXC (ID 100).
========================================================
  Web UI : http://192.168.1.50:3000
```

Verifikation im Script: `systemctl is-active dorothy` + HTTP-Check auf
`localhost:3000` (30 × 5 s). Bei Fehlern: **volle Kette** (Exit-Code, Zeile,
Befehl, Stacktrace, 40 Log-Zeilen, 60 Journal-Zeilen) + `DEBUG=1`-Hinweis.

## 🔄 Update (idempotent – im Container)

```bash
pct enter <CTID>
REPO_REF=main bash /root/dorothy-install.sh
# oder: cd /opt/dorothy && git pull && npm install && npm run build && systemctl restart dorothy
```

## 🗑️ Deinstallieren

```bash
# Nur die App (im Container):
systemctl disable --now dorothy && rm -rf /opt/dorothy /etc/systemd/system/dorothy.service

# Ganzen Container (auf dem Proxmox-Host):
pct stop <CTID> && pct destroy <CTID>
```

## 🧪 Test: Reboot → Web UI wieder da

```bash
pct reboot <CTID> && sleep 20
pct exec <CTID> -- systemctl is-active dorothy     # muss: active
pct exec <CTID> -- curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/
# erwartet: active + 200/307/308
```

## 📁 Dateien

```
install/dorothy.sh   # Proxmox-Install-Script (Host- + Container-Modus, Variablen oben)
dorothy.service      # Referenz der systemd-Unit (wird vom Script nach /etc/systemd/system/ geschrieben)
README.md            # diese Datei
```

`set -euo pipefail`, `bash -n`-geprüft. Lizenz der App: MIT (Upstream).
