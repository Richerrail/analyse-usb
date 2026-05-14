#!/bin/bash
# =============================================================================
# analyse-usb.sh — Analyse de clés USB suspectes en VM isolée
# =============================================================================
# Auteur  : <ton pseudo>
# Licence : MIT
# Dépôt   : https://github.com/TON_PSEUDO/analyse-usb
#
# Description :
#   Monte une clé USB en lecture seule, détecte automatiquement un exécutable
#   SFX (.exe) ou une archive (.7z), effectue une analyse statique complète
#   sur l'hôte (file, exiftool, strings) avec log horodaté, puis lance une
#   VM QEMU sans réseau (Alpine Linux) pour une analyse dynamique sécurisée.
#
# Prérequis :
#   Arch  : sudo pacman -S qemu-full edk2-ovmf wget util-linux dosfstools \
#                          p7zip perl-image-exiftool
#   Debian: sudo apt install qemu-system-x86 ovmf wget util-linux dosfstools \
#                            p7zip-full libimage-exiftool-perl
# =============================================================================
set -euo pipefail


SCRIPT_DIR="$HOME/vm-sandbox"
ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-extended-3.19.1-x86_64.iso"
ISO_FILE="$SCRIPT_DIR/alpine-extended-3.19.1-x86_64.iso"
SHARE_IMG="$SCRIPT_DIR/share.img"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
        echo -e "${YELLOW}[AVERTISSEMENT] Tu n'as pas accès à /dev/kvm.${NC}"
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
        if [ -f "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

detect_usb_disks() {
    lsblk -dn -o NAME,SIZE,VENDOR,MODEL,TRAN | awk '$5 ~ /^usb$/ {print $0}' || true
}

check_mounted() {
    local dev="$1"
    local mnts
    mnts=$(lsblk -rno MOUNTPOINT "/dev/$dev" 2>/dev/null | grep -v '^$' || true)
    echo "$mnts"
}

header
check_deps

mkdir -p "$SCRIPT_DIR"
mkdir -p "$SCRIPT_DIR/logs"
cd "$SCRIPT_DIR"

# --- Téléchargement ISO ---
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

# --- Recherche firmware UEFI ---
OVMF=$(find_ovmf) || {
    echo -e "${RED}[ERREUR] Fichier UEFI (OVMF) introuvable.${NC}"
    echo "Installe : sudo pacman -S edk2-ovmf"
    exit 1
}

# --- Détection clés USB ---
echo ""
echo -e "${YELLOW}[INFO] Recherche des disques USB...${NC}"
echo ""

USB_DISKS=$(detect_usb_disks)

if [ -z "$USB_DISKS" ]; then
    echo -e "${RED}[ERREUR] Aucun disque USB détecté.${NC}"
    echo "Branche ta clé USB et attends 2-3 secondes, puis relance ce script."
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

# Sécurité
ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*\]//' || true)
if [ -n "$ROOT_DEV" ] && echo "$ROOT_DEV" | grep -q "^/dev/$DEVNAME"; then
    echo -e "${RED}[ERREUR CRITIQUE] /dev/$DEVNAME est ton disque système !${NC}"
    exit 1
fi

# --- Monter la clé sur l'hôte en lecture seule ---
MOUNTS=$(check_mounted "$DEVNAME")
if [ -n "$MOUNTS" ]; then
    echo -e "${YELLOW}[INFO] Démontage de la clé sur l'hôte...${NC}"
    sudo umount "/dev/${DEVNAME}"* 2>/dev/null || true
fi

MOUNT_PT=$(mktemp -d)
echo -e "${YELLOW}[INFO] Montage de /dev/${DEVNAME}1 en lecture seule...${NC}"
if ! sudo mount -o ro "/dev/${DEVNAME}1" "$MOUNT_PT" 2>/dev/null; then
    if ! sudo mount -o ro "/dev/$DEVNAME" "$MOUNT_PT" 2>/dev/null; then
        echo -e "${RED}[ERREUR] Impossible de monter la clé.${NC}"
        rmdir "$MOUNT_PT"
        exit 1
    fi
fi

# --- Chercher les fichiers suspects ---
# Cherche .exe (SFX 7z) ou .7z
EXE_FILE=$(find "$MOUNT_PT" -maxdepth 3 -type f -iname "*.exe" | head -n 1)
ARCHIVE=$(find "$MOUNT_PT" -maxdepth 3 -type f -iname "*.7z" | head -n 1)

TARGET_FILE=""
IS_SFX=false

if [ -n "$EXE_FILE" ]; then
    TARGET_FILE="$EXE_FILE"
    echo -e "${GREEN}[OK] Exécutable trouvé : $(basename "$EXE_FILE")${NC}"
    IS_SFX=true
elif [ -n "$ARCHIVE" ]; then
    TARGET_FILE="$ARCHIVE"
    echo -e "${GREEN}[OK] Archive trouvée : $(basename "$ARCHIVE")${NC}"
else
    echo -e "${RED}[ERREUR] Aucun .exe ni .7z trouvé sur la clé.${NC}"
    sudo umount "$MOUNT_PT"
    rmdir "$MOUNT_PT"
    exit 1
fi

# --- Installer les outils sur l'hôte si besoin ---
if ! command -v 7z &> /dev/null; then
    echo -e "${YELLOW}[INFO] Installation de p7zip sur l'hôte...${NC}"
    sudo pacman -S --noconfirm p7zip 2>/dev/null || sudo pacman -S p7zip
fi
if ! command -v exiftool &> /dev/null; then
    echo -e "${YELLOW}[INFO] Installation de exiftool sur l'hôte...${NC}"
    sudo pacman -S --noconfirm perl-image-exiftool 2>/dev/null || sudo pacman -S perl-image-exiftool
fi

# --- Analyse statique rapide sur l'hôte ---
LOG_FILE="$SCRIPT_DIR/logs/analyse-$(basename "$TARGET_FILE")-$(date +%Y%m%d-%H%M%S).log"

echo ""
echo -e "${GREEN}=== ANALYSE STATIQUE RAPIDE SUR L'HOTE ===${NC}"
echo ""
echo -e "${YELLOW}Fichier analysé :${NC} $(basename "$TARGET_FILE")"
echo -e "${YELLOW}Log sauvegardé dans :${NC} $LOG_FILE"
echo ""

{
    echo "========================================"
    echo "ANALYSE STATIQUE - $(date)"
    echo "Fichier: $TARGET_FILE"
    echo "========================================"
    echo ""

    echo "--- [file] ---"
    file "$TARGET_FILE"
    echo ""

    if [ "$IS_SFX" = true ]; then
        echo "--- [7z l] Contenu de l'archive SFX ---"
        7z l "$TARGET_FILE"
        echo ""
    fi

    echo "--- [exiftool] ---"
    exiftool "$TARGET_FILE" 2>/dev/null
    echo ""

    echo "--- [strings - URLs/commandes/IP suspectes] ---"
    strings "$TARGET_FILE" | grep -iE "(http|https|ftp|cmd|powershell|netsh|regsvr32|rundll32|WScript|eval|base64|127\.|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)" | sort -u
    echo ""

    echo "--- [strings COMPLET] ---"
    strings "$TARGET_FILE"
    echo ""

    echo "========================================"
    echo "FIN DE L'ANALYSE"
    echo "========================================"
} | tee "$LOG_FILE"

echo ""
echo -e "${GREEN}[OK] Log complet sauvegardé dans :${NC} $LOG_FILE"
echo ""

# --- Extraire le contenu ---
EXTRACT_DIR=$(mktemp -d)
echo -e "${YELLOW}[INFO] Extraction du contenu...${NC}"
if [ "$IS_SFX" = true ]; then
    7z x -o"$EXTRACT_DIR" "$TARGET_FILE"
else
    7z x -o"$EXTRACT_DIR" "$TARGET_FILE"
fi

# --- Créer un disque virtuel avec le contenu extrait + l'exe ---
echo -e "${YELLOW}[INFO] Création d'un disque virtuel pour la VM...${NC}"
rm -f "$SHARE_IMG"
dd if=/dev/zero of="$SHARE_IMG" bs=1M count=500 status=none
mkfs.vfat -n SHARE "$SHARE_IMG" > /dev/null

MOUNT_SHARE=$(mktemp -d)
sudo mount -o loop "$SHARE_IMG" "$MOUNT_SHARE"
sudo cp "$TARGET_FILE" "$MOUNT_SHARE/"
if [ -n "$(ls -A "$EXTRACT_DIR")" ]; then
    sudo cp -r "$EXTRACT_DIR"/* "$MOUNT_SHARE/"
fi
sudo umount "$MOUNT_SHARE"
rmdir "$MOUNT_SHARE"

# Nettoyer
sudo umount "$MOUNT_PT"
rmdir "$MOUNT_PT"
rm -rf "$EXTRACT_DIR"

echo -e "${GREEN}[OK] Disque virtuel prêt.${NC}"

# --- Lancement QEMU ---
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  LANCEMENT DE LA VM ISOLEE            ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  → Réseau : DESACTIVE (-net none)"
echo "  → Clé USB : isolée sur l'hôte"
echo "  → Fichiers : disponibles sur un disque virtuel dans la VM"
echo ""
echo -e "${YELLOW}DANS LA VM :${NC}"
echo ""
echo "  mkdir -p /mnt/share && mount /dev/vda /mnt/share"
echo "  cd /mnt/share"
echo "  ls -la"
echo ""
echo "  # Voir le contenu extrait :"
echo "  ls -la"
echo ""
echo "  # Pour exécuter avec Wine (si tu veux voir) :"
echo "  apk add wine"
echo "  wine *.exe"
echo ""
echo -e "${BLUE}Pour arrêter : ferme la fenêtre QEMU ou Ctrl+Alt+2 puis 'quit'${NC}"
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
