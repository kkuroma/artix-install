#!/usr/bin/env bash
# =============================================================================
# Artix Linux Installer
# LUKS2 + LVM + Btrfs | OpenRC | UEFI | SDDM + Hyprland
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}══════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}  $*${RESET}"; \
            echo -e "${BOLD}══════════════════════════════════════${RESET}"; }

# ─── Constants ────────────────────────────────────────────────────────────────
LUKS_NAME="artix"
LUKS_DEV="/dev/mapper/${LUKS_NAME}"
VG_NAME="artixvg"
LV_ROOT="/dev/${VG_NAME}/root"
LV_SWAP="/dev/${VG_NAME}/swap"

# ─── Cleanup trap ─────────────────────────────────────────────────────────────
cleanup() {
    local code=$?
    [[ $code -eq 0 ]] && return
    echo ""
    warn "Script failed (exit $code) — cleaning up..."
    swapoff "$LV_SWAP"          2>/dev/null || true
    umount -R /mnt              2>/dev/null || true
    vgchange -an "$VG_NAME"     2>/dev/null || true
    cryptsetup close "$LUKS_NAME" 2>/dev/null || true
    echo -e "\n${RED}${BOLD}Installation failed.${RESET}"
    echo -e "  Check the output above, fix the issue, then re-run."
}
trap cleanup EXIT

# =============================================================================
# PRE-FLIGHT
# =============================================================================
header "Pre-flight Checks"

[[ $EUID -ne 0 ]]        && die "Run as root"
[[ ! -d /sys/firmware/efi ]] && die "Not booted in UEFI mode"

# ─── Network ──────────────────────────────────────────────────────────────────
info "Checking network..."
if ! ping -c1 -W5 artixlinux.org &>/dev/null; then
    warn "No network — trying to start NetworkManager / connman..."
    rc-service NetworkManager start 2>/dev/null || \
    rc-service connmand        start 2>/dev/null || true
    sleep 3
    ping -c1 -W5 artixlinux.org &>/dev/null || \
        die "No network. Connect first (wifi: nmtui or iwctl)"
fi
success "Network OK"

# ─── Keyrings ─────────────────────────────────────────────────────────────────
info "Refreshing keyrings..."
pacman -Sy --noconfirm 2>&1 | tail -2
pacman -S  --noconfirm --needed artix-keyring archlinux-keyring 2>&1 | tail -2
pacman-key --populate artix archlinux 2>&1 | tail -2
success "Keyrings OK"

# ─── gcc-libs conflict fix ────────────────────────────────────────────────────
# Live ISOs ship the old monolithic gcc-libs; basestrap pulls the new split
# packages (libgcc + libstdc++) which conflict — force-overwrite to resolve
info "Fixing gcc-libs split package conflict..."
pacman -Sy --noconfirm \
    --overwrite '/usr/lib/libgcc*' \
    --overwrite '/usr/lib/libstdc*' \
    gcc-libs 2>&1 | tail -2
success "gcc-libs OK"

# ─── Mirrors ──────────────────────────────────────────────────────────────────
info "Optimising mirrors..."

# Arch mirrorlist for [extra] repo used in chroot
curl -s "https://archlinux.org/mirrorlist/?country=all&protocol=https&use_mirror_status=on" \
    | sed 's/^#Server/Server/' > /etc/pacman.d/mirrorlist-arch

pacman -Sy --noconfirm 2>&1 | tail -2
success "Mirrors OK"

# ─── Prerequisites ────────────────────────────────────────────────────────────
info "Checking prerequisites..."
declare -A CMD_PKG=(
    [sgdisk]=gptfdisk   [cryptsetup]=cryptsetup
    [mkfs.btrfs]=btrfs-progs  [btrfs]=btrfs-progs
    [mkfs.fat]=dosfstools      [partprobe]=parted
    [wget]=wget  [git]=git  [curl]=curl
    [pvcreate]=lvm2  [vgcreate]=lvm2  [lvcreate]=lvm2
)

MISSING=()
for cmd in "${!CMD_PKG[@]}"; do
    command -v "$cmd" &>/dev/null \
        && echo -e "  ${GREEN}✓${RESET}  $cmd" \
        || { echo -e "  ${YELLOW}✗${RESET}  $cmd → ${CMD_PKG[$cmd]}"; MISSING+=("${CMD_PKG[$cmd]}"); }
done

for cmd in basestrap fstabgen artix-chroot; do
    command -v "$cmd" &>/dev/null \
        && echo -e "  ${GREEN}✓${RESET}  $cmd" \
        || die "$cmd not found — run this from the Artix live ISO"
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    MISSING=($(printf '%s\n' "${MISSING[@]}" | sort -u))
    info "Installing: ${MISSING[*]}"
    pacman -S --noconfirm --needed "${MISSING[@]}"
fi
success "Prerequisites OK"

# ─── Clock ────────────────────────────────────────────────────────────────────
info "Syncing clock..."
ntpd -qg 2>/dev/null || sntp -S pool.ntp.org 2>/dev/null || \
    warn "Could not sync clock — continuing with current time"
success "Clock OK"

# =============================================================================
# PROMPTS
# =============================================================================
header "Configuration"

echo ""
info "Available disks:"
lsblk -dpno NAME,SIZE,MODEL | grep -v "loop\|rom\|sr"
echo ""
read -rp "Target disk (e.g. /dev/nvme0n1): " DISK
[[ -b "$DISK" ]] || die "Not a valid block device: $DISK"

if lsblk -no FSTYPE "$DISK" 2>/dev/null | grep -q .; then
    warn "Disk $DISK has existing data — this will WIPE everything on it!"
    read -rp "  Type 'yes' to confirm: " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || die "Aborted."
fi

echo ""
while true; do
    read -rsp "LUKS passphrase: " LUKS_PASS;  echo
    read -rsp "LUKS passphrase (confirm): " P2; echo
    [[ "$LUKS_PASS" == "$P2" ]] && break; warn "Mismatch, try again."
done

echo ""
while true; do
    read -rsp "Root password: " ROOT_PASS;  echo
    read -rsp "Root password (confirm): " P2; echo
    [[ "$ROOT_PASS" == "$P2" ]] && break; warn "Mismatch, try again."
done

echo ""
while true; do
    read -rp "Main username: " USERNAME
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
    warn "Invalid — use lowercase letters, numbers, _ or -"
done
while true; do
    read -rsp "Password for $USERNAME: " USER_PASS;  echo
    read -rsp "Password for $USERNAME (confirm): " P2; echo
    [[ "$USER_PASS" == "$P2" ]] && break; warn "Mismatch, try again."
done

echo ""
read -rp "Hostname [artix]: " HOSTNAME
HOSTNAME="${HOSTNAME:-artix}"

echo ""
echo "  LUKS unlock time:"
echo "    1) 2s  — laptop"
echo "    2) 5s  — balanced (default)"
echo "    3) 10s — desktop"
read -rp "  Select [1/2/3]: " ITER_CHOICE
case "${ITER_CHOICE:-2}" in
    1) ITER_TIME=2000  ;;
    3) ITER_TIME=10000 ;;
    *) ITER_TIME=5000  ;;
esac

# ─── Derived values ───────────────────────────────────────────────────────────
if [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]]; then
    PART_BOOT="${DISK}p1"
    PART_LUKS="${DISK}p2"
else
    PART_BOOT="${DISK}1"
    PART_LUKS="${DISK}2"
fi

RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
RAM_GB=$(( (RAM_KB + 1048575) / 1048576 ))
SWAP_GB=$(awk "BEGIN{printf \"%d\", int($RAM_GB * 1.25 + 0.9999)}")

# ─── Summary ──────────────────────────────────────────────────────────────────
header "Summary"
echo -e "  Disk:      ${BOLD}$DISK${RESET}"
echo -e "  p1 boot:   ${BOLD}1G FAT32 EFI${RESET}"
echo -e "  p2 LUKS:   ${BOLD}remainder${RESET}"
echo -e "    swap:    ${BOLD}${SWAP_GB}G LVM${RESET}"
echo -e "    root:    ${BOLD}rest LVM+Btrfs${RESET}"
echo -e "  Hostname:  ${BOLD}$HOSTNAME${RESET}"
echo -e "  User:      ${BOLD}$USERNAME${RESET}"
echo -e "  LUKS time: ${BOLD}${ITER_TIME}ms${RESET}"
echo -e "  Init:      ${BOLD}OpenRC${RESET}"
echo -e "  DE:        ${BOLD}SDDM + Hyprland + Kitty${RESET}"
echo -e "  Timezone:  ${BOLD}America/Chicago${RESET}"
echo -e "  Locale:    ${BOLD}en_US.UTF-8${RESET}"
echo ""
read -rp "Proceed? [y/N] " GO
[[ "${GO,,}" == "y" ]] || die "Aborted."

# =============================================================================
# PARTITIONING
# =============================================================================
header "Partitioning"

wipefs -af "$DISK"
sgdisk -Z "$DISK"
sgdisk \
    -n 1:0:+1G  -t 1:ef00 -c 1:"EFI" \
    -n 2:0:0    -t 2:8309 -c 2:"LUKS" \
    "$DISK"
partprobe "$DISK"
sleep 2
success "Partitioned"

# =============================================================================
# LUKS + LVM
# =============================================================================
header "LUKS + LVM"

printf '%s' "$LUKS_PASS" | cryptsetup luksFormat \
    --type luks2 --cipher aes-xts-plain64 \
    --key-size 512 --hash sha512 \
    --pbkdf argon2id --iter-time "$ITER_TIME" \
    "$PART_LUKS" -

printf '%s' "$LUKS_PASS" | cryptsetup open "$PART_LUKS" "$LUKS_NAME" -
success "LUKS opened"

pvcreate "$LUKS_DEV"
vgcreate "$VG_NAME" "$LUKS_DEV"
lvcreate -L "${SWAP_GB}G" -n swap "$VG_NAME"
lvcreate -l 100%FREE      -n root "$VG_NAME"
mkswap "$LV_SWAP"
swapon "$LV_SWAP"
success "LVM: swap ${SWAP_GB}G + root remainder"

# =============================================================================
# FILESYSTEMS
# =============================================================================
header "Filesystems"

mkfs.fat -F32 -n EFI "$PART_BOOT"
mkfs.btrfs -L artix "$LV_ROOT"

mount "$LV_ROOT" /mnt
for sv in @ @home @log @pkg; do
    btrfs subvolume create "/mnt/$sv"
done
umount /mnt

BTRFS_OPTS="noatime,compress=zstd:3,space_cache=v2,discard=async"
mount -o "${BTRFS_OPTS},subvol=@"          "$LV_ROOT" /mnt
mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg}
mount -o "${BTRFS_OPTS},subvol=@home"      "$LV_ROOT" /mnt/home
mount -o "${BTRFS_OPTS},subvol=@log"       "$LV_ROOT" /mnt/var/log
mount -o "${BTRFS_OPTS},subvol=@pkg"       "$LV_ROOT" /mnt/var/cache/pacman/pkg
mount "$PART_BOOT" /mnt/boot
success "Filesystems mounted"

# =============================================================================
# BASE INSTALL
# =============================================================================
header "Base Install (will take a while)"

BASE_PKGS=(
    base base-devel
    openrc elogind-openrc
    dbus dbus-openrc
    linux linux-headers linux-firmware
    btrfs-progs cryptsetup lvm2
    grub efibootmgr
    networkmanager networkmanager-openrc
    bluez bluez-openrc
    pipewire pipewire-openrc pipewire-pulse pipewire-pulse-openrc
    pipewire-alsa pipewire-jack wireplumber wireplumber-openrc
    sof-firmware
    sudo neovim nano
    git curl wget
    man-db man-pages bash-completion
)

MAX_RETRIES=5
for attempt in $(seq 1 "$MAX_RETRIES"); do
    if basestrap /mnt "${BASE_PKGS[@]}"; then
        break
    fi
    if [[ $attempt -eq $MAX_RETRIES ]]; then
        die "basestrap failed after $MAX_RETRIES attempts"
    fi
    warn "basestrap failed (attempt $attempt/$MAX_RETRIES) — retrying in 5s..."
    sleep 5
done

success "Base installed"

# =============================================================================
# FSTAB
# =============================================================================
header "fstab"
fstabgen -U /mnt >> /mnt/etc/fstab
success "fstab generated"

# =============================================================================
# CHROOT
# =============================================================================
header "Chroot Configuration"

LUKS_UUID=$(blkid -s UUID -o value "$PART_LUKS")
info "LUKS UUID: $LUKS_UUID"

# Persist both mirrorlists into the new system
mkdir -p /mnt/etc/pacman.d
cp /etc/pacman.d/mirrorlist       /mnt/etc/pacman.d/mirrorlist
cp /etc/pacman.d/mirrorlist-arch  /mnt/etc/pacman.d/mirrorlist-arch

# Write dynamic values to a file the chroot script sources.
# printf '%q' shell-escapes passwords so special chars ($, `, \) survive.
cat > /mnt/root/.install-vars << VARS_EOF
INST_HOSTNAME=$(printf '%q' "$HOSTNAME")
INST_LUKS_UUID=$LUKS_UUID
INST_LUKS_NAME=$LUKS_NAME
INST_LV_ROOT=$LV_ROOT
INST_VG_NAME=$VG_NAME
INST_ROOT_PASS=$(printf '%q' "$ROOT_PASS")
INST_USER_PASS=$(printf '%q' "$USER_PASS")
INST_USERNAME=$(printf '%q' "$USERNAME")
VARS_EOF
chmod 600 /mnt/root/.install-vars

# Quoted heredoc — no variable expansion by the outer shell
cat > /mnt/root/configure.sh << 'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }

# Source installer variables
source /root/.install-vars

# ─── Timezone + locale ────────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
success "Locale configured"

# ─── Hostname ─────────────────────────────────────────────────────────────────
echo "$INST_HOSTNAME" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${INST_HOSTNAME}.localdomain ${INST_HOSTNAME}
EOF
success "Hostname: $INST_HOSTNAME"

# ─── mkinitcpio ───────────────────────────────────────────────────────────────
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems resume fsck)/' \
    /etc/mkinitcpio.conf
mkinitcpio -P
success "initramfs built"

# ─── GRUB ─────────────────────────────────────────────────────────────────────
# /boot is on the unencrypted EFI partition — GRUB_ENABLE_CRYPTODISK is NOT
# needed and would cause a redundant passphrase prompt before the kernel.
GRUB_PARAMS="cryptdevice=UUID=${INST_LUKS_UUID}:${INST_LUKS_NAME} root=${INST_LV_ROOT} rootflags=subvol=@ resume=/dev/${INST_VG_NAME}/swap quiet"
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_PARAMS}\"|" /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=artix --recheck
grub-mkconfig -o /boot/grub/grub.cfg
success "GRUB installed"

# ─── Users ────────────────────────────────────────────────────────────────────
echo "root:${INST_ROOT_PASS}" | chpasswd
useradd -m -G wheel,audio,video,input,storage,optical,network,power \
    -s /bin/bash "$INST_USERNAME"
echo "${INST_USERNAME}:${INST_USER_PASS}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
success "Users configured"

# ─── Services ─────────────────────────────────────────────────────────────────
rc-update add NetworkManager default
rc-update add bluetoothd      default
rc-update add elogind         boot
rc-update add dbus            default
success "System services enabled"

# ─── Pipewire (user services) ────────────────────────────────────────────────
su -l "$INST_USERNAME" -c "rc-update add pipewire default --user"
su -l "$INST_USERNAME" -c "rc-update add pipewire-pulse default --user"
su -l "$INST_USERNAME" -c "rc-update add wireplumber default --user"
success "Pipewire user services enabled"

# ─── Bluetooth ────────────────────────────────────────────────────────────────
mkdir -p /etc/bluetooth
if [[ -f /etc/bluetooth/main.conf ]]; then
    sed -i 's/^#\?AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf
else
    printf '[Policy]\nAutoEnable=true\n' > /etc/bluetooth/main.conf
fi

# ─── Arch [extra] repo for desktop packages ───────────────────────────────────
if ! grep -q "^\[extra\]" /etc/pacman.conf; then
    printf '\n[extra]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >> /etc/pacman.conf
fi
pacman -Sy --noconfirm
pacman -S --noconfirm hyprland sddm sddm-openrc kitty
rc-update add sddm default
success "Desktop installed"

# ─── Cleanup secrets ─────────────────────────────────────────────────────────
rm -f /root/.install-vars

echo ""
echo -e "${GREEN}${BOLD}Chroot done.${RESET}"
CHROOT_SCRIPT

chmod +x /mnt/root/configure.sh
artix-chroot /mnt /root/configure.sh

# =============================================================================
# CLEANUP
# =============================================================================
header "Cleanup"

rm -f /mnt/root/configure.sh /mnt/root/.install-vars
swapoff "$LV_SWAP"          2>/dev/null || true
umount -R /mnt              2>/dev/null || true
vgchange -an "$VG_NAME"     2>/dev/null || true
cryptsetup close "$LUKS_NAME" 2>/dev/null || true
trap - EXIT
success "Unmounted and closed"

# =============================================================================
# DONE
# =============================================================================
header "Installation Complete"
echo ""
echo -e "  ${BOLD}Remove the USB and reboot.${RESET}"
echo ""
echo -e "  GRUB will ask for your LUKS passphrase, then SDDM starts."
echo ""
echo -e "  ${YELLOW}Notes:${RESET}"
echo -e "  • Swap: LVM on LUKS ${SWAP_GB}G — hibernation works"
echo ""
