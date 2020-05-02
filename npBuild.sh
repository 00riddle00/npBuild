#! /usr/bin/env bash

# ======================= VARIABLES =======================

# items = packages, groups (base-devel), metapackages (base)
main_items=(
    "base"
    "base-devel"
    "linux"
    "linux-firmware"
)

additional_items=(
    "dhcpcd"
    "openssh"
    "vim"
    "git"
)

vbox_items=(
    "virtualbox-guest-utils"
)

desktop_items=(
    "virtualbox"
    "virtualbox-host-modules-arch"
)

# ==================== UTILITY FUNCTIONS ====================

mkpart_vbox() {
    parted -s /dev/sda mklabel msdos
    parted -s /dev/sda mkpart primary ext4 1MiB 100%
    parted -s /dev/sda set 1 boot on
}

mkpart_desktop() {
    parted -s /dev/sda mklabel gpt
    parted -s /dev/sda mkpart primary fat32 1MiB 551MiB
    parted -s /dev/sda set 1 esp on
    parted -s /dev/sda mkpart primary linux-swap 551MiB 4.501GiB
    parted -s /dev/sda mkpart primary ext4 4.501GiB 100%
}

allow_sudo_nopasswd() {
    sed -i "s/^%wheel ALL=(ALL) ALL/# %wheel ALL=(ALL) ALL/" /etc/sudoers
    sed -i "s/^# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/" /etc/sudoers
}

disallow_sudo_nopasswd() {
    sed -i "s/^%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/" /etc/sudoers
    sed -i "s/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/" /etc/sudoers
}

# ================= CHROOT FUNCTIONS =================

chroot_setup_system() {
    arch-chroot /mnt /bin/bash <<END
        echo -e "en_US.UTF-8 UTF-8\nlt_LT.UTF-8 UTF-8" >> /etc/locale.gen
        locale-gen
        ln -s /usr/share/zoneinfo/Europe/Vilnius /etc/localtime

        hwclock --systohc

        echo -e "127.0.0.1 localhost\n::1       localhost" > /etc/hosts
        echo vm-"$(head /dev/urandom -c 2 | base64 | cut -c -3)"-arch > /etc/hostname

        mkinitcpio -p linux

        # Make pacman and yay colorful and adds eye candy on the progress bar because why not.
        grep "^Color" /etc/pacman.conf >/dev/null || sed -i "s/^#Color$/Color/" /etc/pacman.conf
        grep "ILoveCandy" /etc/pacman.conf >/dev/null || sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf

        pacman --noconfirm -S grub-bios
        grub-install --recheck /dev/sda
        grub-mkconfig -o /boot/grub/grub.cfg

        useradd -m -G wheel userv
        echo -e "passwd\npasswd\n" | passwd userv

        sed -i "s/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/" /etc/sudoers

        sed -Ei "s/^#? ?(PermitRootLogin).*/\1 no/" /etc/ssh/sshd_config
        sed -Ei "s/^#? ?(PasswordAuthentication).*/\1 yes/" /etc/ssh/sshd_config
        systemctl enable sshd

        systemctl enable "dhcpcd@"$(ip link | awk -F: '$0 !~ "lo|vir|wl|^[^0-9]"{print $2;getline}' | sed 's/ //')""
END
}

chroot_install_pkgs() {
    arch-chroot /mnt /bin/bash <<END
        sh npBuild.sh -f install_pkgs
END
}

chroot_apply_dotfiles() {
    arch-chroot /mnt /bin/bash <<END
        runuser --pty -s /bin/bash -l userv -c "
            curl -o /home/userv/npBuild.sh -LO https://raw.githubusercontent.com/00riddle00/NPbuild/master/npBuild.sh
            chmod +x /home/userv/npBuild.sh
            sh /home/userv/npBuild.sh apply_dotfiles
            rm /home/userv/npBuild.sh
        "
        sh npBuild.sh -f enable_services
END
}

# ================= INSTALL FUNCTIONS =================

install_yay() {
	[ -f "/usr/bin/yay" ] || (
    git clone https://aur.archlinux.org/yay.git /home/$username/yay
    chown -R $username:$username /home/$username/yay
    pacman -S --noconfirm --needed go
    runuser -l "$username" -c "cd /home/$username/yay && makepkg --noconfirm -si"
    rm -rf /home/$username/yay
    )
}

aurinstall() {
    # if a package is not found, skips it
    # if a package is already installed, skips it as well
    runuser -l "$username" -c "yay -S --aur --noconfirm --needed --useask "$1""
}

gitmakeinstall() {
	progname="$(basename "$1" .git)"
	dir="$repodir/$progname"
	sudo -u "$username" git clone --depth 1 "$1" "$dir" || { cd "$dir" || return ; sudo -u "$username" git pull --force origin master;}
	cd "$dir" || exit
	sudo make clean install
    rm -r "$dir"
	cd /tmp || return
}

maininstall() { # Installs all needed programs from main repo.
    # if any package is not found, does not install anything from the list
    # if package is already installed, skips it (shows "up-to date" message)
    sudo pacman -S --noconfirm --needed "$1" || yes | sudo pacman -S --needed "$1" 
}

installationloop() {
    repodir="/home/$username/.local/src"; mkdir -p "$repodir"; sudo chown -R "$username":wheel $(dirname "$repodir")

    install_yay

    # updating the system before installing new software
    pacman -Syu --noconfirm
    runuser --pty -s /bin/bash -l "$username" -c "yay -Sua --noconfirm"

    ([[ -f "$progsfile" ]] && cp "$progsfile" /tmp/progs.csv) || curl -Ls "$progsfile" | sed '/^#/d' > /tmp/progs.csv
    while IFS=, read -r tag program comment; do
        case "$tag" in
            "A") aurinstall "$program" ;;
            "G") gitmakeinstall "$program" ;;
            *) maininstall "$program" ;;
        esac
    done < /tmp/progs.csv

    # cleanup
    rmdir "$repodir" 2> /dev/null || return
}

# ================= STANDALONE FUNCTIONS =================

install_pkgs() {

	[[ -f /etc/sudoers.pacnew ]] && cp /etc/sudoers.pacnew /etc/sudoers # just in case

    allow_sudo_nopasswd

    # Use all cores for compilation (temporarily)
	sed -i "s/-j2/-j$(nproc)/;s/^#MAKEFLAGS/MAKEFLAGS/" /etc/makepkg.conf

    # Synchronizing system time to ensure successful and secure installation of software
    ntpdate 0.us.pool.ntp.org >/dev/null 2>&1

    installationloop

	# Reset makepkg settings
    sed -i "s/-j$(nproc)/-j2/;s/^MAKEFLAGS/#MAKEFLAGS/" /etc/makepkg.conf

    disallow_sudo_nopasswd
}

apply_dotfiles() {
    git clone --recurse-submodules -j8 https://github.com/00riddle00/dotfiles "$HOME/.dotfiles"
    # FIXME hardcoded username
    sed -i "s/^export MAIN_USER=.*/export MAIN_USER=userv/" "$HOME/.dotfiles/.zshenv"
    symlink_dotfiles
    # TODO maybe pass password as argument to this function and else assume paswordless sudo
    # FIXME hardcoded username
    echo "passwd" | sudo -S -u userv chsh -s /bin/zsh
    immutable_files
    build_suckless
    prepare_sublime_text
    strfile "$HOME/.dotfiles/bin/cowsay/rms/rms_say"
    install_vim_plugins
}

symlink_dotfiles() {
    source "$HOME/.dotfiles/.zshenv"

    [[ ! -d "$HOME/.config" ]] && mkdir -p "$HOME/.config"

    [[ ! -d "$XDG_DATA_HOME/applications" ]] && mkdir -p "$XDG_DATA_HOME/applications"

    # $HOME
    for full_path in "$DOTFILES_DIR"/.[a-zA-Z]*; do
        file="$(basename "$full_path")"
        # whenever you iterate over files/folders by globbing, it's good practice to avoid the corner 
        # case where the glob does not match (which makes the loop variable expand to the 
        # (un-matching) glob pattern string itself), hence [[ -e "$full_path" ] is used
        [[ -e "$full_path" ]] && 
            [[ "$file" != ".config" ]] &&
            [[ "$file" != ".local" ]] &&
            [[ "$file" != .git* ]] &&
        ln -sf "$full_path" "$HOME/$file"
    done

    # $XDG_CONFIG_HOME
    for full_path in "$DOTFILES_DIR/.config"/[a-zA-Z]*; do
        file="$(basename "$full_path")"
        [[ -e "$full_path" ]] &&
        ln -sf "$full_path" "$XDG_CONFIG_HOME/$file"
    done

    # ~/.local/bin
    local_bin="$DOTFILES_DIR/.local/bin"
    [[ -e "$local_bin" ]] && ln -sf "$local_bin" "$HOME/.local/bin"

    # ~/.local/share ($XDG_DATA_HOME)
    local_shared="$DOTFILES_DIR/.local/share/riddle00"
    [[ -e "$local_shared" ]] && ln -sf "$local_shared" "$XDG_DATA_HOME/riddle00"

    for full_path in "$DOTFILES_DIR/.local/share/applications"/[a-zA-Z]*; do
        file="$(basename "$full_path")"
        [[ -e "$full_path" ]] &&
        ln -sf $full_path "$XDG_DATA_HOME/applications/$file"
    done
}

unlink_dotfiles() {
    source "$HOME/.dotfiles/.zshenv"

    # $HOME
    for full_path in "$DOTFILES_DIR"/.[a-zA-Z]*; do
        file="$(basename "$full_path")"
        [[ -e "$full_path" ]] && 
        [[ "$file" != ".config" ]] &&
        [[ "$file" != ".local" ]] &&
        [[ "$file" != .git* ]] &&
        # also check if it's symbolic link before deleting
        [[ -L "$HOME/$file" ]] &&
        rm -f "$HOME/$file"
    done

    # $XDG_CONFIG_HOME
    for full_path in "$DOTFILES_DIR/.config"/[a-zA-Z]*; do
        file="$(basename "$full_path")"
        [[ -e "$full_path" ]] &&
        [[ -L "$XDG_CONFIG_HOME/$file" ]] &&
        rm -f "$XDG_CONFIG_HOME/$file"
    done

    # ~/.local/bin
    full_path="$DOTFILES_DIR/.local/bin"
    file="$(basename "$full_path")"
    [[ -e "$full_path" ]] && [[ -L "$HOME/.local/$file" ]] && rm -f "$HOME/.local/$file"

    # ~/.local/share ($XDG_DATA_HOME)
    full_path="$DOTFILES_DIR/.local/share/riddle00"
    file="$(basename "$full_path")"
    [[ -e "$full_path" ]] && [[ -L "$XDG_DATA_HOME/$file" ]] && rm -f "$XDG_DATA_HOME/$file"

    for full_path in "$DOTFILES_DIR/.local/share/applications"/[a-zA-Z]*; do
        file="$(basename "$full_path")"
        [[ -e "$full_path" ]] && [[ -L "$XDG_DATA_HOME/applications/$file" ]] && rm -f "$XDG_DATA_HOME/applications/$file"
    done
}

immutable_files() {
    source "$HOME/.dotfiles/.zshenv"

    echo "passwd" | sudo -S chattr +i "$DOTFILES_DIR/.config/Thunar/accels.scm"
    echo "passwd" | sudo -S chattr +i "$DOTFILES_DIR/.config/filezilla/filezilla.xml"
    echo "passwd" | sudo -S chattr +i "$DOTFILES_DIR/.config/htop/htoprc"
    echo "passwd" | sudo -S chattr +i "$DOTFILES_DIR/.config/mimeapps.list"

    re='^[0-9.]+$'

    for dir in $(ls "$DOTFILES_DIR/.config/GIMP"); do
        if [[ $dir =~ $re ]] ; then
            echo "passwd" | sudo -S chattr +i "$DOTFILES_DIR/.config/GIMP/$dir/menurc"
        fi
    done
}

prepare_sublime_text() {
    source "$HOME/.dotfiles/.zshenv"

    mkdir "$XDG_CONFIG_HOME/sublime-text-3/Installed Packages"
    wget -P "$XDG_CONFIG_HOME/sublime-text-3/Installed Packages" https://packagecontrol.io/Package%20Control.sublime-package
}

install_vim_plugins() {
    source "$HOME/.dotfiles/.zshenv"

    apps=(
        "cmake"
        "git"
        "python"
        "zsh"
    )

    for app in "${apps[@]}"; do
        res="$(pacman -Qqe | grep -E "(^|\s)$app($|\s)")";

        if [ -z "$res" ]; then
            sudo pacman -S --noconfirm "$app"
        fi
    done

    rm -rf "$DOTFILES_DIR/.vim/bundle/Vundle.vim"
    git clone https://github.com/VundleVim/Vundle.vim.git "$DOTFILES_DIR/.vim/bundle/Vundle.vim"
    vim +PluginInstall +qall
    python ~/.vim/bundle/YouCompleteMe/install.py
}

enable_services() {
    systemctl enable --now ntpd
    systemctl --user enable mpd.socket
}

# prerequisites:
# - create passwd for root user in Live CD
# - start sshd service
# - connect to LiveCD via ssh
arch_install_vbox() {
    timedatectl set-ntp true
    mkpart_vbox
    mkfs.ext4 -F /dev/sda1
    mount /dev/sda1 /mnt
    printf -v items_to_install ' %s' "${main_items[@]} ${additional_items[@]} ${vbox_items[@]}"
    pacstrap /mnt "$items_to_install"
    genfstab -U /mnt >> /mnt/etc/fstab
    chroot_setup_system
    curl -o /mnt/npBuild.sh -LO https://raw.githubusercontent.com/00riddle00/NPbuild/master/npBuild.sh
    chroot_install_pkgs
    chroot_apply_dotfiles
    rm /mnt/npBuild.sh
    umount /mnt
    eject -m
    reboot -f
}

arch_install_desktop() {
    echo "not implemented"
}

# ======================= EXECUTION =======================

standalone_functions=(
    "arch_install_vbox"
    "arch_install_desktop"
    "install_pkgs"
    "apply_dotfiles"
    "symlink_dotfiles"
    "unlink_dotfiles"
    "immutable_files"
    "build_suckless"
    "prepare_sublime_text"
    "install_vim_plugins"
    "enable_services"
)

while getopts ":f:u:r:b:p:h" opt; do 
    case "${opt}" in
        f) function=${OPTARG} ;;
        u) username=${OPTARG} ;;
        r) dotfilesrepo=${OPTARG} && git ls-remote "$dotfilesrepo" || exit ;;
        b) repobranch=${OPTARG} ;;
        p) progsfile=${OPTARG} ;;
        h) printf "
        -f  [Required] Name of the function to be run.
                List of standalone functions:
                    'arch_install_vbox',
                    'arch_install_desktop',
                    'install_pkgs',
                    'apply_dotfiles',
                    'symlink_dotfiles',
                    'unlink_dotfiles',
                    'immutable_files',
                    'build_suckless',
                    'prepare_sublime_text',
                    'install_vim_plugins',
                    'enable_services'.

        -u  [Optional] User name
        -r  [Optional] Dotfiles repository (local file or url)
        -b  [Optional] Branch of the repo
        -p  [Optional] Dependencies and programs csv (local file or url)
        -h  Show help\\n" 
        exit ;;
        *) printf "Invalid option: -%s\\n" "$OPTARG" && exit ;;
    esac
done

[[ -z "$username" ]] && username="riddle"
[[ -z "$dotfilesrepo" ]] && dotfilesrepo="https://github.com/00riddle00/dotfiles"
#[[ -z "$progsfile" ]] && progsfile="https://raw.githubusercontent.com/00riddle00/NPbuild/master/progs.csv"
[[ -z "$progsfile" ]] && progsfile="progs.csv"
[[ -z "$repobranch" ]] && repobranch="master"

if [[ -n "$function" ]]; then
    if [[ " ${standalone_functions[@]} " =~ " ${function} " ]]; then
        eval "$function" 
    else
        echo "ERR: The function '$function' does not exist as standalone"
    fi
else
    echo "ERR: no function passed to the script"
fi

