#!/bin/bash
# =============================================================================
# analyse-usb.sh — Analyse de clés USB suspectes en VM isolée
# =============================================================================
# Auteur  : <richerrail>
# Licence : MIT
# Dépôt   : https://github.com/richerrail/analyse-usb
#
# Description :
#   Monte une clé USB en lecture seule, extrait son contenu, effectue une
#   analyse statique sur l'hôte, puis lance une VM QEMU sans réseau
#   (Alpine Linux) pour une analyse dynamique sécurisée.
#
# Prérequis :
#   Arch  : sudo pacman -S qemu-full edk2-ovmf wget util-linux dosfstools \
#                          p7zip perl-image-exiftool
#   Debian: sudo apt install qemu-system-x86 ovmf wget util-linux dosfstools \
#                            p7zip-full libimage-exiftool-perl
# =============================================================================
set -euo pipefail

# --- Configuration -----------------------------------------------------------
SCRIPT_DIR="$HOME/vm-sandbox"
ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-extended-3.19.1-x86_64.iso"
ISO_FILE="$SCRIPT_DIR/alpine-extended-3.19.1-x86_64.iso"
SHARE_IMG="$SCRIPT_DIR/share.img"

# --- Couleurs ----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Fonctions utilitaires ---------------------------------------------------

header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  ANALYSE USB ISOLEE (sans reseau)      ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

check_deps() {
    local missing=()
    for cmd in qemu-system-x86_64 qemu-img wget lsblk mkfs.vfat; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}[ERREUR] Paquets manquants : ${missing[*]}${NC}"
        echo "Installe-les avec :"
        echo "  sudo pacman -S qemu-full qemu-img wget util-linux dosfstools"
        exit 1
    fi

    if [ ! -e /dev/kvm ]; then
        echo -e "${RED}[ERREUR] /dev/kvm absent.${NC}"
        echo "Active la virtualisation (VT-x/AMD-V) dans ton BIOS/UEFI."
        exit 1
    fi

    if [ ! -r /dev/kvm ]; then
        echo -e "${YELLOW}[AVERTISSEMENT] Pas d'accès à /dev/kvm.${NC}"
        echo "Ajoute-toi au groupe kvm, déconnecte-toi et reconnecte-toi :"
        echo "  sudo usermod -aG kvm \$USER"
        exit 1
    fi
}

find_ovmf() {
    local paths=(
        "/usr/share/edk2/x64/OVMF_CODE.fd"
        "/usr/share/edk2/x64/OVMF_CODE.4m.fd"
        "/usr/share/edk2/x64/OVMF.fd"
        "/usr/share/OVMF/OVMF_CODE.fd"
        "/usr/share/OVMF/x64/OVMF_CODE.fd"
        "/usr/share/qemu/edk2-x86_64-code.fd"
    )
    for p in "${paths[@]}"; do
        [ -f "$p" ] && echo "$p" && return 0
    done
    return 1
}

detect_usb_disks() {
    lsblk -dn -o NAME,SIZE,VENDOR,MODEL,TRAN | awk '$5 ~ /^usb$/ {print $0}' || true
}

check_mounted() {
    local dev="$1"
    lsblk -rno MOUNTPOINT "/dev/$dev" 2>/dev/null | grep -v '^$' || true
}

# --- Point d'entrée ----------------------------------------------------------

header
check_deps

mkdir -p "$SCRIPT_DIR"
cd "$SCRIPT_DIR"

# Téléchargement ISO Alpine
if [ ! -f "$ISO_FILE" ]; then
    echo -e "${YELLOW}[INFO] ISO Alpine non trouvée. Téléchargement (~500 Mo)...${NC}"
    if ! wget --show-progress -q "$ISO_URL" -O "$ISO_FILE"; then
        echo -e "${RED}[ERREUR] Échec du téléchargement.${NC}"
        exit 1
    fi
    echo -e "${GREEN}[OK] ISO téléchargée.${NC}"
else
    echo -e "${GREEN}[OK] ISO déjà présente.${NC}"
fi

# Firmware UEFI
OVMF=$(find_ovmf) || {
    echo -e "${RED}[ERREUR] Fichier UEFI (OVMF) introuvable.${NC}"
    echo "Installe : sudo pacman -S edk2-ovmf"
    exit 1
}

# Détection des clés USB
echo ""
echo -e "${YELLOW}[INFO] Recherche des disques USB...${NC}"
echo ""

USB_DISKS=$(detect_usb_disks)

if [ -z "$USB_DISKS" ]; then
    echo -e "${RED}[ERREUR] Aucun disque USB détecté.${NC}"
    echo "Branche ta clé USB et attends 2-3 secondes, puis relance le script."
    exit 1
fi

echo "Disques USB détectés :"
echo ""
printf " %-8s %-10s %-20s %-20s\n" "DEVICE" "TAILLE" "VENDEUR" "MODELE"
echo "---------------------------------------------------------------"
echo "$USB_DISKS" | while read -r name size vendor model tran; do
    printf " %-8s %-10s %-20s %-20s\n" "/dev/$name" "$size" "$vendor" "$model"
done
echo ""

read -rp "Tape le nom du device (ex: sdb, sdc) : " DEVNAME
DEVNAME=$(echo "$DEVNAME" | sed 's|^/dev/||')

if [ ! -b "/dev/$DEVNAME" ]; then
    echo -e "${RED}[ERREUR] /dev/$DEVNAME n'existe pas.${NC}"
    exit 1
fi

# Protection contre la sélection du disque système
ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*\]//' || true)
if [ -n "$ROOT_DEV" ] && echo "$ROOT_DEV" | grep -q "^/dev/$DEVNAME"; then
    echo -e "${RED}[ERREUR CRITIQUE] /dev/$DEVNAME est ton disque système !${NC}"
    exit 1
fi

# Démontage si nécessaire
MOUNTS=$(check_mounted "$DEVNAME")
if [ -n "$MOUNTS" ]; then
    echo -e "${YELLOW}[INFO] Démontage de la clé sur l'hôte...${NC}"
    sudo umount "/dev/${DEVNAME}"* 2>/dev/null || true
fi

# Montage en lecture seule
MOUNT_PT=$(mktemp -d)
echo -e "${YELLOW}[INFO] Montage de /dev/${DEVNAME}1 en lecture seule...${NC}"
if ! sudo mount -o ro "/dev/${DEVNAME}1" "$MOUNT_PT" 2>/dev/null; then
    if ! sudo mount -o ro "/dev/$DEVNAME" "$MOUNT_PT" 2>/dev/null; then
        echo -e "${RED}[ERREUR] Impossible de monter la clé.${NC}"
        rmdir "$MOUNT_PT"
        exit 1
    fi
fi

# Recherche de l'archive .7z
ARCHIVE=$(find "$MOUNT_PT" -maxdepth 3 -type f -iname "*.7z" | head -n 1)
if [ -z "$ARCHIVE" ]; then
    echo -e "${RED}[ERREUR] Aucune archive .7z trouvée sur la clé.${NC}"
    sudo umount "$MOUNT_PT"
    rmdir "$MOUNT_PT"
    exit 1
fi

echo -e "${GREEN}[OK] Archive trouvée : $(basename "$ARCHIVE")${NC}"

# Installation des outils si absents
for pkg_cmd in "7z:p7zip" "exiftool:perl-image-exiftool"; do
    cmd="${pkg_cmd%%:*}"
    pkg="${pkg_cmd##*:}"
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${YELLOW}[INFO] Installation de $pkg...${NC}"
        sudo pacman -S --noconfirm "$pkg" 2>/dev/null || sudo pacman -S "$pkg"
    fi
done

# Extraction
EXTRACT_DIR=$(mktemp -d)
echo -e "${YELLOW}[INFO] Extraction de l'archive...${NC}"
7z x -o"$EXTRACT_DIR" "$ARCHIVE"

# Analyse statique rapide
EXE_FILE=$(find "$EXTRACT_DIR" -maxdepth 2 -type f -iname "*.exe" | head -n 1)
if [ -n "$EXE_FILE" ]; then
    echo ""
    echo -e "${GREEN}=== ANALYSE STATIQUE SUR L'HOTE ===${NC}"
    echo ""
    echo -e "${YELLOW}Fichier :${NC} $(basename "$EXE_FILE")"
    echo ""
    echo -e "${YELLOW}[file]${NC}"
    file "$EXE_FILE"
    echo ""
    echo -e "${YELLOW}[exiftool]${NC}"
    exiftool "$EXE_FILE" 2>/dev/null | head -n 20
    echo ""
    echo -e "${YELLOW}[strings — éléments suspects]${NC}"
    strings "$EXE_FILE" \
        | grep -iE "(http|https|ftp|cmd|powershell|netsh|regsvr32|rundll32|WScript|eval|base64)" \
        | head -n 15
    echo ""
fi

# Création du disque virtuel partagé
echo -e "${YELLOW}[INFO] Création du disque virtuel pour la VM...${NC}"
rm -f "$SHARE_IMG"
dd if=/dev/zero of="$SHARE_IMG" bs=1M count=200 status=none
mkfs.vfat -n SHARE "$SHARE_IMG" > /dev/null

MOUNT_SHARE=$(mktemp -d)
sudo mount -o loop "$SHARE_IMG" "$MOUNT_SHARE"
sudo cp -r "$EXTRACT_DIR"/* "$MOUNT_SHARE/"
sudo umount "$MOUNT_SHARE"
rmdir "$MOUNT_SHARE"

# Nettoyage
sudo umount "$MOUNT_PT"
rmdir "$MOUNT_PT"
rm -rf "$EXTRACT_DIR"

echo -e "${GREEN}[OK] Disque virtuel prêt.${NC}"

# Lancement QEMU
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  LANCEMENT DE LA VM ISOLEE             ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  → Réseau    : DÉSACTIVÉ (-net none)"
echo "  → Clé USB   : isolée sur l'hôte"
echo "  → Fichiers  : montables via /dev/vda dans la VM"
echo ""
echo -e "${YELLOW}Commandes utiles dans la VM (login: root) :${NC}"
echo ""
echo "  mkdir -p /mnt/share && mount /dev/vda /mnt/share"
echo "  cd /mnt/share && ls -la"
echo ""
echo "  file *.exe"
echo "  strings *.exe | less"
echo "  exiftool *.exe"
echo ""
echo "  # Exécution optionnelle avec Wine :"
echo "  apk add wine && wine *.exe"
echo ""
echo -e "${BLUE}Pour arrêter : ferme la fenêtre QEMU ou Ctrl+Alt+2 → quit${NC}"
echo ""

sleep 2

qemu-system-x86_64 \
    -enable-kvm \
    -m 4096 \
    -smp 2 \
    -cpu host \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF" \
    -cdrom "$ISO_FILE" \
    -boot d \
    -drive file="$SHARE_IMG",format=raw,if=virtio \
    -net none \
    -display sdl \
    -name "ANALYSE-USB-ISOLATED"

echo ""
echo -e "${GREEN}VM arrêtée.${NC}"
