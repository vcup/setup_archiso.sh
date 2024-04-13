#! /usr/bin/sh
target_profile="/usr/share/archiso/configs/releng"
profile_dir="./archiso"
override_airoot="./isoroot"
airoot="${profile_dir}/airootfs"
workdir="./workdir"
arins_cnf="$airoot/root/user_configuration.json"
arins_users="$airoot/root/user_credentials.json"

hostname='archlinux'
username='alkvm'
install_services=''

set -e

_usage() {
    IFS='' read -r -d '' usagetext <<ENDUSAGETEXT || true
usage: setup_archiso.sh [options]
  options:
     -H <hostname>    Set the hostname of this livecd build will install to system
                      Default: '${hostname}'
     -S <service,>    Set the services want to enable of this livecd build will install system. separate by comma.
     -h               This message
ENDUSAGETEXT
    printf '%s' "${usagetext}"
    exit "${1}"
}

_set_overrides() {
    # Set variables that have command line overrides
    if [[ -v override_username ]]; then
      username="$override_username"
    elif [[ -v override_hostname ]]; then
      echo '############'
      echo "$override_hostname"' != '"$hostname"
      if [[ "$override_hostname" != "$hostname" ]]; then
        username="$override_hostname"
      fi
    fi
    if [[ -v override_hostname ]]; then
        hostname="$override_hostname"
    fi
    if [[ -v override_install_services ]]; then
        install_services="$override_install_services"
    fi
}

_set_hostname() {
  jq ".hostname = \"$hostname\"" "$arins_cnf" | sponge "$arins_cnf"
}

_set_username() {
  jq --arg username "$username" '."!users"[0].username = $username' "$arins_users" | sponge "$arins_users"
}

_set_services() {
  jq --arg services "$install_services" '.services += ($services | split(","))' "$arins_cnf" | sponge "$arins_cnf"
}


while getopts 'H:U:S:rh?' arg; do
    case "${arg}" in
        H) override_hostname="${OPTARG}" ;;
        H) override_username="${OPTARG}" ;;
        S) override_install_services="${OPTARG}" ;;
        h|?) _usage 0 ;;
        *)
            _msg_error "Invalid argument '${arg}'" 0
            _usage 1
            ;;
    esac
done

_set_overrides

[ ! -d ${target_profile} ] && sudo pacman -S archiso
rsync -aP "${target_profile}/" "${profile_dir}"
sed '/reflector/d' -i "${profile_dir}/packages.x86_64"
echo 'jq
moreutils
pacman-contrib
geoip
asciinema
' >> "$_"

# disable reflector, we'll rank it manual

rsync -aP "${override_airoot}/" "${profile_dir}/airootfs/"

_set_hostname
_set_username
_set_services

# auto run install script
sed '/automated_script$/a\    asciinema rec $HOME\/install.cast --append --stdin -i 1 -c "zsh \/root\/install.sh"' -i "${airoot}/root/.automated_script.sh"

authkeys='.ssh/authorized_keys'
isoauthkeys="$airoot/root/$authkeys"
create_keypair() {
  mkdir -p "$airoot/root/.ssh"
  ssh-keygen -t rsa -b 4096 -N '' -f "$_/id_rsa"
  cat "$_.pub" >> "$isoauthkeys"
}
add_pubkey() {
  homedir=$HOME
  [ -n "$SUDO_USER" ] && homedir=$(eval echo ~$SUDO_USER)
  [ -d "$homedir/.ssh" ] || return 1
  for key in $(find "$homedir/.ssh" -name '*.pub'); do
    cat "$key" >> "$isoauthkeys"
  done
  [ ! -f "$homedir/$authkeys" ] || cat "$homedir/$authkeys" >> "$isoauthkeys"
}
n2nconfs="$airoot/root/fakeroot/etc/n2n"
copy_n2nconfs() {
  [ ! -d "$n2nconfs" ] && mkdir -p "$n2nconfs" && chmod --reference=/etc/n2n $_
  cp /etc/n2n/edge-*.conf "$n2nconfs"
}

if [ ! -d "$airoot/root/.ssh" ]; then
  create_keypair
  add_pubkey
  sort -u "$isoauthkeys" | sponge "$isoauthkeys"
fi

[ -d "$n2nconfs" ] || copy_n2nconfs

mkarchiso -v -w "${workdir}" -o . "${profile_dir}"

rm -rf ${workdir}
