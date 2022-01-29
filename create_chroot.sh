#!/usr/bin/env bash


export debconf_locales="locales	locales/default_environment_locale	select	en_US.UTF-8
locales	locales/locales_to_be_generated	select	en_US.UTF-8 UTF-8"

#Force root
[[ "$(id -u)" != 0 ]] && exec sudo "$0" "$@"

Main() {
    local target=$(mktemp -d)
    local code_name="$1"
    local proxy="$2"

    hash debootstrap || exit 1
    [[ -n $proxy ]] && export http_proxy=$proxy

    debootstrap --include=git,lvm2,bc,pv,parallel,qemu-utils,rsync $code_name "$target"
    #https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=697765 workaround
    chroot "$target" bash -c debconf-set-selections < <(echo "$debconf_locales")
    for f in sys dev dev/pts proc run; do
      mount --bind /$f $target/$f
    done

    chroot "$target" bash -c "DEBIAN_FRONTEND=noninteractive apt-get -y install locales"

    for f in sys dev/pts dev proc run; do
      umount -l $target/$f
    done

    XZ_OPT=-4T0 tar --exclude=/run/* --exclude=/tmp/* --exclude=/proc/* --exclude=/dev/* --exclude=/sys/*  -Jcf bcrm."${code_name}".tar.xz -C "$target" .
}

bash -n $(readlink -f $0) && Main "$@" #self check and run

