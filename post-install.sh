#!/usr/bin/env bash
# =============================================================================
# Post-Install Package Setup
# Run as your main user (NOT root) after first boot into Artix
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

[[ $EUID -eq 0 ]] && die "Run as your regular user, not root."

# paru resolves both official repos and AUR transparently
install() { paru -S --noconfirm --needed "$@"; }

# =============================================================================
# REPOS
# =============================================================================
header "Configuring Repositories"

# [extra] — Arch packages not in Artix repos
if ! grep -q "^\[extra\]" /etc/pacman.conf; then
    sudo tee -a /etc/pacman.conf > /dev/null << 'EOF'

[extra]
Include = /etc/pacman.d/mirrorlist-arch
EOF
fi

# [multilib] — required for Steam 32-bit libs
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    sudo tee -a /etc/pacman.conf > /dev/null << 'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist-arch
EOF
fi

# [universe] — Artix community repo
if ! grep -q "^\[universe\]" /etc/pacman.conf; then
    sudo tee -a /etc/pacman.conf > /dev/null << 'EOF'

[universe]
Server = https://universe.artixlinux.org/$arch
EOF
fi

# Refresh mirrorlist-arch globally (no country filter — works anywhere)
curl -s "https://archlinux.org/mirrorlist/?country=all&protocol=https&use_mirror_status=on" \
    | sed 's/^#Server/Server/' \
    | sudo tee /etc/pacman.d/mirrorlist-arch > /dev/null

sudo pacman -Sy --noconfirm
success "Repos configured"

# =============================================================================
# PARU
# =============================================================================
header "Installing paru"

if ! command -v paru &>/dev/null; then
    sudo pacman -S --noconfirm --needed git base-devel
    tmp=$(mktemp -d)
    git clone https://aur.archlinux.org/paru.git "$tmp/paru"
    (cd "$tmp/paru" && makepkg -si --noconfirm)
    rm -rf "$tmp"
    success "paru installed"
else
    success "paru already present"
fi

# =============================================================================
# BASE SYSTEM
# =============================================================================
header "Base System"

install \
    base-devel linux-headers linux-firmware amd-ucode \
    btrfs-progs lvm2 efibootmgr grub grub-btrfs \
    fwupd dkms smartmontools dmidecode \
    usbutils pciutils man-db inotify-tools \
    exfatprogs cronie sysstat lm_sensors

sudo rc-update add cronie default
sudo rc-service cronie start 2>/dev/null || true
success "Base system installed"

# =============================================================================
# NETWORKING & SECURITY
# =============================================================================
header "Networking & Security"

install \
    openssh nmap mtr traceroute bind socat sshfs \
    nss-mdns dnsmasq tailscale cloudflared \
    wireshark-qt strace tcsh iw

sudo rc-update add tailscale default
sudo rc-service tailscale start 2>/dev/null || true
sudo usermod -aG wireshark "$USER"
success "Networking installed"

# =============================================================================
# SHELL & CLI TOOLS
# =============================================================================
header "Shell & CLI Tools"

install \
    zsh zoxide fzf fd bat lsd yazi \
    btop ncdu duf iotop tmux \
    neovim nano nano-syntax-highlighting \
    git wget curl jq bc pv parallel \
    tree unzip unrar zip 7zip aria2 \
    reflector pacman-contrib \
    the_silver_searcher thefuck \
    figlet lolcat cmatrix cowsay fastfetch \
    meson ninja patchelf perl-rename \
    tk luarocks imagemagick pandoc-bin

chsh -s /bin/zsh "$USER"
success "Shell & CLI tools installed"

# =============================================================================
# DESKTOP ENVIRONMENT
# =============================================================================
header "Desktop Environment"

install \
    hyprland hypridle hyprlock hyprpicker hyprpaper uwsm \
    sddm sddm-openrc \
    kitty konsole \
    waybar swaync swayosd cliphist \
    grim slurp satty wtype ydotool wlr-randr \
    nwg-displays nwg-drawer \
    xdg-desktop-portal-hyprland xdg-desktop-portal-gtk xdg-utils \
    polkit-gnome network-manager-applet libnotify \
    qt5-wayland qt5ct qt6-wayland qt6ct xsettingsd \
    adw-gtk-theme \
    noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra \
    ttf-jetbrains-mono-nerd maplemono-nf-cn \
    numix-circle-icon-theme-git archlinux-xdg-menu \
    matugen-bin awww gslapper \
    imv mpv vlc vlc-plugins-all gst-plugin-pipewire


success "Desktop environment installed"

# =============================================================================
# AUDIO
# =============================================================================
header "Audio"

install \
    pipewire pipewire-alsa pipewire-jack pipewire-pulse \
    wireplumber libpulse pwvucontrol

success "Audio installed"

# =============================================================================
# FONTS & INPUT (CJK)
# =============================================================================
header "CJK Input"

install \
    fcitx5 fcitx5-chinese-addons fcitx5-configtool \
    fcitx5-gtk fcitx5-mozc fcitx5-qt

if ! grep -q "XMODIFIERS" /etc/environment 2>/dev/null; then
    sudo tee -a /etc/environment > /dev/null << 'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF
fi
success "CJK input installed"

# =============================================================================
# DEVELOPMENT
# =============================================================================
header "Development Tools"

install \
    nodejs-lts-jod npm python312 python311 \
    docker docker-compose \
    qemu-full libvirt virt-manager \
    vscodium sqlitebrowser \
    openrgb claude-code opencode

sudo usermod -aG docker  "$USER"
sudo usermod -aG libvirt "$USER"
sudo rc-update add docker   default;  sudo rc-service docker   start 2>/dev/null || true
sudo rc-update add libvirtd default;  sudo rc-service libvirtd start 2>/dev/null || true
success "Dev tools installed"

# =============================================================================
# GAMING
# =============================================================================
header "Gaming"

install \
    steam gamescope mangohud protonup-qt \
    osu-lazer-bin prismlauncher

success "Gaming installed"

# =============================================================================
# PRODUCTIVITY & OFFICE
# =============================================================================
header "Productivity & Office"

install \
    obsidian libreoffice-still gimp inkscape \
    cups cups-pdf xournalpp calcurse \
    zathura zathura-pdf-mupdf texlive-latex \
    flatpak

sudo rc-update add cupsd default
sudo rc-service cupsd start 2>/dev/null || true
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
success "Productivity installed"

# =============================================================================
# APPLICATIONS
# =============================================================================
header "Applications"

install \
    obs-studio qbittorrent \
    kdeconnect kde-cli-tools ark dolphin dolphin-plugins \
    gnome-disk-utility gparted \
    bitwarden timeshift \
    powertop power-profiles-daemon brightnessctl \
    bluez bluez-utils bluetui \
    cava kdenlive \
    vesktop zen-browser-bin localsend feishin

sudo rc-update add power-profiles-daemon default
sudo rc-service power-profiles-daemon start 2>/dev/null || true
success "Applications installed"

# =============================================================================
# WALKER + ELEPHANT PROVIDERS
# =============================================================================
header "Walker + Elephant"

install \
    walker-bin \
    elephant-bin elephant-bluetooth-bin elephant-calc-bin \
    elephant-clipboard-bin elephant-desktopapplications-bin \
    elephant-menus-bin elephant-providerlist-bin \
    elephant-runner-bin elephant-websearch-bin

success "Walker + providers installed"

# =============================================================================
# ZRAM (OpenRC)
# =============================================================================
header "zram"

install zramswap-openrc

if [[ ! -f /etc/conf.d/zramswap ]]; then
    sudo tee /etc/conf.d/zramswap > /dev/null << 'EOF'
ZRAM_SIZE=4096
ZRAM_ALGORITHM=zstd
EOF
fi
sudo rc-update add zramswap boot
success "zram configured (4G, zstd)"

# =============================================================================
# SYSTEM CONFIG
# =============================================================================
header "System Configuration"

# mDNS — .local hostnames for KDE Connect etc.
if ! grep -q "mdns_minimal" /etc/nsswitch.conf 2>/dev/null; then
    sudo sed -i \
        's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' \
        /etc/nsswitch.conf
fi

# powertop auto-tune on boot
sudo tee /etc/local.d/powertop.start > /dev/null << 'EOF'
#!/bin/sh
powertop --auto-tune
EOF
sudo chmod +x /etc/local.d/powertop.start

success "System config done"

# =============================================================================
# DONE
# =============================================================================
header "Post-Install Complete"
echo ""
echo -e "  ${YELLOW}Remaining manual steps:${RESET}"
echo ""
echo -e "  ${BOLD}1. GPU drivers${RESET}"
echo -e "     bash setup-gpu.sh"
echo ""
echo -e "  ${BOLD}2. CachyOS kernel${RESET}  (do last, after everything works)"
echo -e "     paru -S cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist"
echo -e "     paru -S linux-cachyos-bore linux-cachyos-bore-headers scx-scheds proton-cachyos"
echo -e "     sudo grub-mkconfig -o /boot/grub/grub.cfg"
echo ""
echo -e "  ${BOLD}3. Reboot${RESET}  — group changes (docker, libvirt, wireshark) need a fresh login"
echo ""
echo -e "  ${BOLD}4. fcitx5${RESET}  — run fcitx5-configtool to configure input methods"
echo ""
echo -e "  ${BOLD}5. Tailscale${RESET}  — sudo tailscale up"
echo ""
echo -e "  ${BOLD}6. Syncthing${RESET}  — paru -S syncthing && sudo rc-update add syncthing default"
echo ""
