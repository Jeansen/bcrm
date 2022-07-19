#! /usr/bin/env bash
# shellcheck disable=SC2155,SC2153,SC2015,SC2094,SC2016,SC2034

# Copyright (C) 2017-2022 Marcel Lautenbach {{{
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License asublished by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Thisp rogram is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with thisrogram.  If not, see <http://www.gnu.org/licenses/>.
#}}}

# OPTIONS -------------------------------------------------------------------------------------------------------------{{{
unset IFS #Make sure IFS is not overwritten from the outside
export LC_ALL=en_US.UTF-8
export LVM_SUPPRESS_FD_WARNINGS=true
export XZ_OPT= #Make sure no compression is in place, can be set with -z. See Main()
[[ $TERM == unknown || $TERM == dumb ]] && export TERM=xterm
set -o pipefail
shopt -s globstar
#}}}

# CONSTANTS -----------------------------------------------------------------------------------------------------------{{{
declare VERSION=e16910b
declare -r LOG_PATH='/tmp'
declare -r F_LOG="$LOG_PATH/bcrm.log"
declare -r F_SCHROOT_CONFIG='/etc/schroot/chroot.d/bcrm'
declare -r F_SCHROOT='bcrm.stretch.tar.xz'
declare -r F_PART_LIST='part_list'
declare -r F_VGS_LIST='vgs_list'
declare -r F_LVS_LIST='lvs_list'
declare -r F_PVS_LIST='pvs_list'
declare -r F_PART_TABLE='part_table'
declare -r F_CHESUM='check.md5'
declare -r F_CONTEXT='context'
declare -r F_VENDOR_LIST='vendor.list'
declare -r F_DEVICE_MAP='device_map'
declare -r F_ROOT_FOLDER_DU='root_folder_du'

declare -r SCHROOT_HOME=/tmp/dbs
declare -r BACKUP_FOLDER=/var/bcrm/backup
declare -r SCRIPTNAME=$(basename "$0")
declare -r SCRIPTPATH=$(dirname "$0")
declare -r PIDFILE="/var/run/$SCRIPTNAME"
declare -r ROOT_DISK=$(lsblk -lpo pkname,mountpoint | grep '\s/$' | gawk '{print $1}')
declare -r SRC_NBD=/dev/nbd0
declare -r DEST_NBD=/dev/nbd1
declare -r CLONE_DATE=$(date '+%d%m%y')
declare -r SNAP4CLONE='snap4clone'
declare -r SALT=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 10)
declare -r LUKS_LVM_NAME="${SALT}_${CLONE_DATE}"
declare -r FIFO='/tmp/bcrm.fifo'

declare -r ID_GPT_LVM=e6d6d379-f507-44c2-a23c-238f2a3df928
declare -r ID_GPT_EFI=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
declare -r ID_GPT_LINUX=0fc63daf-8483-4772-8e79-3d69d8477de4
declare -r ID_DOS_EFI=ef
declare -r ID_DOS_LVM='0x8e'
declare -r ID_DOS_LINUX=83
declare -r ID_DOS_FAT32=c
declare -r ID_DOS_EXT='0x5'
declare _RMODE=false
declare MODE="" #clone,backup,restore
#}}}

# PREDEFINED COMMAND SEQUENCES ----------------------------------------------------------------------------------------{{{
declare -r LSBLK_CMD='lsblk -Ppno NAME,KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT,SIZE'
#}}}

# VARIABLES -----------------------------------------------------------------------------------------------------------{{{

# GLOBALS -------------------------------------------------------------------------------------------------------------{{{
declare -A SRCS
declare -A DESTS
declare -A CONTEXT          #Values needed for backup/restore

declare -A CHG_SYS_FILES    #Container for system files that needed to be changed during execution
                            #Key = original file path, Value = MD5sum

declare -A MNTJRNL MOUNTS
declare -A SRC2DEST PSRC2PDEST NSRC2NDEST
declare -A DEVICE_MAP

declare PVS=() VG_DISKS=() CHROOT_MOUNTS=()
#}}}

# FILLED BY OR BECAUSE OF PROGRAM ARGUMENTS ---------------------------------------------------------------------------{{{
declare -A EXT_PARTS EXCLUDES CHOWN
declare REMOVE_PKGS=()
declare PKGS=() #Will be filled with a list of packages that will be needed, depending on given arguments
declare SRCS_ORDER=() DESTS_ORDER=() SRC_EXCLUDES=()

declare SRC_IMG=""
declare DEST_IMG=""
declare IMG_TYPE=""
declare IMG_SIZE=""
declare SRC=""
declare DEST=""
declare VG_SRC_NAME_CLONE=""
declare ENCRYPT_PWD=""
declare HOST_NAME=""
declare EFI_BOOT_IMAGE=""

declare UEFI=false
declare CREATE_LOOP_DEV=false
declare PVALL=false
declare SPLIT=false
declare IS_CHECKSUM=false
declare SCHROOT=false
declare IS_CLEANUP=true
declare ALL_TO_LVM=false
declare UPDATE_EFI_BOOT=false
declare UNIQUE_CLONE=false
declare YES=false

declare MIN_RESIZE=2048 #In 1M units
declare SWAP_SIZE=-1    #Values < 0 mean no change/ignore
declare BOOT_SIZE=-1
declare -A LVM_EXPAND_BY #How much % of free space to use from a VG, e.g. when a dest disk is larger than a src disk.
declare -A LVM_SIZE_TO
#}}}

# CHECKS FILLED BY MAIN -----------------------------------------------------------------------------------------------{{{
declare -A PARAMS=() #All arguments and their (default) values passed via CLI.
declare DISABLED_MOUNTS=()
declare -A TO_LVM=()
declare VG_SRC_NAME=""
declare BOOT_PART=""
declare SWAP_PART=""
declare EFI_PART=""
declare MNTPNT=""
declare TABLE_TYPE=""

declare INTERACTIVE=false
declare HAS_GRUB=false
declare HAS_LUKS=false    #If source is encrypted
declare HAS_EFI=false     #If the cloned system is UEFI enabled
declare SYS_HAS_EFI=false #If the currently running system has UEFI
declare IS_LVM=false

declare EXIT=0
declare SECTORS_SRC=0
declare SECTORS_DEST=0
declare SECTORS_SRC_USED=0
declare VG_FREE_SIZE=0

declare SYS_CHANGED=false #If source system has been changed, e.g. deactivated hibernation
declare LIVE_CHECKSUMS=true
#}}}

#}}}

# PRIVATE - Only used by PUBLIC functions -----------------------------------------------------------------------------{{{

#--- Display ---{{{

echo_() { #{{{
    exec 1>&3 #restore stdout
    echo "$1"
    exec 3>&1         #save stdout
    exec >>$F_LOG 2>&1 #again all to the log
} #}}}

logmsg() { #{{{
    local d=$(date --rfc-3339=seconds)
    printf "\n%s\t%s\n\n" "[BCRM] ${d}" "${1}" >> $F_LOG
} #}}}

show_usage() { #{{{
    local -A usage

    printf "\nUsage: $(basename $0) -s <source> -d <destination> [options]\n\n"

    printf "\nOPTIONS"
    printf "\n-------\n\n"
    printf "  %-3s %-30s %s\n"   "-s," "--source"                "The source device or folder to clone or restore from"
    printf "  %-3s %-30s %s\n"   "-d," "--destination"           "The destination device or folder to clone or backup to"
    printf "  %-3s %-30s %s\n"   "   " "--source-image"          "Use the given image as source in the form of <path>:<type>"
    printf "  %-3s %-30s %s\n"   "   " ""                        "For example: '/path/to/file.vdi:vdi'. See below for supported types."
    printf "  %-3s %-30s %s\n"   "   " "--destination-image"     "Use the given image as destination in the form of <path>:<type>[:<virtual-size>]"
    printf "  %-3s %-30s %s\n"   "   " ""                        "For instance: '/path/to/file.img:raw:20G'"
    printf "  %-3s %-30s %s\n"   "   " ""                        "If you omit the size, the image file must exists."
    printf "  %-3s %-30s %s\n"   "   " ""                        "If you provide a size, the image file will be created or overwritten."
    printf "  %-3s %-30s %s\n"   "-c," "--check"                 "Create/Validate checksums"
    printf "  %-3s %-30s %s\n"   "-z," "--compress"              "Use compression (compression ratio is about 1:3, but very slow!)"
    printf "  %-3s %-30s %s\n"   "   " "--split"                 "Split backup into chunks of 1G files"
    printf "  %-3s %-30s %s\n"   "-H," "--hostname"              "Set hostname"
    printf "  %-3s %-30s %s\n"   "   " "--remove-pkgs"           "Remove the given list of whitespace-separated packages as a final step."
    printf "  %-3s %-30s %s\n"   "   " ""                        "The whole list must be enclosed in \"\""
    printf "  %-3s %-30s %s\n"   "-n," "--new-vg-name"           "LVM only: Define new volume group name"
    printf "  %-3s %-30s %s\n"   "   " "--vg-free-size"          "LVM only: How much space should be added to remaining free space in source VG."
    printf "  %-3s %-30s %s\n"   "-e," "--encrypt-with-password" "LVM only: Create encrypted disk with supplied passphrase"
    printf "  %-3s %-30s %s\n"   "-p," "--use-all-pvs"           "LVM only: Use all disks found on destination as PVs for VG"
    printf "  %-3s %-30s %s\n"   "   " "--lvm-expand"            "LVM only: Have the given LV use the remaining free space."
    printf "  %-3s %-30s %s\n"   "   " ""                        "An optional percentage can be supplied, e.g. 'root:80'"
    printf "  %-3s %-30s %s\n"   "   " ""                        "Which would add 80% of the remaining free space in a VG to this LV"
    printf "  %-3s %-30s %s\n"   "   " "--lvm-set-size"          "LVM only: Set size of given LV, e.g. 'root:80G'."
    printf "  %-3s %-30s %s\n"   "-u," "--make-uefi"             "Convert to UEFI"
    printf "  %-3s %-30s %s\n"   "-w," "--swap-size"             "Swap partition size. May be zero to remove any swap partition."
    printf "  %-3s %-30s %s\n"   "-m," "--resize-threshold"      "Do not resize partitions smaller than <size> (default 2048M)"
    printf "  %-3s %-30s %s\n"   "   " "--schroot"               "Run in a secure chroot environment with a fixed and tested tool chain"
    printf "  %-3s %-30s %s\n"   "   " "--no-cleanup"            "Do not remove temporary (backup) files and mounts."
    printf "  %-3s %-30s %s\n"   "   " ""                        "Useful when tracking down errors with --schroot."
    printf "  %-3s %-30s %s\n"   "   " "--disable-mount"         "Disable the given mount point in <destination>/etc/fstab."
    printf "  %-3s %-30s %s\n"   "   " ""                        "For instance --disable-mount /some/path. Can be used multiple times."
    printf "  %-3s %-30s %s\n"   "   " "--to-lvm"                "Convert given source partition or folder to LV. E.g. '/dev/sda1:boot' would be"
    printf "  %-3s %-30s %s\n"   "   " ""                        "converted to LV with the name 'boot'. Can be used multiple times."
    printf "  %-3s %-30s %s\n"   "   " ""                        "Only works for partitions that have a valid mountpoint in fstab"
    printf "  %-3s %-30s %s\n"   "   " ""                        "To convert a folder, e.g /var, to LVM you have to specify the LV size."
    printf "  %-3s %-30s %s\n"   "   " ""                        "For example: '/var:var:5G'."
    printf "  %-3s %-30s %s\n"   "   " "--all-to-lvm"            "Convert all source partitions to LV. (except EFI)"
    printf "  %-3s %-30s %s\n"   "   " "--include-partition"     "Also include the content of the given partition to the specified path."
    printf "  %-3s %-30s %s\n"   "   " ""                        "E.g: 'part=/dev/sdX,dir=/some/path/,user=1000,group=10001,exclude=fodler1,folder2'"
    printf "  %-3s %-30s %s\n"   "   " ""                        "would copy all content from /dev/sdX to /some/path."
    printf "  %-3s %-30s %s\n"   "   " ""                        "If /some/path does not exist, it will be created with the given user"
    printf "  %-3s %-30s %s\n"   "   " ""                        "and group ID, or root otherwise. With exclude you can filter folders and files."
    printf "  %-3s %-30s %s\n"   "   " ""                        "This option can be specified multiple times."
    printf "  %-3s %-30s %s\n"   "   " "--exclude-folder"        "Exclude a folder from source partition or backup."
    printf "  %-3s %-30s %s\n"   "   " ""                        "This option can be specified multiple times."
    printf "  %-3s %-30s %s\n"   "   " "--update-efi-boot"       "Add a new Entry to EFI NVRAM and make the cloned disk the first boot device."
    printf "  %-3s %-30s %s\n"   "   " ""                        "Use this option if you plan to replace an existing disk with the clone."
    printf "  %-3s %-30s %s\n"   "   " ""                        "Especially if you plan to keep the original disk installed, but the system should"
    printf "  %-3s %-30s %s\n"   "   " ""                        "boot from the clone."
    printf "  %-3s %-30s %s\n"   "   " "--efi-boot-iamge"        "Path to an existing EFI image, e.g. '\EFI\debian\grub.efi'"
    printf "  %-3s %-30s %s\n"   "-U," "--unique-clone"          "For GPT partition tables: Randomize the cloned disk's GUID and all partitions' unique GUIDs."
    printf "  %-3s %-30s %s\n"   "   " ""                        "For MBR partition tables: Randomize the disk identifier only."
    printf "  %-3s %-30s %s\n"   "-q," "--quiet"                 "Quiet, do not show any output."
    printf "  %-3s %-30s %s\n"   "-h," "--help"                  "Display this help and exit."
    printf "  %-3s %-30s %s\n"   "-v," "--version"               "Show version information for this instance of bcrm and exit."
    printf "  %-3s %-30s %s\n"   "-y," "--yes"                   "Answer 'yes' to all questions."

    printf "\n\nADVANCED OPTIONS"
    printf "\n----------------\n\n"
    printf "  %-3s %-30s %s\n"   "-b," "--boot-size"             "Boot partition size. For instance: 200M or 4G."
    printf "  %-3s %-30s %s\n"   "   " ""                        "Be careful, the  script only checks for the bootable flag,"
    printf "  %-3s %-30s %s\n"   "   " ""                        "Only use with a dedicated /boot partition"

    printf "\n\nADDITIONAL NOTES"
    printf "\n----------------\n"
    printf "\nSize values must be postfixed with a size indcator, e.g: 200M or 4G. The following indicators are valid:\n\n"
    printf "  %-3s %s\n"       "K"    "[kilobytes]"
    printf "  %-3s %s\n"       "M"    "[megabytes]"
    printf "  %-3s %s\n"       "G"    "[gigabytes]"
    printf "  %-3s %s\n"       "T"    "[terabytes]"

    printf "\nWhen using virtual images you always have to provide the image type. Currently the following image types are supported:\n\n"
    printf "  %-7s %s\n"       "raw"    "Plain binary"
    printf "  %-7s %s\n"       "vdi"    "Virtual Box"
    printf "  %-7s %s\n"       "qcow2"  "QEMU/KVM"
    printf "  %-7s %s\n"       "vmdk"   "VMware"
    printf "  %-7s %s\n\n\n"   "vhdx"   "Hyper-V"

    printf "\nThe following log files are available:\n\n"
    printf "  %-40s %s\n"       "/tmp/bcrm.log"    	  			 			"General procelain log fiile."
    printf "  %-40s %s\n"       "/tmp/bcrm.<partition>.md5.log"		    	"Full log created from md5sum (requires -c)."
    printf "  %-40s %s\n"       "/tmp/bcrm.<partition>.md5.failed.log"    	"Only files with failed checksum (requires -c)."
    printf "  %-40s %s\n"       "/tmp/bcrm.<partition>.log"    	            "Log file filled by tar when creating or restoring a backup."
    printf "  %-40s %s\n"       "/tmp/bcrm.<src-part>__<dest-part>.log"     "Log file filled by rsync during clone."

    exit_ 1
} #}}}

# -t: <text>
# Flags defining the type of text and symbol to be displayed
# -c = CURRENT (➤)
# -y = SUCCESS (✔)
# -n = FAIL (✘)
# -i = INFO (i)
# -I = Mark text (-t) for Input
# -u: Update a message indicator, e.g. from status CURRENT to SUCCESS.
message() { #{{{
    local OPTIND
    local status
    local text
    local update=false
    local is_input=false
    clor_current=$(tput bold; tput setaf 3)
    clr_yes=$(tput setaf 2)
    clor_no=$(tput setaf 1)
    clor_info=$(tput setaf 6)
    clor_warn=$(tput setaf 3)
    clr_rmso=$(tput sgr0)

    exec 1>&3 #restore stdout

    #prepare
    local option
    while getopts ':Iriwnucyt:' option; do
        case "$option" in
        I)
            is_input=true
            ;;
        t)
            text=" $OPTARG"
            ;;
        y)
            status="${clr_yes}✔${clr_rmso}"
            tput rc
            ;;
        n)
            status="${clor_no}✘${clr_rmso}"
            tput rc
            ;;
        w)
            status="${clor_warn}!${clr_rmso}"
            ;;
        i)
            status="${clor_info}i${clr_rmso}"
            ;;
        u)
            update=true
            ;;
        c)
            status="${clor_current}➤${clr_rmso}"
            tput sc
            ;;
        r)
            tput rc
            ;;
        :)
            exit_ 5 "Method call error: \t${FUNCNAME[0]}()\tMissing argument for $OPTARG"
            ;;
        ?)
            exit_ 5 "Method call error: \t${FUNCNAME[0]}()\tIllegal option: $OPTARG"
            ;;
        esac
    done
    shift $((OPTIND - 1))
    status="${status}"

    #execute
    [[ -n $status ]] && echo -e -n "[ $status ] "
    [[ -n $text ]] \
        && text=$(echo "$text" | sed -e 's/^\s*//; 2,$ s/^/      /') \
        && echo -e -n "$text" \
        && tput el \
        && tput ed

    [[ $is_input == false ]] && echo

    [[ $update == true ]] && tput rc
    tput civis
    exec 3>&1          #save stdout
    exec >>$F_LOG 2>&1 #again all to the log
} #}}}

spinner() { #{{{
    local pid="$1"
    local msg="$2"
    local stat="$3"
    local sp

    message -u -c -t "$msg [ $stat ]"
    sleep 2
    [[ $stat == scan ]] && sp='   s  sc scascansca sc  s   sc  sca scan sca  sc'
    [[ $stat == sync ]] && sp='   s  sy synsyncsyn sy  s   sy  syn sync syn  sy'

    while kill -0 $pid 2>/dev/null; do
        message -u -c -t "$msg [ ${sp:0:4} ]"
        sp=${sp#????}${sp:0:4}
        sleep 0.1
    done
} #}}}
#}}}

#--- Context ---{{{

vendor_compare() { #{{{
    logmsg "vendor_compare"

    if (( $# == 2 )); then
        eval local -A from="$1"
        eval local -A to="$2"
    elif (( $# == 1 )); then
        local input="$(</dev/stdin)"
        eval local -A from="$input"
        eval local -A to="$1"
    else
        return 1
    fi

    local k
    for k in "${!from[@]}"; do
        [[ ${from[$k]} == "${to[$k]}" ]] || echo -e "$k has different versions:\n${from[$k]}\n${to[$k]}"
    done
} #}}}

vendor_list() { #{{{
    logmsg "vendor_list"
    local -A v

    local tools
    IFS=, read -ra tools <<<"${1// /,}"

    local t
    for t in "${tools[@]}"; do
        case "$t" in
        gawk)
            v[$t]="$($t --version | head -n1 | cut -d ',' -f1)"
            ;;
        rsync)
            v[$t]="$($t --version | head -n1 | gawk '{print $1, $2, $3}')"
            ;;
        tar|flock|bc|blockdev|fdisk|sfdisk|parted)
            v[$t]="$($t --version | head -n1)"
            ;;
        'mkfs.vfat'|'mkfs')
            { v[$t]="$($t --version )"; } 2>/dev/null #mkfs pollutes the log otherwise!
            ;;
        lvm)
            v[$t]="$(lvs --version | head -n3)"
            ;;
        qemu-img)
            v[$t]="$($t --version | head -n1 | gawk '{print $1,$2,$3}')"
            ;;
        locale-gen|git)
            ;;
        *)
            return 1
            ;;
        esac
    done
    local -p v | sed 's/^[^=]*=//' | sed 's/(/(\n/; s/" /"\n/g; s/\[/  [/g'
} #}}}

# Save key/values of context map to file
ctx_save() { #{{{
    logmsg "ctx_save"
    {
        declare -p BOOT_PART
        declare -p HAS_GRUB
        declare -p SECTORS_SRC
        declare -p SECTORS_SRC_USED
        declare -p IS_LVM
        declare -p IS_CHECKSUM
        declare -p HAS_EFI
        declare -p TABLE_TYPE
        declare -p SRCS_ORDER
    } >"$DEST/$F_CONTEXT"

    echo "# Backup date: $(date)" >>"$DEST/$F_CONTEXT"
    echo "# Version used: $VERSION" >>"$DEST/$F_CONTEXT"
} #}}}

#}}}

#--- Wrappers ---- {{{

# By convention methods ending with a '_' wrap shell functions or commands with the same name.

# $1: <exit code>
# $2: <message>
exit_(){ #{{{
    [[ -n $2 ]] && message -n -t "$2"
    EXIT=${1:-0}
    exit $EXIT
} #}}}
#}}}

#--- Mounting ---{{{

mount_exta_lvm() { #{{{
    local OPTIND
    local option
    while getopts ':s:d:cu' option; do
        case "$option" in
        s)
			local smpnt="$OPTARG"
            ;;
        d)
			local dmpnt="$OPTARG"
            ;;
        c)
            local create="true"
            ;;
        u)
            local update_fstab="true"
            ;;
        :)
            exit_ 5 "Method call error: \t${FUNCNAME[0]}()\tMissing argument for $OPTARG"
            ;;
        ?)
            exit_ 5 "Method call error: \t${FUNCNAME[0]}()\tIllegal option: $OPTARG"
            ;;
        esac
    done

    shift $((OPTIND - 1))

    local -A lvs_dmpaths
    local -A dmpath_uuids
    while read -r k v; do lvs_dmpaths[$k]="$v"; done <<<$(lvs --no-headings -o lv_name,dm_path "$VG_SRC_NAME_CLONE" | gawk '{print $1,$2}')
    while read -r j w; do dmpath_uuids[$j]="$w"; done <<<$(lsblk -nlo path,uuid "$DEST" | gawk '{if ($2) print $1,$2}')

    local l='' name='' paht='' uuid=''
    for l in "${!TO_LVM[@]}"; do
        IFS=: read -r name size fs <<<"${TO_LVM[$l]}"
        path="${lvs_dmpaths[$name]}"
        uuid="${dmpath_uuids[${path}]}"
        if [[ $update_fstab == true && -s "$dmpnt/etc/fstab" && ! $l =~ ^/dev ]]; then
            [[ -z $uuid ]] && exit_ 1 "Missing UUID for $name [$path]"
            printf "%s\t%s\t%s\terrors=remount-ro\t0\t1\n" "UUID=$uuid" "$l" "$fs" >> "$dmpnt/etc/fstab"
        elif [[ -n $path && -n $fs ]]; then
            [[ -n $smpnt && -n $dmpnt ]] && rsync -av -f"+ $l" -f"- *" "$smpnt/$l" "$dmpnt"
			[[ $create == true ]] && mkdir -p "$dmpnt/$l"
			mount_ "$path" -p "$dmpnt/$l"
        fi
    done
} #}}}

find_mount_part() { #{{{
    local m=''
    for m in $(echo "${!MOUNTS[@]}" | tr ' ' '\n' | sort -r | grep -E '^/' | grep -v -E '^/dev/'); do
        [[ $1 =~ $m ]] && echo "$m" && return 0
    done
} #}}}

mount_(){ #{{{
    local cmd="mount"
    local OPTIND
    local src=$(realpath -s "$1")
    local path=''

    mkdir -p "${MNTPNT}/$src" && path=$(realpath -s "${MNTPNT}/$src")

    shift

    local option
    while getopts ':p:t:o:b' option; do
        case "$option" in
        t)
            ! mountpoint -q  "$src" && cmd+=" -t $OPTARG"
            ;;
        p)
            path=$(realpath -s "$OPTARG")
            ;;
        b)
            cmd+=" --bind"
            ;;
        o)
            cmd+=" -o $OPTARG"
            ;;
        :)
            printf "missing argument for -%s\n" "$OPTARG" >&2
            ;;
        ?)
            printf "illegal option: -%s\n" "$OPTARG" >&2
            ;;
        esac
    done
    shift $((OPTIND - 1))

    mountpoint -q "$src" && cmd+=" --bind"
    logmsg "$cmd $src $path"
    [[ -n ${MNTJRNL["$src"]} && ${MNTJRNL["$src"]} != "$path" ]] && return 1
    [[ -n ${MNTJRNL["$src"]} && ${MNTJRNL["$src"]} == "$path" ]] && return 0
    { $cmd "$src" "$path" && MNTJRNL["$src"]="$path"; } || return 1
} #}}}

umount_() { #{{{
    local OPTIND
    local cmd="umount -l"

    #TODO remove local?
    local option=''
    while getopts ':R' option; do
        case "$option" in
        R)
            cmd+=" -R"
            local OPT_R='true'
            ;;
        :)
            printf "missing argument for -%s\n" "$OPTARG" >&2
            ;;
        ?)
            printf "illegal option: -%s\n" "$OPTARG" >&2
            ;;
        esac
    done
    shift $((OPTIND - 1))

    local mnt=$(realpath -s "$1")

    if [[ $# -eq 0 ]]; then
        local m=''
        for m in "${MNTJRNL[@]}"; do $cmd "$m"; done
        return 0
    fi

    #TODO validate mounts in list and use return instead of exit
    logmsg "$cmd ${MNTJRNL[$mnt]}"
    local x=${MNTJRNL[$mnt]}
    if [[ $OPT_R == true ]]; then
        $cmd ${MNTJRNL[$mnt]} || exit_ 1
        for f in "${!MNTJRNL[@]}"; do
            [[ ${MNTJRNL[$f]} =~ $x ]] && unset MNTJRNL[$f]
        done
    else
        { $cmd ${MNTJRNL[$mnt]} && unset MNTJRNL[$mnt]; } || exit_ 1
    fi
} #}}}

get_mount() { #{{{
    local k=$(realpath -s "$1")
    [[ -z $k || -z ${MNTJRNL[$k]} ]] && return 1
    echo ${MNTJRNL[$k]}
    return 0
} #}}}

mount_chroot() { #{{{
    logmsg "mount_chroot"
    local mp="$1"

    umount_chroot

    local f
    for f in sys dev dev/pts proc run; do
        mount --bind "/$f" "$mp/$f"
    done

    CHROOT_MOUNTS+=("$mp")
} #}}}

umount_chroot() { #{{{
    logmsg "umount_chroot"
    local f

    for f in ${CHROOT_MOUNTS[@]}; do
        umount -Rl "$f"
    done
} #}}}

#}}}

#--- LVM related --{{{
# $1: <vg-name>
# $2: <src-dev>
# $3: <dest-dev>
vg_extend() { #{{{
    logmsg "vg_extend"
    local vg_name="$1"
    local src="$2"
    local dest="$3"
    PVS=()

    if [[ -d $src ]]; then
        src=$(df -P "$src" | tail -1 | gawk '{print $1}')
    fi

    local e=''
    while read -r e; do
        local name='' type=''
        read -r name type <<<"$e"
        [[ -n $(lsblk -no mountpoint "$name" 2>/dev/null) ]] && continue
        echo ';' | sfdisk -q "$name" && sfdisk "$name" -Vq
        local part=$(lsblk "$name" -lnpo name,type | grep part | gawk '{print $1}')
        pvcreate -ff "$part" && vgextend "$vg_name" "$part"
        PVS+=("$part")
    done < <(lsblk -po name,type | grep disk | grep -Ev "$dest|$src")
} #}}}

# $1: <vg-name>
# $2: <Ref. to GLOABAL array holding VG disks>
vg_disks() { #{{{
    logmsg "vg_disks"
    local name=$1
    local -n disks=$2

    local f=''
    for f in $(pvs --no-headings -o pv_name,lv_dm_path | grep -E "${name}\-\w+" | gawk '{print $1}' | sort -u); do
        disks+=($(lsblk -pnls $f | grep disk | gawk '{print $1}'))
    done
} #}}}

#}}}

#--- Registration ---{{{

add_device_links() { #{{{
    local kdev=$1
    local devlinks=$(find /dev -type l -exec readlink -nf {} \; -exec echo " {}" ';' | grep "$kdev" | gawk '{print $2}')
    DEVICE_MAP[$kdev]="$devlinks"

    local d=''
    for d in $devlinks;
        do DEVICE_MAP[$d]=$kdev;
    done
} #}}}

mounts() { #{{{
    logmsg "mounts"
    if [[ $_RMODE == false ]]; then
        local mp mpnt sdev sid fs spid ptype type mountpoint rest
        local ldata=$(lsblk -lnpo name,kname,uuid,partuuid "$SRC")

        _(){ #{{{
            local s=''
            for s in ${!SRCS[@]}; do
                sid=$s
                IFS=: read -r sdev fs spid ptype type mountpoint rest <<<${SRCS[$s]}

                [[ -z ${mountpoint// } ]] && mp="$sdev" || mp="$mountpoint"
                mount_ "$mp" && mpnt=$(get_mount "$mp") || exit_ 1 "Could not mount ${mp}."

                if [[ -f $mpnt/etc/fstab ]]; then
                    local dev='' mnt='' fs=''
                    while read -r dev mnt fs; do
                        if [[ ! ${fs// } =~ nfs|swap|udf ]]; then
                            _(){
                                local name kname uuid partuuid
                                read -r name kname uuid partuuid <<<$(grep -iE "${dev//*=/}" <<<"$ldata") #Ignore -real, -cow

                                if [[ -n ${name// } ]]; then
                                    MOUNTS[$mnt]="${uuid}"
                                    [[ -n ${name// } ]] && MOUNTS[${name//*=/}]=$mnt
                                    [[ -n ${partuuid// } ]] && MOUNTS[${partuuid}]=$mnt
                                    [[ -n ${uuid// } ]] && MOUNTS[$uuid]="${mnt}"
                                fi
                            };_
                        fi
                    done <<<"$(grep -E '^[^;#]' "$mpnt/etc/fstab" | gawk '{print $1,$2,$3}')"
                fi

                umount_ "$mp"
            done
        };_ #}}}
    else
        local files=()
        pushd "$SRC" >/dev/null || return 1

        _(){ #{{{
            local file=''
            for file in [0-9]*; do
                local k=$(echo "$file" | sed "s/\.[a-z]*$//")
                files+=("$k")
            done
        };_ #}}}

        _(){ #{{{
            local file=''
            for file in "${files[@]}"; do
                local i uuid puuid fs type sused dev mnt dir user group
                IFS=. read -r i uuid puuid fs type sused dev mnt dir user group <<<"$(pad_novalue $file)"
                mnt=${mnt//_//}

                MOUNTS[${mnt}]="$uuid"
                [[ -n ${dev//NOVALUE/} ]] && MOUNTS[${dev//_//}]=$mnt
                [[ -n ${puuid//NOVALUE/} ]] && MOUNTS[${puuid}]=$mnt
                [[ -n ${uuid//NOVALUE/} ]] && MOUNTS[$uuid]="$mnt"
            done
        };_ #}}}

        popd >/dev/null || return 1
    fi
} #}}}

set_dest_uuids() { #{{{
    logmsg "set_dest_uuids"

    if [[ -b $DEST && $IS_LVM == true ]]; then
        vgchange -an "$VG_SRC_NAME_CLONE"
        vgchange -ay "$VG_SRC_NAME_CLONE"
    fi

    local lvs_list=$(lvs --no-headings -o lv_name,dm_path "$VG_SRC_NAME_CLONE" | gawk '{print $1,$2}')

    _is_lvm_candidate() {
        local path="$1"
        local lv_name='' dm_path='' line=''

        while read -r line; do
            read -r lv_name dm_path <<<"$line"
            if [[ $path == "$dm_path" ]]; then
				local l='' name='' _=''
                for l in "${!TO_LVM[@]}"; do
                    if [[ ! (-b $l || $l =~ ^/dev) ]]; then
                        IFS=: read -r name _ <<<"${TO_LVM[$l]}"
                        [[ $name == "$lv_name" ]] && return 0
                    fi
                done
            fi
        done < <(echo "$lvs_list")

        return 1
    }

    _update_order() {
        local order=($(lsblk -lnpo uuid $DEST))
        local e=''
        for e in "${!order[@]}"; do
            [[ ${order[$e]} == $1 ]] && DESTS_ORDER["$e"]="$1"
        done
    }

    local name kdev fstype uuid puuid type parttype mountpoint size e
    while read -r e; do
        read -r name kdev fstype uuid puuid type parttype mountpoint size <<<"$e"
        eval local "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint" "$size"

        (( ${#TO_LVM[@]} > 0 )) && _is_lvm_candidate $NAME && continue

        #Filter all we don't want
        [[ $UEFI == true && ${PARTTYPE} =~ $ID_GPT_EFI|${ID_DOS_EFI} ]] && continue;

        local mp
        [[ -z ${MOUNTPOINT// } ]] && mp="$NAME" || mp="$MOUNTPOINT"
        mount_ "$mp" -t "$FSTYPE" || exit_ 1 "Could not mount ${mp}."

        local used='' avail=''
        read -r used avail <<<$(df --block-size=1K --output=used,size "$NAME" | tail -n -1)
        avail=$((avail - used)) #because df keeps 5% for root!
        umount_ "$mp"

        DESTS[$UUID]="${NAME}:${FSTYPE:- }:${PARTUUID:- }:${PARTTYPE:- }:${TYPE:- }:${avail:- }" #Avail to be checked
        _update_order "$UUID"

        # [[ ${PVS[@]} =~ $NAME ]] && continue
    done < <($LSBLK_CMD "$DEST" $([[ $PVALL == true ]] && echo ${PVS[@]}) | gawk "! /PARTTYPE=\"($ID_DOS_LVM|$ID_DOS_EXT)\"/ && ! /TYPE=\"(disk|crypt)\"/ && ! /FSTYPE=\"(crypto_LUKS|LVM2_member|swap)\"/ {print $1}" | sort -u -b -k1,1)
    DESTS_ORDER=(${DESTS_ORDER[@]})
} #}}}

# $1: partition, e.g. /dev/sda1
get_uuid() { #{{{
    if [[ $_RMODE == true ]]; then
        ({ eval $(grep -e "$1" $F_PART_LIST); echo "$UUID"; })
    else
        local env=$(blkid -o export "$1")
        local uuid=$(eval "$env"; echo "$UUID")
        echo "$uuid"
    fi
} #}}}

# $2: <File with lsblk dump>
init_srcs() { #{{{
    logmsg "init_srcs"
    local file="$1"
    local srcs_order_selected=()

    _update_order() {
        local order=($(lsblk -lnpo uuid $SRC))
        local e=''
        for e in "${!order[@]}"; do
            [[ ${order[$e]} == $1 ]] && SRCS_ORDER["$e"]="$1"
        done
    }

    _(){ #{{{
        local e=''
        while read -r e; do
            local name='' kdev='' fstype='' uuid='' puuid='' type='' parttype='' mountpoint='' size=''
            read -r name kdev fstype uuid puuid type parttype mountpoint size <<<"$e"
            eval local "$name" "$kdev" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint" "$size"

            add_device_links "$KNAME"

            #Filter all we don't want
            { lvs -o lv_dmpath,lv_role | grep "$NAME" | grep "snapshot" -q || [[ $NAME =~ real$|cow$ ]]; } && continue

            if [[ $_RMODE == false ]]; then
                local mp=''
                [[ -z ${MOUNTPOINT// } ]] && mp="$NAME" || mp="$MOUNTPOINT"
                mount_ "$mp" -t "$FSTYPE" || exit_ 1 "Could not mount ${mp}."

                local mpnt=$(get_mount $mp) || exit_ 1 "Could not find mount journal entry for $mp. Aborting!" #do not use local, $? will be affected!
                local used='' size=''
                read -r used <<<$(df -k --output=used "$mpnt" | tail -n -1)
                size=$(sector_to_kbyte $(blockdev --getsz "$NAME"))

                local l=''
                for l in ${!TO_LVM[@]}; do
                    if [[ -d $mpnt/$l ]]; then
                        used=$((used - $(to_kbyte $(du -sb $mpnt/$l)) ))
                    fi
                done
                umount_ "$mp"
                _update_order "$UUID"
            fi
            SRCS[$UUID]="${NAME}:${FSTYPE:- }:${PARTUUID:- }:${PARTTYPE:- }:${TYPE:- }:${MOUNTPOINT:- }:${used:- }:${size:- }"
            srcs_order_selected=srcs_order
        done < <(echo "$file" | gawk "! /PARTTYPE=\"($ID_DOS_LVM|$ID_DOS_EXT)\"/ && ! /TYPE=\"(disk|crypt)\"/ && ! /FSTYPE=\"(crypto_LUKS|LVM2_member|swap)\"/ {print $1}" | sort -u -b -k1,1)
        SRCS_ORDER=(${SRCS_ORDER[@]})
    };_ #}}}

    _(){ #{{{
        if [[ $_RMODE == true ]]; then
            pushd "$SRC" >/dev/null || return 1
            local f=''
            for f in [0-9]*; do
                local i='' uuid='' puuid='' fs='' type='' sused='' dev='' mnt=''
                local sname='' sfstype='' spartuuid='' sparttype='' stype='' mp='' used='' size=''
                IFS=. read -r i uuid puuid fs type sused dev mnt <<<"$(pad_novalue "$f")"
                IFS=: read -r sname sfstype spartuuid sparttype stype mp used size <<<"${SRCS[$uuid]}"
                if [[ $type == part ]]; then
                    sname=$(grep "$uuid" "$F_PART_LIST" | gawk '{print $1}' | cut -d '"' -f2)
                    size=$(sector_to_kbyte $(grep "$sname" "$F_PART_TABLE" | grep -o 'size=.*,' | grep -o '[0-9]*'))
                fi
                SRCS[$uuid]="${sname//NOVALUE/}:${sfstype//NOVALUE/}:${spartuuid//NOVALUE/}:${sparttype//NOVALUE/}:${stype//NOVALUE/}:${mp//NOVALUE/}:${sused//NOVALUE/}:${size//NOVALUE/}"
            done
        fi
    };_ #}}}
} #}}}
#}}}

#--- Post cloning ---{{{

# $1: <mount point>
# $2: "<dest-dev>"
grub_install() { #{{{
    logmsg "grub_install"
    chroot "$1" bash -c "
        DEBIAN_FRONTEND=noninteractive apt-get install -y $3 &&
        grub-install $2 &&
        update-grub &&
        update-initramfs -u -k all" || return 1

} #}}}

# $1: <mount point>
# $2: <boot image>
update_efi_boot() { #{{{
    logmsg "update_efi_boot"
    local images=($1/boot/**/EFI/**/*.efi)
    local image_path="$2"

    _find_image() {
        local path='' i=''
        for i in ${!images[@]}; do
            path="\\EFI$(echo ${images[$i]//*EFI/} | tr / \\ 2>/dev/null)"
            [[ "$path" == "$image_path" ]] && return 0
        done
        return 1
    }

    if [[ -z ${image_path// } ]]; then
        message -i -t "Available EFI images:"
        local i=''
        for i in ${!images[@]}; do
            message -i -t "$i -- ${images[$i]}"
        done
        message -I -i -t "Select EFI image [0-$i]: "

        local nr=''
        read -r nr
        if [[ $nr -ge 0 && $nr -le $i ]]; then
            image_path="\\EFI$(echo ${images[$i]//*EFI/} | tr / \\ 2>/dev/null)"
        else
            logmsg "Invalid selection. No changes to NVRAM applied!"
            return 1
        fi
    else
        _find_image || { logmsg "Boot image $EFI_BOOT_IMAGE not found. No changes applied!"; return 1; }
    fi

    boot_order=$(efibootmgr | grep BootOrder | gawk '{print $2}')
    efibootmgr -c -L "bcrm_$CLONE_DATE" -d "$DEST" -l "$image_path"
    boot_id=$(efibootmgr -v | tail -n1 | gawk '{print $1}' | grep -Eo '[0-9]*')
    bootorder=$boot_id,$bootorder
} #}}}

# $1: <mount point>
# $2: ["<list of packages to install>"]
pkg_remove() { #{{{
    local mp="$1"
    local pkgs="$2"
    logmsg "pkg_remove"
    [[ -n ${pkgs// } ]] && { chroot "$mp" sh -c "apt-get remove -y $pkgs" || return 1; }
    return 0
} #}}}

# $1: <mount point>
# $2: ["<list of packages to install>"]
pkg_install() { #{{{
    local mp="$1"
    local pkgs="$2"
    logmsg "pkg_install"
    [[ -n ${pkgs// } ]] && { chroot "$mp" sh -c "apt-get install -y $pkgs" || return 1; }
    return 0
} #}}}

# $1: <mount point>
create_rclocal() { #{{{
    logmsg "create_rclocal"
    printf '%s' '#! /usr/bin/env bash
    systemctl stop ssh.service
    update-grub
    sleep 10
    systemctl disable bcrm-update.service
    rm /etc/systemd/system/bcrm-update.service
    rm /usr/local/bcrm-local.sh
    reboot' >"$1/usr/local/bcrm-local.sh"
    chmod +x "$1/usr/local/bcrm-local.sh"

    printf '%s' '[Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/usr/local/bcrm-local.sh

    [Install]
    WantedBy=multi-user.target' >"$1/etc/systemd/system/bcrm-update.service"

    chroot "$1" bash -c "systemctl enable bcrm-update.service" || return 1
} #}}}

#}}}

#--- Validation ---{{{

# $1: <dest-dev>
# $2: <checksum file>
create_m5dsums() { #{{{
    logmsg "create_m5dsums"
    local dest="$1"
    local file="$2"
    # find "$1" -type f \! -name '*.md5' -print0 | xargs -0 md5sum -b > "$1/$2"
    pushd "$dest" || return 1
    find . -type f \! -name '*.md5' \! -name '\.*' -print0 | parallel --no-notice -0 md5sum -b >"$file"
    popd || return 1
    validate_m5dsums "$dest" "$file" || return 1
} #}}}

# $1: <src-dev>
# $2: <checksum file>
validate_m5dsums() { #{{{
    logmsg "validate_m5dsums"
    local src="$1"
    local file="$2"
    pushd "$src" || return 1
    md5sum -c "$file" --quiet || return 1
    popd || return 1
} #}}}

#}}}

#--- Disk and partition setup ---{{{

sync_block_dev() { #{{{
    logmsg "sync_block_dev"
    sleep 3
    udevadm settle && blockdev --rereadpt "$1" && udevadm settle
} #}}}

# $1: <password>
# $2: <dest-dev>
# $3: <luks lvm name>
encrypt() { #{{{
    logmsg "encrypt"
    local passwd="$1"
    local dest="$2"
    local name="$3"
    local size='' type=''

    if [[ $HAS_EFI == true ]]; then
        if [[ $_RMODE == true ]]; then
            echo -e "$(cat $F_PART_TABLE | tr -d ' ' | grep -o "size=[0-9]*,type=${ID_GPT_EFI^^}")\n;" \
            | sfdisk --label gpt "$dest" || return 1
        else
            read -r size type <<<$(sfdisk -l -o Size,Type-UUID $SRC | grep ${ID_GPT_EFI^^})
            echo -e "size=$size, type=$type\n;" | sfdisk --label gpt "$dest" || return 1
        fi
    elif [[ $UEFI == true ]]; then
        echo ';' | sfdisk "$DEST"
        mbr2gpt $DEST && HAS_EFI=true
        read -r size type <<<$(sfdisk -l -o Size,Type-UUID $DEST | grep ${ID_GPT_EFI^^})
    else
        { echo ';' | sfdisk "$dest"; } || return 1 #delete all partitions and create one for the whole disk.
    fi

    sleep 3
    ENCRYPT_PART=$(sfdisk -qlo device "$dest" | tail -n 1)
    echo -n "$passwd" | cryptsetup luksFormat "$ENCRYPT_PART" --type luks1 -
    echo -n "$passwd" | cryptsetup open "$ENCRYPT_PART" "$name" --type luks1 -
} #}}}

# $1: <src-sectors>
# $2: <dest-sectors>
# $3: <file with partition table dump>
# $4: <REF for result data>
expand_disk() { #{{{
    logmsg "expand_disk"
    local src_size=$1
    local dest_size=$2
    local pdata="$3"
    local -n pdata_new=$4
    local -i swap_size=0
    local size='' new_size=''

    local -A val_parts #Partitions with fixed sizes
    local -A var_parts #Partitions to be expanded

    _size() { #{{{
        local part="$1"
        local part_size="$2"
        #Substract the swap partition size
        [[ $part_size -le 0 ]] && part_size=$(echo "$pdata" | grep "$part" | sed -E 's/.*size=\s*([0-9]*).*/\1/')
        src_size=$((src_size - part_size))
        dest_size=$((dest_size - part_size))
    } #}}}

    [[ -n $SWAP_PART  ]] && _size "$SWAP_PART" "$SWAP_SIZE"
    [[ -n $BOOT_PART  ]] && _size "$BOOT_PART" "$BOOT_SIZE"
    [[ -n $EFI_PART  ]] && _size "$EFI_PART" 0

    local expand_factor=$(echo "scale=4; $dest_size / $src_size" | bc)

    _(){ #{{{
        if [[ $SWAP_SIZE -eq 0 && -n $SWAP_PART ]]; then
            local swap_part=${SWAP_PART////\\/} #Escape for sed interpolation
            pdata=$(echo "$pdata" | sed "/$swap_part/d")
        fi
    };_ #}}}

    _(){ #{{{
        local n=0
        while read -r name size; do
            if [[ (-n $BOOT_PART && $name == "$BOOT_PART") ||
                (-n $SWAP_PART && $name == "$SWAP_PART") ||
                (-n $EFI_PART && $name == "$EFI_PART") ]]
            then
                val_parts[$name]=${size%,*}
                [[ -n $BOOT_PART && $name == "$BOOT_PART" && "$BOOT_SIZE" -gt 0  ]] &&
                    val_parts[$name]=$(to_sector ${BOOT_SIZE}K)
                [[ -n $SWAP_PART && $name == "$SWAP_PART" && "$SWAP_SIZE" -gt 0  ]] &&
                    val_parts[$name]=$(to_sector ${SWAP_SIZE}K)
            else
                var_parts[$name]=${size%,*}
                ((n++))
            fi
        done < <(echo "$pdata" | grep '^/' | gawk '{print $1,$6}')
    };_ #}}}

    _(){ #{{{
        local k=''
        for k in "${!var_parts[@]}"; do
            local nv=$(echo "${var_parts[$k]} * $expand_factor" | bc)
            var_parts[$k]=${nv%.*}
        done
    };_ #}}}

    _(){ #{{{
        local e=''
        while read -r e; do
            local size=$(echo "$e" | sed -E 's/.*size=\s*([0-9]*).*/\1/')
            local part=$(echo "$e" | gawk '{print $1}')

            if [[ -n "$size" ]]; then
                if [[ $part == "$SWAP_PART" || $part == "$BOOT_PART" || $part == "$EFI_PART" ]]; then
                    pdata=$(sed "s/$size/${val_parts[$part]}/" < <(echo "$pdata"))
                else
                    [[ $(sector_to_mbyte $size) -le "$MIN_RESIZE" ]] && continue
                    pdata=$(sed "s/$size/${var_parts[$part]}/" < <(echo "$pdata"))
                fi
            fi
        done < <(echo "$pdata" | grep '^/')
    };_ #}}}

    _(){ #{{{
        #Remove fixed offsets and only apply size values. We assume the extended partition ist last!
        pdata=$(sed 's/start=\s*\w*,//g' < <(echo "$pdata"))
        #When a field is absent or empty the default value of size indicates "as much as asossible";
        #Therefore we remove the size for extended partitions
        pdata=$(sed '/type=5/ s/size=\s*\w*,//' < <(echo "$pdata"))
        #and the last partition, if it is not swap or swap should be erased.
        local last_line=$(echo "$pdata" | tail -1 | sed -n -e '$ ,$p')
        if [[ $SWAP_SIZE -eq 0 && $last_line =~ $swap_part || ! $last_line =~ $SWAP_PART ]]; then
            pdata=$(sed '$ s/size=\s*\w*,//g' < <(echo "$pdata"))
        fi
    };_ #}}}

    #Finally remove some headers
    pdata=$(sed '/last-lba:/d' < <(echo "$pdata"))

    _set_type() {
        local p="$1"
        case $TABLE_TYPE in
        dos)
            pdata=$(sed "\|$p| s/type=\w*/type=8e/" < <(echo "$pdata"))
            ;;
        gpt)
            pdata=$(sed "\|$p| s/type=\([[:alnum:]]*-\)*[[:alnum:]]*/type=${ID_GPT_LVM^^}/" < <(echo "$pdata"))
            ;;
        *)
            exit_ 1 "Unsupported partition table $TABLE_TYPE."
            ;;
        esac
    }

    _(){ #{{{
        local p
        for p in "${!TO_LVM[@]}"; do
            [[ ! -d $p ]] && _set_type "$p"
        done
    };_ #}}}

    if [[ $HAS_LUKS == true ]]; then
      [[ $HAS_EFI == true ]] && pdata=$(sed "s/${ID_GPT_LINUX^^}/${ID_GPT_LVM^^}/" < <(echo "$pdata"))
      [[ $(grep -E '^/' < <(echo "$pdata") | wc -l ) -eq 1 ]] && _set_type " "
    fi

    pdata_new="$pdata"
    return 0
} #}}}

# $1: <dest-dev>
mbr2gpt() { #{{{
    logmsg "mbr2gpt"
    local dest="$1"
    local overlap=$(echo q | gdisk "$dest" | grep -E '\d*\s*blocks!' | gawk '{print $1}')
    local pdata=$(sfdisk -d "$dest")

    _(){ #{{{
        if [[ $overlap -gt 0 ]]; then
            local sectors=$(echo "$pdata" | tail -n 1 | grep -o -P 'size=\s*(\d*)' | gawk '{print $2}')
            sfdisk "$dest" < <(echo "$pdata" | sed -e "$ s/$sectors/$((sectors - overlap))/")
        fi
    };_ #}}}

    sync_block_dev "$dest"
    sgdisk -z "$dest"
    sgdisk -g "$dest"
    sync_block_dev "$dest"

    _(){ #{{{
        pdata=$(sfdisk -d "$dest")
        pdata=$(echo "$pdata" | grep 'size=' | sed -e 's/^[^,]*,\s*//; s/uuid=[a-Z0-9-]*,\{,1\}//')
        pdata=$(echo -e "size=1024000, type=${ID_GPT_EFI^^}\n${pdata}")
        local size=$(echo "$pdata" | grep -o -P 'size=\s*(\d*)' | gawk '{print $2}' | tail -n 1)
        pdata=$(echo "$pdata" | sed -e "s/$size/$((size - 1024000))/") #TODO what if n partitions with the same size?
    };_ #}}}

    sfdisk "$dest" < <(echo "$pdata")
    sync_block_dev "$dest"
} #}}}

# $1: <file with lsblk dump>
# $2: <src-dev>
# $3: <dest-dev>
disk_setup() { #{{{
    logmsg "disk_setup"
    local parts=() pvs_parts=()
    local file="$1"
    local src="$2"
    local dest="$3"

    #Collect all source paritions and their file systems
    _scan_src_parts() { #{{{
        local plist=$( echo "$file" \
            | grep 'TYPE="part"' \
            | grep -vE 'PARTTYPE="0x5"'
        )

        local e=''
        while read -r e; do
            read -r name kname fstype uuid partuuid type parttype mountpoint <<<"$e"
            eval "$name" "$kname" "$fstype" "$uuid" "$partuuid" "$type" "$parttype" "$mountpoint"

            [[ $SWAP_SIZE -eq 0 && $FSTYPE == swap ]] && continue

            if [[ $TYPE == part && $FSTYPE != crypto_LUKS ]]; then
                parts+=("${NAME}:${FSTYPE}")
            fi
        done < <(echo "$plist")
        parts=($(printf "%s\n" "${parts[@]}" | sort -k 1 -t ':'))
    } #}}}

    #Create file systems (including swap) or pvs volumes.
    _create_dests() { #{{{
        local plist=$(
            lsblk -Ppo NAME,KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE "$dest" \
                | grep -vE 'PARTTYPE="0x5"' \
                | grep -vE 'TYPE="disk"'
        ) #only partitions
        plist=$(printf "%s\n" "${plist[@]}" | sort -k 1 -t ' ')

        local e=''
        local -i n=0
        while read -r e; do
            local name='' kname='' fstype='' uuid='' partuuid='' type='' parttype=''
            read -r name kname fstype uuid partuuid type parttype <<<"$e"
            eval "$name" "$kname" "$fstype" "$uuid" "$partuuid" "$type" "$parttype"

            local sname='' sfstype=''
            IFS=: read -r sname sfstype <<<${parts[$n]}

            if [[ $sfstype == swap ]]; then
                mkswap -f "$NAME" && continue
            elif [[ ${PARTTYPE} =~ $ID_GPT_LVM|${ID_DOS_LVM} || $sfstype == LVM2_member ]]; then #LVM
                pvcreate -ff "$NAME"
            elif [[ ${PARTTYPE} =~ $ID_GPT_EFI|${ID_DOS_EFI} ]]; then #EFI
                mkfs -t vfat "$NAME"
                [[ $UEFI == true ]] && continue
            elif [[ -n ${sfstype// } ]]; then
                mkfs -t "$sfstype" "$NAME"
            else
                return 1
            fi
            n=$((n + 1))
        done < <(echo "$plist")
    } #}}}

    _scan_src_parts
    _create_dests
    sync_block_dev "$dest"
} #}}}

# $1: <Ref.>
# $2: <dest-mount>
boot_setup() { #{{{
    logmsg "boot_setup"
    local -n sd="$1"
    local dmnt="$2"

    local path=(
        "/cmdline.txt"
        "/etc/fstab"
        "/grub/grub.cfg"
        "/boot/grub/grub.cfg"
        "/etc/initramfs-tools/conf.d/resume"
    )

    local k='' d uuid='' fstype=''
    for k in ${!sd[@]}; do
        sed -i "s|$k|${sd[$k]}|" \
            "$dmnt/${path[0]}" "$dmnt/${path[1]}" \
            "$dmnt/${path[2]}" "$dmnt/${path[3]}" \
            2>/dev/null

        sed -i "s|\(PART\)*UUID=/[^ ]*|${sd[$k]}|" \
            "$dmnt/${path[0]}" "$dmnt/${path[1]}" \
            "$dmnt/${path[2]}" "$dmnt/${path[3]}" \
            2>/dev/null

        #Resume file might be wrong, so we just set it explicitely
        if [[ -e $dmnt/${path[4]} ]]; then
            local name='' uuid='' fstype=''
            read -r name uuid fstype type <<<$(lsblk -lnpo name,uuid,fstype,type "$DEST" | grep 'swap')

            local rplc=''
            if [[ -z $name ]]; then
                rplc="RESUME="
            elif [[ $type == lvm ]]; then
                #For some reson UUID with LVM does not work, though update-initramfs will not complain.
                rplc="RESUME=$name"
            else
                rplc="RESUME=UUID=$uuid"
            fi
            sed -i -E "/RESUME=none/!s|^RESUME=.*|$rplc|i" "$dmnt/${path[4]}" #We don't overwrite none
        fi

        if [[ -e $dmnt/${path[1]} ]]; then
            #Make sure swap is set correctly.
            if [[ $SWAP_SIZE -eq 0 ]]; then
                sed -i '/swap/d' "$dmnt/${path[1]}"
            else
                read -r fstype uuid <<<$(lsblk -lnpo fstype,uuid "$DEST" ${PVS[@]} | grep '^swap')
                sed -i -E "/^[^#].*\bswap/ s/[^ ]*/UUID=$uuid/" "$dmnt/${path[1]}"
            fi
        fi
    done
} #}}}

# $1: <destination to mount>
# $2: <has efi> true|false
# $3: <add efi partition to fstab> true|false
# $4: <dest-dev>
grub_setup() { #{{{
    logmsg "grub_setup"
    local d="$1"
    local has_efi=$2
    local uefi=$3
    local dest="$4"
    local mp r=0
    local resume=$(lsblk -lpo name,fstype "$DEST" | grep swap | gawk '{print $1}')

    mount_ "$d" || exit_ 1 "Could not mount ${d}."
    mp=$(get_mount "$d") || exit_ 1 "Could not find mount journal entry for $d. Aborting!" #do not use local, $? will be affected!

    sed -i -E '/GRUB_CMDLINE_LINUX=/ s|[a-z=]*UUID=[-0-9a-Z]*[^ ]*[^\"]||' "$mp/etc/default/grub"
    sed -i -E "/GRUB_CMDLINE_LINUX_DEFAULT=/ s|resume=[^ \"]*|resume=$resume|" "$mp/etc/default/grub"
    sed -i -E '/GRUB_ENABLE_CRYPTODISK=/ s/=./=n/' "$mp/etc/default/grub"
    sed -i 's/^/#/' "$mp/etc/crypttab"
    mount_chroot "$mp"

    _(){ #{{{
        local m=''
        for m in $(echo ${!MOUNTS[@]} | tr ' ' '\n' | grep -E '^/' | grep -vE '^/dev' | sort -u); do
            if [[ -n ${SRC2DEST[${MOUNTS[$m]}]} ]]; then
                local ddev='' rest=''
                IFS=: read -r ddev rest <<<"${DESTS[${SRC2DEST[${MOUNTS[$m]}]}]}"
                mount_ "$ddev" -p "$mp/$m" || exit_ 1 "Failed to mount $ddev to ${mp/$m}."
            fi
        done

        (( ${#TO_LVM[@]} > 0 )) && mount_exta_lvm -d $mp
    };_ #}}}

    _(){ #{{{
        if [[ $uefi == true && $has_efi == true ]]; then
            local name='' uuid='' parttype=''
            read -r name uuid parttype <<<"$(lsblk -pPo name,uuid,parttype "$dest" | grep -i $ID_GPT_EFI)"
            eval "$name" "$uuid" "$parttype"
            echo -e "UUID=${UUID}\t/boot/efi\tvfat\tumask=0077\t0\t1" >>"$mp/etc/fstab"
            mkdir -p "$mp/boot/efi" && mount_ "$NAME" -p "$mp/boot/efi"
        fi

        local d=''
        for d in ${DISABLED_MOUNTS[@]}; do
            sed -i "\|\s$d\s| s|^|#|" "$mp/etc/fstab"
        done
    };_ #}}}

    if [[ $has_efi == true ]]; then
        local apt_pkgs="grub-efi-amd64-signed shim-signed"
        REMOVE_PKGS+=(grub-pc)
    else
        local apt_pkgs="grub-pc"
    fi

    pkg_remove "$mp" "${REMOVE_PKGS[*]}" || return 1
    [[ ${#TO_LVM[@]} -gt 0 ]] && { pkg_install "$mp" "lvm2" || return 1; }
    grub_install "$mp" "$dest" "$apt_pkgs" || return 1

    if [[ $UPDATE_EFI_BOOT == true ]]; then
        update_efi_boot "$mp" "$EFI_BOOT_IMAGE" || r=2
    fi

    create_rclocal "$mp"
    umount_chroot
    return $r
} #}}}

# $1: <password>
# $2: <destination to mount>
# $3: <dest-dev>
# $4: <luks_lvm_name>
# $5: <encrypt_part>
crypt_setup() { #{{{
    logmsg "crypt_setup"
    local passwd="$1"
    local d="$2"
    local dest="$3"
    local luks_lvm_name="$4"
    local encrypt_part="$5"
    local mp="${MNTPNT}/$d"

    mount_ "$d" && { mpnt=$(get_mount $d) || exit_ 1 "Could not find mount journal entry for $d. Aborting!"; }
    mount_chroot "$mp"

    _(){ #{{{
        local m='' ddev='' rest=''
        for m in $(echo ${!MOUNTS[@]} | tr ' ' '\n' | grep -E '^/' | grep -vE '^/dev' | sort -u); do
            if [[ -n ${SRC2DEST[${MOUNTS[$m]}]} ]]; then
                IFS=: read -r ddev rest <<<${DESTS[${SRC2DEST[${MOUNTS[$m]}]}]}
                mount_ "$ddev" -p "$mp/$m" || exit_ 1 "Failed to mount $ddev to ${mp/$m}."
            fi
        done

        (( ${#TO_LVM[@]} > 0 )) && mount_exta_lvm -d $mp
    };_ #}}}

    _(){ #{{{
        if [[ $UEFI == true && $HAS_EFI == true ]]; then
            local name='' uuid='' parttype=''
            read -r name uuid parttype <<<"$(lsblk -pPo name,uuid,parttype "$DEST" | grep -i $ID_GPT_EFI)"
            eval "$name" "$uuid" "$parttype"
            echo -e "UUID=${UUID}\t/boot/efi\tvfat\tumask=0077\t0\t1" >>"$mp/etc/fstab"
            mkdir -p "$mp/boot/efi" && mount_ "$NAME" -p "$mp/boot/efi"
        fi
    };_ #}}}

    local apt_pkgs=(cryptsetup keyutils)

    if [[ $HAS_EFI == true ]]; then
        apt_pkgs+=(grub-efi-amd64)
    else
        apt_pkgs+=(grub-pc)
    fi

    printf '%s' '#!/bin/sh
    exec /bin/cat /${1}' >"$mp/home/dummy" && chmod +x "$mp/home/dummy"

    printf '%s' '#!/bin/sh
    set -e

    PREREQ=\"\"

    prereqs()
    {
        echo "$PREREQ"
    }

    case $1 in
    prereqs)
        prereqs
        exit 0
        ;;
    esac

    . /usr/share/initramfs-tools/hook-functions

    cp -a /crypto_keyfile.bin $DESTDIR/crypto_keyfile.bin
    mkdir -p $DESTDIR/home
    cp -a /home/dummy $DESTDIR/home

    exit 0' >"$mp/etc/initramfs-tools/hooks/lukslvm" && chmod +x "$mp/etc/initramfs-tools/hooks/lukslvm"

    dd oflag=direct bs=512 count=4 if=/dev/urandom of="$mp/crypto_keyfile.bin"
    echo -n "$1" | cryptsetup luksAddKey "$encrypt_part" "$mp/crypto_keyfile.bin" -
    chmod 000 "$mp/crypto_keyfile.bin"

    # local dev=$(lsblk -asno pkname /dev/mapper/$luks_lvm_name | head -n 1)
    echo "$luks_lvm_name UUID=$(cryptsetup luksUUID "$encrypt_part") /crypto_keyfile.bin luks,keyscript=/home/dummy" >"$mp/etc/crypttab"

    sed -i -E '/GRUB_CMDLINE_LINUX=/ s|[a-z=]*UUID=[-0-9a-Z]*[^ ]*[^\"]||' "$mp/etc/default/grub"

    grep -q 'GRUB_CMDLINE_LINUX' "$mp/etc/default/grub" \
        && sed -i -E "/GRUB_CMDLINE_LINUX=/ s|\"(.*)\"|\"cryptdevice=UUID=$(cryptsetup luksUUID $encrypt_part):$luks_lvm_name \1\"|" "$mp/etc/default/grub" \
        || echo "GRUB_CMDLINE_LINUX=cryptdevice=UUID=$(cryptsetup luksUUID $encrypt_part):$luks_lvm_name" >>"$mp/etc/default/grub"

    grep -q 'GRUB_ENABLE_CRYPTODISK' "$mp/etc/default/grub" \
        && sed -i -E '/GRUB_ENABLE_CRYPTODISK=/ s/=./=y/' "$mp/etc/default/grub" \
        || echo "GRUB_ENABLE_CRYPTODISK=y" >>"$mp/etc/default/grub"

    sed -i -E "/GRUB_CMDLINE_LINUX_DEFAULT=/ s|resume=[^ \"]*|resume=$resume|" "$mp/etc/default/grub"

    pkg_remove "$mp" "$REMOVE_PKGS" || return 1
    [[ ${#TO_LVM[@]} -gt 0 ]] && { pkg_install "$mp" "lvm2" || return 1; }
    grub_install "$mp" "$dest" "${apt_pkgs[*]}" || return 1
    [[ $UPDATE_EFI_BOOT == true ]] && update_efi_boot "$mp" "$EFI_BOOT_IMAGE"

    create_rclocal "$mp"
    umount_chroot
} #}}}

# $1: <full path>
# $2: <type>
# $3: <size>
create_image() { #{{{
    logmsg "create_image"
    local img="$1"
    local type="$2"
    local size="$3"
    local options=""

    case "$type" in
    vdi)
        options="$options -o static=on"
        ;;
    esac
    logmsg "qemu-img create -f $type $options $img $size"
    # shellcheck disable=SC2086
    qemu-img create -f "$type" $options "$img" "$size" || return 1
} #}}}
#}}}

#--- Value conversion and calculation --- {{{

#TODO Check if valid and still needed
# $1: <file>
pad_novalue() { #{{{
    local file="$1"
    while echo "$file" | sed '/\.\./!{q10}' > /dev/null; do
        file=$(echo "$file" | sed 's/\.\./\.NOVALUE\./')
    done
    echo "$file"
} #}}}

# $1: <bytes>
to_readable_size() { #{{{
    local size=$(to_byte $1)
    local dimension=B

    local d=''
    for d in K M G T P; do
        if (($(echo "scale=2; $size / 2 ^ 10 >= 1" | bc -l))); then
            size=$(echo "scale=2; $size / 2 ^ 10" | bc)
            dimension="$d"
        else
            echo "${size}${dimension}"
            return 0
        fi
    done

    echo "${size}${dimension}"
    return 0
} #}}}

# $1: <number+K|M|G|T>
to_byte() { #{{{
    local p=$1
    [[ $p =~ ^[0-9]+(k|K)$ ]] && echo $((${p%[a-zA-Z]} * 2 ** 10))
    [[ $p =~ ^[0-9]+(m|M)$ ]] && echo $((${p%[a-zA-Z]} * 2 ** 20))
    [[ $p =~ ^[0-9]+(g|G)$ ]] && echo $((${p%[a-zA-Z]} * 2 ** 30))
    [[ $p =~ ^[0-9]+(t|T)$ ]] && echo $((${p%[a-zA-Z]} * 2 ** 40))
    { [[ $p =~ ^[0-9]+$ ]] && echo "$p"; } || return 1
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_kbyte() { #{{{
    local v=$1
    validate_size "$v" && v=$(to_byte "$v")
    echo $((v / 2 ** 10))
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_mbyte() { #{{{
    local v=$1
    validate_size "$v" && v=$(to_byte "$v")
    echo $((v / 2 ** 20))
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_gbyte() { #{{{
    local v=$1
    validate_size "$v" && v=$(to_byte "$v")
    echo $((v / 2 ** 30))
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_tbyte() { #{{{
    local v=$1
    validate_size "$v" && v=$(to_byte "$v")
    echo $((v / 2 ** 40))
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
validate_size() { #{{{
    [[ $1 =~ ^[0-9]+(K|k|M|m|G|g|T|t) ]] && return 0 || return 1
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_sector() { #{{{
    local v=$1
    validate_size "$v" && v=$(to_byte "$v")
    echo $((v / 512))
} #}}}

# $1: <sectos> of 512 Bytes
sector_to_kbyte() { #{{{
    local v=$1
    [[ ! $v =~ ^[0-9]+$ ]] && return 1
    echo $((v / 2))
} #}}}

# $1: <sectos> of 512 Bytes
sector_to_mbyte() { #{{{
    local v=$1
    [[ ! $v =~ ^[0-9]+$ ]] && return 1
    echo $((v / (2 * 2 ** 10)))
} #}}}

# $1: <sectos> of 512 Bytes
sector_to_gbyte() { #{{{
    local v=$1
    [[ ! $v =~ ^[0-9]+$ ]] && return 1
    echo $((v / (2 * 2 ** 20)))
} #}}}

# $1: <sectos> of 512 Bytes
sector_to_tbyte() { #{{{
    local v=$1
    [[ ! $v =~ ^[0-9]+$ ]] && return 1
    echo $((v / (2 * 2 ** 30)))
} #}}}
#}}}


#}}}

# PUBLIC - To be used in Main() only ----------------------------------------------------------------------------------{{{

Cleanup() { #{{{
    {
        logmsg "Cleanup"
        if [[ $IS_CLEANUP == true ]]; then
            umount_
            [[ $SCHROOT_HOME =~ ^/tmp/ ]] && rm -rf "$SCHROOT_HOME" #TODO add option to overwrite and show warning
            rm "$F_SCHROOT_CONFIG"
            [[ $VG_SRC_NAME_CLONE && -b $DEST ]] && vgchange -an "$VG_SRC_NAME_CLONE"
            [[ -n $ENCRYPT_PWD ]] && cryptsetup close "/dev/mapper/$LUKS_LVM_NAME"

            [[ -n $DEST_IMG ]] && qemu-nbd -d $DEST_NBD
            if [[ -n $SRC_IMG ]]; then
                vgchange -an ${VG_SRC_NAME}
                qemu-nbd -d "$SRC_NBD"
                rmmod nbd
            fi

            find "$MNTPNT" -xdev -depth -type d -empty ! -exec mountpoint -q {} \; -exec rmdir {} \;
            rmdir "$MNTPNT"
        fi
        if [[ $SYS_CHANGED == true ]]; then
            systemctl --runtime unmask sleep.target hibernate.target suspend.target hybrid-sleep.target
            message -i -t "Re-enabling previously deactived power management settings."
        fi
        lvremove -f "${VG_SRC_NAME}/$SNAP4CLONE" &>/dev/null
        rm "$FIFO"
        flock -u 200
    } &>/dev/null

    _(){ #{{{
        #Check if system files have been changed for execution and restore
        local f='' failed=()
        for f in "${!CHG_SYS_FILES[@]}"; do
            if [[ ${CHG_SYS_FILES["$f"]} == $(md5sum "${BACKUP_FOLDER}/${f}" | gawk '{print $1}') ]]; then
                cp "${BACKUP_FOLDER}/${f}" "$f"
            else
                failed+=("$f")
            fi
        done
    };_ #}}}
    [[ ${#failed[@]} -gt 0 ]] && message -n -t "Backups of original file(s) ${f[*]} changed. Will not restore. Check ${BACKUP_FOLDER}."

    exec 1>&3
    tput cnorm

    exec 200>&-
    exit "$EXIT" #Make sure we really exit the script!
} #}}}

To_file() { #{{{
    logmsg "To_file"
    if [ -n "$(ls "$DEST")" ]; then return 1; fi

    pushd "$DEST" >/dev/null || return 1

    vendor_list "${PKGS[*]}" >"$DEST/$F_VENDOR_LIST" || exit_ 1 "Cannot create vendor list."

    _save_disk_layout() { #{{{
        logmsg "To_file@_save_disk_layout"
        local snp=$(
            sudo lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_active,lv_role \
                | grep 'snap' \
                | sed -e 's/^\s*//' \
                | gawk '{print $1}'
        )

        [[ -z $snp ]] && snp="NOSNAPSHOT"

        if [[ $IS_LVM == true ]]; then
            pvs --noheadings -o pv_name,vg_name,lv_active \
                | grep 'active$' \
                | sed -e 's/active$//;s/^\s*//' \
                | uniq \
                | grep -E "\b$VG_SRC_NAME\b" >$F_PVS_LIST

            vgs --noheadings --units m --nosuffix -o vg_name,vg_size,vg_free,lv_active \
                | grep 'active$' \
                | sed -e 's/active$//;s/^\s*//' \
                | uniq \
                | grep -E "\b$VG_SRC_NAME\b" >$F_VGS_LIST

            lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_active,lv_role,lv_dm_path \
                | grep -v 'snap' \
                | grep 'active public.*' \
                | sed -e 's/^\s*//; s/\s*$//' \
                | grep -E "\b$VG_SRC_NAME\b"  >$F_LVS_LIST
        fi

        SECTORS_SRC="$(blockdev --getsz $SRC)"
        sfdisk -d "$SRC" >"$F_PART_TABLE"

        sleep 3 #IMPORTANT !!! So changes by sfdisk can settle.
        #Otherwise resultes from lsblk might still show old values!
        $LSBLK_CMD "$SRC" | grep -v "$snp" >"$F_PART_LIST"
    } #}}}

    _copy() { #{{{
        local sdev="$1" mpnt="$2" file="$3" excludes=()
        local cmd="tar --warning=none --atime-preserve=system --numeric-owner --xattrs --directory=$mpnt"
        local ss=${MOUNTS[$sdev]}

        _(){ #{{{
            local x='' excl="--exclude='./run/*' --exclude='./tmp/*' --exclude='./proc/*' --exclude='./dev/*' --exclude='./sys/*'"
            for x in ${SRC_EXCLUDES[@]}; do
                [[ $x =~ ^$ss ]] && excl="$excl --exclude=.$x"
            done
        };_ #}}}

        [[ -n $4 ]] && excludes=(${EXCLUDES[$4]//:/ })

        _(){ #{{{
            if [[ -z $excludes ]]; then
                cmd="$cmd $excl "
            else
                local ex=''
                for ex in ${excludes[@]}; do
                    cmd="$cmd --exclude='$ex'"
                done
            fi
        };_ #}}}

        _(){ #{{{
            if [[ $INTERACTIVE == true ]]; then
                local ipc=$(mktemp)
                du --bytes $excl -s -x $mpnt | gawk '{print $1}' > $ipc &
                spinner $! "Creating backup for $sdev" "scan"
                local size=$(cat $ipc)

                if [[ $SPLIT == true ]]; then
                    cmd="$cmd -Scpvf - . 2>$LOG_PATH/bcrm.${file}.log | pv --interval 0.5 --numeric -s $size | split -b 1G - $file"
                else
                    cmd="$cmd -Scpvf - . 2>$LOG_PATH/bcrm.${file}.log | pv --interval 0.5 --numeric -s $size > $file"
                fi

                local e=''
                mkfifo "$FIFO"
                {
                    eval "$cmd" 2>"$FIFO"
                } &

                local e=''
                while read -r e; do
                    [[ $e -ge 100 ]] && e=100 #Just a precaution
                    message -u -c -t "Creating backup for $sdev [ $(printf '%3d%%' $e) ]"
                done < "$FIFO"
                message -u -c -t "Creating backup for $sdev [ $(printf '%3d%%' 100) ]" #In case we are faster than the update interval of pv, especially when at 98-99%.
            else
                message -c -t "Creating backup for $sdev"
                if [[ $SPLIT == true ]]; then
                    cmd="$cmd -Scpf - . 2>$LOG_PATH/bcrm.${file}.log | split -b 1G - $file"
                else
                    cmd="$cmd -Scpf $file . 2>$LOG_PATH/bcrm.${file}.log"
                fi
                eval "$cmd"
            fi
        };_ #}}}

        _(){ #{{{
            if [[ LIVE_CHECKSUMS == true ]]; then
                logmsg "Creating Checksums for backup of $sdev"
                path="$(dirname $(readlink -f "$file"))"
                tar -tf "$file" >> "$file.list"
                cd "$mpnt"
                local l=''
                while read -r l; do
                    [[ -f $l ]] && md5sum "$l" >> "$path/${file}.md5"
                done < "$path/${file}.list"
            fi
        };_ #}}}
        message -y
        g=$((g + 1))
    } #}}}

    _(){ #{{{
        message -c -t "Creating backup of disk layout"
        {
            _save_disk_layout
            init_srcs "$($LSBLK_CMD ${VG_DISKS[@]:-$SRC})"

            local k='' av=''
            for k in "${!DEVICE_MAP[@]}"; do
                av+="[$k]=\"${DEVICE_MAP[$k]}\" ";
            done

            echo "DEVICE_MAP=($av)" > $F_DEVICE_MAP
            mounts
        }
        message -y
    };_ #}}}

    if [[ $IS_LVM ]]; then
        local vg_src_name=$(pvs --noheadings -o pv_name,vg_name | grep "$SRC" | xargs | gawk '{print $2}')
        if [[ -z $vg_src_name ]]; then
            while read -r e g; do
                grep -q "${SRC##*/}" < <(dmsetup deps -o devname "$e" | sed 's/.*(\(\w*\).*/\1/g') && vg_src_name="$g"
            done < <(pvs --noheadings -o pv_name,vg_name | xargs)
        fi

        local lvs_data=$(lvs --noheadings -o lv_name,lv_dm_path,vg_name \
            | grep "\b${vg_src_name}\b"
        )

        local src_vg_free=$( vgs --noheadings --units m --nosuffix -o vg_name,vg_free \
            | grep "\b${vg_src_name}\b" \
            | gawk '{print $2}'
        )
    fi

    _(){ #{{{
        #TODO check usage of mount, mountpoint. Should be only one in use.
        local s g=0 mpnt sdev fs spid ptype type used size
        for s in ${!SRCS[@]}; do
            local tdev sid=$s
            IFS=: read -r sdev fs spid ptype type mountpoint used size <<<${SRCS[$s]}
            local mount=${MOUNTS[$sid]:-${MOUNTS[$spid]}}

            if [[ $type == lvm ]]; then
                local lv_src_name=$(grep $sdev <<<"$lvs_data" | gawk '{print $1}')
            fi

            if [[ $type == lvm && "${src_vg_free%%.*}" -ge "500" && -z $SRC_IMG ]]; then
                tdev="/dev/${VG_SRC_NAME}/$SNAP4CLONE"
                lvremove -f "${VG_SRC_NAME}/$SNAP4CLONE" &>/dev/null #Just to be sure
                lvcreate -l100%FREE -s -n $SNAP4CLONE "${VG_SRC_NAME}/$lv_src_name"
            else
                if [[ $type == lvm && "${src_vg_free%%.*}" -lt "500" && -z $SRC_IMG ]]; then
                    message -w -t "No snapshot for cloning created."
                    [[ $IS_CHECKSUM == true  ]] && message -w -t "Integrity checks disabled."
                fi
                [[ -z ${mountpoint// } ]] && tdev="$sdev" || tdev="$mountpoint"
            fi

            mount_ "$tdev" || exit_ 1 "Could not mount ${tdev}."
            mpnt=$(get_mount "$tdev")  || exit_ 1 "Could not find mount journal entry for $tdev. Aborting!"

            [[ -n $XZ_OPT ]] && cmd="$cmd --xz"

            sid=${sid// }
            spid=${spid// }
            local file="${g}.${sid// }.${spid// }.${fs// }.${type// }.${used}.${sdev//\//_}.${mount//\//_}"

            _(){ #{{{
                if [[ -s $mpnt/etc/fstab ]]; then
                    local f=''
                    for f in */$mpnt; do
                        du -sb "$f" >> $F_ROOT_FOLDER_DU
                    done
                fi
            };_ #}}}

            _copy "$sdev" $mpnt "$file"

            _(){ #{{{
                local em=''
                for em in ${!EXT_PARTS[@]}; do
                    local l=${MOUNTS[$s]}
                    local e=${EXT_PARTS[$em]}

                    if [[ $l == $(find_mount_part $em ) ]]; then
                        local user password
                        read -r user password <<<${CHOWN[$em]/:/ }

                        mount_ "$e"
                        local mpnt_e=$(get_mount $e) || exit_ 1 "Could not find mount journal entry for $e. Aborting!"
                        local file="${g}.${sid// }.${spid// }.${fs// }.${type// }.${used}.${sdev//\//_}.${mount//\//_}.${em//\//_}.${user}.${password}"

                        _copy "$e" "$mpnt_e" "$file" "$em"
                        umount_ "$e"
                    fi
                done
            };_ #}}}

            [[ -f $mpnt/grub/grub.cfg || -f $mpnt/grub.cfg || -f $mpnt/boot/grub/grub.cfg ]] && HAS_GRUB=true
            umount_ "$tdev"
            [[ $type == lvm ]] && lvremove -f "${VG_SRC_NAME}/$SNAP4CLONE"
        done
    };_ #}}}

    popd >/dev/null || return 1

    ctx_save

    if [[ $IS_CHECKSUM == true ]]; then
        message -c -t "Creating checksums"
        {
            create_m5dsums "$DEST" "$F_CHESUM" || return 1
        }
        message -y
    fi

    return 0
} #}}}

Clone() { #{{{
    logmsg "Clone"
    local OPTIND

    while getopts ':r' option; do
        case "$option" in
        r)
            _RMODE=true
            ;;
        :)
            printf "missing argument for -%s\n" "$OPTARG" >&2
            return 1
            ;;
        ?)
            printf "illegal option: -%s\n" "$OPTARG" >&2
            return 1
            ;;
        esac
    done
    shift $((OPTIND - 1))

    _lvm_setup() { #{{{
        logmsg "[ Clone ] _lvm_setup"
        local s1='' s2=''
        local dest=$1
        local -A src_lfs

        vgcreate "$VG_SRC_NAME_CLONE" $(pvs --noheadings -o pv_name | grep "$dest" | tr -d ' ')
        [[ $PVALL == true ]] && vg_extend "$VG_SRC_NAME_CLONE" "$SRC" "$DEST"

        local lvs_cmd='lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_active,lv_role,lv_dm_path'
        local lvm_data=$({ [[ $_RMODE == true ]] && cat "$SRC/$F_LVS_LIST" || $lvs_cmd; } | grep -E "\b$VG_SRC_NAME\b")

        local vg_data=$(vgs --noheadings --units m --nosuffix -o vg_name,vg_size,vg_free | grep -E "\b$VG_SRC_NAME\b|\b$VG_SRC_NAME_CLONE\b")
        [[ $_RMODE == true ]] && vg_data=$(echo -e "$vg_data\n$(cat $SRC/$F_VGS_LIST)")

        local -i fixd_size_dest=0
        local -i fixd_size_src=0
        local created=()

        _create_fixed() { #{{{ TODO works, but should be factored out to avoid multiple nesting!
            local part="$1"
            local part_size=$2

            local d=''
            for d in ${DEVICE_MAP[$part]}; do
                if echo "$lvm_data" | grep -q "$d\|$part"; then
                    local name size
                    read -r name size <<<$(echo "$lvm_data" | grep "$d\|$part" | gawk '{print $1, $3}')
                    local part_size_src=${size%%.*}
                    local part_size_dest=${size%%.*}

                    [[ $part_size -ge 0 ]] && part_size_dest=$(to_mbyte ${part_size}K)

                    if [[ $part_size_dest -gt 0 ]]; then
                        fixd_size_src+=$part_size_src
                        fixd_size_dest+=$part_size_dest
                        lvcreate --yes -L$part_size_dest -n "$name" "$VG_SRC_NAME_CLONE"
                        created+=($name)
                    fi
                fi
            done

            if [[ -n ${TO_LVM[$part]} ]]; then
                local partid=$(get_uuid $part)
                local lv_name=${TO_LVM[$part]}
                IFS=: read -r sname fs spid ptype type mp used size <<<"${SRCS[$partid]}"
                size=$(to_mbyte ${size}K)
                local part_size_src=${size%%.*}
                local part_size_dest=${size%%.*}

                [[ $part_size -ge 0 ]] && part_size_dest=$(to_mbyte ${part_size}K)

                if [[ $part_size_dest -gt 0 ]]; then
                    fixd_size_src+=$part_size_src
                    fixd_size_dest+=$part_size_dest
                    lvcreate --yes -L$part_size_dest -n $lv_name "$VG_SRC_NAME_CLONE"
                    created+=($name)
                fi
            fi
        } #}}}

        [[ -n $SWAP_PART ]] && _create_fixed "$SWAP_PART" $SWAP_SIZE
        [[ -n $BOOT_PART ]] && _create_fixed "$BOOT_PART" $BOOT_SIZE

        _(){ #{{{
            local l=''
            for l in ${!TO_LVM[@]}; do
                if [[ -d $l ]]; then
                    IFS=: read -r lv_name size fs <<<"${TO_LVM[$l]}"
                    local size=$(to_mbyte $size)
                    local part_size_src=${size%%.*}
                    local part_size_dest=${size%%.*}

                    if [[ $part_size_dest -gt 0 ]]; then
                        fixd_size_dest+=$part_size_dest
                        lvcreate --yes -L$part_size_dest -n $lv_name "$VG_SRC_NAME_CLONE"
                    fi
                fi
            done
        };_ #}}}

        _(){ #{{{
            local e=''
            while read -r e; do
                local vg_name='' vg_size='' vg_free='' src_vg_free=''
                read -r vg_name vg_size vg_free <<<"$e"
                [[ $vg_name == "$VG_SRC_NAME" ]] && s1=$((${vg_size%%.*} - ${vg_free%%.*} - $fixd_size_src)) && src_vg_free=${vg_free%%.*}
                [[ $vg_name == "$VG_SRC_NAME_CLONE" ]] && s2=$((${vg_free%%.*} - $fixd_size_dest - $VG_FREE_SIZE))
            done < <(echo "$vg_data")
            [[ $VG_FREE_SIZE -eq 0  ]] && s2=$((s2 - src_vg_free))
        };_ #}}}

        _(){ #{{{
            local f=''
            for f in ${!SRCS[@]}; do
                local sname='' fs='' spid='' ptype='' type='' used='' mp='' size='' lsize='' lv_size=''
                IFS=: read -r sname fs spid ptype type mp used size <<<"${SRCS[$f]}"
                if grep -qE "${sname}" < <(echo "${!TO_LVM[@]}" | tr ' ' '\n'); then
                    lv_size=$(to_mbyte ${size}K)
                    s2=$((s2 - lv_size))
                fi
            done
        };_ #}}}

        _(){ #{{{
            if [[ ($ALL_TO_LVM == true || ${#TO_LVM[@]} -gt 0) && $IS_LVM == false ]]; then
                local e=''
                while read -r e; do
                    local vg_name='' vg_size='' vg_free=''
                    read -r vg_name vg_size vg_free <<<"$e"
                    [[ $vg_name == "$VG_SRC_NAME_CLONE" ]] && s2=$((${vg_free%%.*} - $fixd_size_dest - $VG_FREE_SIZE))
                done < <(echo "$vg_data")

                local f=$({ [[ $_RMODE == true ]] && cat "$SRC/$F_PART_LIST" || $LSBLK_CMD "$SRC"; } | grep 'SWAP')
                if [[ -n $f  ]]; then
                    local name='' kdev='' fstype='' uuid='' puuid='' type='' parttype='' mountpoint='' size=''
                    read -r name kdev fstype uuid puuid type parttype mountpoint size <<<"$f"
                    eval local "$name" "$kdev" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint" "$size"
                    src_swap=$(to_mbyte $SIZE)
                    s1=$(sector_to_mbyte $SECTORS_SRC)
                    s1=$((s1 - src_swap - fixd_size_src))
                fi
            fi
        };_ #}}}

        scale_factor=$(echo "scale=4; $s2 / $s1" | bc)

        local -A expands

        #TODO rework this and the next block. Currently there are two stage, LVM and ALL_TO_LVM using SRC
        #SWAP is excluded from LVM conversion, too
        _(){ #{{{
            local lv_name vg_name lv_size vg_size vg_free lv_active lv_role lv_dm_path e size
            while read -r e; do
                read -r lv_name vg_name lv_size vg_size vg_free lv_active lv_role lv_dm_path <<<"$e"
                lv_size=${lv_size%%.*}
                if [[ $vg_name == "$VG_SRC_NAME" && -n $VG_SRC_NAME ]]; then
                    for c in ${created[@]}; do
                        [[ $c == $lv_name ]] && continue 2
                    done

                    [[ $lv_dm_path == "$SWAP_PART" ]] && continue
                    (( ${LVM_EXPAND_BY[$lv_name]:-0} >0 )) && expands[$lv_name]="$lv_size" && continue
                    [[ $lv_role =~ snapshot ]] && continue

                    if (( ${LVM_SIZE_TO[$lv_name]:-0} >0 )); then
                        lvcreate --yes -L"${LVM_SIZE_TO[$lv_name]}" -n "$lv_name" "$VG_SRC_NAME_CLONE" || exit_ 1 "LV creation of $lv_name failed."
                    elif ((s1 < s2)); then
                        lvcreate --yes -L"$lv_size" -n "$lv_name" "$VG_SRC_NAME_CLONE" || exit_ 1 "LV creation of $lv_name failed."
                    else
                        size=$(echo "scale=0; $lv_size * $scale_factor / 1" | bc)
                        lvcreate --yes -L$size -n "$lv_name" "$VG_SRC_NAME_CLONE" || exit_ 1 "LV creation of $lv_name failed."
                    fi
                fi
            done < <(echo "$lvm_data")
        };_ #}}}

        _(){ #{{{
            local f sname fs spid ptype type mp used size lsize
            for f in "${!SRCS[@]}"; do
                IFS=: read -r sname fs spid ptype type mp used size <<<"${SRCS[$f]}"

                local vg_free=$( vgs --noheadings --units m --nosuffix -o vg_name,vg_free \
                    | grep "\b${VG_SRC_NAME_CLONE}\b" \
                    | gawk '{print $2}'
                )

                vg_free=$(( ${vg_free%%.*} - $VG_FREE_SIZE ))

                local lv_size=''
                if [[ -n ${TO_LVM[$sname]} && $sname != "$BOOT_PART" ]] ; then
                    lv_size=$(to_mbyte ${size}K) #TODO to_mbyte should be able to deal with floats
                    ((s1 > s2)) && lv_size=$(echo "scale=0; $lv_size * $scale_factor / 1" | bc)
                    (( vg_free < lv_size  )) && lv_size=$vg_free
                    lvcreate --yes -L$lv_size -n "${TO_LVM[$sname]}" "$VG_SRC_NAME_CLONE" || return 1
                fi
            done
        };_ #}}}

        local -i free=$(declare f=$(vgs --noheadings --nosuffix --units m -o vg_free $VG_SRC_NAME_CLONE); echo ${f%%.*})
        _(){ #{{{
            local e=''
            for e in ${!expands[@]}; do
                free=$((free - expands[$e]))
            done
        };_ #}}}

        _(){ #{{{
            local e=''
            for e in ${!expands[@]}; do
                local size=''
                if (( LVM_EXPAND_BY[$e] >0 )); then
                    size=$(echo "scale=0; ${expands[$e]} + ($free * ${LVM_EXPAND_BY[$e]} / 100)" | bc)
                    lvcreate --yes -L"$size" -n "$e" "$VG_SRC_NAME_CLONE"
                elif (( LVM_SIZE_TO[$e] >0 )) ; then
                    lvcreate --yes -L${LVM_SIZE_TO[$e]} -n "$e" "$VG_SRC_NAME_CLONE"
                fi
            done
        };_ #}}}

        _(){ #{{{
            local s=''
            for s in "${!SRCS[@]}"; do
                local name='' fs='' pid='' ptype='' type='' mp='' used='' size=''
                IFS=: read -r name fs pid ptype type mp used size <<<"${SRCS[$s]}"
                [[ $type == 'lvm' ]] && src_lfs[${name##*-}]=$fs
                [[ $type == 'part' ]] && grep -qE "${name}" < <(echo "${!TO_LVM[@]}" | tr ' ' '\n') && src_lfs[${TO_LVM[$name]}]=$fs
            done

			local l=''
            for l in "${!TO_LVM[@]}"; do
                local lv_name='' size='' fs=''
                IFS=: read -r lv_name size fs <<<"${TO_LVM[$l]}"
                [[ -n $fs ]] && src_lfs[$lv_name]=$fs
            done
        };_ #}}}

        _(){ #{{{
            local e=''
            while read -r e; do
                local lv_name='' dm_path='' type=''
                read -r lv_name dm_path type <<<"$e"
                [[ $dm_path =~ swap ]] && mkswap -f "$dm_path" && continue
                [[ -z ${src_lfs[$lv_name]} ]] && exit_ 1 "Unexpected Error" #Yes, I know... but has to do for the moment!
                { [[ "${src_lfs[$lv_name]}" == swap ]] && mkswap -f "$dm_path"; } || mkfs -t "${src_lfs[$lv_name]}" "$dm_path"
            done < <(lvs --no-headings -o lv_name,dm_path "$VG_SRC_NAME_CLONE" | gawk '{print $1,$2}')
        };_ #}}}
    } #}}}

    _prepare_disk() { #{{{
        logmsg "[ Clone ] _prepare_disk"
        if hash lvm 2>/dev/null; then
            # local vgname=$(vgs -o pv_name,vg_name | eval grep "'${DEST}|${VG_DISKS/ /|}'" | gawk '{print $2}')
            local vgname=$(vgs -o pv_name,vg_name | grep "${DEST}" | gawk '{print $2}')
            vgreduce --removemissing "$vgname"
            vgremove -f "$vgname"
            pvremove -f "${DEST}*"

            local e=''
            while read -r e; do
                echo "pvremove -f $e"
                pvremove "$e" || exit_ 1 "Cannot remove PV $e"
            done < <(pvs --noheadings -o pv_name,vg_name | grep -E '(/\w*)+(\s+)$')
        fi

        dd oflag=direct if=/dev/zero of="$DEST" bs=512 count=100000
        dd oflag=direct bs=512 if=/dev/zero of="$DEST" count=4096 seek=$(($(blockdev --getsz "$DEST") - 4096)) #TODO still needed?

        #For some reason sfdisk < 2.29 does not create PARTUUIDs when importing a partition table.
        #But when we create a partition and afterward import a prviously dumped partition table, it works!
        # echo -e "n\np\n\n\n\nw\n" | fdisk "$DEST"

        sleep 3

        if [[ -n $ENCRYPT_PWD ]]; then
            encrypt "$ENCRYPT_PWD" "$DEST" "$LUKS_LVM_NAME"
        else
            local ptable="$(if [[ $_RMODE == true ]]; then cat "$SRC/$F_PART_TABLE"; else sfdisk -d "$SRC"; fi)"
            expand_disk "$SECTORS_SRC" "$SECTORS_DEST" "$ptable" 'ptable'
            if [[ $UNIQUE_CLONE == true ]]; then
                grep -E 'label:\s*dos' < <(echo "$ptable") &&
                    ptable=$(echo "$ptable" | sed "s/\(label-id:\).*/\1 0x$(xxd -l 4 -p /dev/urandom)/")
            fi
            sfdisk --force "$DEST" < <(echo "$ptable")
            sfdisk -Vq "$DEST" || return 1
            [[ $UEFI == true ]] && mbr2gpt $DEST && HAS_EFI=true
            if [[ $UNIQUE_CLONE == true ]]; then
                grep -E 'label:\s*gpt' < <(echo "$ptable") && sgdisk -G /$DEST
            fi
        fi
        partprobe "$DEST"
    } #}}}

    _finish() { #{{{
        [[ -z $1 ]] && return 1 #Just to protect ourselves
        logmsg "[ Clone ] _finish"
        [[ -f "$1/etc/hostname" && -n $HOST_NAME ]] && echo "$HOST_NAME" >"$1/etc/hostname"
        [[ -f $1/grub/grub.cfg || -f $1/grub.cfg || -f $1/boot/grub/grub.cfg ]] && HAS_GRUB=true
        [[ ${#SRC2DEST[@]} -gt 0 ]] && boot_setup "SRC2DEST" "$1"
        [[ ${#PSRC2PDEST[@]} -gt 0 ]] && boot_setup "PSRC2PDEST" "$1"
        [[ ${#NSRC2NDEST[@]} -gt 0 ]] && boot_setup "NSRC2NDEST" "$1"
    } #}}}

    _from_file() { #{{{
        logmsg "[ Clone ] _from_file"
        local files=()
        pushd "$SRC" >/dev/null || return 1
        files=($(< <(printf "%s\n" [0-9]* | grep -vE '(md5|list)$')))

        vendor_list ${PKGS[*]} | vendor_compare "$(cat $F_VENDOR_LIST)" || message -w -t "Vendor tools mismatch."

        #Now, we are ready to restore files from previous backup images
        local file mpnt i uuid puuid fs type sused dev mnt dir ddev dfs dpid dptype dtype davail user group o_user o_group
        for file in "${files[@]}"; do
            IFS=. read -r i uuid puuid fs type sused dev mnt dir user group<<<"$(pad_novalue "$file")"
            IFS=: read -r ddev dfs dpid dptype dtype davail <<<"${DESTS[${SRC2DEST[$uuid]}]}"
            dir=${dir//_//}
            mnt=${mnt//_//}
            dev=${dev//_//}

            if [[ -n $ddev ]]; then
                mount_ "$ddev" || exit_ 1 "Could not mount $ddev. Aborting!"
                mpnt=$(get_mount $ddev) || exit_ 1 "Could not find mount journal entry for $ddev. Aborting!"
                if [[ -n $dir ]]; then
                    mpnt=$(realpath -s "$mpnt/$dir")
                    mnt=$(realpath -s "$mnt/$dir" && mkdir -p "$mpnt")
                    o_user=$(stat -c "%u" "$mpnt")
                    o_group=$(stat -c "%g" "$mpnt")
                fi

				[[ $mnt == / ]] && (( ${#TO_LVM[@]} > 0 )) && mount_exta_lvm -d $mpnt -c
                pushd "$mpnt" >/dev/null || return 1

                ((davail - sused <= 0)) \
                    && exit_ 10 "Require $(to_readable_size ${sused}K) but destination is only $(to_readable_size ${davail}K)"

                local cmd="tar --warning=none --same-owner -xf - -C $mpnt"
                [[ -n $XZ_OPT ]] && cmd="$cmd --xz"

                _(){ #{{{
                    if [[ $INTERACTIVE == true ]]; then
                        local size=$(du --bytes -c "${SRC}/${file}" | tail -n1 | gawk '{print $1}')
                        cmd="pv --interval 0.5 --numeric -s $size \"${SRC}\"/${file}* | $cmd"
                        [[ $fs == vfat ]] && cmd="fakeroot $cmd"
                        local e
                        while read -r e; do
                            [[ $e -ge 100 ]] && e=100
                            message -u -c -t "Restoring $dev ($mnt) to $ddev [ $(printf '%3d%%' $e) ]"
                            #Note that with pv stderr holds the current percentage value!
                        done < <((eval "$cmd") 2>&1)
                        message -u -c -t "Restoring $dev ($mnt) to $ddev [ $(printf '%3d%%' 100) ]"
                    else
                        message -c -t "Restoring $dev ($mnt) to $ddev"
                        cmd="$cmd < ${SRC}/${file}"
                        [[ $fs == vfat ]] && cmd="fakeroot $cmd"
                        eval "$cmd"
                    fi
                };_ #}}}

                (( ${#TO_LVM[@]} > 0 )) && mount_exta_lvm -d $mpnt -u

                # Tar will change parent folder permissions because all contend was saved with '.'.
                # So we either restore the original values or the ones provided by argument overwrites.
                if [[ -n $dir ]]; then
                    chown ${user:-$o_user} "$mpnt"
                    chgrp ${group:-$o_group} "$mpnt"
                fi

                if [[ $IS_CHECKSUM == true ]]; then
                    logmsg "Validating Checksums for restored target $dev"
                    {
                        local flog=$LOG_PATH/bcrm.${dev//\//_}.md5.failed.log
                        local log=$LOG_PATH/bcrm.${dev//\//_}.md5.log
                        sync && md5sum -c "$SRC/${file}.md5" > "$log" || { grep 'FAILED$' "$log" >> "$flog" &&
                        exit_ 9 "Validation of target files for $dev <-> $ddev failed."; }
                    }
                fi

                popd >/dev/null || return 1
                _finish "$mpnt" 2>/dev/null
                umount_ -R "$ddev" #-R in case TO_LVM has folders!
            fi
            message -y
        done

        popd >/dev/null || return 1
        return 0
    } #}}}

        _copy() { #{{{
            local sdev=$1 ddev=$2 smpnt=$3 dmpnt=$4 excludes=() cmd
            local ss=${MOUNTS[$sdev]}

            [[ -n $5 ]] && excludes=(${EXCLUDES[$5]//:/ })

            _(){ #{{{
                local x
                for x in "${SRC_EXCLUDES[@]}"; do
                    [[ $ss =~ $x ]] && cmd="$cmd --exclude='/$x'"
                done
            };_ #}}}

            _(){ #{{{
                local x=''
                if [[ -n $excludes ]]; then
                    for x in "${excludes[@]}"; do
                        cmd="$cmd --exclude='/$x'"
                    done
                else
                    cmd='--exclude="/run/*" --exclude="/tmp/*" --exclude="/proc/*" --exclude="/dev/*" --exclude="/sys/*"'
                fi
            };_ #}}}

            _(){ #{{{
                if [[ $INTERACTIVE == true ]]; then
                    ipc=$(mktemp)
                    find "$smpnt" -xdev -type f,d,l -not \( ${cmd//--exclude=/-path } \) | wc -l > $ipc &
                    spinner $! "Cloning $sdev to $ddev" "scan"
                    local size=$(cat "$ipc")

                    local e=''
                    while read -r e; do
                        [[ $e -ge 100 ]] && e=100
                        message -u -c -t "Cloning $sdev to $ddev [ $(printf '%3d%%' $e) ]"
                    done < <(eval rsync -vaSXxH --log-file $LOG_PATH/bcrm.${sdev//\//_}_${ddev//\//_}.log $cmd "$smpnt/" "$dmpnt" | pv --interval 0.5 --numeric -le -s "$size" 2>&1 >/dev/null)
                    message -u -c -t "Cloning $sdev to $ddev [ $(printf '%3d%%' 100) ]"
                else
                    message -c -t "Cloning $sdev to $ddev"
                    eval rsync -aSXxH $cmd "$smpnt/" "$dmpnt"
                fi
            };_ #}}}
            message -y
        } #}}}

    _clone() { #{{{
        logmsg "[ Clone ] _clone"

        local lvs_data=$(lvs --noheadings -o lv_name,lv_dm_path,vg_name \
            | grep "\b${VG_SRC_NAME}\b"
        )

        local src_vg_free=$( vgs --noheadings --units m --nosuffix -o vg_name,vg_free \
            | grep "\b${VG_SRC_NAME}\b" \
            | gawk '{print $2}'
        )

        local s=''
        for s in "${SRCS_ORDER[@]}"; do
            local sdev='' sfs='' spid='' sptype='' stype='' mountpoint='' sused='' ssize=''
            IFS=: read -r sdev sfs spid sptype stype mountpoint sused ssize <<<${SRCS[$s]}
            local ddev='' dfs='' dpid='' dptype='' dtype='' davail=''
            IFS=: read -r ddev dfs dpid dptype dtype davail <<<${DESTS[${SRC2DEST[$s]}]}

            if [[ $stype == lvm ]]; then
                local lv_src_name=$(grep $sdev <<<"$lvs_data" | gawk '{print $1}')
            fi

            if [[ $stype == lvm && "${src_vg_free%%.*}" -ge "500" && -z $SRC_IMG ]]; then
                local tdev="/dev/${VG_SRC_NAME}/$SNAP4CLONE"
                lvremove -f "${VG_SRC_NAME}/$SNAP4CLONE" &>/dev/null #Just to be sure
                lvcreate -l100%FREE -s -n $SNAP4CLONE "${VG_SRC_NAME}/$lv_src_name"
            else
                local tdev="$sdev"
            fi

            local smpnt=''
            mount_ "$tdev" || exit_ 1 "Could not mount $tdev. Aborting!"
            smpnt=$(get_mount "$tdev") || exit_ 1 "Could not find mount journal entry for $tdev. Aborting!"

            local dmpnt=''
            mount_ "$ddev" || exit_ 1 "Could not mount $ddev. Aborting!"
            dmpnt=$(get_mount "$ddev") || exit_ 1 "Could not find mount journal entry for $tdev. Aborting!"

            ((davail - sused <= 0)) && exit_ 10 "Require $(to_readable_size ${sused}K) but $ddev is only $(to_readable_size ${davail}K)"

            if [[ -s $smpnt/etc/fstab ]] && gawk '/^[^#]/{if( $2 =="/" ) {exit 0} else {exit 1}}' $smpnt/etc/fstab; then
                (( ${#TO_LVM[@]} > 0 )) && mount_exta_lvm -s $smpnt -d $dmpnt
            fi

            _copy "$sdev" "$ddev" "$smpnt" "$dmpnt"

            (( ${#TO_LVM[@]} > 0 )) && mount_exta_lvm -d $dmpnt -u

            _(){ #{{{
                local em=''
                for em in ${!EXT_PARTS[@]}; do
                    local e=${EXT_PARTS[$em]}
                    local l=${MOUNTS[$s]}
                    if [[ $l == $(find_mount_part $em ) ]]; then
                        local user password
                        read -r user password <<<${CHOWN[$em]/:/ }

                        mount_ "$e" || exit_ 1 "Could not mount $e. Aborting!"
                        local smpnt_e=$(get_mount $e) || exit_ 1 "Could not find mount journal entry for $e. Aborting!"

                        local o_user=$(stat -c "%u" "$dmpnt/${em/$l/}")
                        local o_group=$(stat -c "%g" "$dmpnt/${em/$l/}")

                        _copy "$e" "$ddev:$em" "$smpnt_e" "$dmpnt/${em/$l/}" $em

                        chown ${user:-$o_user} "$dmpnt/${em/$l/}"
                        chgrp ${group:-$o_group} "$dmpnt/${em/$l/}"

                        umount_ "$e"
                    fi
                done
            };_ #}}}

            _finish "$dmpnt"
            umount_ -R "$ddev" #-R in case TO_LVM has folders!
            umount_ "$tdev"
            [[ $stype == lvm ]] && lvremove -f "${VG_SRC_NAME}/$SNAP4CLONE"

        done
        return 0
    } #}}}

    _src2dest() { #{{{
        logmsg "[ Clone ] _src2dest"

        local si=0
        local di=0

        local i sdev sfs spid sptype stype srest ddev dfs dpid dptype dtype drest
        for ((i = 0; i < ${#SRCS_ORDER[@]}; i++)); do
            IFS=: read -r sdev sfs spid sptype stype srest <<<${SRCS[${SRCS_ORDER[$i]}]}
            IFS=: read -r ddev dfs dpid dptype dtype drest <<<${DESTS[${DESTS_ORDER[$i]}]}

            SRC2DEST[${SRCS_ORDER[$i]}]=${DESTS_ORDER[$i]}
            [[ -n ${spid// } && -n ${dpid// } ]] && PSRC2PDEST[$spid]=$dpid
            [[ -n ${sdev// } && -n ${ddev// } ]] && NSRC2NDEST[$sdev]=$ddev
            [[ -n ${spid// } && -n ${dpid// } ]] && PSRC2PDEST[$spid]=$ddev
        done
    } #}}}

    message -c -t "Cloning disk layout"
    {
        local f=$([[ $_RMODE == true ]] && cat "$SRC/$F_PART_LIST" || $LSBLK_CMD ${VG_DISKS[@]:-$SRC})

        init_srcs "$f"

        [[ $_RMODE == true ]] && eval $(cat $F_DEVICE_MAP)
        mounts

        _(){ #{{{
            if [[ $ALL_TO_LVM == true ]]; then
                local y sdevname fs spid ptype type rest
                for y in "${SRCS_ORDER[@]}"; do
                    IFS=: read -r sdevname fs spid ptype type rest <<<"${SRCS[$y]}"
                    if [[ $type == part ]]; then
                        if [[ ! ${ptype} =~ $ID_GPT_LVM|${ID_DOS_LVM} \
                        && ! ${ptype} =~ $ID_GPT_EFI|${ID_DOS_EFI} ]]; then
                            name="${MOUNTS[$y]##*/}"
                            TO_LVM[$sdevname]="${name:-root}"
                        fi
                    fi
                done
            fi
        };_ #}}}

        _(){ #{{{
            if [[ -n $ENCRYPT_PWD ]]; then
                local f=''
                for f in "${SRCS_ORDER[@]}"; do
                    local name='' fstype='' partuuid='' parttype='' type='' used='' avail=''
                    IFS=: read -r name fstype partuuid parttype type used avail <<<"${SRCS[$f]}"
                    if ! grep -qE "${name}" < <(echo "${!TO_LVM[@]}" | tr ' ' '\n'); then
                        [[ $type == part && ! $parttype =~ $ID_GPT_EFI|${ID_DOS_EFI} ]] \
                            && exit_ 1 "Cannot encrypt disk. All partitions (except for EFI) must be of type 'lvm'."
                    fi
                done
            fi
        };_ #}}}

        _prepare_disk
        sync_block_dev $DEST

        _(){ #{{{
            if [[ -n $ENCRYPT_PWD ]]; then
                if [[ $HAS_EFI == true ]]; then
                    local dev='' type=''
                    read -r dev type <<<$(sfdisk -l -o Device,Type-UUID $DEST | grep ${ID_GPT_EFI^^})
                    mkfs -t vfat "$dev"
                fi
                pvcreate -ffy "/dev/mapper/$LUKS_LVM_NAME"
                _lvm_setup "/dev/mapper/$LUKS_LVM_NAME" || exit_ 1 "LVM setup failed!"
            else
                disk_setup "$f" "$SRC" "$DEST" || exit_ 2 "Disk setup failed!"
                _lvm_setup "$DEST" || exit_ 1 "LVM setup failed!"
                sleep 3
            fi
        };_ #}}}

        #Now collect what we have created
        set_dest_uuids
        _src2dest
    }
    message -y

    if [[ $_RMODE == true ]]; then
        _from_file || return 1
    else
        _clone || return 1
    fi

    if [[ $HAS_GRUB == true ]]; then
        message -c -t "Running boot setup"
        _(){ #{{{
            local ddev='' rest=''
            IFS=: read -r ddev rest <<<${DESTS[${SRC2DEST[${MOUNTS['/']}]}]}
            [[ -z $ddev ]] && exit_ 1 "Unexpected error - empty destination."
            if [[ -n $ENCRYPT_PWD ]]; then
                crypt_setup "$ENCRYPT_PWD" "$ddev" "$DEST" "$LUKS_LVM_NAME" "$ENCRYPT_PART" || return 1
            else
                grub_setup "$ddev" "$HAS_EFI" "$UEFI" "$DEST" || { message -r -w && return 1; }
            fi
        };_ #}}}
        message -y
    fi
    return 0
} #}}}

#}}}

Main() { #{{{
    local args_count=$# #getop changes the $# value. To be sure we save the original arguments count.
    local args=$@       #Backup original arguments.

    _validate_block_device() { #{{{
        logmsg "Main@_validate_block_device"
        local t=$(lsblk --nodeps --noheadings -o TYPE "$1")
        ! [[ $t =~ disk|loop ]] && exit_ 1 "Invalid block device. $1 is not a disk."
    } #}}}

    _is_valid_lv() { #{{{
        logmsg "Main@_is_valid_lv"
        local lv_name="$1"
        local vg_name="$2"

        if [[ $_RMODE == true ]]; then
            grep -qw "$lv_name" < <(gawk '{print $1}' "$SRC/$F_LVS_LIST" | sort -u)
        else
            lvs --noheadings -o lv_name,vg_name | grep -w "$vg_name" | grep -qw "$1"
        fi
    } #}}}

    _is_valid_lv_name() { #{{{
        logmsg "Main@_is_valid_lv_name"
        local lv_name="$1"
        [[ $lv_name =~ ^[a-zA-Z0-9_][a-zA-Z0-9+_.-]* ]] && return 0
        return 1
    } #}}}

    _is_partition() { #{{{
        logmsg "Main@_is_partition"
        local part=$1

        [[ -n $part && $part =~ $SRC ]] || return 1
        local name parttype type fstype
        read -r name parttype type fstype <<<$(lsblk -Ppo NAME,PARTTYPE,TYPE,FSTYPE "$part")
        eval "$name" "$parttype" "$type" "$fstype"
        [[ $TYPE == part && -n $FSTYPE && ! "$FSTYPE" =~ ^(crypto_LUKS|LVM2_member)$ && $PARTTYPE != $ID_GPT_EFI ]] && return 0
        return 1
    } #}}}

    _run_schroot() { #{{{
        logmsg "Main@_run_schroot"
        # debootstrap --make-tarball=bcrm.tar --include=git,locales,lvm2,bc,pv,parallel,qemu-utils stretch ./dbs2
        # debootstrap --unpack-tarball=$(dirname $(readlink -f $0))/bcrm.tar --include=git,locales,lvm2,bc,pv,parallel,qemu-utils,rsync stretch /tmp/dbs

        [[ -s $SCRIPTPATH/$F_SCHROOT ]] || exit_ 2 "Cannot run schroot because the archive containing it - $F_SCHROOT - is missing."
        [[ -n $(ls -A "$SCHROOT_HOME") ]] && exit_ 2 "Schroot home not empty!"

        echo_ "Creating chroot environment. This might take a while ..."
        { mkdir -p "$SCHROOT_HOME" && tar xf "${SCRIPTPATH}/$F_SCHROOT" -C "$_"; } \
            || exit_ 1 "Faild extracting chroot. See the log $F_LOG for details."

        mount_chroot "$SCHROOT_HOME"

        [[ -n $DEST_IMG ]] && mount_ "${DEST_IMG%/*}" -p "$SCHROOT_HOME/${DEST_IMG%/*}" -b
        [[ -n $SRC_IMG ]] && mount_ "${SRC_IMG%/*}" -p "$SCHROOT_HOME/${SRC_IMG%/*}" -b

        if [[ -d "$SRC" && -b $DEST ]]; then
            { mkdir -p "$SCHROOT_HOME/$SRC" && mount_ "$SRC" -p "$SCHROOT_HOME/$SRC" -b; } \
                || exit_ 1 "Failed preparing chroot for restoring from backup."
        elif [[ -b "$SRC" && -d $DEST ]]; then
            { mkdir -p "$SCHROOT_HOME/$DEST" && mount_ "$DEST" -p "$SCHROOT_HOME/$DEST" -b; } \
                || exit_ 1 "Failed preparing chroot for backup creation."
        fi

        echo -n "$(< <(echo -n "
            [bcrm]
            type=plain
            directory=${SCHROOT_HOME}
            profile=desktop
            preserve-environment=true
        "))" | sed -e '/./,$!d; s/^\s*//' >$F_SCHROOT_CONFIG

        cp -r $(dirname $(readlink -f $0)) "$SCHROOT_HOME"
        echo_ "Now executing chroot in $SCHROOT_HOME"
        rm "$PIDFILE" && schroot -c bcrm -d /sf_bcrm -- bcrm.sh ${args//--schroot/} #Do not double quote args to avoid wrong interpretation!

        umount_chroot

        umount_ "$SCHROOT_HOME/$DEST"
        umount_ "$SCHROOT_HOME/${SRC_IMG%/*}"
        umount_ "$SCHROOT_HOME/${DEST_IMG%/*}"
    } #}}}

    _prepare_locale() { #{{{
        logmsg "Main@_prepare_locale"
        mkdir -p $BACKUP_FOLDER
        local cf="/etc/locale.gen"
        CHG_SYS_FILES["$cf"]=$(md5sum "$cf" | gawk '{print $1}')

        mkdir -p "${BACKUP_FOLDER}/${cf%/*}" && cp "$cf" "${BACKUP_FOLDER}/${cf}"
        echo "en_US.UTF-8 UTF-8" >"$cf"
        locale-gen >/dev/null || return 1
    } #}}}

    #If boot is a directory on /, returns ""
    # $1: <Ref. to store boot partition name>
    _find_boot() { #{{{
        logmsg "Main@_find_boot"
        local ldata=$($LSBLK_CMD $SRC)
        [[ -n $1 ]] && local -n boot_part="$1"

        local lvs_list=$(lvs -o lv_dmpath,lv_role)

        _set() { #{{{
            local name="$1"
            local mountpoint="$2"
            local mp=''
            [[ -z ${mountpoint// } ]] && mp="${name}" || mp="${mountpoint}"
            mount_ "$mp" || exit_ 1 "Could not mount ${mp}."
            mpnt=$(get_mount $mp) || exit_ 1 "Could not find mount journal entry for $mp. Aborting!"
            if [[ -f ${mpnt}/etc/fstab ]]; then
                local part=$(gawk '$1 ~ /^[^;#]/' "${mpnt}/etc/fstab" | grep -E "\s+/boot\s+" | gawk '{print $1}')
                if [[ -n $part ]]; then
                    local name kdev fstype uuid puuid type parttype mountpoint size
                    read -r name kdev fstype uuid puuid type parttype mountpoint size <<<$(echo "$ldata" | grep "=\"${part#*=}\"")
                    eval local "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint" "$size"
                    boot_part=$KNAME
                fi
            fi
            umount_ "$mp"
        } #}}}

        _(){ #{{{
            local mpnt f name mountpoint fstype type
            if [[ $IS_LVM == true ]]; then
                local parts=$(lsblk -lpo name,fstype,mountpoint | grep "${VG_SRC_NAME//-/--}-" | grep -iv 'swap')
                while read -r name fstype mountpoint; do
                    if grep "$name" <<<"$lvs_list" | grep -vq "snapshot"; then
                        [[ -n $fstype ]] && _set $name $mountpoint
                    fi
                done <<<"$parts"
            else
                parts=$(lsblk -lpo name,type,fstype,mountpoint $SRC | grep 'part' | grep -iv 'swap')
                while read -r name type fstype mountpoint; do
                    [[ -n $fstype ]] && _set "$name" "$mountpoint"
                done <<<"$parts"
            fi
        };_ #}}}
        [[ -z $boot_part ]] && return 1 || return 0
    } #}}}

    _dest_size() { #{{{
        logmsg "Main@_dest_size"
        local used size dest_size=0

        if [[ -d $DEST ]]; then
            read -r size used <<<$(df --block-size=1M --output=size,used "$DEST" | tail -n 1)
            dest_size=$((size - used))
        else
            if [[ $PVALL == true ]]; then
                local d=''
                for d in $(lsblk -po name,type | grep disk | grep -v "$DEST" | gawk '{print $1}'); do
                    dest_size=$((dest_size + $(blockdev --getsize64 "$d")))
                done
            else
                dest_size=$(blockdev --getsize64 "$DEST")
            fi
            dest_size=$(to_mbyte ${dest_size})
        fi
        echo $dest_size
    } #}}}

    _src_size() { #{{{
        logmsg "Main@_src_size"
        local -n __src_size=$1
        __src_size=0
        local plist=$(lsblk -nlpo fstype,type,kname,name,mountpoint "$SRC" | grep '^\S' | grep -v LVM2_member | gawk 'BEGIN {OFS=":"} {print $1,$3,$4,$5}')
        local lvs_list=$(lvs -o lv_dmpath,lv_role)

        local fs dev name mountpoint swap_size=0
        while IFS=: read -r fs dev name mountpoint; do
            if grep "$name" <<<"$lvs_list" | grep -vq "snapshot" && [[ -n ${fs// } ]]; then
                if [[ $SWAP_SIZE -lt 0 && $fs == swap ]]; then
                    swap_size=$(swapon --show=size,name --bytes --noheadings | grep $dev | gawk '{print $1}') #no swap = 0
                    swap_size=$(to_kbyte ${swap_size:-0})
                fi

                [[ -z ${mountpoint// } && $fs != swap ]] && { mount_ "$dev" || exit_ 1 "Could not mount ${dev}."; }
                __src_size=$((swap_size + __src_size + $(df -k --output=used "$dev" | tail -n -1)))
                [[ -z ${mountpoint// } && $fs != swap ]] && { umount_ "$dev" || exit_ 1 "Could not unmount ${dev}."; }
            fi
        done <<<"$plist"

        __src_size=$(to_mbyte ${__src_size}K)
    } #}}}

_filter_params_x() { #{{{
    local p=''
    for p in "${!PARAMS[@]}"; do
        [[ $p == -h || $p == --help ]] && show_usage
    done

    if [[ -d ${PARAMS[-d]} || -d ${PARAMS[-destination]} ]]; then
        MODE='backup'
    elif [[ -d ${PARAMS[-s]} || -d ${PARAMS[-source]} ]]; then
        MODE='restore'
    else
        MODE='clone'
    fi

    local p=''
    case $MODE in
        'backup')
            for p in "${!PARAMS[@]}"; do
                case $p in
                    --destination-image\
                    |-H|--hostname\
                    |--remove-pkgs\
                    |-n|--new-vg-name\
                    |--vg-free-size\
                    |-e|--encrypt-with-passwor\
                    |-p|--use-all-pvs\
                    |--lvm-expand\
                    |--lvm-set-size\
                    |-u|--make-uefi\
                    |-w|--swap-size\
                    |-m|--resize-threshold\
                    |--disable-mount\
                    |--to-lvm\
                    |--all-to-lvm\
                    |--update-efi-boot\
                    |--efi-boot-iamge\
                    |-U|--unique-clone\
                    |-v|--version)
                    unset PARAMS[$p]
                    ;;
                esac
            done
            ;;
        'restore')
            for p in "${!PARAMS[@]}"; do
                case $p in
                    --source-image\
                    |--split\
                    |--include-partition\
                    |--no-cleanup\
                    |--quiet\
                    |--yes)
                    unset PARAMS[$p]
                    ;;
                esac
            done
            ;;
        'clone')
            for p in "${!PARAMS[@]}"; do
                case $p in
                    -c|--check\
                    |--compress\
                    |--split\
                    |--version)
                    unset PARAMS[$p]
                    ;;
                esac
            done
            ;;
    esac
} #}}}

    trap Cleanup INT TERM EXIT

    exec 3>&1 4>&2
    tput sc

    #TODO check if still needed
    { >&3; } 2<> /dev/null || exit_ 9
    { >&4; } 2<> /dev/null || exit_ 9

    #{{{
    #needs to be global or the $? check will fail!
    option=$(getopt \
        -o 'b:cd:e:hH:m:n:pqs:uUvw:yz' \
        --long '
            all-to-lvm,
            boot-size:,
            check,
            compress,
            destination,
            destination-image:,
            disable-mount:,
            efi-boot-image:,
            encrypt-with-password:,
            exclude-folder:,
            help,
            hostname:,
            include-partition:,
            lvm-expand:,
            lvm-set-size:,
            make-uefi,
            new-vg-name:,
            no-cleanup,
            quiet,
            remove-pkgs:,
            resize-threshold:,
            schroot,
            source,
            source-image:,
            split,
            swap-size:,
            to-lvm:,
            unique-clone,
            update-efi-boot,
            use-all-pvs,
            version,
            vg-free-size:,
            yes' \
        -n "$(basename "$0" \
        )" -- "$@")
    #}}}

    [[ $? -ne 0 ]] && show_usage

    eval set -- "$option"
    unset option

    [[ $args_count -eq 0 || "$*" =~ -h|--help ]] && show_usage #Don't have to be root to get the usage info

    #Force root
    [[ $(id -u) -ne 0 ]] && exec sudo "$0" "$@"

    echo >"$F_LOG"

    SYS_HAS_EFI=$([[ -d /sys/firmware/efi ]] && echo true || echo false)

    #Make sure BASH is the right version so we can use array references!
    local v=$(echo "${BASH_VERSION%.*}" | tr -d '.')
    ((v < 43)) && exit_ 1 "ERROR: Bash version must be 4.3 or greater!"

    #Lock the script, only one instance is allowed to run at the same time!
    exec 200>"$PIDFILE"
    flock -n 200 || exit_ 1 "Another instance is already running!"
    pid=$$
    echo $pid 1>&200

    while (( $# )); do
        ! [[ $1 =~ ^- ]] && exit_ 1 "Invalid argument $1"
        [[ $1 == -- ]] && break
        if [[ $1 =~ ^- && ($2 =~ ^- || -z $2 ) ]]; then
            PARAMS["$1"]=true
            shift
        elif [[ -n ${PARAMS[$1]} ]]; then
            PARAMS["$1"]="${PARAMS[$1]}|$2"
            shift 2
        else
            PARAMS["$1"]="$2"
            shift 2
        fi
    done

    _(){ #{{{
        local k
        for k in "${!PARAMS[@]}"; do
            case "$k" in
            '-h' | '--help')
                show_usage
                ;;
            '-v' | '--version')
                echo_ "$VERSION"
                exit_ 0
                ;;
            '-y' | '--yes')
                YES=true
                ;;
            '-s' | '--source')
                SRC=$(readlink -e "${PARAMS[$k]}") || exit_ 1 "Specified source ${PARAMS[$k]} does not exist!"
                ;;
            '-d' | '--destination')
                DEST=$(readlink -e "${PARAMS[$k]}") || exit_ 1 "Specified destination ${PARAMS[$k]} does not exist!"
                ;;
            '--source-image')
                read -r SRC_IMG IMG_TYPE <<<"${PARAMS[$k]//:/ }"

                [[ -n $SRC_IMG && -z $IMG_TYPE ]] && exit_ 1 "Missing type attribute"
                [[ $IMG_TYPE =~ ^raw$|^vdi$|^vmdk$|^qcow2$ ]] || exit_ 2 "Invalid image type in $k ${PARAMS[$k]}"
                [[ ! -e "$SRC_IMG" ]] && exit_ 1 "Specified image file does not exists."

                ischroot || modprobe nbd max_part=16 || exit_ 1 "Cannot load nbd kernel module."

                PKGS+=(qemu-img)
                CREATE_LOOP_DEV=true
                ;;
            '--destination-image')
                read -r DEST_IMG IMG_TYPE IMG_SIZE <<<"${PARAMS[$k]//:/ }"

                [[ -n $DEST_IMG && -z $IMG_TYPE ]] && exit_ 1 "Missing type attribute"
                [[ $IMG_TYPE =~ ^raw$|^vdi$|^vmdk$|^qcow2$ ]] || exit_ 2 "Invalid image type in $k ${PARAMS[$k]}"
                [[ ! -e "$DEST_IMG" && -z $IMG_SIZE ]] && exit_ 1 "Specified image file does not exists."

                if [[ -n $DEST_IMG && -n $IMG_SIZE ]]; then
                    validate_size "$IMG_SIZE" || exit_ 2 "Invalid size attribute in $k ${PARAMS[$k]}"
                fi

                ischroot || modprobe nbd max_part=16 || exit_ 1 "Cannot load nbd kernel module."

                PKGS+=(qemu-img)
                CREATE_LOOP_DEV=true
                ;;
            '-n' | '--new-vg-name')
                VG_SRC_NAME_CLONE="${PARAMS[$k]}"
                _is_valid_lv_name "$VG_SRC_NAME_CLONE" || exit_ 1 "Valid characters for VG names are: 'a-z A-Z 0-9 + _ . -'. VG names cannot begin with a hyphen."
                ;;
            '-e' | '--encrypt-with-password')
                ENCRYPT_PWD="${PARAMS[$k]}"
                [[ -z "${ENCRYPT_PWD// }" ]] && exit_ 2 "Invalid password."
                PKGS+=(cryptsetup)
                ;;
            '-H' | '--hostname')
                HOST_NAME="${PARAMS[$k]}"
                ;;
            '-u' | '--make-uefi')
                PKGS+=(gdisk)
                UEFI=true;
                ;;
            '-p' | '--use-all-pvs')
                PVALL=true
                ;;
            '-q' | '--quiet')
                exec 3>&-
                exec 4>&-
                ;;
            '--split')
                SPLIT=true;
                ;;
            '-c' | '--check')
                IS_CHECKSUM=true
                PKGS+=(parallel)
                ;;
            '-z' | '--compress')
                export XZ_OPT=-4T0
                PKGS+=(xz)
                ;;
            '-m' | '--resize-threshold')
                { validate_size "${PARAMS[$k]}" && MIN_RESIZE=$(to_mbyte "${PARAMS[$k]}"); } || exit_ 2 "Invalid size specified.
                    Use K, M, G or T suffixes to specify kilobytes, megabytes, gigabytes and terabytes."
                ;;
            '-w' | '--swap-size')
                { validate_size "${PARAMS[$k]}" && SWAP_SIZE=$(to_kbyte "${PARAMS[$k]}"); } || exit_ 2 "Invalid size specified.
                    Use K, M, G or T suffixes to specify kilobytes, megabytes, gigabytes and terabytes."
                ;;
            '-b' | '--boot-size')
                { validate_size "${PARAMS[$k]}" && BOOT_SIZE=$(to_kbyte "${PARAMS[$k]}"); } || exit_ 2 "Invalid size specified.
                    Use K, M, G or T suffixes to specify kilobytes, megabytes, gigabytes and terabytes."
                ;;
            '--lvm-expand')
                local name size
                read -r name size <<<"${PARAMS[$k]/:/ }"
                [[ "${size:-100}" =~ ^0*[1-9]$|^0*[1-9][0-9]$|^100$ ]] || exit_ 2 "Invalid size attribute in $k ${PARAMS[$k]}"
                LVM_EXPAND_BY[$name]=$size
                ;;
            '--lvm-set-size')
                local name size
                read -r name size <<<"${PARAMS[$k]/:/ }"
                validate_size $size || exit_ 2 "Invalid size specified."
                LVM_SIZE_TO[$name]=$(to_mbyte $size)
                ;;
            '--vg-free-size')
                { validate_size "${PARAMS[$k]}" && VG_FREE_SIZE=$(to_mbyte "${PARAMS[$k]}"); } || exit_ 2 "Invalid size specified.
                    Use K, M, G or T suffixes to specify kilobytes, megabytes, gigabytes and terabytes."
                ;;
            '--remove-pkgs')
                REMOVE_PKGS+=(${PARAMS[$k]})
                ;;
            '--schroot')
                PKGS+=(schroot debootstrap)
                SCHROOT=true;
                ;;
            '--disable-mount')
                DISABLED_MOUNTS+=("${PARAMS[$k]}")
                ;;
            '--no-cleanup')
                IS_CLEANUP=false
                ;;
            '--update-efi-boot')
                UPDATE_EFI_BOOT=true
                UNIQUE_CLONE=true
                ;;
            '--efi-boot-image')
                EFI_BOOT_IMAGE="${PARAMS[$k]}"
                ;;
            '-U' | '--unique-clone')
                #Do not allow overwrites, e.g. when UPDATE_EFI_BOOT is true
                [[ $UNIQUE_CLONE == false ]] && UNIQUE_CLONE=true
                PKGS+=(gdisk)
                ;;
            '--all-to-lvm')
                ALL_TO_LVM=true
                PKGS+=(lvm)
                ;;
            '--exclude-folder')
                [[ "${PARAMS[$k]}" =~ ^/ ]] && SRC_EXCLUDES+=("${PARAMS[$k]}") || exit_ 1 "Exclude folders must be absolute paths."
                ;;
            '--include-partition')
                local excludes
                {
                    local x=''
                    for x in ${PARAMS[$k]//,/ }; do
                        local k='' v=''
                        read -r k v <<<"${x/=/ }"
                        if [[ -n $k && -n $v ]]; then
                            local part='' mp='' user='' group=''
                            [[ $k == user ]] && user=$v
                            [[ $k == group ]] && group=$v
                            [[ $k == part ]] && part=$v
                            [[ $k == dir ]] && mp=$v
                            excludes=$v
                        elif [[ -n $k ]]; then
                            excludes=${excludes}:$k
                        fi
                    done

                    local fstype='' type=''
                    [[ -b $part ]] && read -r type fstype <<<$(lsblk -lpno type,fstype $part) || exit_ 2 "$part not a block device."
                    if [[ $type == part || -z $fstype ]]; then
                        [[ -n $user && $user =~ ^[0-9]+$ || -z $user ]] || exit_ 1 "Invalid user ID."
                        [[ -n $group && $group =~ ^[0-9]+$ || -z $group ]] || exit_ 1 "Invalid group ID."
                        EXT_PARTS[$mp]=$part
                        EXCLUDES[$mp]=$excludes
                        CHOWN[$mp]=$user:$group
                    else
                        exit_ 2 "$part is not a partition"
                    fi
                }
                ;;
            '--to-lvm')
                _(){
                    local params=()
                    readarray -t -d '|' params <<<"${PARAMS[$k]}"

                    local p
                    for p in "${params[@]}"; do
						local src_path lv_name size
                        read -r src_path lv_name size <<<"${p//:/ }"
                        validate_size "$size" || exit_ 1 "Invalid size."
                        [[ -z $lv_name ]] && exit_ 1 "Missing LV name"
                        if _is_valid_lv_name "$lv_name"; then
                            if [[ -d $src_path ]]; then
                                [[ -z $size ]] && exit_ 1 "Missing size declaration."
                                fs=$(df --output=fstype "$src_path" | tail -1)
                            fi
                            [[ -n ${TO_LVM[$src_path]} ]] && exit_ 1 "$k already specified. Duplicate parameters?"
                            TO_LVM[$src_path]=${lv_name}:${size}:${fs}
                            TO_LVM[$src_path]=${TO_LVM[$src_path]%:} #Remove trailing ':'
                        else
                            exit_ 1 "Invalid LV name '$lv_name'."
                        fi
                    done
                    PKGS+=(lvm)
                };_
                ;;
            '--')
                break
                ;;
            *)
                show_usage
                ;;
            esac
        done
        _filter_params_x
    };_ #}}}

    hash pv &>/dev/null && INTERACTIVE=true || message -i -t "No progress will be shown. Consider installing package: pv"

    #Do not use /tmp! It will be excluded on backups!
    MNTPNT=$(mktemp -d -p /mnt) || exit_ 1 "Could not set temporary mountpoint."

    message -i -t "Temporarily disabling power management settings."
    systemctl --runtime mask sleep.target hibernate.target suspend.target hybrid-sleep.target &>/dev/null && SYS_CHANGED=true

    grep -q 'LVM2_member' < <([[ -d $SRC ]] && cat "$SRC/$F_PART_LIST" || lsblk -o FSTYPE "$SRC") && PKGS+=(lvm)

    PKGS+=(gawk rsync tar flock bc blockdev fdisk sfdisk locale-gen git mkfs parted)
    [[ -d $SRC ]] && PKGS+=(fakeroot) && _RMODE=true

    _(){ #{{{
        local packages=()
        #Inform about ALL missing but necessary tools.
        for c in "${PKGS[@]}"; do
            hash "$c" 2>/dev/null || {
                case "$c" in
                lvm)
                    packages+=(lvm2)
                    ;;
                qemu-img)
                    packages+=(qemu-utils)
                    ;;
                blockdev)
                    packages+=(util-linux)
                    ;;
                mkfs.vfat)
                    packages+=(dosfstools)
                    ;;
                *)
                    packages+=("$c")
                    ;;
                esac
                abort='exit_ 1'
            }
        done

        exec >$F_LOG 2>&1

        [[ -n $abort ]] && message -n -t "ERROR: Some packages missing. Please install packages: ${packages[*]}"
        eval "$abort"
    };_ #}}}

    [[ (-b "$SRC" || -f $SRC_IMG) && -d $DEST && -n "$(ls $DEST)" ]] && exit_ 1 "Destination not empty!"

    if [[ $SCHROOT == true ]]; then
        _run_schroot
        exit_ 0
    fi

    if [[ -n $SRC_IMG ]]; then
        { qemu-nbd --cache=writeback -f "$IMG_TYPE" -c $SRC_NBD "$SRC_IMG"; } || exit_ 1 "QEMU Could not load image. Check $F_LOG for details."
        SRC=$SRC_NBD
        sleep 3
    fi

    [[ -n $DEST && -n $DEST_IMG && -n $IMG_TYPE && -n $IMG_SIZE ]] && exit_ 1 "Invalid combination."
    [[ -d $DEST && $BOOT_SIZE -gt 0 ]] && exit_ 1 "Invalid combination."

    if [[ -n $DEST_IMG ]]; then
        [[ ! -e $DEST_IMG ]] && { create_image "$DEST_IMG" "$IMG_TYPE" "$IMG_SIZE" || exit_ 1 "Image creation failed."; }
        chmod +rwx "$DEST_IMG"
        { qemu-nbd --cache=writeback -f "$IMG_TYPE" -c $DEST_NBD "$DEST_IMG"; } || exit_ 1 "QEMU Could not load image. Check $F_LOG for details."
        DEST=$DEST_NBD
        sleep 3
    fi

    [[ -z $SRC || -z $DEST ]] &&
        show_usage

    [[ -d $SRC && ! -b $DEST ]] &&
        exit_ 1 "$DEST is not a valid block device."

    [[ ! -b $SRC && -d $DEST ]] &&
        exit_ 1 "$SRC is not a valid block device."

    [[ ! -d $SRC && ! -b $SRC && -b $DEST ]] &&
        exit_ 1 "Invalid device or directory: $SRC"

    [[ -b $SRC && ! -b $DEST && ! -d $DEST ]] &&
        exit_ 1 "Invalid device or directory: $DEST"

    [[ -d $DEST && ! -r $DEST && ! -w $DEST && ! -x $DEST ]] &&
        exit_ 1 "$DEST is not writable."

    [[ -d $SRC && ! -r $SRC && ! -x $SRC ]] &&
        exit_ 1 "$SRC is not readable."

    if [[ -b $SRC ]]; then
        lsblk -lpo parttype "$SRC" | grep -qi $ID_GPT_EFI && HAS_EFI=true
        lsblk -lpo type "$SRC" | grep -qi 'crypt' && HAS_LUKS=true
	fi

    if [[ $SYS_HAS_EFI == false ]]; then
        [[ $UPDATE_EFI_BOOT == true ]] &&
            exit_ 1 "Cannot update EFI boot order. Current running system does not support UEFI."
        [[ $UEFI == true ]] &&
            exit_ 1 "Cannot convert to UEFI because system booted in legacy mode. Check your UEFI firmware settings!"
        [[ $HAS_EFI == true ]] &&
            exit_ 1 "Cannot clone UEFI system. Current running system does not support UEFI."
    fi

    _(){ #{{{
        if [[ -b $DEST ]]; then
            local pv_name='' vg_name=''
            read -r pv_name vg_name < <(pvs -o pv_name,vg_name --no-headings | grep "$DEST")
            if [[ -n $vg_name ]]; then
                message -I -i -t "Destination has physical volumes still assigned. Delete ${vg_name}? [y/N]: "
                if [[ $YES == false ]]; then
                    read -r choice
                    if [[ $choice =~ Y|y|Yes|yes ]]; then
                        vgremove -y "$vg_name"
                    else
                        exit_ 1
                    fi
                else
                    vgremove -y "$vg_name"
                fi
            fi
        fi
    };_ #}}}

    _(){ #{{{
        local d=''
        for d in "$SRC" "$DEST"; do
            [[ -b $d ]] && _validate_block_device $d
        done
    };_ #}}}

    [[ $(realpath "$SRC") == $(realpath "$DEST") ]] &&
        exit_ 1 "Source and destination cannot be the same!"

    [[ -n $(lsblk --noheadings -o mountpoint $DEST 2>/dev/null) ]] &&
        exit_ 1 "Invalid device condition. Some or all partitions of $DEST are mounted."

    _(){ #{{{
        local part=''
        for part in ${EXT_PARTS[@]}; do
            if [[ -b $SRC ]]; then
                grep "^$part/*\$" -q < <(lsblk -lnpo name "$SRC") && exit_ 2 "Cannot include partition ${part}. It is part of the source device ${SRC}."
            fi
            if [[ -b $DEST ]]; then
                grep "^$part/*\$" -q < <(lsblk -lnpo name "$DEST") && exit_ 2 "Cannot include partition ${part}. It is part of the destination device ${DEST}."
            fi
        done
    };_ #}}}

    [[ $PVALL == true && -n $ENCRYPT_PWD ]] && exit_ 1 "Encryption only supported for simple LVM setups with a single PV!"

    _(){ #{{{
        #Check that all expected files exists when restoring
        if [[ -d $SRC ]]; then
            local meta_files=("$F_CONTEXT" "$F_PART_LIST" "$F_DEVICE_MAP" "$F_VENDOR_LIST" "$F_PART_TABLE" "$F_ROOT_FOLDER_DU")
            [[ $IS_CHECKSUM == true ]] && meta_files+=("$F_CHESUM")
            [[ $IS_LVM == true ]] && meta_files+=($F_VGS_LIST $F_LVS_LIST $F_PVS_LIST)

            local f=''
            for f in $meta_files; do
                [[ -s $SRC/$f ]] || exit_ 2 "Cannot restore dump, meta file $f is missing or empty!"
            done

            local mnts=$(grep -v -i 'swap' "$SRC/$F_PART_LIST" \
                | grep -Po 'MOUNTPOINT="[^\0]+?"' \
                | grep -v 'MOUNTPOINT=""' \
                | cut -d '=' -f 2 \
                | tr -d '"' \
                | tr -s "/" "_"
            ) #TODO What if mount point has spaces?

            local f=''
            for f in $mnts; do
                grep "$f\$" <(ls -A "$SRC") || exit_ 2 "$SRC folder missing files."
            done
        fi
    };_ #}}}

    if [[ -d $SRC && $IS_CHECKSUM == true ]]; then
        message -c -t "Validating checksums"
        validate_m5dsums "$SRC" "$F_CHESUM" || { message -n && exit_ 1; }
        message -y
    fi

    #Load context
    if [[ -d "$SRC" && -e "$SRC/$F_CONTEXT" ]]; then
        eval "$(cat $SRC/$F_CONTEXT)"
    fi

    [[ $UEFI == true && $SYS_HAS_EFI == false ]] &&
        exit_ 1 "Cannot convert to UEFI because system booted in legacy mode. Check your UEFI firmware settings!"

    [[ $HAS_EFI == true && $UEFI == true ]] && UEFI=false #Ignore -u if destination is alread EFI-enabled.

    _(){ #{{{
        local src_size=0
        if [[ -d $SRC ]]; then
            src_size=$(sector_to_mbyte $SECTORS_SRC_USED)
        else
            _src_size 'src_size'
        fi

        local dest_size=$(_dest_size)

        (( src_size < dest_size )) \
            || exit_ 1 "Destination too small: Need at least $(to_readable_size ${src_size}M) but $DEST is only $(to_readable_size ${dest_size}M)"

        if [[ -b $SRC ]]; then
            SECTORS_SRC=$(blockdev --getsz "$SRC")
            SECTORS_SRC_USED=$(to_sector ${src_size}M)
            TABLE_TYPE=$(blkid -o value -s PTTYPE $SRC)
        fi

        [[ -b $DEST ]] \
            && SECTORS_DEST=$(to_sector ${dest_size}M)
    };_ #}}}

    _(){ #{{{
        #Make sure source or destination folder are not mounted on the same disk to backup to or restore from.
        local d=''
        for d in "$SRC" "$DEST" "$DEST_IMG"; do
            [[ -f $d ]] && d=$(dirname "$d")
            if [[ -d $d ]]; then
                local disk=()
                disk+=($(df --block-size=1M "$d" | tail -n 1 | gawk '{print $1}'))
                disk+=($(lsblk -psnlo name,type $disk 2>/dev/null | grep disk | gawk '{print $1}'))
                [[ ${disk[-1]} == "$SRC" || ${disk[-1]} == "$DEST" ]] && exit_ 1 "Source and destination cannot be the same!"
            fi
        done
    };_ #}}}

    _(){ #{{{
        if [[ -d $SRC && $IS_LVM == true ]]; then
            VG_SRC_NAME=$(gawk '{print $2}' "$SRC/$F_PVS_LIST" | sort -u)
        else
            #Follwing algorithm is a safe-gurad in case there are multiple VGs with similar names.
            #For instance 'vg00' and 'vg00-1'. This is something that might not happen in reals world
            #setups, but it will during automated tests!

            local vgs=($(vgs --noheadings -o vg_name))
            local src_vgs=($(lsblk -nl -o name,type $SRC | grep lvm | gawk '{print $1}'))
            local -A vgs_set
            local v='' s=''
            for v in ${vgs[@]}; do
                for s in ${src_vgs[@]}; do
                    #Store all VGs that match to a LV name including its lengths.
                    grep -q $v < <(echo $s) && vgs_set[$v]=${#v};
                done;
            done

            #Create a list where the index is the length of the VG name
            local l='' lengths=()
            for l in ${!vgs_set[@]}; do
                lengths[${vgs_set[$l]}]=$l;
            done
            #The largest name is the match with most charachters and must be the right source VG name.
            VG_SRC_NAME=${lengths[-1]}
        fi
    };_ #}}}

    _(){ #{{{
        if [[ -z $VG_SRC_NAME ]]; then
            while read -r e g; do
                grep -q ${SRC##*/} < <(dmsetup deps -o devname | sort -u | sed 's/.*(\(\w*\).*/\1/g') && VG_SRC_NAME=$g
            done < <(if [[ -d $SRC && $IS_LVM == true ]]; then cat "$SRC/$F_PVS_LIST"; else pvs --noheadings -o pv_name,vg_name; fi)
        else
            vg_disks "$VG_SRC_NAME" "VG_DISKS" && IS_LVM=true
            if [[ -b $SRC ]] && grep -q 'LVM2_member' < <(lsblk -lpo fstype $SRC); then
                grep -q lvm < <(lsblk -lpo type $SRC) || exit_ 1 "Found LVM, but LVs have not been activated. Did you forget to run 'vgchange -ay $VG_SRC_NAME' ?"
            fi
        fi
    };_ #}}}

    [[ $SRC == "$ROOT_DISK" && $IS_LVM == false && $IS_CHECKSUM == true ]] && LIVE_CHECKSUMS=false && message -w -t "No LVM system detected. File integrity checks disabled."

    [[ $ALL_TO_LVM == true && -z $VG_SRC_NAME && -z $VG_SRC_NAME_CLONE && ! -d $DEST ]] && exit_ 1 "You need to provide a VG name when convertig a standard disk to LVM."

    _(){ #{{{
        if [[ $IS_LVM == true ]]; then
            local l='' lvs=$(lvs --no-headings -o lv_name $VG_SRC_NAME | xargs | tr ' ' '\n')
            for l in ${!TO_LVM[@]}; do
                grep -qE "\b${TO_LVM[$l]}\b" < <(echo "$lvs") && exit_ 1 "LV name '${TO_LVM[$l]}' already exists. Cannot convert "
            done

            local f=''
            for f in ${!LVM_EXPAND_BY[@]} ${!LVM_SIZE_TO[@]}; do
                ! _is_valid_lv "$f" "$VG_SRC_NAME" \
                && exit_ 2 "Volumen name $f does not exists in ${VG_SRC_NAME}!"
            done

            [[ -z $VG_SRC_NAME_CLONE ]] \
                && VG_SRC_NAME_CLONE=${VG_SRC_NAME}_${CLONE_DATE}

            [[ ${VG_SRC_NAME[0]} == "$VG_SRC_NAME_CLONE" ]] && exit_ 1 "VG with name '$VG_SRC_NAME_CLONE' already exists!"

            if [[ -b $DEST ]]; then
                #Even whenn SRC and DEST have dirrent VG names, another one could already exists!
                vgs --no-headings -o vg_name | grep -qE "\b$VG_SRC_NAME_CLONE\b" \
                    && exit_ 1 "VG with name '$VG_SRC_NAME_CLONE' already exists!"

                if [[ -b $SRC ]]; then
                    grep -q "${VG_SRC_NAME_CLONE//-/--}-" < <(dmsetup deps -o devname) \
                    && exit_ 2 "Generated VG name $VG_SRC_NAME_CLONE already exists!"
                fi
            fi
        fi
    };_ #}}}

    SWAP_PART=$(if [[ -d $SRC ]]; then
        grep 'swap' "$SRC/$F_PART_LIST" | gawk '{print $1}' | cut -d '"' -f 2
    else
        lsblk -lpo name,fstype "$SRC" | grep swap | gawk '{print $1}'
    fi)

    EFI_PART=$(if [[ -d $SRC ]]; then
        grep "${ID_GPT_EFI^^}" "$SRC/$F_PART_TABLE" | gawk '{print $1}'
    else
        sfdisk -d $SRC | grep "${ID_GPT_EFI^^}" | gawk '{print $1}'
    fi)

    #Context already initialized, only when source is a disk is of interest here

    if [[ -b $SRC && -z $BOOT_PART ]]; then
        _find_boot 'BOOT_PART' #|| exit_ 1 "No bootartition found."
    fi

    [[ $BOOT_SIZE -gt 0 && -z $BOOT_PART ]] && exit_ 1 "Boot is equal to root partition."

    {
        #In case another distribution is used when cloning, e.g. cloning an Ubuntu system with Debian Live CD.
        [[ ! -e /run/resolvconf/resolv.conf ]] && mkdir /run/resolvconf && cp /run/NetworkManager/resolv.conf /run/resolvconf/
        [[ ! -e /run/NetworkManager/resolv.conf ]] && mkdir /run/NetworkManager && cp /run/resolvconf/resolv.conf /run/NetworkManager/
    } 2>/dev/null

    _prepare_locale || exit_ 1 "Could not prepare locale!"

    #TODO avoid return values and use exit_ instead?
    #main
    message -i -t "Backup started at $(date)"
    if [[ -b $SRC && -b $DEST ]]; then
        Clone || exit_ 1
    elif [[ -d "$SRC" && -b $DEST ]]; then
        Clone -r || exit_ 1
    elif [[ -b "$SRC" && -d $DEST ]]; then
        To_file || exit_ 1
    fi
    message -i -t "Backup finished at $(date)"
} #}}}

#self check and run
bash -n "$(readlink -f "$0")" && Main "$@"
