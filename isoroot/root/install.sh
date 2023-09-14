#! /usr/bin/zsh
mountedroot=/mnt/archinstall
arins_cnf='user_configuration.json'
arins_users='user_credentials.json'
mirrorlist=/etc/pacman.d/mirrorlist

set -e

sed 's/#ParallelDownloads/ParallelDownloads/' -i /etc/pacman.conf

sortedmirrors() {
  echo -n 'getting country...' &&\
  country=$(geoiplookup $(curl -s http://icanhazip.com) | awk -F ': ' '{print $2}' | cut -d ',' -f1) &&\
  echo "$country" &&\
  echo 'downloading latest mirrors' &&\
  curl -s 'https://archlinux.org/mirrorlist/?country='$country'&use_mirror_status=on' |\
  sed -e 's/^#//' -e '/^#/d' -e '/^$/d' | tee "$1" &&\
  echo 'ranking mirrors...' &&\
  rankmirrors -n 12 "$1" | sponge "$1" &&\
  cat $1
}

sortedmirrors "$mirrorlist"

# getting metainfo
metainfo_dev=$(lsblk --noheadings --output=LABEL,PATH | awk '/metainfo/ {print $2}')
if [ -b "$metainfo_dev" ]; then
  mount -m -o ro $metainfo_dev /mnt/metainfo &&\
  . "$_/vm_detail" &&\
  [ -n "$VMNAME" ] &&\
  jq ".hostname = \"$VMNAME\"" "$arins_cnf" | sponge "$arins_cnf"
fi

# prepare n2nconfs
n2nconfs=~/fakeroot/etc/n2n
declare -a n2nedges=()
for file in $(find "$n2nconfs" -name 'edge-*.conf' -printf '%f\n'); do
  conf_name=("$(echo "$file" | sed 's/^edge-//;s/.conf$//')")
  jq ".services += [\"edge@$conf_name.service\"]" $arins_cnf | sponge "$arins_cnf"
done

# install the archlinux to /dev/sda
time archinstall \
  --config "$arins_cnf" \
  --creds "$arins_users" \
  || exit 1
  #--silent \

# install preconfiguration to archlinux
[ -n "$(ls -A 'fakeroot/')" ] &&\
(cp -r 'fakeroot/'* $mountedroot || exit 1)
sed 's|#MulticastDNS=.*|MulticastDNS=yes|' -i "$mountedroot/etc/systemd/resolved.conf"
sed 's/ ALL$/ NOPASSWD:ALL/1' -i "$mountedroot/etc/sudoers.d/"*

test ! -d "$mountedroot/root/.ssh" && mkdir "$_"
cp -r ~/.ssh/authorized_keys "$mountedroot/root/.ssh"
chroot=(arch-chroot "$mountedroot")
for user in $(ls "$mountedroot/home");do
  user_home="$mountedroot/home/$user"
  test ! -d "$user_home/.ssh" && mkdir "$_"
  cp ~/.ssh/authorized_keys "$user_home/.ssh"
  cp ~/zshrc "$user_home/.zshrc"
  cp ~/p10k.zsh "$user_home/.p10k.zsh"
  mkdir -p "$user_home/.config/tmux"
  cp ~/tmux.conf "$_/tmux.conf"
  $chroot chown $user:$user -R "/home/$user"

  su=($chroot su $user)
  sudo=($chroot sudo -iu $user)
  $chroot chsh $user --shell /usr/bin/zsh
  # https://github.com/hedzr/mirror-list#%E4%BD%BF%E7%94%A8-github-%E9%95%9C%E5%83%8F%E7%BD%91%E7%AB%99
  $sudo git config --global url.'https://hub.nuaa.cf'.insteadOf 'https://github.com'
  $sudo TMUX=no source .zshrc
  $sudo git clone https://aur.archlinux.org/yay.git
  $su -c 'cd ~/yay && (until GOPROXY=goproxy.io,direct makepkg -si --noconfirm; do; done;)'
  $su -c 'git clone https://github.com/tmux-plugins/tpm ~/.config/tmux/plugins/tpm' &&\
  $su -c '~/.config/tmux/plugins/tpm/scripts/install_plugins.sh'
  rm -rf "$user_home/.gitconfig" "$user_home/.cache" "$user_home/.subversion" "$user_home/.bash"* "$user_home/.zcompdump"* "$user_home/yay"
  $sudo ls -lha
done

rm -r "$mountedroot/var/cache/pacman/pkg/"*
$chroot pacman -Scc --noconfirm

# try clear filesystem
$chroot fstrim -v /
$chroot btrfs filesystem defragment -r /
$chroot btrfs balance start --full-balance /

# remove hold
if [ -v 'VMNAME' ]; then
  $chroot dd if='/dev/zero' of="/zerofile" status=progress ||\
  $chroot sync && $chroot rm -f "/zerofile" && $chroot sync
fi

btrfs subvolume snapshot -r "/mnt/archinstall" "/mnt/archinstall/.snapshots/@-0"
btrfs subvolume snapshot -r "/mnt/archinstall/home" "/mnt/archinstall/.snapshots/@home-0"
btrfs subvolume snapshot -r "/mnt/archinstall/var/cache/pacman/pkg" "/mnt/archinstall/.snapshots/@pkg-0"
btrfs subvolume snapshot -r "/mnt/archinstall/var/log" "/mnt/archinstall/.snapshots/@log-0"

