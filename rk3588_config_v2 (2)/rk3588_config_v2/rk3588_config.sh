#!/bin/bash

# =============================================================================
# Script d'Automatisation de Configuration RK3588
# Version: 1.5
# Description: Automatise la configuration des cartes RK3588 avec extension de partition
# Note: Version adaptée pour RK3588 (non-S) - services MAC fix / sources Focal
#       retirés car non nécessaires. lightdm et XFCE sont conservés (boot graphique).
#       ToDesk, NoMachine et adb sont désinstallés avant livraison client.
# Usage: ./rk3588_config.sh [SERIAL_NUMBER]
# Exemple: ./rk3588_config.sh HARDIOTM749914DB0
# =============================================================================

# Configuration des couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Variables globales
SCRIPT_NAME="RK3588 Auto Config"
SCRIPT_VERSION="1.5"
LOG_FILE="/var/log/rk3588_config.log"
SERIAL_NUMBER=""

# Configuration du disque NVMe (modifiez le point de montage si besoin)
NVME_DEVICE="/dev/nvme0n1"
NVME_PART="/dev/nvme0n1p1"
NVME_MOUNT="/mnt/nvme"

# Configuration de la génération du numéro de série
# Serial = SERIAL_PREFIX + CRC32(MAC de SERIAL_IFACE en minuscules)
SERIAL_PREFIX="HARDIOTM7"
SERIAL_IFACE="wlan0"

# =============================================================================
# FONCTIONS UTILITAIRES
# =============================================================================

print_header() {
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}           $SCRIPT_NAME v$SCRIPT_VERSION${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}

log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
    echo -e "$message"
}

print_success() {
    log_message "${GREEN}✓ $1${NC}"
}

print_error() {
    log_message "${RED}✗ $1${NC}"
}

print_warning() {
    log_message "${YELLOW}⚠ $1${NC}"
}

print_info() {
    log_message "${BLUE}ℹ $1${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Ce script doit être exécuté avec les privilèges root (sudo)"
        exit 1
    fi
}

validate_serial_format() {
    local serial="$1"
    if [[ ! "$serial" =~ ^HARDIOTM7[A-F0-9]{8}$ ]]; then
        print_error "Format de Serial Number invalide: $serial"
        print_info "Format attendu: HARDIOTM7XXXXXXXX (où X = caractères hexadécimaux)"
        print_info "Exemple: HARDIOTM749914DB0"
        return 1
    fi
    return 0
}

# =============================================================================
# FONCTIONS DE CONFIGURATION
# =============================================================================

configure_wifi() {
    print_info "Configuration de la connexion WiFi..."
    
    if nmcli dev wifi connect NXT-AP2 password "2889100*-+" &>> "$LOG_FILE"; then
        print_success "Connexion WiFi établie avec succès"
        
        # Test de connectivité
        if ping -c 4 8.8.8.8 &>/dev/null; then
            print_success "Test de connectivité Internet réussi"
        else
            print_warning "Connexion WiFi établie mais pas d'accès Internet"
        fi
    else
        print_error "Échec de la connexion WiFi"
        return 1
    fi
}

generate_serial_number() {
    print_info "Génération du numéro de série depuis la MAC de $SERIAL_IFACE..."

    # 1) Lire la MAC de l'interface
    local mac
    mac=$(cat /sys/class/net/$SERIAL_IFACE/address 2>/dev/null)
    if [[ -z "$mac" ]]; then
        print_error "Impossible de lire la MAC de $SERIAL_IFACE"
        return 1
    fi

    # 2) Mettre la MAC en minuscules
    mac=$(echo "$mac" | tr 'A-Z' 'a-z')

    # 3) Calculer le CRC32 du texte de la MAC (hex majuscules, 8 caractères)
    local crc
    crc=$(python3 -c "import binascii,sys; print('%08X' % (binascii.crc32(sys.argv[1].encode()) & 0xffffffff))" "$mac" 2>/dev/null)
    if [[ -z "$crc" ]]; then
        print_error "Échec du calcul du CRC32 (python3 est-il installé ?)"
        return 1
    fi

    # 4) Construire le serial et le stocker dans la variable globale
    SERIAL_NUMBER="${SERIAL_PREFIX}${crc}"

    print_info "MAC ($SERIAL_IFACE): $mac"
    print_info "CRC32: $crc"
    print_success "Serial Number généré: $SERIAL_NUMBER"
}

configure_serial_number() {
    local serial="$1"
    print_info "Configuration du numéro de série: $serial"
    
    # Accorder l'accès au répertoire vendor
    chown admin /vendor &>> "$LOG_FILE"
    
    # Écrire le numéro de série
    echo "$serial" > /vendor/serial
    
    if [[ $? -eq 0 ]]; then
        print_success "Numéro de série configuré: $serial"
    else
        print_error "Échec de l'écriture du numéro de série"
        return 1
    fi
}

set_hostname() {
    local serial="$1"
    print_info "Configuration du hostname: $serial"

    # Définir le hostname de façon permanente
    if hostnamectl set-hostname "$serial" &>> "$LOG_FILE"; then
        print_success "Hostname défini via hostnamectl"
    else
        # Repli si hostnamectl indisponible
        echo "$serial" > /etc/hostname
        hostname "$serial" &>> "$LOG_FILE"
        print_warning "hostnamectl indisponible - /etc/hostname mis à jour manuellement"
    fi

    # Mettre à jour /etc/hosts pour éviter les avertissements de résolution
    if grep -qE "^127\.0\.1\.1" /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$serial/" /etc/hosts
    else
        echo -e "127.0.1.1\t$serial" >> /etc/hosts
    fi
    print_success "Fichier /etc/hosts mis à jour"
}

create_serial_script() {
    print_info "Création du script de lecture du numéro de série..."
    
    # Créer le script
    cat > /usr/local/bin/serial.sh << 'EOF'
#!/bin/bash
echo "Serial Number:"
cat /vendor/serial
EOF
    
    # Le rendre exécutable et le déplacer
    chmod +x /usr/local/bin/serial.sh
    cp /usr/local/bin/serial.sh /usr/bin/serialnumber
    chmod +x /usr/bin/serialnumber
    
    print_success "Script serialnumber créé et installé"
}

setup_nvme() {
    print_info "Configuration du disque NVMe ($NVME_DEVICE)..."

    # Vérifier que le disque NVMe est présent
    if [[ ! -b "$NVME_DEVICE" ]]; then
        print_warning "Disque NVMe $NVME_DEVICE non détecté - configuration ignorée"
        return 0
    fi

    # Créer le point de montage
    mkdir -p "$NVME_MOUNT" &>> "$LOG_FILE"

    # Créer une partition si aucune n'existe (disque totalement vierge)
    if [[ ! -b "$NVME_PART" ]]; then
        print_warning "Aucune partition sur $NVME_DEVICE - création GPT + partition"
        parted -s "$NVME_DEVICE" mklabel gpt &>> "$LOG_FILE"
        parted -s "$NVME_DEVICE" mkpart primary ext4 0% 100% &>> "$LOG_FILE"
        partprobe "$NVME_DEVICE" &>> "$LOG_FILE"
        udevadm settle &>> "$LOG_FILE"
        sleep 2
    fi

    # Détecter le VRAI type de système de fichiers de la partition
    local fstype
    fstype=$(blkid -s TYPE -o value "$NVME_PART" 2>/dev/null)

    if [[ "$fstype" == "ext4" ]]; then
        # Déjà en ext4 : on ne reformate pas (aucune perte de données au re-run)
        print_info "Partition $NVME_PART déjà en ext4 - pas de reformatage"
    else
        # Disque d'usine (NTFS/exFAT/vfat) ou sans FS : formatage en ext4
        if [[ -n "$fstype" ]]; then
            print_warning "Partition $NVME_PART en '$fstype' (non ext4) - reformatage en ext4"
        else
            print_warning "Aucun système de fichiers sur $NVME_PART - formatage en ext4"
        fi

        # Démonter par sécurité avant de formater
        umount "$NVME_PART" &>> "$LOG_FILE" 2>&1

        if ! mkfs.ext4 -F "$NVME_PART" &>> "$LOG_FILE"; then
            print_error "Échec du formatage de $NVME_PART"
            return 1
        fi
        print_success "Partition $NVME_PART formatée en ext4"
    fi

    # Récupérer l'UUID (mis à jour après un éventuel reformatage)
    local nvme_uuid
    nvme_uuid=$(blkid -s UUID -o value "$NVME_PART" 2>/dev/null)
    if [[ -z "$nvme_uuid" ]]; then
        print_error "Impossible de récupérer l'UUID de $NVME_PART"
        return 1
    fi
    print_info "UUID NVMe: $nvme_uuid"

    # Supprimer toute ancienne entrée fstab pour ce point de montage
    # (évite les UUID périmés, ex: l'ancienne signature NTFS) puis ajouter la bonne
    sed -i "\#[[:space:]]${NVME_MOUNT}[[:space:]]#d" /etc/fstab
    echo "UUID=$nvme_uuid  $NVME_MOUNT  ext4  defaults,nofail  0  2" >> /etc/fstab
    print_success "Entrée fstab mise à jour (montage automatique au démarrage)"

    # Recharger systemd (fstab modifié) puis monter
    systemctl daemon-reload &>> "$LOG_FILE" 2>&1
    if mount "$NVME_MOUNT" &>> "$LOG_FILE" || mount -a &>> "$LOG_FILE"; then
        print_success "Disque NVMe monté sur $NVME_MOUNT"
    else
        print_error "Échec du montage du disque NVMe (vérifiez /etc/fstab)"
        return 1
    fi
}

remove_xfce() {
    print_info "Suppression de l'environnement de bureau XFCE..."

    # Les guillemets empêchent l'expansion glob par le shell ;
    # apt-get interprète lui-même le motif xfce4*
    if apt-get purge -y "xfce4*" &>> "$LOG_FILE"; then
        print_success "Paquets XFCE supprimés"

        # Nettoyer les dépendances orphelines
        apt-get autoremove -y &>> "$LOG_FILE"
        print_info "Dépendances orphelines nettoyées"
    else
        print_error "Échec de la suppression de XFCE"
        return 1
    fi
}

set_multiuser_target() {
    print_info "Configuration du target par défaut sur multi-user (mode console)..."

    if systemctl set-default multi-user.target &>> "$LOG_FILE"; then
        print_success "Target par défaut défini sur multi-user.target"
    else
        print_error "Échec de la configuration du target par défaut"
        return 1
    fi
}

install_docker() {
    print_info "Installation de Docker..."
    
    # Mise à jour du système
    print_info "Mise à jour des paquets système..."
    apt-get update &>> "$LOG_FILE"
    
    # Installation des prérequis
    print_info "Installation des certificats et outils..."
    apt-get install -y ca-certificates curl &>> "$LOG_FILE"
    
    # Créer le répertoire pour les clés
    install -m 0755 -d /etc/apt/keyrings
    
    # Télécharger la clé GPG
    print_info "Configuration des clés GPG Docker..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    
    # Ajouter le dépôt Docker
    print_info "Ajout du dépôt Docker..."
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Mise à jour et installation de Docker
    print_info "Installation des composants Docker..."
    apt-get update &>> "$LOG_FILE"
    
    if apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin &>> "$LOG_FILE"; then
        print_success "Docker installé avec succès"
    else
        print_error "Échec de l'installation de Docker"
        return 1
    fi
}

# Désinstalle les paquets installés parmi la liste donnée.
# Simulation d'abord : si apt veut retirer d'autres paquets, la purge est annulée.
purge_packages() {
    local pkgs=() p extra
    for p in "$@"; do
        dpkg -s "$p" &>/dev/null && pkgs+=("$p")
    done

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        print_info "Paquets absents ($*) - rien à faire"
        return 0
    fi

    extra=$(apt-get -s purge "${pkgs[@]}" 2>/dev/null | awk '/^(Remv|Purg)/ {print $2}' \
            | sort -u | grep -vxF -f <(printf '%s\n' "${pkgs[@]}"))
    if [[ -n "$extra" ]]; then
        print_warning "Purge de ${pkgs[*]} annulée - apt retirerait aussi: $(echo $extra)"
        return 1
    fi

    if apt-get purge -y "${pkgs[@]}" &>> "$LOG_FILE"; then
        print_success "Paquets désinstallés: ${pkgs[*]}"
    else
        print_warning "Échec de la désinstallation de: ${pkgs[*]}"
        return 1
    fi
}

disable_services() {
    print_info "Suppression de ToDesk, NoMachine, adb et du kit aging-test..."

    local target_home="/home/admin"

    # ToDesk : arrêt du service et des processus, puis désinstallation
    systemctl disable --now todeskd.service &>> "$LOG_FILE"
    pkill -f "ToDesk" &>> "$LOG_FILE" && print_info "Processus ToDesk tués"
    purge_packages todesk
    rm -rf /opt/todesk /etc/todesk \
           "$target_home/.todesk" "$target_home/.config/todesk" \
           /etc/xdg/autostart/todesk* "$target_home"/.config/autostart/todesk*
    print_success "ToDesk supprimé"

    # NoMachine : arrêt du serveur (port 4000), puis désinstallation
    systemctl disable --now nxserver.service &>> "$LOG_FILE"
    pkill -f "/usr/NX" &>> "$LOG_FILE" && print_info "Processus NoMachine tués"
    purge_packages nomachine
    rm -rf /usr/NX /etc/NX "$target_home/.nx"
    print_success "NoMachine supprimé"

    # adb / adbd : arrêt du service, suppression de l'unité et des paquets
    systemctl disable --now adbd.service &>> "$LOG_FILE"
    rm -f /etc/systemd/system/adbd.service /lib/systemd/system/adbd.service
    purge_packages adb android-libadb
    systemctl daemon-reload &>> "$LOG_FILE"
    systemctl reset-failed adbd.service &>> "$LOG_FILE"
    print_success "adb / adbd supprimé"

    # Kit aging-test / burn-in : processus en cours
    pkill -f "agingtest/aging_test.sh" &>> "$LOG_FILE"
    pkill -f "agingtest/run.sh" &>> "$LOG_FILE"
    pkill -f "agingtest/monitor_system.sh" &>> "$LOG_FILE"
    pkill -f "agingtest/memory_leak_detector.sh" &>> "$LOG_FILE"
    killall -q stress memtester glmark2-es2 &>> "$LOG_FILE" 2>&1
    print_success "Processus stress/memtester/glmark2/aging_test arrêtés (s'ils tournaient)"

    # Kit aging-test : entrée autostart
    local autostart_desktop="$target_home/.config/autostart/myscript.desktop"
    if [[ -f "$autostart_desktop" ]]; then
        rm -f "$autostart_desktop"
        print_success "Autostart aging-test supprimé: $autostart_desktop"
    else
        print_info "Autostart aging-test absent - rien à faire"
    fi

    print_success "ToDesk, NoMachine, adb et aging-test supprimés"
}

# =============================================================================
# FONCTIONS DE VÉRIFICATION ET LOGS
# =============================================================================

generate_system_report() {
    print_info "Génération du rapport système..."
    
    local report_file="/var/log/rk3588_system_report.log"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    {
        echo "============================================================"
        echo "           RAPPORT SYSTÈME RK3588"
        echo "           Généré le: $timestamp"
        echo "============================================================"
        echo ""
        
        echo "--- INFORMATIONS SYSTÈME ---"
        echo "Hostname: $(hostname)"
        echo "Utilisateur: $(whoami)"
        echo "Uptime: $(uptime)"
        echo "Kernel: $(uname -r)"
        echo "Architecture: $(uname -m)"
        echo ""
        
        echo "--- PARTITIONS ---"
        echo "Configuration des partitions:"
        lsblk 2>/dev/null || echo "Informations de partition non disponibles"
        echo ""
        echo "Espace disque:"
        df -h / 2>/dev/null || echo "Informations d'espace disque non disponibles"
        echo ""
        
        echo "--- ADRESSE MAC ---"
        echo "Adresse MAC détectée:"
        ip link show | grep -E "link/ether" | head -1 | awk '{print $2}' | tr '[:lower:]' '[:upper:]'
        echo ""
        
        echo "--- VERSION DOCKER ---"
        if command -v docker &> /dev/null; then
            echo "Docker version: $(docker --version 2>/dev/null || echo 'Erreur version Docker')"
            echo "Docker status: $(systemctl is-active docker 2>/dev/null || echo 'Service non disponible')"
            if command -v docker-compose &> /dev/null; then
                echo "Docker Compose: $(docker-compose --version 2>/dev/null || echo 'Erreur version')"
            else
                echo "Docker Compose: Non installé"
            fi
        else
            echo "Docker: Non installé"
        fi
        echo ""
        
        echo "--- NUMÉRO DE SÉRIE ---"
        if command -v serialnumber &> /dev/null; then
            echo "Serial Number (commande):"
            serialnumber 2>/dev/null || echo "Erreur lecture serialnumber"
        elif [[ -f "/vendor/serial" ]]; then
            echo "Serial Number (fichier): $(cat /vendor/serial)"
        else
            echo "Serial Number: Non configuré"
        fi
        echo ""
        
        echo "--- STOCKAGE ---"
        echo "Configuration des partitions (lsblk):"
        lsblk 2>/dev/null || echo "Informations lsblk non disponibles"
        echo ""
        echo "Espace disque (df -h):"
        df -h 2>/dev/null || echo "Informations df non disponibles"
        echo ""
        
        echo "--- MONTAGE NVMe ---"
        if [[ -b "$NVME_DEVICE" ]]; then
            echo "Disque NVMe: Détecté ($NVME_DEVICE)"
            if mountpoint -q "$NVME_MOUNT" 2>/dev/null || mount | grep -q " $NVME_MOUNT "; then
                echo "Montage: OK (monté sur $NVME_MOUNT)"
                echo "Détails:"
                df -h "$NVME_MOUNT" 2>/dev/null
                echo "Entrée fstab:"
                grep "$NVME_MOUNT" /etc/fstab 2>/dev/null || echo "  Aucune entrée fstab trouvée"
            else
                echo "Montage: KO (non monté sur $NVME_MOUNT)"
            fi
        else
            echo "Disque NVMe: Non détecté"
        fi
        echo ""
        
        echo "--- INTERFACES RÉSEAU ---"
        echo "Interfaces disponibles:"
        ip link show 2>/dev/null | grep -E "^[0-9]:" | awk '{print $2}' | tr -d ':'
        echo ""
        
        # Vérifier eth2
        if ip link show eth2 &>/dev/null; then
            local eth2_mac=$(ip link show eth2 2>/dev/null | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | head -1)
            echo "eth2: Détectée"
            if [[ -n "$eth2_mac" ]]; then
                echo "  MAC Address: $(echo $eth2_mac | tr '[:lower:]' '[:upper:]')"
            else
                echo "  MAC Address: Non disponible"
            fi
        else
            echo "eth2: Non détectée"
        fi
        
        # Vérifier eth1
        if ip link show eth1 &>/dev/null; then
            local eth1_mac=$(ip link show eth1 2>/dev/null | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | head -1)
            echo "eth1: Détectée"
            if [[ -n "$eth1_mac" ]]; then
                echo "  MAC Address: $(echo $eth1_mac | tr '[:lower:]' '[:upper:]')"
            else
                echo "  MAC Address: Non disponible"
            fi
        else
            echo "eth1: Non détectée"
        fi
        
        # Vérifier wlan0 (WiFi - sert à la génération du serial)
        if ip link show "$SERIAL_IFACE" &>/dev/null; then
            local wlan_mac=$(cat /sys/class/net/$SERIAL_IFACE/address 2>/dev/null)
            echo "$SERIAL_IFACE: Détectée"
            if [[ -n "$wlan_mac" ]]; then
                echo "  MAC Address: $(echo $wlan_mac | tr '[:lower:]' '[:upper:]')"
            else
                echo "  MAC Address: Non disponible"
            fi
        else
            echo "$SERIAL_IFACE: Non détectée"
        fi
        echo ""
        
        echo "--- CONNEXION RÉSEAU ---"
        echo "Connexions actives:"
        nmcli connection show --active
        echo ""
        echo "Test de connectivité Internet:"
        if ping -c 2 8.8.8.8 &>/dev/null; then
            echo "✓ Connexion Internet OK"
        else
            echo "✗ Pas de connexion Internet"
        fi
        echo ""
        
        echo "============================================================"
        echo "           FIN DU RAPPORT"
        echo "============================================================"
        
    } > "$report_file"
    
    print_success "Rapport système généré: $report_file"
    
    # Afficher un résumé
    echo ""
    print_info "RÉSUMÉ DE CONFIGURATION:"
    echo "=========================="
    
    # Serial Number
    if command -v serialnumber &> /dev/null; then
        echo -e "${GREEN}Serial Number: $(serialnumber 2>/dev/null | tail -1)${NC}"
    elif [[ -f "/vendor/serial" ]]; then
        echo -e "${GREEN}Serial Number: $(cat /vendor/serial)${NC}"
    else
        echo -e "${RED}Serial Number: Non configuré${NC}"
    fi
    
    # Hostname
    echo -e "${GREEN}Hostname: $(hostname)${NC}"
    
    # Adresse MAC WiFi (wlan0)
    if [[ -f "/sys/class/net/$SERIAL_IFACE/address" ]]; then
        echo -e "${GREEN}MAC $SERIAL_IFACE: $(cat /sys/class/net/$SERIAL_IFACE/address 2>/dev/null | tr '[:lower:]' '[:upper:]')${NC}"
    else
        echo -e "${YELLOW}MAC $SERIAL_IFACE: Interface non détectée${NC}"
    fi
    
    # Espace disque
    local disk_usage=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%' 2>/dev/null || echo "0")
    if [[ $disk_usage -lt 80 ]] 2>/dev/null; then
        echo -e "${GREEN}Espace disque: $(df -h / | tail -1 | awk '{print $3"/"$2" ("$5")"}' 2>/dev/null || echo "N/A")${NC}"
    else
        echo -e "${YELLOW}Espace disque: $(df -h / | tail -1 | awk '{print $3"/"$2" ("$5")"}' 2>/dev/null || echo "N/A")${NC}"
    fi
    
    # Version Docker
    if command -v docker &> /dev/null; then
        echo -e "${GREEN}Docker: $(docker --version 2>/dev/null | head -1 || echo "Installé mais erreur version")${NC}"
    else
        echo -e "${RED}Docker: Non installé${NC}"
    fi
    
    # Montage NVMe
    if [[ -b "$NVME_DEVICE" ]]; then
        if mountpoint -q "$NVME_MOUNT" 2>/dev/null || mount | grep -q " $NVME_MOUNT "; then
            echo -e "${GREEN}Montage NVMe: OK ($NVME_MOUNT) ✓${NC}"
        else
            echo -e "${RED}Montage NVMe: KO (non monté)${NC}"
        fi
    else
        echo -e "${YELLOW}Montage NVMe: Disque non détecté${NC}"
    fi
    
    # Interfaces réseau
    if ip link show eth2 &>/dev/null; then
        local eth2_mac=$(ip link show eth2 2>/dev/null | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | head -1 | tr '[:lower:]' '[:upper:]')
        echo -e "${GREEN}eth2: ${eth2_mac:-"MAC non disponible"}${NC}"
    else
        echo -e "${RED}eth2: Non détectée${NC}"
    fi
    
    if ip link show eth1 &>/dev/null; then
        local eth1_mac=$(ip link show eth1 2>/dev/null | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | head -1 | tr '[:lower:]' '[:upper:]')
        echo -e "${GREEN}eth1: ${eth1_mac:-"MAC non disponible"}${NC}"
    else
        echo -e "${YELLOW}eth1: Non détectée${NC}"
    fi
    
    # Connexion réseau
    if ping -c 1 8.8.8.8 &>/dev/null; then
        echo -e "${GREEN}Connectivité Internet: OK${NC}"
    else
        echo -e "${RED}Connectivité Internet: KO${NC}"
    fi
    
    echo "=========================="
}

# =============================================================================
# FONCTION PRINCIPALE
# =============================================================================

show_usage() {
    echo "Usage: $0 [SERIAL_NUMBER]"
    echo ""
    echo "Paramètres:"
    echo "  SERIAL_NUMBER    (Optionnel) Numéro de série au format HARDIOTM7XXXXXXXX."
    echo "                   Si omis, il est généré automatiquement à partir de"
    echo "                   la MAC de l'interface $SERIAL_IFACE (CRC32)."
    echo ""
    echo "Exemples:"
    echo "  $0                      # génère le serial depuis la MAC"
    echo "  $0 HARDIOTM749914DB0    # force un serial donné"
    echo ""
    echo "Le script automatise les tâches suivantes:"
    echo "  - Génération automatique du numéro de série (depuis la MAC)"
    echo "  - Configuration du numéro de série"
    echo "  - Définition du hostname avec le numéro de série"
    echo "  - Création du script serialnumber"
    echo "  - Configuration et montage automatique du disque NVMe"
    echo "  - Installation de Docker"
    echo "  - Désinstallation de ToDesk, NoMachine et adb/adbd"
    echo "  - Suppression du kit aging-test (autostart + processus)"
    echo "  - lightdm et XFCE sont conservés (boot graphique)"
    echo "  - Génération du rapport système"
}

main() {
    print_header
    
    # Vérification des privilèges
    check_root
    
    # Initialisation du fichier de log
    touch "$LOG_FILE"
    log_message "=== Début de la configuration RK3588 ==="
    
    # Numéro de série : généré automatiquement depuis la MAC,
    # ou utilisé tel quel s'il est fourni en argument (optionnel)
    if [[ -n "$1" ]]; then
        SERIAL_NUMBER="$1"
        print_info "Serial Number fourni en argument: $SERIAL_NUMBER"
    else
        generate_serial_number || {
            print_error "Échec de la génération du Serial Number - arrêt"
            exit 1
        }
    fi
    
    # Validation du format du serial number
    if ! validate_serial_format "$SERIAL_NUMBER"; then
        exit 1
    fi
    
    log_message "Serial Number: $SERIAL_NUMBER"
    
    print_info "Configuration en cours pour la carte RK3588"
    print_info "Serial Number: $SERIAL_NUMBER"
    echo ""
    
    # Exécution des étapes de configuration
    configure_serial_number "$SERIAL_NUMBER" || {
        print_error "Échec de la configuration du serial number - arrêt"
        exit 1
    }
    
    set_hostname "$SERIAL_NUMBER" || print_warning "Configuration du hostname échouée, continuation..."
    
    create_serial_script || print_warning "Création script serial échouée, continuation..."
    configure_wifi || print_warning "Configuration WiFi échouée, continuation..."

    setup_nvme || print_warning "Configuration NVMe échouée, continuation..."
    
    #install_docker || print_warning "Installation Docker échouée, continuation..."
    
    disable_services || print_warning "Désactivation des services échouée, continuation..."

    # lightdm et XFCE conservés : pas de passage en mode console
    remove_xfce || print_warning "Suppression XFCE échouée, continuation..."
    set_multiuser_target || print_warning "Configuration multi-user.target échouée, continuation..."


    # Génération du rapport final
    echo ""
    generate_system_report
    
    log_message "=== Configuration terminée ==="
    print_success "Configuration de la carte RK3588 terminée!"
    print_info "Consultez le rapport complet: /var/log/rk3588_system_report.log"
    print_info "Logs détaillés: $LOG_FILE"
    
    echo ""
    print_warning "Un redémarrage est recommandé pour finaliser la suppression des services"
    print_info "Exécutez: sudo reboot"
    rm -f  "/home/admin/rk3588_config.sh"
}

# =============================================================================
# POINT D'ENTRÉE
# =============================================================================

main "$@"