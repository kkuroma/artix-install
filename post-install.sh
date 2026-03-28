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

# ─── Resilient installer ─────────────────────────────────────────────────────
# Tries the full batch first (fast). If anything in the batch fails, falls back
# to installing each package individually so one bad package doesn't block the
# rest. All failures are collected and reported at the end.
ALL_FAILED=()

install() {
    local pkgs=("$@")
    local failed=()

    if yay -S --noconfirm --needed "${pkgs[@]}" 2>&1; then
        return 0
    fi

    warn "Batch failed — retrying packages one by one..."
    for pkg in "${pkgs[@]}"; do
        if ! yay -S --noconfirm --needed "$pkg" 2>&1; then
            warn "  ✗ $pkg"
            failed+=("$pkg")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        ALL_FAILED+=("${failed[@]}")
    fi
    return 0
}

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
# YAY (AUR helper)
# =============================================================================
header "Installing yay"

if ! command -v yay &>/dev/null; then
    sudo pacman -S --noconfirm --needed git base-devel
    tmp=$(mktemp -d)
    git clone https://aur.archlinux.org/yay.git "$tmp/yay"
    (cd "$tmp/yay" && makepkg -si --noconfirm)
    rm -rf "$tmp"
    success "yay installed"
else
    success "yay already present"
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
    exfatprogs cronie cronie-openrc sysstat lm_sensors \
    htop vim mesa-utils memtest86+ memtest86+-efi \
    archlinux-contrib

sudo rc-update add cronie default
sudo rc-service cronie start 2>/dev/null || true
success "Base system installed"

# =============================================================================
# NETWORKING & SECURITY
# =============================================================================
header "Networking & Security"

install \
    openssh openssh-openrc \
    nmap mtr traceroute bind socat sshfs \
    nss-mdns dnsmasq tailscale tailscale-openrc cloudflared \
    wireshark-qt strace tcsh iw iwd \
    wireless_tools wpa_supplicant

sudo rc-update add tailscaled default
sudo rc-service tailscaled start 2>/dev/null || true
sudo tailscale set --operator="$USER" 2>/dev/null || true
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
    tk luarocks imagemagick pandoc-bin \
    ex-vi-compat shntool speech-dispatcher tint

sudo chsh -s /bin/zsh "$USER"
success "Shell & CLI tools installed"

# =============================================================================
# DESKTOP ENVIRONMENT
# =============================================================================
header "Desktop Environment"

install \
    hyprland hypridle hyprlock hyprpicker uwsm \
    sddm sddm-openrc \
    kitty konsole \
    waybar swaync swayosd cliphist \
    grim slurp satty wtype ydotool wlr-randr \
    nwg-displays nwg-drawer \
    xdg-desktop-portal-hyprland xdg-desktop-portal-gtk xdg-utils \
    polkit-gnome network-manager-applet libnotify \
    qt5-wayland qt5ct qt6-wayland qt6ct xsettingsd \
    adw-gtk-theme gnome-settings-daemon \
    noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra \
    ttf-jetbrains-mono-nerd maplemono-nf-cn \
    numix-circle-icon-theme-git archlinux-xdg-menu \
    matugen-bin awww gslapper \
    imv mpv vlc vlc-plugins-all gst-plugin-pipewire \
    plymouth glfw kclock \
    gtk3-demos gtk4-demos \
    kf6-servicemenus-reimage \
    xorg-server xorg-xhost xorg-xinit

success "Desktop environment installed"

# =============================================================================
# AUDIO
# =============================================================================
header "Audio"

install \
    pipewire \
    pipewire-alsa pipewire-jack pipewire-pulse \
    wireplumber \
    libpulse pwvucontrol

# pipewire + wireplumber run as user-level services, started automatically
# by the desktop session (uwsm / hyprland). No OpenRC service needed.
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
    vscodium-bin sqlitebrowser \
    openrgb opencode claude-code \
    freecad pinta lmms puddletag upscayl-bin

success "Dev tools installed"

# =============================================================================
# VIRTUALIZATION
# =============================================================================
header "Virtualization"

install \
    docker docker-openrc docker-compose \
    qemu-full libvirt libvirt-openrc virt-manager \
    edk2-ovmf iptables-nft dnsmasq

sudo usermod -aG docker  "$USER"
sudo usermod -aG libvirt "$USER"
sudo rc-update add docker   default
sudo rc-update add libvirtd default
sudo rc-service docker   start 2>/dev/null || true
sudo rc-service libvirtd start 2>/dev/null || true

# Enable default NAT network for libvirt VMs
if sudo virsh net-info default &>/dev/null; then
    sudo virsh net-autostart default 2>/dev/null || true
    sudo virsh net-start default 2>/dev/null || true
fi
success "Virtualization installed"

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
    cups cups-openrc cups-pdf xournalpp calcurse \
    zathura zathura-pdf-mupdf \
    flatpak

# TeX Live — full set matching the source system
install \
    texlive-basic texlive-latex texlive-latexextra texlive-latexrecommended \
    texlive-fontsextra texlive-fontsrecommended texlive-fontutils \
    texlive-bibtexextra texlive-binextra texlive-context \
    texlive-formatsextra texlive-games texlive-humanities \
    texlive-luatex texlive-mathscience texlive-metapost \
    texlive-music texlive-pictures texlive-plaingeneric \
    texlive-pstricks texlive-publishers texlive-xetex

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
    powertop power-profiles-daemon power-profiles-daemon-openrc brightnessctl \
    bluez bluez-utils bluetui \
    cava kdenlive \
    vesktop-bin zen-browser-bin localsend-bin feishin-bin \
    syncthing

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

# ─── Report failures ─────────────────────────────────────────────────────────
if [[ ${#ALL_FAILED[@]} -gt 0 ]]; then
    echo ""
    warn "The following packages failed to install:"
    printf "  ${RED}✗${RESET}  %s\n" "${ALL_FAILED[@]}"
    echo ""
    echo -e "  You can retry them manually:  ${BOLD}yay -S ${ALL_FAILED[*]}${RESET}"
fi

echo ""
echo -e "  ${YELLOW}Remaining manual steps:${RESET}"
echo ""
echo -e "  ${BOLD}1. CachyOS kernel${RESET}  (do last, after everything works)"
echo -e "     yay -S cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist"
echo -e "     yay -S linux-cachyos-bore linux-cachyos-bore-headers scx-scheds proton-cachyos"
echo -e "     sudo grub-mkconfig -o /boot/grub/grub.cfg"
echo ""
echo -e "  ${BOLD}2. Reboot${RESET}  — group changes (docker, libvirt, wireshark) need a fresh login"
echo ""
echo -e "  ${BOLD}3. fcitx5${RESET}  — run fcitx5-configtool to configure input methods"
echo ""
echo -e "  ${BOLD}4. Tailscale${RESET}  — sudo tailscale up"
echo ""
