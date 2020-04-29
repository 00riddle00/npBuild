#!/bin/bash
# TODO change above possibly to /bin/sh

# ======================= VARIABLES =======================

# items = packages, groups (base-devel), metapackages (base)
main_items=(
    "base"
    "base-devel"
    "linux"
    "linux-firmware"
)

additional_items=(
    "vim"
    "dhcpcd"
    "openssh"
    "git"
)

vbox_items=(
    "virtualbox-guest-utils"
)

desktop_items=()

# ==================== UTILITY FUNCTIONS ====================

mkpart_vbox() {
    parted -s /dev/sda mklabel msdos
    parted -s /dev/sda mkpart "primary" "ext4" "0%" "100%"
    parted -s /dev/sda set 1 boot on
}

mkpart_desktop() {
    echo "empty so far"
}

allow_sudo_nopasswd() {
    sed -i "s/^%wheel ALL=(ALL) ALL/# %wheel ALL=(ALL) ALL/" /etc/sudoers
    sed -i "s/^# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/" /etc/sudoers
}

disallow_sudo_nopasswd() {
    sed -i "s/^%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/" /etc/sudoers
    sed -i "s/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/" /etc/sudoers
}

# ================= CHROOT UTILITY FUNCTIONS =================

chroot_setup_system() {
    arch-chroot /mnt /bin/bash <<END
        echo -e "en_US.UTF-8 UTF-8\nlt_LT.UTF-8 UTF-8" >> /etc/locale.gen
        locale-gen
        ln -s /usr/share/zoneinfo/Europe/Vilnius /etc/localtime

        hwclock --systohc

        echo -e "127.0.0.1 localhost\n::1       localhost" > /etc/hosts
        echo vm-$(head /dev/urandom -c 2 | base64 | cut -c -3)-arch > /etc/hostname

        mkinitcpio -p linux

        pacman --noconfirm -S grub-bios
        grub-install --recheck /dev/sda
        grub-mkconfig -o /boot/grub/grub.cfg

        useradd -m -G wheel userv
        echo -e "passwd\npasswd\n" | passwd userv

        sed -i "s/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/" /etc/sudoers

        sed -Ei "s/^#? ?(PermitRootLogin).*/\1 no/" /etc/ssh/sshd_config
        sed -Ei "s/^#? ?(PasswordAuthentication).*/\1 yes/" /etc/ssh/sshd_config
        systemctl enable sshd

        systemctl enable "dhcpcd@$(ip link | awk -F: '$0 !~ "lo|vir|wl|^[^0-9]"{print $2;getline}' | sed 's/ //')"
END
}

chroot_install_pkgs() {
    arch-chroot /mnt /bin/bash <<END
        sh np_build.sh install_pkgs
END
}

chroot_apply_dotfiles() {
    arch-chroot /mnt /bin/bash <<END
        runuser --pty -s /bin/bash -l userv -c "
            curl -o /home/userv/np_build.sh -LO https://raw.githubusercontent.com/00riddle00/NPbuild/master/np_build.sh
            chmod +x /home/userv/np_build.sh
            sh /home/userv/np_build.sh apply_dotfiles
            rm /home/userv/np_build.sh
        "
        sh np_build.sh enable_services
END
}

# ================= STANDALONE FUNCTIONS =================

# TODO maybe run this as user, not as root 
install_pkgs() {

    allow_sudo_nopasswd

    # get pacman package list
    curl -LO https://raw.githubusercontent.com/00riddle00/NPbuild/master/pkgs_main_repos.md

    sudo pacman -Syu --noconfirm
    # if any package is not found, does not install anything from the list
    # if package is already installed, skips it (shows "up-to date" message)
    #
    ## temp solution to avoid gvim/vim conflict pacman prompt
    sudo pacman -R --noconfirm vim
    sudo pacman -S --noconfirm --needed - < pkgs_main_repos.md

    # install yay
    git clone https://aur.archlinux.org/yay.git /home/userv/yay
    chown -R userv:userv /home/userv/yay
    pacman -S --noconfirm go
    runuser -l userv -c "cd /home/userv/yay && makepkg --noconfirm -si"
    runuser -l userv -c "rm -rf /home/userv/yay"

    # get aur package list
    curl -o /home/userv/pkgs_aur.md -LO https://raw.githubusercontent.com/00riddle00/NPbuild/master/pkgs_aur.md
    chown userv:userv /home/userv/pkgs_aur.md

    # if a package is not found, skips it
    # if a package is already installed, skips it as well
    runuser --pty -l userv -c "yay -Syu --noconfirm"
    runuser --pty -l userv -c "yay -S --aur --noconfirm --useask - < /home/userv/pkgs_aur.md"

    rm /pkgs_main_repos.md
    rm /home/userv/pkgs_aur.md

    disallow_sudo_nopasswd
}

apply_dotfiles() {
    git clone --recurse-submodules -j8 https://github.com/00riddle00/dotfiles $HOME/.dotfiles
    # FIXME hardcoded username
    sed -i "s/^export MAIN_USER=.*/export MAIN_USER=userv/" $HOME/.dotfiles/.zshenv
    symlink_dotfiles
    # TODO maybe pass password as argument to this function and else assume paswordless sudo
    # FIXME hardcoded username
    echo "passwd" | sudo -S -u userv chsh -s /bin/zsh
    immutable_files
    build_suckless
    prepare_sublime_text
    strfile $HOME/.dotfiles/bin/cowsay/rms/rms_say
    install_vim_plugins
}

symlink_dotfiles() {
    source $HOME/.dotfiles/.zshenv

    if [ ! -d $HOME/.config ]; then
          mkdir -p $HOME/.config;
    fi

    if [ ! -d $HOME/.local/share/applications ]; then
          mkdir -p $HOME/.local/share/applications;
    fi

    # $HOME dir
    for entry in $DOTFILES_DIR/.[a-zA-Z]*; do
        # whenever you iterate over files/folders by globbing, it's good practice to avoid the corner 
        # case where the glob does not match (which makes the loop variable expand to the 
        # (un-matching) glob pattern string itself), hence [ -e "$entry" ] is used
        [ -e "$entry" ] && 
            [[ ${entry##*/} != ".config" ]] &&
            [[ ${entry##*/} != ".local" ]] &&
            [[ ${entry##*/} != .git* ]] &&
        ln -sf $entry $HOME/${entry##*/}
    done

    # $XDG_CONFIG_HOME dir
    for entry in $DOTFILES_DIR/.config/[a-zA-Z]*; do
        [ -e "$entry" ] &&
        ln -sf $entry $XDG_CONFIG_HOME/${entry##*/}
    done

    # $XDG_DATA_HOME dir
    local_bin="$DOTFILES_DIR/.local/bin"
    [ -e "$local_bin" ] && ln -sf $local_bin $HOME/.local/bin

    local_shared="$DOTFILES_DIR/.local/share/riddle00"
    [ -e "$local_shared" ] && ln -sf $local_shared $XDG_DATA_HOME/riddle00

    for entry in $DOTFILES_DIR/.local/share/applications/[a-zA-Z]*; do
        [ -e "$entry" ] &&
        ln -sf $entry $XDG_DATA_HOME/applications/${entry##*/}
    done
}

unlink_dotfiles() {
    source $HOME/.dotfiles/.zshenv

    # $HOME dir
    for entry in $DOTFILES_DIR/.[a-zA-Z]*; do
        [ -e "$entry" ] && 
            [[ ${entry##*/} != ".config" ]] &&
            [[ ${entry##*/} != ".local" ]] &&
            [[ ${entry##*/} != .git* ]] &&
        # also check if it's symbolic link before deleting
        [ -L "$HOME/${entry##*/}" ] &&
        rm -rf $HOME/${entry##*/}
    done

    # $XDG_CONFIG_HOME dir
    for entry in $DOTFILES_DIR/.config/[a-zA-Z]*; do
        [ -e "$entry" ] &&  [ -L "$XDG_CONFIG_HOME/${entry##*/}" ] && rm -rf $XDG_CONFIG_HOME/${entry##*/}
    done

    # $XDG_DATA_HOME dir
    local_bin="$DOTFILES_DIR/.local/bin"
    [ -e "$local_bin" ] &&  [ -L "$HOME/.local/${local_bin##*/}" ] && rm -rf $HOME/.local/${local_bin##*/}

    local_shared="$DOTFILES_DIR/.local/share/riddle00"
    [ -e "$local_shared" ] &&  [ -L "$XDG_DATA_HOME/${local_shared##*/}" ] && rm -rf $XDG_DATA_HOME/${local_shared##*/}

    for entry in $DOTFILES_DIR/.local/share/applications/[a-zA-Z]*; do
        [ -e "$entry" ] &&
        [ -L "$XDG_DATA_HOME/applications/${entry##*/}" ] &&
        rm -rf $XDG_DATA_HOME/applications/${entry##*/}
    done
}

immutable_files() {
    source $HOME/.dotfiles/.zshenv

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

build_suckless() {
    mkdir -p ~/tmp1/

    git clone https://github.com/00riddle00/dwm ~/tmp1/dwm
    cd ~/tmp1/dwm
    echo "passwd" | sudo make clean install

    git clone https://github.com/00riddle00/dwmblocks ~/tmp1/dwmblocks
    cd ~/tmp1/dwmblocks
    echo "passwd" | sudo make clean install

    git clone https://github.com/00riddle00/dmenu ~/tmp1/dmenu
    cd ~/tmp1/dmenu
    echo "passwd" | sudo make clean install

    git clone https://github.com/00riddle00/st ~/tmp1/st
    cd ~/tmp1/st
    echo "passwd" | sudo make clean install

    rm -rf ~/tmp1
}

prepare_sublime_text() {
    source $HOME/.dotfiles/.zshenv

    mkdir "$XDG_CONFIG_HOME/sublime-text-3/Installed Packages"
    wget -P "$XDG_CONFIG_HOME/sublime-text-3/Installed Packages" https://packagecontrol.io/Package%20Control.sublime-package
}

install_vim_plugins() {
    source $HOME/.dotfiles/.zshenv

    apps=(
        "cmake"
        "git"
        "python"
        "zsh"
    )

    for app in "${apps[@]}"; do
        res=$(pacman -Qqe | grep -E "(^|\s)$app($|\s)");

        if [ -z "$res" ]; then
            sudo pacman -S --noconfirm $app
        fi
    done

    rm -rf $DOTFILES_DIR/.vim/bundle/Vundle.vim
    git clone https://github.com/VundleVim/Vundle.vim.git $DOTFILES_DIR/.vim/bundle/Vundle.vim
    vim +PluginInstall +qall
    python ~/.vim/bundle/YouCompleteMe/install.py
}

enable_services() {
    systemctl enable --now ntpd
    systemctl --user enable mpd.socket
}

# ==================== INSTALL FUNCTIONS ====================

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
    pacstrap /mnt $items_to_install
    genfstab -U /mnt >> /mnt/etc/fstab
    chroot_setup_system
    curl -o /mnt/np_build.sh -LO https://raw.githubusercontent.com/00riddle00/NPbuild/master/np_build.sh
    chroot_install_pkgs
    chroot_apply_dotfiles
    rm /mnt/np_build.sh
    umount /mnt
    eject -m
    reboot -f
}

arch_install_desktop() {
    echo "not implemented"
}

# ======================= EXECUTION =======================

if [ "$#" -ne 1 ]; then
    echo "Exactly one argument (=function name) should be passed to this script"
    exit 1
fi

case "$1" in 
    arch_install_vbox) arch_install_vbox;; 
    arch_install_desktop) arch_install_desktop;; 
    install_pkgs) install_pkgs;; 
    apply_dotfiles) apply_dotfiles;; 
    symlink_dotfiles) symlink_dotfiles;; 
    unlink_dotfiles) unlink_dotfiles;; 
    immutable_files) immutable_files;; 
    build_suckless) build_suckless;; 
    prepare_sublime_text) prepare_sublime_text;; 
    install_vim_plugins) install_vim_plugins;; 
    enable_services) enable_services;; 
    *) echo "ERR: no such function"
esac 
