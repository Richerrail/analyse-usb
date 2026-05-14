# 🔬 analyse-usb — Analyse de clés USB suspectes en VM isolée

[![License: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/plateforme-Linux-lightgrey.svg)]()
[![Requires: QEMU](https://img.shields.io/badge/requires-QEMU-orange.svg)]()
[![Shell: Bash](https://img.shields.io/badge/shell-bash-green.svg)]()

Script Bash qui analyse le contenu d'une clé USB suspecte dans une machine virtuelle **totalement isolée du réseau**, sans risque pour l'hôte.

---

## ⚠️ Avertissement

Ce script est destiné à un usage **éducatif et défensif** uniquement.  
N'analyse jamais de fichiers suspects directement sur ton système hôte.

---

## 🧰 Prérequis

### Arch Linux
```bash
sudo pacman -S qemu-full edk2-ovmf wget util-linux dosfstools p7zip perl-image-exiftool
```

### Debian / Ubuntu
```bash
sudo apt install qemu-system-x86 ovmf wget util-linux dosfstools p7zip-full libimage-exiftool-perl
```

### Accès KVM (toutes distributions)
```bash
sudo usermod -aG kvm $USER
# Déconnecte-toi et reconnecte-toi pour appliquer
```

> La virtualisation (VT-x / AMD-V) doit être activée dans le BIOS/UEFI.

---

## 🚀 Utilisation

**1. Clone le dépôt**
```bash
git clone https://github.com/richerrail/analyse-usb.git
cd analyse-usb
chmod +x analyse-usb.sh
```

**2. Branche ta clé USB** et attends 2-3 secondes.

**3. Lance le script**
```bash
./analyse-usb.sh
```

---

## 🔄 Ce que fait le script

```
Clé USB branchée
      │
      ▼
Détection des disques USB (lsblk)
      │
      ▼
Montage en lecture seule sur l'hôte
      │
      ▼
Extraction de l'archive .7z
      │
      ├─► Analyse statique sur l'hôte
      │     • file       → type de fichier
      │     • exiftool   → métadonnées
      │     • strings    → URLs / commandes suspectes
      │
      ▼
Création d'un disque virtuel FAT (share.img)
      │
      ▼
Lancement QEMU (Alpine Linux, -net none)
      │
      ▼
Analyse dynamique dans la VM isolée
```

---

## 🖥️ Dans la VM Alpine (après boot)

```bash
# Login : root (sans mot de passe)

mkdir -p /mnt/share && mount /dev/vda /mnt/share
cd /mnt/share
ls -la

# Identifier le fichier
file *.exe

# Chercher des chaînes suspectes
strings *.exe | less

# Lire les métadonnées
exiftool *.exe

# Exécution optionnelle avec Wine (toujours sans réseau)
apk add wine
wine *.exe
```

---

## 🛡️ Garanties de sécurité

| Mesure | Détail |
|---|---|
| `-net none` | Aucune interface réseau dans la VM |
| Lecture seule | La clé USB est montée en `ro` sur l'hôte |
| Pas de disque persistant | Tout disparaît à l'arrêt de la VM |
| Protection disque système | Vérifie que le device choisi n'est pas `/` |

---

## 📁 Structure du dépôt

```
analyse-usb/
├── analyse-usb.sh   # Script principal
└── README.md        # Ce fichier
```

---

## 📄 Licence

[MIT](LICENSE) — libre d'utilisation, de modification et de distribution.
