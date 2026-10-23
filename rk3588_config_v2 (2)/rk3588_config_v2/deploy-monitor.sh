#!/usr/bin/env bash
# Déploiement complet du monitoring client :
#   1. écrit ~/monitor-client.sh
#   2. crée le service systemd monitor-client.service
#   3. active, (re)démarre et affiche le statut
#
# Usage : bash deploy-monitor.sh      (sudo sera demandé si nécessaire)
set -euo pipefail

SERVICE_NAME="monitor-client"

# ---------- Utilisateur cible (celui qui lance le script, même via sudo) ----------
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
SCRIPT_PATH="$TARGET_HOME/monitor-client.sh"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    echo "Erreur : dossier personnel introuvable pour $TARGET_USER" >&2
    exit 1
fi

# sudo uniquement si on n'est pas déjà root
if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

command -v python3 >/dev/null || { echo "Erreur : python3 n'est pas installé." >&2; exit 1; }

echo "==> Utilisateur : $TARGET_USER ($TARGET_HOME)"

# ======================= 1. Script de monitoring =======================
echo "==> Écriture de $SCRIPT_PATH"
TMP_SCRIPT="$(mktemp)"
cat > "$TMP_SCRIPT" <<'MONITOR_EOF'
#!/usr/bin/env bash
exec python3 - <<'PY'
import csv
import fcntl
import io
import os
import signal
import socket
import time
from collections import deque
from datetime import datetime
from pathlib import Path

# ================= PARAMÈTRES MODIFIABLES =================
INTERVALLE_SECONDE = 1
FIFO_MESURES = 300
RAPPORTS_SECONDE_CONSERVES = 5

INTERVALLE_MINUTE = 60
DUREE_RAPPORT_MINUTE = 24 * 3600
RAPPORTS_MINUTE_CONSERVES = 2

DOSSIER = Path.home() / "device-client-logs"
# =========================================================

parametres = (
    INTERVALLE_SECONDE, FIFO_MESURES,
    RAPPORTS_SECONDE_CONSERVES, INTERVALLE_MINUTE,
    DUREE_RAPPORT_MINUTE, RAPPORTS_MINUTE_CONSERVES
)
if any(valeur <= 0 for valeur in parametres):
    raise SystemExit("Les paramètres doivent être positifs.")

os.umask(0o077)

SECONDE = DOSSIER / "seconde"
MINUTE = DOSSIER / "minute"
for dossier in (DOSSIER, SECONDE, MINUTE):
    dossier.mkdir(parents=True, exist_ok=True)

verrou = (DOSSIER / "monitor.lock").open("a")
try:
    fcntl.flock(verrou, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit("Le monitoring est déjà actif.")

def arreter(signum, frame):
    raise SystemExit(0)

signal.signal(signal.SIGTERM, arreter)
signal.signal(signal.SIGINT, arreter)

MACHINE = socket.gethostname()
BOOT_ID = Path("/proc/sys/kernel/random/boot_id").read_text().strip()

TITRES = [
    "Date et heure avec fuseau",
    "Nom de la machine",
    "Identifiant du démarrage",
    "Durée depuis le démarrage",
    "Durée depuis le démarrage (secondes)",
    "Utilisation du processeur (%)",
    "Mémoire RAM utilisée (Go)",
    "Mémoire RAM totale (Go)",
    "Mémoire RAM disponible (Go)",
    "Utilisation de la mémoire RAM (%)",
    "Température maximale des capteurs (°C)",
    "Espace disque utilisé (Go)",
    "Capacité du disque (Go)",
    "Occupation du disque (%)",
    "Charge moyenne sur 1 minute",
    "Charge moyenne sur 5 minutes",
    "Charge moyenne sur 15 minutes",
]

CSV_SECONDE = SECONDE / f"fifo-demarrage-{BOOT_ID}.csv"
TXT_SECONDE = CSV_SECONDE.with_suffix(".txt")

def nombre(valeur):
    return f"{valeur:.2f}".replace(".", ",")

def compteurs_cpu():
    valeurs = list(map(
        int,
        Path("/proc/stat").read_text().splitlines()[0].split()[1:9]
    ))
    return sum(valeurs), valeurs[3] + valeurs[4]

def mesurer(cpu):
    memoire = {}
    for ligne in Path("/proc/meminfo").read_text().splitlines():
        cle, valeur = ligne.split(":", 1)
        memoire[cle] = int(valeur.split()[0]) * 1024

    total = memoire["MemTotal"]
    disponible = memoire["MemAvailable"]
    utilisee = total - disponible

    temperatures = []
    for fichier in Path("/sys/class/thermal").glob("thermal_zone*/temp"):
        try:
            temperatures.append(int(fichier.read_text()) / 1000)
        except (OSError, ValueError):
            pass

    disque = os.statvfs("/")
    capacite = disque.f_blocks * disque.f_frsize
    occupation = (disque.f_blocks - disque.f_bfree) * disque.f_frsize

    uptime = int(float(Path("/proc/uptime").read_text().split()[0]))
    jours, reste = divmod(uptime, 86400)
    heures, reste = divmod(reste, 3600)
    minutes, secondes = divmod(reste, 60)

    duree = (
        f"{jours} j {heures:02d} h "
        f"{minutes:02d} min {secondes:02d} s"
    )

    return [
        datetime.now().astimezone().isoformat(timespec="seconds"),
        MACHINE,
        BOOT_ID,
        duree,
        str(uptime),
        nombre(cpu),
        nombre(utilisee / 1e9),
        nombre(total / 1e9),
        nombre(disponible / 1e9),
        nombre(100 * utilisee / total),
        nombre(max(temperatures)) if temperatures else "Indisponible",
        nombre(occupation / 1e9),
        nombre(capacite / 1e9),
        nombre(100 * occupation / capacite) if capacite else "Indisponible",
        *[nombre(valeur) for valeur in os.getloadavg()],
    ]

def contenu_csv(lignes, entete=True):
    tampon = io.StringIO()
    writer = csv.writer(tampon, delimiter=";")
    if entete:
        writer.writerow(TITRES)
    writer.writerows(lignes)
    return tampon.getvalue()

def bloc_texte(ligne):
    return (
        "=" * 75 + "\n"
        + "\n".join(
            f"{titre:<43} : {valeur}"
            for titre, valeur in zip(TITRES, ligne)
        )
        + "\n"
    )

def remplacer(fichier, contenu, encodage):
    temporaire = fichier.with_suffix(fichier.suffix + ".tmp")
    with temporaire.open("w", encoding=encodage, newline="") as sortie:
        sortie.write(contenu)
    os.replace(temporaire, fichier)

def supprimer_rapport(fichier_csv):
    fichier_csv.unlink(missing_ok=True)
    fichier_csv.with_suffix(".txt").unlink(missing_ok=True)

def nettoyer_seconde():
    # Le rapport actuel est toujours conservé.
    # Pour les autres, classement par dernière écriture.
    anciens = sorted(
        (
            fichier
            for fichier in SECONDE.glob("fifo-demarrage-*.csv")
            if fichier != CSV_SECONDE
        ),
        key=lambda fichier: fichier.stat().st_mtime,
        reverse=True,
    )
    for fichier in anciens[RAPPORTS_SECONDE_CONSERVES - 1:]:
        supprimer_rapport(fichier)

def rapports_minute():
    rapports = []
    for fichier in MINUTE.glob("rapport-24h-*.csv"):
        suffixe = fichier.stem.removeprefix("rapport-24h-")
        if suffixe.isdigit():
            rapports.append((int(suffixe), fichier))
    return sorted(rapports)

def nettoyer_minute():
    for _, fichier in rapports_minute()[:-RAPPORTS_MINUTE_CONSERVES]:
        supprimer_rapport(fichier)

# Reprendre le FIFO si le service redémarre pendant le même boot.
fifo = deque(maxlen=FIFO_MESURES)
if CSV_SECONDE.exists():
    with CSV_SECONDE.open(encoding="utf-8-sig", newline="") as fichier:
        reader = csv.reader(fichier, delimiter=";")
        if next(reader, None) == TITRES:
            for ligne in reader:
                if len(ligne) == len(TITRES):
                    fifo.append(ligne)

existants = rapports_minute()
debut_rapport = existants[-1][0] if existants else None

def enregistrer_minute(ligne):
    global debut_rapport
    maintenant = time.time()

    if (
        debut_rapport is None
        or maintenant < debut_rapport
        or maintenant >= debut_rapport + DUREE_RAPPORT_MINUTE
    ):
        debut_rapport = int(maintenant)

    fichier_csv = MINUTE / f"rapport-24h-{debut_rapport}.csv"
    fichier_txt = fichier_csv.with_suffix(".txt")
    nouveau = not fichier_csv.exists() or fichier_csv.stat().st_size == 0

    with fichier_csv.open("a", encoding="utf-8", newline="") as fichier:
        if nouveau:
            fichier.write("\ufeff")
        fichier.write(contenu_csv([ligne], entete=nouveau))
        fichier.flush()
        os.fsync(fichier.fileno())

    with fichier_txt.open("a", encoding="utf-8") as fichier:
        fichier.write(bloc_texte(ligne))
        fichier.flush()
        os.fsync(fichier.fileno())

    nettoyer_minute()

nettoyer_minute()
dernier_jour_nettoyage = None

print(f"Machine : {MACHINE}", flush=True)
print(f"Identifiant du démarrage : {BOOT_ID}", flush=True)
print(f"FIFO : {CSV_SECONDE}", flush=True)
print(f"Historique à la minute : {MINUTE}", flush=True)

ancien_total, ancien_repos = compteurs_cpu()
prochaine_mesure = time.monotonic() + INTERVALLE_SECONDE
prochaine_minute = prochaine_mesure

while True:
    time.sleep(max(0, prochaine_mesure - time.monotonic()))

    total, repos = compteurs_cpu()
    ecart = total - ancien_total
    cpu = (
        100 * (ecart - (repos - ancien_repos)) / ecart
        if ecart > 0 else 0
    )
    ancien_total, ancien_repos = total, repos

    ligne = mesurer(max(0, min(100, cpu)))
    fifo.append(ligne)

    remplacer(CSV_SECONDE, contenu_csv(fifo), "utf-8-sig")
    remplacer(
        TXT_SECONDE,
        "".join(bloc_texte(mesure) for mesure in fifo),
        "utf-8"
    )

    # Nettoyage après la première mesure, puis chaque jour.
    jour = datetime.now().astimezone().date()
    if jour != dernier_jour_nettoyage:
        nettoyer_seconde()
        nettoyer_minute()
        dernier_jour_nettoyage = jour

    maintenant = time.monotonic()
    if maintenant >= prochaine_minute:
        enregistrer_minute(ligne)
        prochaine_minute += (
            int((maintenant - prochaine_minute) // INTERVALLE_MINUTE) + 1
        ) * INTERVALLE_MINUTE

    prochaine_mesure += INTERVALLE_SECONDE
    if prochaine_mesure <= time.monotonic():
        prochaine_mesure = time.monotonic() + INTERVALLE_SECONDE
PY
MONITOR_EOF

$SUDO install -m 0755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$TMP_SCRIPT" "$SCRIPT_PATH"
rm -f "$TMP_SCRIPT"

# ======================= 2. Service systemd =======================
echo "==> Écriture de $SERVICE_PATH"
$SUDO tee "$SERVICE_PATH" > /dev/null <<SERVICE_EOF
[Unit]
Description=Surveillance CPU RAM temperature uptime
After=local-fs.target
RequiresMountsFor=$TARGET_HOME

[Service]
Type=simple
User=$TARGET_USER
Environment=HOME=$TARGET_HOME
Environment=PYTHONUNBUFFERED=1
WorkingDirectory=$TARGET_HOME
ExecStart=/bin/bash $SCRIPT_PATH
Restart=on-failure
RestartSec=5
KillMode=control-group
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# ======================= 3. Activation et démarrage =======================
echo "==> Activation et (re)démarrage du service"
$SUDO systemctl daemon-reload
$SUDO systemctl enable "${SERVICE_NAME}.service"
# restart : prend en compte les modifications si le service tournait déjà
$SUDO systemctl restart "${SERVICE_NAME}.service"

sleep 2
$SUDO systemctl status "${SERVICE_NAME}.service" --no-pager || true

echo
echo "==> Déploiement terminé."
echo "    Logs     : $TARGET_HOME/device-client-logs/"
echo "    Journal  : journalctl -u ${SERVICE_NAME} -f"
