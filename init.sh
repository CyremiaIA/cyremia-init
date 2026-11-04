#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# Cyremia — mise en service d'une machine Ubuntu fraîchement installée.
#
#   curl -fsSL <URL>/init.sh | sudo bash
#   (ou)  sudo bash init.sh [nom-de-la-machine]
#
# Variables facultatives : NOM=cyr-pc-xxx-01  TS_AUTHKEY=tskey-auth-…
# Idempotent : on peut le relancer autant de fois que nécessaire.
# Ce fichier ne contient AUCUN secret (clés SSH publiques seulement).
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

LOG=/var/log/cyremia-init.log
ALLOY_VERSION="1.5.1"
LOKI_URL="http://100.124.28.18:3100/loki/api/v1/push"
BESZEL_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPcMATwAAGRU5N2mwjV9cSvcelp2SXU8uIjKCKb8S5k1"
UTILISATEUR="${SUDO_USER:-cyremia}"
[ "$UTILISATEUR" = root ] && UTILISATEUR=cyremia

V='\033[1;32m'; R='\033[1;31m'; J='\033[1;33m'; B='\033[1;36m'; N='\033[0m'
msg()  { printf "${B}[cyremia %s]${N} %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
ok()   { printf "${V}   ✔ %s${N}\n" "$*" | tee -a "$LOG"; }
warn() { printf "${J}   ⚠ %s${N}\n" "$*" | tee -a "$LOG"; ERREURS=$((ERREURS+1)); }
ERREURS=0
ETAPES=11; ETAPE=0
# Barre d'avancement globale : [■■■■■□□□□□]  50 %  étape 5/10
barre() { local p=$1 plein=$(( $1 / 5 )) b=""; for i in $(seq 1 20); do [ "$i" -le "$plein" ] && b="$b■" || b="$b·"; done
  printf "\n${V}[%s] %3d %%${N}" "$b" "$p"; }
etape() { ETAPE=$((ETAPE+1)); barre $(( (ETAPE-1) * 100 / ETAPES )); printf "  étape %d/%d\n" "$ETAPE" "$ETAPES"; msg "$*"; }
# Lance une commande longue avec un indicateur animé et le temps écoulé
travail() { local lib="$1"; shift; "$@" >>"$LOG" 2>&1 & local pid=$! t0=$SECONDS i=0 s='|/-\'
  while kill -0 $pid 2>/dev/null; do printf "\r   %s %s… %ds " "${s:i++%4:1}" "$lib" $((SECONDS-t0)); sleep 0.2; done
  wait $pid; local rc=$?; printf "\r\033[K"; return $rc; }
# Les questions lisent le clavier, pas le script (qui arrive par le tube de curl)
demander() { local r=""; if [ -r /dev/tty ]; then read -r -p "$1" r </dev/tty || true; fi; printf '%s' "$r"; }

if [ "$(id -u)" -ne 0 ]; then echo "À lancer avec sudo :  curl -fsSL … | sudo bash" >&2; exit 1; fi

clear 2>/dev/null || true
cat <<'LOGO'

   ____  __   __  ____    _____   __  __   ___      _
  / ___| \ \ / / |  _ \  | ____| |  \/  | |_ _|    / \
 | |      \ V /  | |_) | |  _|   | |\/| |  | |    / _ \
 | |___    | |   |  _ <  | |___  | |  | |  | |   / ___ \
  \____|   |_|   |_| \_\ |_____| |_|  |_| |___| /_/   \_\

  ---------------------------------------------------------
            Cyremia  -  Ubuntu Server 26.04 LTS
  ---------------------------------------------------------
LOGO
echo
msg "Journal complet : $LOG"

# ── 0. Réseau ────────────────────────────────────────────────────────────
etape "Vérification de l'accès à Internet"
for i in $(seq 1 30); do curl -fsS -o /dev/null --max-time 5 https://pkgs.tailscale.com && break; sleep 2; done \
  && ok "Internet joignable" || { printf "${R}Pas d'Internet : impossible de continuer.${N}\n"; exit 1; }

# ── 1. Nom de la machine ─────────────────────────────────────────────────
NOM="${NOM:-${1:-}}"
if [ -z "$NOM" ]; then
  echo "   Convention : cyr-<pc|srv|rpi>-<rôle>-<NN>   (ex. cyr-pc-atelier-01)"
  NOM="$(demander "   Nom de la machine [$(hostname)] : ")"
  NOM="${NOM:-$(hostname)}"
fi
if ! printf '%s' "$NOM" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'; then
  printf "${R}Nom invalide : %s${N}\n" "$NOM"; exit 1; fi
etape "Nom de la machine : $NOM"
hostnamectl set-hostname "$NOM"
sed -i "/^127\.0\.1\.1/d" /etc/hosts; echo "127.0.1.1 $NOM" >> /etc/hosts
ok "hostname = $NOM"

# ── 2. Paquets de base ───────────────────────────────────────────────────
etape "Mise à jour de la liste des paquets et installation des outils"
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -q -o DPkg::Lock::Timeout=600"
# Réessaie une commande jusqu'à 3 fois en réparant ce qui peut l'être entre deux essais
essayer() { local lib="$1"; shift; local n
  for n in 1 2 3; do
    travail "$lib" "$@" && return 0
    printf "${J}   ↻ %s : échec (essai %d/3), réparation puis nouvel essai${N}\n" "$lib" "$n" | tee -a "$LOG"
    dpkg --configure -a >>"$LOG" 2>&1; $APT -f install -y >>"$LOG" 2>&1; sleep $((n*5))
  done; return 1; }
essayer "Liste des paquets" $APT update || warn "apt-get update a signalé une erreur"
essayer "Installation des outils" $APT install -y curl ca-certificates ufw smartmontools htop jq unattended-upgrades openssh-server \
  && ok "curl, ufw, smartmontools, htop, jq, openssh-server" || warn "installation des paquets incomplète"

# ── 3. Accès SSH par clé ─────────────────────────────────────────────────
etape "Clés SSH Cyremia pour l'utilisateur $UTILISATEUR"
id "$UTILISATEUR" >/dev/null 2>&1 || { useradd -m -s /bin/bash -G sudo "$UTILISATEUR"; ok "utilisateur $UTILISATEUR créé"; }
HOME_U="$(getent passwd "$UTILISATEUR" | cut -d: -f6)"
install -d -m 700 -o "$UTILISATEUR" -g "$UTILISATEUR" "$HOME_U/.ssh"
AK="$HOME_U/.ssh/authorized_keys"; touch "$AK"
while IFS= read -r cle; do
  [ -n "$cle" ] && ! grep -qF "$(echo "$cle" | awk '{print $2}')" "$AK" && echo "$cle" >> "$AK"
done <<'CLES'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEEC1StlJNv4nl7V8qqjt5fm13WflMlCAdkLcv9HZzOu
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHg+BXX+by/rkKBZCfa7S0rm6hcYKJYIqyLDZaC0KGif
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDIGImp/CJ25K6DVx7szyd+H1dWQRtnIvBqGjbOPNQ0zYl5JD/Su2AAywEscrDnjgbkAv/vB064Q3PQYwy5u+h1mLoazkG9R1Hc23VAbJ/PSsnG5zlgIQ/ynSTx5uQe1ny93t1J2xIQKggaulzeSCyX/HCH1N/I89ghp/312vBtXMl0uKAyzqw/RixEl/Ik6OMqPEj2k4bcOg7QhvFXfenf0UotDuVFiMqcePaHCNRohavSooa3ITek5XeNzd6BCpsp6TsV5z3t5EOQPy4aPjLnEr2m8xuiwkWiNm7WVAKz9oGQoka/oCbKzWAZ8gOG4WLFyILxl9pZkSyOqXt1wh1OHqha8GaR8jdNh88f1d/XnBI7crLlSj8cTbspLdVr0S8e8eYbgD209bsmyE5RmUruFtwwdP9G4XgNDM8S/Yo8gyQyGd4cGZbnKEe6OHeNora8PDJI8+X1LSocH8tNTCAvXr4Po4xYMEwhLZB2wMIe9boEhDjV5wYsjtzkIRpW0WilkCx81PEh3gGZPNTPxbDZH/0MVlnlbwWP0zgzDmdGsUXhcnMnUFW/cC4nuTR8Tvx8N76Oqq/yhUbsTdIKq+IXS69eytXbthWd4jRwidIy2FLLWbEgJVYQnt2MmeqdtlMy7J98RLFo0Y+ntZHKZ50jGJufDIxVpX7e8vNiBl/8OQ==
CLES
chown "$UTILISATEUR:$UTILISATEUR" "$AK"; chmod 600 "$AK"
ok "$(grep -c '^ssh-' "$AK") clé(s) dans $AK"
echo "$UTILISATEUR ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-cyremia; chmod 440 /etc/sudoers.d/90-cyremia
visudo -cq && ok "sudo sans mot de passe pour $UTILISATEUR" || { rm -f /etc/sudoers.d/90-cyremia; warn "sudoers refusé"; }
# Mot de passe SSH coupé seulement une fois les clés en place
if [ "$(grep -c '^ssh-' "$AK")" -ge 1 ]; then
  cat > /etc/ssh/sshd_config.d/10-cyremia.conf <<'EOF'
# Cyremia : connexion SSH par clé uniquement
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  sshd -t && { systemctl enable --now ssh >/dev/null 2>&1; systemctl reload ssh 2>/dev/null || systemctl restart ssh; ok "SSH : clé uniquement, root interdit"; } \
    || { rm -f /etc/ssh/sshd_config.d/10-cyremia.conf; warn "config sshd invalide, retirée"; }
fi

# ── 4. Mises à jour automatiques sans redémarrage ───────────────────────
etape "Mises à jour de sécurité automatiques (jamais de redémarrage seul)"
cat > /etc/apt/apt.conf.d/99cyremia-serveur <<'EOF'
// Cyremia : la machine se corrige seule mais ne redémarre JAMAIS d'elle-même.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
EOF
ok "/etc/apt/apt.conf.d/99cyremia-serveur"

# ── 5. Tailscale ─────────────────────────────────────────────────────────
etape "Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  essayer "Installation de Tailscale" sh -c "curl -fsSL https://tailscale.com/install.sh | sh" && ok "Tailscale installé" || warn "installation de Tailscale échouée"
fi
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status >/dev/null 2>&1; then
    tailscale set --hostname="$NOM" >/dev/null 2>&1; ok "déjà connecté au tailnet"
  else
    TS_AUTHKEY="${TS_AUTHKEY:-$(demander "   Clé d'authentification Tailscale (Entrée = lien de connexion) : ")}"
    if [ -n "$TS_AUTHKEY" ]; then
      tailscale up --hostname="$NOM" --auth-key="$TS_AUTHKEY" && ok "connecté au tailnet" || warn "tailscale up a échoué"
    else
      echo "   ➜ Ouvre le lien ci-dessous sur un autre appareil pour autoriser la machine :"
      tailscale up --hostname="$NOM" && ok "connecté au tailnet" || warn "tailscale up a échoué"
    fi
  fi
  TSIP="$(tailscale ip -4 2>/dev/null | head -1)"
fi

# ── 6. Agent Beszel (métriques) ──────────────────────────────────────────
etape "Agent Beszel (métriques, port 45876 sur Tailscale uniquement)"
case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; *) ARCH="" ;; esac
if [ -n "$ARCH" ]; then
  if [ ! -x /opt/beszel-agent/beszel-agent ]; then
    id beszel >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin beszel
    install -d -o beszel -g beszel /opt/beszel-agent
    essayer "Téléchargement de Beszel" sh -c "curl -fsSL https://github.com/henrygd/beszel/releases/latest/download/beszel-agent_linux_${ARCH}.tar.gz | tar -xz -C /opt/beszel-agent beszel-agent" && chown beszel:beszel /opt/beszel-agent/beszel-agent \
      && ok "binaire Beszel installé" || warn "téléchargement de Beszel échoué"
  fi
  usermod -aG disk beszel 2>/dev/null || true
  cat > /etc/systemd/system/beszel-agent.service <<EOF
[Unit]
Description=Beszel Agent Service
Wants=network-online.target
After=network-online.target

[Service]
Environment="PORT=45876"
Environment="KEY=$BESZEL_KEY"
ExecStart=/opt/beszel-agent/beszel-agent
User=beszel
Restart=on-failure
RestartSec=5
StateDirectory=beszel-agent
KeyringMode=private
LockPersonality=yes
ProtectClock=yes
ProtectHome=read-only
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectSystem=strict
RemoveIPC=yes
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable --now beszel-agent >/dev/null 2>&1; systemctl restart beszel-agent
  sleep 2; systemctl is-active -q beszel-agent && ok "beszel-agent actif" || warn "beszel-agent ne démarre pas"
fi

# ── 7. Agent Alloy (journaux → Loki) ─────────────────────────────────────
etape "Agent Alloy (journaux système vers Loki)"
if [ -n "$ARCH" ]; then
  if ! command -v alloy >/dev/null 2>&1 || ! alloy --version 2>/dev/null | grep -q "$ALLOY_VERSION"; then
    DEB="/tmp/alloy-${ALLOY_VERSION}.deb"
    essayer "Téléchargement d'Alloy" curl -fsSL -o "$DEB" "https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSION}/alloy-${ALLOY_VERSION}-1.${ARCH}.deb" \
      && essayer "Installation d'Alloy" $APT install -y "$DEB" && ok "Alloy $ALLOY_VERSION installé" || warn "installation d'Alloy échouée"
    rm -f "$DEB"
  fi
  if [ -d /etc/alloy ]; then
    cat > /etc/alloy/config.alloy <<'ALLOYCFG'
// ─────────────────────────────────────────────────────────────
// Alloy — variante SYSTEMD (paquet .deb, sans Docker)
//
// Pour les machines qui n'hébergent aucun conteneur et ne sont pas worker
// Coolify : aujourd'hui `cyr-pc-display-01` (borne d'affichage).
// Ne collecte que journald — c'est là que vivent les logs utiles de ces
// machines (boot, GDM/autologin, course au snap Firefox du kiosque, réseau).
//
// Variables lues dans /etc/default/alloy : HOSTNAME_LABEL, LOKI_URL.
// Installation : ./install.sh <nom-du-noeud>  (cf. README)
// ─────────────────────────────────────────────────────────────

loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "level"
  }
}

loki.source.journal "system" {
  path          = "/var/log/journal"
  max_age       = "12h"
  labels        = { job = "systemd-journal", host = sys.env("HOSTNAME_LABEL"), env = "infra", project = "infra" }
  relabel_rules = loki.relabel.journal.rules
  forward_to    = [loki.process.clean_journal.receiver]
}

// Mêmes règles de nettoyage que les agents Docker (cf. agent/config.alloy),
// plus le bruit propre à une machine de bureau avec session graphique.
loki.process "clean_journal" {
  forward_to = [loki.write.default.receiver]

  stage.match {
    selector = "{unit=\"tailscaled.service\"}"
    stage.drop {
      expression          = "(TSMP disco|discoKey|controlclient direct:|magicsock:|netcheck:|derp-)"
      drop_counter_reason = "tailscale_chatter"
    }
  }

  stage.match {
    selector = "{unit=~\"init.scope|user@.*|systemd-logind.service\"}"
    stage.drop {
      expression          = "(Deactivated successfully|Removed slice|Created slice|user-runtime-dir|Queued start job|ninjarmm-patcher|anacron|motd-news|apt-daily|apt-news|fwupd-refresh|man-db|logrotate|dpkg-db-backup|e2scrub|update-notifier)"
      drop_counter_reason = "systemd_churn"
    }
  }

  stage.match {
    selector = "{unit=\"cron.service\"}"
    stage.drop {
      expression          = "pam_unix\\(cron:session\\)"
      drop_counter_reason = "cron_pam"
    }
  }

  // 4. Coolify interroge chaque worker en SSH toutes les ~40 s (sudo docker ps /
  //    inspect). Sur un worker prod ça fait ~70 k lignes/jour de pure comptabilité.
  //    On garde TOUT ce qui a une valeur d'audit : `Accepted publickey`,
  //    `Invalid user`, `Failed password`, les tentatives [preauth]. On ne jette que
  //    le cycle de vie des sessions, déjà tracé par ces lignes-là.
  stage.match {
    selector = "{unit=~\"ssh.service|session-.*scope\"}"
    stage.drop {
      expression          = "(pam_unix\\(sshd:session\\)|Disconnected from user (root|ubuntu|cyremia) |Received disconnect from .*: disconnected by user)"
      drop_counter_reason = "ssh_session_bookkeeping"
    }
  }
  stage.match {
    selector = "{unit=\"systemd-logind.service\"}"
    stage.drop {
      expression          = "(New session |Removed session |Session .* logged out)"
      drop_counter_reason = "logind_session_churn"
    }
  }
  stage.match {
    selector = "{unit=~\"session-.*scope\"}"
    stage.drop {
      expression          = "(pam_unix\\(sudo:session\\)|COMMAND=/usr/bin/docker (container )?(ls|ps|inspect|stats|version|info))"
      drop_counter_reason = "coolify_ssh_poll"
    }
  }

  // Bureau graphique : bruit permanent de GNOME/GDM/dbus/snapd sur une borne
  // qui tourne 24/7. On garde tout ce qui touche au kiosque et à Firefox.
  stage.match {
    selector = "{unit=~\"gdm.service|dbus.service|snapd.service|packagekit.service|colord.service|udisks2.service|upower.service|gnome-remote-desktop.service\"}"
    stage.drop {
      expression          = "(?i)(refresh|autorefresh|Connection .* closed|activating service|successfully activated|GetAll|profile added|device added|battery|line-power|udisks|seat0 already)"
      drop_counter_reason = "desktop_noise"
    }
  }
}

loki.write "default" {
  endpoint {
    url = sys.env("LOKI_URL")
  }
}
ALLOYCFG
    cat > /etc/default/alloy <<EOF
## Généré par le script d'initialisation Cyremia.
CONFIG_FILE="/etc/alloy/config.alloy"
CUSTOM_ARGS="--storage.path=/var/lib/alloy/data --server.http.listen-addr=127.0.0.1:12345"
RESTART_ON_UPGRADE=true
HOSTNAME_LABEL="$NOM"
LOKI_URL="$LOKI_URL"
EOF
    usermod -aG systemd-journal alloy 2>/dev/null || true
    if [ ! -d /var/log/journal ]; then mkdir -p /var/log/journal; systemd-tmpfiles --create --prefix /var/log/journal; systemctl restart systemd-journald; fi
    systemctl enable --now alloy >/dev/null 2>&1; systemctl restart alloy
    sleep 3; systemctl is-active -q alloy && ok "alloy actif (host=$NOM)" || warn "alloy ne démarre pas"
  fi
fi

# ── 8. Pare-feu ──────────────────────────────────────────────────────────
etape "Pare-feu ufw : tout fermé sauf SSH (22) et Tailscale"
ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null
ufw allow 22/tcp comment 'SSH' >/dev/null
ip link show tailscale0 >/dev/null 2>&1 && ufw allow in on tailscale0 comment 'Tailscale' >/dev/null
ufw --force enable >/dev/null && ok "ufw actif" || warn "ufw n'a pas pu être activé"

# ── 9. Disques ───────────────────────────────────────────────────────────
etape "État SMART des disques"
for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
  s="$(smartctl -H /dev/$d 2>/dev/null | grep -Eo 'PASSED|FAILED|OK' | head -1)"
  [ -n "$s" ] && echo "   /dev/$d : $s" | tee -a "$LOG"
done

# ── 11. Contrôle final : chaque brique est testée, réparée si possible ─
etape "Contrôle final"
controle() { local lib="$1" test="$2" repare="${3:-}"
  if eval "$test" >/dev/null 2>&1; then ok "$lib"; return; fi
  if [ -n "$repare" ]; then
    printf "${J}   ↻ %s : KO, tentative de réparation${N}\n" "$lib" | tee -a "$LOG"
    eval "$repare" >>"$LOG" 2>&1; sleep 4
    if eval "$test" >/dev/null 2>&1; then ok "$lib (réparé)"; return; fi
  fi
  warn "$lib : TOUJOURS EN ÉCHEC"; }
controle "nom de la machine = $NOM"     '[ "$(hostname)" = "$NOM" ]'                       'hostnamectl set-hostname "$NOM"'
controle "clés SSH en place"            'grep -q "^ssh-" "$AK"'
controle "serveur SSH actif"            'systemctl is-active ssh'                            'systemctl restart ssh'
controle "SSH par clé uniquement"       'sshd -T 2>/dev/null | grep -qx "passwordauthentication no"' 'systemctl reload ssh'
controle "sudo sans mot de passe"       'sudo -u "$UTILISATEUR" sudo -n true'
controle "Tailscale connecté"           'tailscale status'                                   'systemctl restart tailscaled; sleep 3; tailscale up --hostname="$NOM" --timeout=20s'
controle "Loki joignable via Tailscale" 'curl -fsS --max-time 5 http://100.124.28.18:3100/ready'
controle "agent Beszel actif"           'systemctl is-active beszel-agent'                   'systemctl restart beszel-agent'
controle "Beszel écoute sur 45876"      'ss -ltn | grep -q ":45876 "'                        'systemctl restart beszel-agent'
controle "agent Alloy actif"            'systemctl is-active alloy'                          'systemctl restart alloy'
controle "Alloy envoie à Loki sans erreur" '! journalctl -u alloy --since "-2 min" --no-pager | grep -qiE "error.*(loki|push|send)"' 'systemctl restart alloy'
controle "pare-feu ufw actif"           'ufw status | grep -q "Status: active"'              'ufw --force enable'
controle "règle ufw Tailscale"          'ufw status | grep -q tailscale0'                    'ip link show tailscale0 && ufw allow in on tailscale0 comment Tailscale'
controle "mises à jour sans redémarrage" 'grep -q "Automatic-Reboot \"false\"" /etc/apt/apt.conf.d/99cyremia-serveur'

# ── Bilan ────────────────────────────────────────────────────────────────
barre 100; echo
msg "TERMINÉ — $NOM"
echo "   IP locale     : $(hostname -I | awk '{print $1}')"
echo "   IP Tailscale  : ${TSIP:-non connecté}"
echo "   Connexion     : ssh $UTILISATEUR@${TSIP:-$(hostname -I | awk '{print $1}')}"
echo "   Reste à faire : ajouter la machine dans Beszel et installer l'agent Ninja (console)."
if [ "$ERREURS" -gt 0 ]; then printf "${R}   %s avertissement(s) : voir %s${N}\n" "$ERREURS" "$LOG"; exit 2; fi
printf "${V}   Aucune erreur.${N}\n"
