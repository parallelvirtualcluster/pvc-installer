#!/usr/bin/env bash

logfile="/tmp/pvc-install.log"
lockfile="/run/pvc-install.lock"

if [[ $( whoami ) != "root" ]]; then
    echo "STOP! This script is designed to run as root within the installer only!"
    echo "To build a PVC installer ISO file, use './buildiso.sh'."
    echo "To build a PVC installer PXE root, use './buildpxe.sh'."
    exit 1
fi

echo
active_ttys=( $( w | grep "^root" | awk '{ print $2 }' ) )
echo "Active TTYs: ${active_ttys[@]}"
this_tty=$( tty | sed -e "s:/dev/::" )
echo "This TTY: ${this_tty}"
echo

if [[ ${#active_ttys} -gt 1 ]]; then
    if [[ "${active_ttys[@]}" =~ "ttyS" ]]; then
        if grep -q -E -o "tty[0-9]+" <<<"${this_tty}"; then
            echo "Found more than one TTY and at least one serial TTY!"
            echo -n "If you wish to run the installer on this graphical TTY instead of the serial TTY, press enter within 15 seconds... "
            if ! read -t 15; then
                echo "timeout."
                exit 0
            fi
        else
            echo "Found more than one TTY!"
            echo -n "Waiting for other TTYs to time out... "
            sleep $(( 16 + $( grep -E -o '[0-9]+' <<<"${this_tty}" ) ))
            echo "done."
        fi
    else
        echo "Found more than one graphical TTY!"
        echo -n "If you wish to run the installer on this graphical TTY, press enter within 60 seconds... "
        if ! read -t 60; then
            echo "timeout."
            echo "To launch the installer again on this TTY, run '/install.sh'."
            exit 0
        fi
    fi
fi
if [[ -f ${lockfile} ]]; then
    echo "Aborting installer due to lockfile presence: $( cat ${lockfile} )."
    exit 0
fi
printf "PID $$ on TTY ${this_tty}" > ${lockfile}
echo

# Set the target consoles in the installed image
target_consoles=""
for tty in $( echo -e "$( sed 's/ /\n/g' <<<"${active_ttys[@]}" )" | sort ); do
    tty_type=${tty%%[0-9]*}
    # Only use the first of each console type
    if grep -q "${tty_type}" <<<"${target_consoles}"; then
        continue
    fi

    if [[ ${tty_type} == "ttyS" ]]; then
        # Add 115200 baud rate
        tty="${tty},115200n8"
    fi
    target_consoles="${target_consoles} console=${tty}"
done

iso_name="XXDATEXX"
target_deploy_user="XXDEPLOYUSERXX"

supported_filesystems="ext4 xfs"
default_filesystem="ext4"

supported_debrelease="buster bullseye"
default_debrelease="buster"
default_debmirror="http://mirror.csclub.uwaterloo.ca/debian"

# Base packages (installed by debootstrap)
basepkglist="lvm2,parted,gdisk,sudo,vim,gpg,gpg-agent,openssh-server,vlan,ifenslave,python3,ca-certificates,curl"
case $( uname -m ) in
    x86_64)
        basepkglist="${basepkglist},grub-pc,grub-efi-amd64,linux-image-amd64"
    ;;
    aarch64)
        basepkglist="${basepkglist},grub-efi-arm64,linux-image-arm64"
    ;;
esac
# Supplemental packages (installed in chroot after debootstrap)
suppkglist="firmware-linux,firmware-linux-nonfree,firmware-bnx2,firmware-bnx2x,ntp,ipmitool,acpid,acpi-support-base,lsscsi"

# Modules to blacklist (known-faulty)
target_module_blacklist=( "hpwdt" )

# DANGER - THIS PASSWORD IS PUBLIC
# It should be used ONLY immediately after booting the PVC node in a SECURE environment
# to facilitate troubleshooting of a failed boot. It should NOT be exposed to the Internet,
# and it should NOT be left in place after system configuration. The PVC Ansible deployment
# roles will overwrite it by default during configuration.
root_password="hCb1y2PF"

# Cleanup function for failures or final termination
cleanup() {
    set +o errexit
   
    echo -n "Cleaning up target... "
    umount ${target}/tmp >&2
    umount ${target}/run >&2
    umount ${target}/sys >&2
    umount ${target}/proc >&2
    umount ${target}/dev/pts >&2
    umount ${target}/dev >&2
    umount ${target}/var/lib/ceph >&2
    umount ${target}/var/lib/zookeeper >&2
    umount ${target}/boot/efi >&2
    umount ${target}/boot >&2
    umount ${target} >&2
    vgchange -an >&2
    rmdir ${target} >&2
    echo "done."

    echo -n "Removing lockfile... "
    rm ${lockfile}
    echo "done."
    echo

    if [[ -z ${DONE} ]]; then
        case ${install_option} in
            on)
                echo "A fatal error occurred!; restarting installer in 15 seconds. Press any key to spawn a shell."
                if ! read -t 15; then
                    exec ${0}
                fi
            ;;
            *)
                echo "A fatal error occurred. Use the shell to inspect the log for errors at:"
                echo -e "  ${logfile}"
                echo "To restart the installer, run '/install.sh'."
            ;;
        esac
    fi
}
trap cleanup EXIT

# Checkin function
seed_checkin() (
    case ${1} in
        start)
            action="install-start"
        ;;
        end)
            action="install-complete"
        ;;
    esac
    curl -X POST \
        -H "Content-Type: application/json" \
        -d "{\"action\":\"${action}\",\"hostname\":\"${target_hostname}\",\"host_macaddr\":\"${host_macaddr}\",\"host_ipaddr\":\"${host_ipaddr}\",\"bmc_macaddr\":\"${bmc_macaddr}\",\"bmc_ipaddr\":\"${bmc_ipaddr}\"}" \
        ${pvcbootstrapd_checkin_uri} >&2
)

# Obtain the preseed options from the kernel command line
install_option=""
seed_host=""
seed_file=""
kernel_cmdline=( $( cat /proc/cmdline ) )
for option in ${kernel_cmdline[@]}; do
    case ${option} in
        pvcinstall.preseed=*)
            install_option=${option#pvcinstall.preseed=}
        ;;
        pvcinstall.seed_host=*)
            seed_host=${option#pvcinstall.seed_host=}
        ;;
        pvcinstall.seed_file=*)
            seed_file=${option#pvcinstall.seed_file=}
        ;;
    esac
done

seed_config() {
    # Get IPMI BMC MAC for checkings
    bmc_macaddr="$( ipmitool lan print 2>/dev/null | grep 'MAC Address  ' | awk '{ print $NF }' )"
    bmc_ipaddr="$( ipmitool lan print 2>/dev/null | grep 'IP Address  ' | awk '{ print $NF }' )"

    # Perform DHCP on all interfaces to come online
    for interface in $( ip address | grep '^[0-9]' | grep 'eno\|enp\|ens\|wlp' | awk '{ print $2 }' | tr -d ':' ); do
        ip link set ${interface} up
        pgrep dhclient &>/dev/null || dhclient ${interface} >&2
    done

    # Fetch the seed config
    tftp -m binary "${seed_host}" -c get "${seed_file}" /tmp/install.seed >&2 || exit 1

    # Load the variables from the seed config
    . /tmp/install.seed || exit 1

    # Ensure optional configurations are set to defaults if unset
    if [[ -z ${filesystem} ]]; then
        filesystem="${default_filesystem}"
    fi

    if [[ -z ${debrelease} ]]; then
        debrelease="${default_debrelease}"
    fi

    if [[ -z ${debmirror} ]]; then
        debmirror="${default_debmirror}"
    fi

    # Append the addpkglist to the suppkglist if present
    if [[ -n ${addpkglist} ]]; then
        suppkglist="${suppkglist},${addpkglist}"
    fi

    # Handle the target interface
    target_route="$( ip route show to match ${seed_host} | grep 'scope link' )"
    target_interface="$( grep -E -o 'e[a-z]+[0-9]+[a-z0-9]*' <<<"${target_route}" )"

    host_macaddr=$( ip -br link show ${target_interface} | awk '{ print $3 }' )
    host_ipaddr=$( ip -br address show ${target_interface} | awk '{ print $3 }' | awk -F '/' '{ print $1 }' )

    o_target_disk="${target_disk}"
    # Handle the target disk
    case "${target_disk}" in
        /dev/*)
            # Get the real path of the block device (for /dev/disk/* symlink paths)
            target_disk="$( realpath ${target_disk} )"
        ;;
        detect:*)
            # Read the detect string into separate variables
            # A detect string is formated thusly:
            #   detect:<Controller-or-Model-Name>:<Capacity-in-human-units><0-indexed-ID>
            # For example:
            #   detect:INTEL:800GB:1
            #   detect:DELLBOSS:240GB:0
            #   detect:PERC H330 Mini:200GB:0
            echo "Attempting to find disk for detect string '${o_target_disk}'"
            IFS=: read detect b_name b_size b_id <<<"${target_disk}"
            # Get the lsscsi output (exclude NVMe)
            lsscsi_data_all="$( lsscsi -s -N )"
            # Get the available sizes, and match to within +/- 3%
            lsscsi_sizes=( $( awk '{ print $NF }' <<<"${lsscsi_data_all}" | sort | uniq ) )
            # For each size...
            for size in ${lsscsi_sizes[@]}; do
                # Get whether we match +3% and -3% sizes to handle human -> real deltas
                # The break below is pretty safe. I can think of no two classes of disks
                # where the difference is within 3% of each other. Even the common
                # 120GB -> 128GB and 240GB -> 256GB size deltas are well outside of 3%,
                # so this should be safe in all cases.
                # We use Python for this due to BASH's problematic handling of floating-
                # point numbers.
                is_match="$(
                    python <<EOF
from re import sub
try:
    b_size = float(sub(r'\D.','','${b_size}'))
    t_size = float(sub(r'\D.','','${size}'))
except ValueError:
    exit(0)
plusthreepct = t_size * 1.03
minusthreepct = t_size * 0.97
if b_size > minusthreepct and b_size < plusthreepct:
    print("match")
EOF
                )"
                # If we do, this size is our actual block size, not what was specified
                if [[ -n ${is_match} ]]; then
                    b_size=${size}
                    break
                fi
            done
            # Search for the b_name first
            lsscsi_data_name="$( grep --color=none -Fiw "${b_name}" <<<"${lsscsi_data_all}" )"
            # Search for the b_blocks second
            lsscsi_data_name_size="$( grep --color=none -Fiw "${b_size}" <<<"${lsscsi_data_name}" )"
            # Read the /dev/X results into an array
            lsscsi_filtered=( $( awk '{ print $(NF-1) }' <<<"${lsscsi_data_name_size}" ) )
            # Get the b_id-th entry
            target_disk="${lsscsi_filtered[${b_id}]}"
        ;;
    esac

    if [[ ! -b ${target_disk} ]]; then
        echo "Invalid disk or disk not found for '${o_target_disk}'!"
        exit 1
    else
        echo "Found target disk '${target_disk}'"
    fi

    echo
    echo "WARNING! All data on block device ${target_disk} will be wiped!"
    echo -n "Press any key within 15 seconds to cancel... "
    if read -t 15; then
        DONE="c"
        exit 0
    fi
    echo
}

interactive_config() {
    clear

    echo "--------------------------------------------------------"
    echo "| PVC Node installer (${iso_name}) |"
    echo "--------------------------------------------------------"
    echo
    echo "This LiveCD will install a PVC node base system ready for bootstrapping with 'pvc-ansible'."
    echo
    echo "* NOTE: If you make a mistake and need to restart the installer while answering"
    echo "        the questions below, you may do so by typing ^C to cancel the script,"
    echo "        then re-running it by calling /install.sh in the resulting shell."
    echo

    echo "1) Please enter a fully-qualified hostname for the system. This should match the hostname"
    echo "in the 'pvc-ansible' inventory."
    while [[ -z ${target_hostname} ]]; do
        echo
        echo -n "> "
        read target_hostname
        if [[ -z ${target_hostname} ]]; then
            echo
            echo "Please enter a hostname."
            continue
        fi
        echo
    done

    disks="$(
        for disk in /dev/sd? /dev/nvme?n?; do
            if [[ ! -b ${disk} ]]; then
                continue
            fi
            disk_data="$( fdisk -l ${disk} 2>/dev/null )"
            echo -n "${disk}"
            echo -en "\t$( grep "^Disk model:" <<<"${disk_data}" | awk '{ $1=""; print $0 }' )"
            echo -en "  $( grep "^Disk ${disk}:" <<<"${disk_data}" | awk '{ $1=""; $2="size:"; print $0 }' )"
            echo
        done
    )"

    echo "2a) Please enter the disk to install the PVC base system to. This disk will be"
    echo "wiped, an LVM PV created on it, and the system installed to this LVM."
    echo "* NOTE: PVC requires a disk of at least 30GB to be installed to, and 100GB is the"
    echo "recommended minimum size for optimal production partition sizes."
    echo "* NOTE: For optimal performance, this disk should be high-performance flash (SSD, etc.)."
    echo "* NOTE: This disk should be a RAID-1 volume configured in hardware, or a durable storage"
    echo "device, maximum redundancy and resiliency."
    echo
    echo "Available disks:"
    echo
    echo -e "$( sed 's/\(.*\)/  \1/' <<<"${disks[@]}" )"
    while [[ ! -b ${target_disk} ]]; do
        echo
        echo -n "> "
        read target_disk
        if [[ ! -b ${target_disk} ]]; then
            echo
            echo "Please enter a valid target disk."
            continue
        fi
        blockdev_size_gbytes="$(( $( blockdev --getsize64 ${target_disk} ) / 1024 / 1024 / 1024 - 1))"
        if [[ ${blockdev_size_gbytes} -lt 30 ]]; then
            target_disk=""
            echo
            echo "The specified disk is too small (<30 GB) to use as a PVC system disk."
            echo "Please choose an alternative disk."
            continue
        fi
        echo
    done

    echo "2b) Please enter an alternate filesystem for the system partitions if desired."
    echo "    Supported: ${supported_filesystems}"
    echo "    Default: ${default_filesystem}"
    while [[ -z ${filesystem} ]]; do
        echo
        echo -n "> "
        read filesystem
        if [[ -z ${filesystem} ]]; then
            filesystem="${default_filesystem}"
        fi
        if ! grep -qw "${filesystem}" <<<"${supported_filesystem}"; then
            filesystem=""
            echo
            echo "Please enter a valid filesystem."
            continue
        fi
        echo
    done

    for interface in $( ip address | grep '^[0-9]' | grep 'eno\|enp\|ens\|wlp' | awk '{ print $2 }' | tr -d ':' ); do
        ip link set ${interface} up
    done
    sleep 2
    interfaces="$(
        ip address | grep '^[0-9]' | grep 'eno\|enp\|ens\|wlp' | awk '{ print $2"\t"$3 }' | tr -d ':'
    )"
    echo "3a) Please enter the primary network interface for external connectivity. If"
    echo "no entries are shown here, ensure a cable is connected, then restart the"
    echo "installer with ^C and '/install.sh'."
    echo
    echo "Available interfaces:"
    echo
    echo -e "$( sed 's/\(.*\)/  \1/' <<<"${interfaces[@]}" )"
    while [[ -z ${target_interface} ]]; do
        echo
        echo -n "> "
        read target_interface
        if [[ -z ${target_interface} ]]; then
            echo
            echo "Please enter a valid interface."
            continue
        fi
        if ! grep -qw "${target_interface}" <<<"${interfaces[@]}"; then
            target_interface=""
            echo
            echo "Please enter a valid interface."
            continue
        fi
        echo
    done

    echo -n "3b) Is a tagged vLAN required for the primary network interface? [y/N] "
    read vlans_req
    if [[ ${vlans_req} == 'y' || ${vlans_req} == 'Y' ]]; then
        echo
        echo "Please enter the vLAN ID for the interface."
        while [[ -z ${vlan_id} ]]; do
            echo
            echo -n "> "
            read vlan_id
            if [[ -z ${vlan_id} ]]; then
                echo
                echo "Please enter a numeric vLAN ID."
                continue
            fi
        done
        echo
    else
        vlan_id=""
        echo
    fi

    echo "3c) Please enter the IP address, in CIDR format [X.X.X.X/YY], of the primary"
    echo "network interface. Leave blank for DHCP configuration of the interface on boot."
    echo
    echo -n "> "
    read target_ipaddr
    if [[ -n ${target_ipaddr} ]]; then
        target_netformat="static"
        echo
        echo "3d) Please enter the default gateway IP address of the primary"
        echo "network interface."
        while [[ -z ${target_defgw} ]]; do
            echo
            echo -n "> "
            read target_defgw
            if [[ -z ${target_defgw} ]]; then
                echo
                echo "Please enter a default gateway; the installer requires Internet access."
                continue
            fi
            echo
        done
    else
        target_netformat="dhcp"
        echo
    fi

    echo -n "Bringing up primary network interface in ${target_netformat} mode... "
    case ${target_netformat} in
        'static')
            if [[ -n ${vlan_id} ]]; then
                modprobe 8021q >&2
                vconfig add ${target_interface} ${vlan_id} >&2
                vlan_interface=${target_interface}.${vlan_id}
                ip link set ${target_interface} up >&2 || true
                ip link set ${vlan_interface} up >&2 || true
                ip address add ${target_ipaddr} dev ${vlan_interface} >&2 || true
                ip route add default via ${target_defgw} >&2 || true
                formatted_ipaddr="$( sipcalc ${target_ipaddr} | grep -v '(' | awk '/Host address/{ print $NF }' )"
                formatted_netmask="$( sipcalc ${target_ipaddr} | grep -v '(' | awk '/Network mask/{ print $NF }' )"
                real_interface="${vlan_interface}"
                target_interfaces_is="static-vlan"
            else
                ip link set ${target_interface} up >&2 || true
                ip address add ${target_ipaddr} dev ${target_interface} >&2 || true
                ip route add default via ${target_defgw} >&2 || true
                formatted_ipaddr="$( sipcalc ${target_ipaddr} | grep -v '(' | awk '/Host address/{ print $NF }' )"
                formatted_netmask="$( sipcalc ${target_ipaddr} | grep -v '(' | awk '/Network mask/{ print $NF }' )"
                real_interface="${target_interface}"
                target_interfaces_is="static-raw"
            fi
            cat <<EOF >/etc/resolv.conf
nameserver 8.8.8.8
EOF
        ;;
        'dhcp')
            if [[ -n ${vlan_id} ]]; then
                modprobe 8021q >&2
                vconfig add ${target_interface} ${vlan_id} &>/dev/null
                vlan_interface=${target_interface}.${vlan_id}
                dhclient ${vlan_interface} >&2
                real_interface="${vlan_interface}"
                target_interfaces_is="dhcp-vlan"
            else
                dhclient ${target_interface} >&2
                real_interface="${target_interface}"
                target_interfaces_is="dhcp-raw"
            fi
        ;;
    esac
    echo "done."
    echo

    echo -n "Waiting for networking to become ready... "
    while ! ping -q -c 1 8.8.8.8 &>/dev/null; do
        sleep 1
    done
    echo "done."
    echo

    echo "4a) Please enter an alternate Debian release codename for the system if desired."
    echo "    Supported: ${supported_debrelease}"
    echo "    Default: ${default_debrelease}"
    while [[ -z ${debrelease} ]]; do
        echo
        echo -n "> "
        read debrelease
        if [[ -z ${debrelease} ]]; then
            debrelease="${default_debrelease}"
        fi
        if ! grep -qw "${debrelease}" <<<"${supported_debrelease}"; then
            debrelease=""
            echo
            echo "Please enter a valid release."
            continue
        fi
        echo
    done

    echo "4b) Please enter an HTTP URL for an alternate Debian mirror if desired."
    echo "    Default: ${default_debmirror}"
    while [[ -z ${debmirror} ]]; do
        echo
        echo -n "> "
        read debmirror
        if [[ -z ${debmirror} ]]; then
            debmirror="${default_debmirror}"
        fi
        if ! wget -O /dev/null ${debmirror}/dists/${debrelease}/Release &>/dev/null; then
            debmirror=""
            echo
            echo "Please enter a valid Debian mirror URL."
            continue
        fi
        echo
        echo "Repository mirror '${debmirror}' successfully validated."
        echo
    done

    echo "4c) Please enter any additional packages, comma-separated without spaces,"
    echo "that you require installed in the base system (firmware, etc.). These"
    echo "must be valid packages or the install will fail!"
    echo -n "> "
    read addpkglist
    echo

    target_keys_method="wget"
    echo "5) Please enter an HTTP URL containing a text list of SSH authorized keys to"
    echo "fetch. These keys will be allowed access to the deployment user 'XXDEPLOYUSER'"
    echo "via SSH."
    echo ""
    echo "Leave blank to bypass this and use a password instead."
    echo
    echo -n "> "
    read target_keys_path
    if [[ -z ${target_keys_path} ]]; then
        echo
        echo "No SSH keys URL specified. Falling back to password configuration."
        echo
        echo "5) Please enter a password (hidden), twice, for the deployment user '${target_deploy_user}'."
        while [[ -z "${target_password}" ]]; do
            echo
            echo -n "> "
            read -s target_password_1
            echo
            echo -n "> "
            read -s target_password_2
            echo
            if [[ -n "${target_password_1}" && "${target_password_1}" -eq "${target_password_2}" ]]; then
                target_password="${target_password_1}"
            else
                echo
                echo "The specified passwords do not match or are empty."
            fi
        done
    else
        while ! wget -O /dev/null ${target_keys_path} &>/dev/null; do
            echo
            echo "Please enter a valid SSH keys URL."
            echo
            echo -n "> "
            read target_keys_path
        done
        echo
        echo "SSH key source '${target_keys_path}' successfully validated."
    fi
    echo
}    

case ${install_option} in
    on)
        seed_config
    ;;
    *)
        interactive_config
    ;;
esac

titlestring_text="| Proceeding with installation of host '${target_hostname}'. |"
titlestring_len="$(( $( wc -c <<<"${titlestring_text}" ) - 2 ))"
for i in $( seq 0 ${titlestring_len} ); do echo -n "-"; done; echo
echo "${titlestring_text}"
for i in $( seq 0 ${titlestring_len} ); do echo -n "-"; done; echo
echo

### Script begins ###
echo "LOGFILE: ${logfile}"
echo

exec 1> >( tee -ia ${logfile} )
exec 2> >( tee -ia ${logfile} >/dev/null )
set -o errexit
set -o xtrace

case ${install_option} in
    on)
        seed_checkin start
    ;;
    *)
        # noop
        true
    ;;
esac

echo -n "Determining partition sizes... "
blockdev_size_bytes="$( blockdev --getsize64 ${target_disk} )"
blockdev_size_gbytes="$(( ${blockdev_size_bytes} / 1024 / 1024 / 1024 - 1))"
if [[ ${blockdev_size_gbytes} -ge 100 ]]; then
    # Optimal sized system disk (>=100GB), use large partitions
    size_root_lv="32"
    size_ceph_lv="8"
    size_zookeeper_lv="32"
    size_swap_lv="16"
    echo "found large disk (${blockdev_size_gbytes} >= 100GB), using optimal partition sizes."
else
    # Minimum sized disk (>=30GB), use small partitions
    size_root_lv="8"
    size_ceph_lv="4"
    size_zookeeper_lv="8"
    size_swap_lv="8"
    echo "found small disk (${blockdev_size_gbytes} < 100GB), using small partition sizes."
fi

echo -n "Unmounting potential partitions on target device... "
for mount in $( mount | grep "${target_disk}" | awk '{ print $3 }' | sort -r ); do
    umount -f ${mount} >&2 || true
done
echo "done."

echo -n "Unmounting potential LVM logical volumes on target device... "
for vg in $( pvscan | grep "${target_disk}" | awk '{ print $4 }' ); do
    for mount in $( mount | grep "/${vg}" | awk '{ print $3 }' | sort -r ); do
        umount -f ${mount} >&2 || true
    done
done
echo "done."

echo -n "Disabing potential LVM volume groups on target device... "
for vg in $( pvscan | grep "${target_disk}" | awk '{ print $4 }' ); do
    vgchange -an ${vg} >&2 || true
    sleep 1
    vgchange -an ${vg} >&2 || true
    yes | vgremove -f ${vg} >&2 || true
done
echo "done."

echo -n "Removing existing LVM physical volumes... "
for pv in $( pvscan | grep "${target_disk}" | awk '{ print $2 }' ); do
    yes | pvremove -f ${pv} >&2 || true
done
echo "done."

echo -n "Wiping partition signatures on '${target_disk}'... "
wipefs -a ${target_disk} >&2
echo "done."

echo -n "Preparing GPT partitions on '${target_disk}'... "
# New GPT, part 1 32MB BIOS boot, part 2 64MB ESP, part 3 928MB BOOT, part 4 inf LVM PV
echo -e "o\ny\nn\n1\n\n32M\nEF02\nn\n2\n\n64M\nEF00\nn\n3\n\n928M\n8300\nn\n4\n\n\n8E00\nw\ny\n" | gdisk ${target_disk} >&2
echo "done."

echo -n "Rescanning disks... "
partprobe >&2 || true
sleep 5
echo "done."

echo -n "Creating LVM PV on '${target_disk}4'... "
yes | pvcreate -ffy ${target_disk}4 >&2
echo "done."

echo -n "Creating LVM VG 'vgx'... "
yes | vgcreate -f vgx ${target_disk}4 >&2
echo "done."

echo -n "Creating root logical volume (${size_root_lv}GB)... "
yes | lvcreate -L ${size_root_lv}G -n root vgx >&2
echo "done."
echo -n "Creating filesystem on root logical volume (${filesystem})... "
yes | mkfs.${filesystem} /dev/vgx/root >&2
echo "done."

echo -n "Creating ceph logical volume (${size_ceph_lv}GB)... "
yes | lvcreate -L ${size_ceph_lv}G -n ceph vgx >&2
echo "done."
echo -n "Creating filesystem on ceph logical volume (${filesystem})... "
yes | mkfs.${filesystem} /dev/vgx/ceph >&2
echo "done."

echo -n "Creating zookeeper logical volume (${size_zookeeper_lv}GB)... "
yes | lvcreate -L ${size_zookeeper_lv}G -n zookeeper vgx >&2
echo "done."
echo -n "Creating filesystem on zookeeper logical volume (${filesystem})... "
yes | mkfs.${filesystem} /dev/vgx/zookeeper >&2
echo "done."

echo -n "Creating swap logical volume (${size_swap_lv}GB)... "
yes | lvcreate -L ${size_swap_lv}G -n swap vgx >&2
echo "done."
echo -n "Creating swap space on swap logical volume... "
yes | mkswap -f /dev/vgx/swap >&2
echo "done."

echo -n "Creating filesystem on boot partition (ext2)... "
yes | mkfs.ext2 ${target_disk}3 >&2
echo "done."

echo -n "Creating filesystem on ESP partition (vfat)... "
yes | mkdosfs -F32 ${target_disk}2 >&2
echo "done."

vgchange -ay >&2
target="/tmp/target"
mkdir -p ${target} >&2
echo -n "Mounting disks on temporary target '${target}'... "
mount /dev/vgx/root ${target} >&2
mkdir -p ${target}/boot >&2
chattr +i ${target}/boot >&2
mount ${target_disk}3 ${target}/boot >&2
mkdir -p ${target}/boot/efi >&2
chattr +i ${target}/boot/efi >&2
mount ${target_disk}2 ${target}/boot/efi >&2
mkdir -p ${target}/var/lib/ceph >&2
chattr +i ${target}/var/lib/ceph >&2
mount /dev/vgx/ceph ${target}/var/lib/ceph >&2
mkdir -p ${target}/var/lib/zookeeper >&2
chattr +i ${target}/var/lib/zookeeper >&2
mount /dev/vgx/zookeeper ${target}/var/lib/zookeeper >&2
mkdir -p ${target}/tmp >&2
chattr +i ${target}/tmp >&2
mount -t tmpfs tmpfs ${target}/tmp >&2
echo "done."

echo -n "Running debootstrap install... "
echo "Command: debootstrap --include=${basepkglist} ${debrelease} ${target}/ ${debmirror}" >&2
debootstrap --include=${basepkglist} ${debrelease} ${target}/ ${debmirror} >&2
echo "done."

echo -n "Adding non-free repository (firmware, etc.)... "
mkdir -p ${target}/etc/apt/sources.list.d/ >&2
echo "deb ${debmirror} ${debrelease} contrib non-free" | tee -a ${target}/etc/apt/sources.list >&2
chroot ${target} apt-get update >&2
echo "done."

echo -n "Installing supplemental packages... "
chroot ${target} apt-get install -y --no-install-recommends $( sed 's/,/ /g' <<<"${suppkglist}" ) >&2
echo "done."

# Determine the bypath name of the specified system disk
for disk in /dev/disk/by-path/*; do
    bypathlink="$( realpath ${disk} | awk -F'/' '{ print $NF }' )"
    enteredname="$( awk -F'/' '{ print $NF }' <<<"${target_disk}" )"
    if [[ ${bypathlink} == ${enteredname} ]]; then
        bypath_disk="${disk}"
    fi
done

echo -n "Adding fstab entries... "
echo "/dev/mapper/vgx-root / ${filesystem} errors=remount-ro 0 1" | tee -a ${target}/etc/fstab >&2
echo "/dev/mapper/vgx-ceph /var/lib/ceph ${filesystem} errors=remount-ro 0 2" | tee -a ${target}/etc/fstab >&2
echo "/dev/mapper/vgx-zookeeper /var/lib/zookeeper ${filesystem} errors=remount-ro 0 2" | tee -a ${target}/etc/fstab >&2
echo "/dev/mapper/vgx-swap none swap sw 0 0" | tee -a ${target}/etc/fstab >&2
echo "${bypath_disk}-part3 /boot ext2 defaults 0 2" | tee -a ${target}/etc/fstab >&2
echo "${bypath_disk}-part2 /boot/efi vfat umask=0077 0 2" | tee -a ${target}/etc/fstab >&2
echo "tmpfs /tmp tmpfs defaults 0 0" | tee -a ${target}/etc/fstab >&2
echo "done."

seed_interfaces_segment() {
    # A seed install is always "dhcp-raw" since the provisioner is always a dedicated, access port
    target_interfaces_block="auto ${target_interface}\niface ${target_interface} inet dhcp\npost-up /etc/network/pvcprovisionerd.checkin.sh \$IFACE"
}

interactive_interfaces_segment() {
    case ${target_interfaces_is} in
        static-vlan)
            target_interfaces_block="auto ${vlan_interface}\niface ${vlan_interface} inet ${target_netformat}\n\tvlan_raw_device ${target_interface}\n\taddress ${formatted_ipaddr}\n\tnetmask ${formatted_netmask}\n\tgateway ${target_defgw}"
        ;;
        static-raw)
            target_interfaces_block="auto ${target_interface}\niface ${target_interface} inet ${target_netformat}\n\taddress ${formatted_ipaddr}\n\tnetmask ${formatted_netmask}\n\tgateway ${target_defgw}"
        ;;
        dhcp-vlan)
            target_interfaces_block="auto ${vlan_interface}\niface ${vlan_interface} inet ${target_netformat}\n\tvlan_raw_device${target_interface}"
        ;;
        dhcp-raw)
            target_interfaces_block="auto ${target_interface}\niface ${target_interface} inet ${target_netformat}"
        ;;
    esac
}

echo -n "Creating bootstrap interface segment... "
case ${install_option} in
    on)
        seed_interfaces_segment
    ;;
    *)
        interactive_interfaces_segment
    ;;
esac
echo "done."

echo -n "Adding bootstrap interface segment... "
echo -e "${target_interfaces_block}" | tee ${target}/etc/network/interfaces.d/${target_interface} >&2
echo "done."

case ${install_option} in
    on)
        echo -n "Creating bond interface segment... "
        bond_interfaces="$( ip -br link show | grep -E -o '^e[a-z]+[0-9]+[a-z0-9]*' | grep -v "^${target_interface}$" | tr '\n' ' ' )"
        bond_interfaces_block="auto bond0\niface bond0 inet manual\n\tbond-mode 802.3ad\n\tbond-slaves ${bond_interfaces}\n\tpost-up ip link set mtu 9000 dev \$IFACE"
        echo "done."

        echo -n "Adding bond interface segment... "
        echo -e "${bond_interfaces_block}" | tee ${target}/etc/network/interfaces.d/bond0 >&2
        echo "done."

        echo -n "Adding bootstrap interface post-up checkin script... "
        cat <<EOF | tee ${target}/etc/network/pvcprovisionerd.checkin.sh >&2
#!/usr/bin/env bash
target_interface=\${1}
pvcbootstrapd_checkin_uri="${pvcbootstrapd_checkin_uri}"
host_macaddr=\$( ip -br link show \${target_interface} | awk '{ print \$3 }' )
host_ipaddr=\$( ip -br address show \${target_interface} | awk '{ print \$3 }' | awk -F '/' '{ print \$1 }' )
bmc_macaddr=\$( ipmitool lan print | grep 'MAC Address  ' | awk '{ print \$NF }' )
bmc_ipaddr=\$( ipmitool lan print | grep 'IP Address  ' | awk '{ print \$NF }' )

if [[ -f /etc/pvc-install.base && -f /etc/pvc-install.pvc ]]; then
    # The second boot, after Ansible has configured the cluster
    action="system-boot_configured"
else
    # The first boot, when Ansible has not been run yet
    action="system-boot_initial"
fi

sleep 30

curl -X POST \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"\${action}\",\"hostname\":\"\$( hostname -s )\",\"host_macaddr\":\"\${host_macaddr}\",\"host_ipaddr\":\"\${host_ipaddr}\",\"bmc_macaddr\":\"\${bmc_macaddr}\",\"bmc_ipaddr\":\"\${bmc_ipaddr}\"}" \
    \${pvcbootstrapd_checkin_uri}

if [[ \${action} == "system-boot_configured" ]]; then
    # Clean up the bootstrap interface and this script
    rm /etc/network/interfaces.d/\${target_interface}
    rm \$0
fi
EOF
        chmod +x ${target}/etc/network/pvcprovisionerd.checkin.sh
        echo "done."
    ;;
    *)
        # noop
        true
    ;;
esac

echo -n "Setting temporary 'root' password... "
echo "root:${root_password}" | chroot ${target} chpasswd >&2
echo "done."

echo -n "Adding deployment user... "
mv ${target}/home ${target}/var/home >&2
chroot ${target} useradd -u 200 -d /var/home/${target_deploy_user} -m -s /bin/bash -g operator -G sudo ${target_deploy_user} >&2
chroot ${target} mkdir -p /var/home/${target_deploy_user}/.ssh
if [[ -n ${target_keys_path} ]]; then
    case ${target_keys_method} in
        wget)
            wget -O ${target}/var/home/${target_deploy_user}/.ssh/authorized_keys ${target_keys_path} || failed_keys="y"
        ;;
        tftp)
            tftp -m binary "${seed_host}" -c get "${target_keys_path}" ${target}/var/home/${target_deploy_user}/.ssh/authorized_keys || failed_keys="y"
        ;;
    esac
    chroot ${target} chmod 0600 /var/home/${target_deploy_user}/.ssh/authorized_keys
    chroot ${target} chown -R ${target_deploy_user}:operator /var/home/${target_deploy_user}
else
    echo "${target_deploy_user}:${target_password}" | chroot ${target} chpasswd >&2
fi
echo "done."
if [[ -n ${failed_keys} ]]; then
    target_password="$( pwgen -s 8 1 )"
    echo "WARNING: Failed to fetch keys; target deploy user SSH keyauth will fail."
    echo "Setting temporary random password '${temp_password}' instead."
    echo "${target_deploy_user}:${target_password}" | chroot ${target} chpasswd >&2
fi

echo -n "Setting NOPASSWD for sudo group... "
sed -i 's/^%sudo\tALL=(ALL:ALL) ALL/%sudo\tALL=(ALL:ALL) NOPASSWD: ALL/' ${target}/etc/sudoers
echo "done."

echo -n "Setting /etc/issue generator... "
mkdir -p ${target}/etc/network/if-up.d >&2
echo -e "#!/bin/sh
IP=\"\$( ip -4 addr show dev ${target_interface} | grep inet | awk '{ print \$2 }' | head -1 )\"
cat <<EOF >/etc/issue
Debian GNU/Linux 10 \\\\n \\\\l

Bootstrap interface IP address: \$IP

EOF" | tee ${target}/etc/network/if-up.d/issue-gen >&2
chmod +x ${target}/etc/network/if-up.d/issue-gen 1>&2
echo "done."

echo -n "Generating host rsa and ed25519 keys... "
rm ${target}/etc/ssh/ssh_host_*_key* >&2
chroot ${target} ssh-keygen -t rsa -N "" -f /etc/ssh/ssh_host_rsa_key >&2
chroot ${target} ssh-keygen -t ed25519 -N "" -f /etc/ssh/ssh_host_ed25519_key >&2
echo "done."

echo -n "Setting hostname... "
echo "${target_hostname}" | tee ${target}/etc/hostname >&2
echo "done."

echo -n "Setting resolv.conf... "
echo "nameserver 8.8.8.8" | tee ${target}/etc/resolv.conf >&2
echo "done."

echo -n "Installing GRUB bootloader... "
mount --bind /dev ${target}/dev >&2
mount --bind /dev/pts ${target}/dev/pts >&2
mount --bind /proc ${target}/proc >&2
mount --bind /sys ${target}/sys >&2
mount --bind /run ${target}/run >&2
if [[ -d /sys/firmware/efi ]]; then
    bios_target="x86_64-efi"
else
    bios_target="i386-pc"
fi
cat <<EOF | tee ${target}/etc/default/grub >&2
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Parallel Virtual Cluster (PVC) - Debian"
GRUB_CMDLINE_LINUX="noautogroup blacklist=hpwdt ${target_consoles}"
GRUB_TERMINAL_INPUT="console serial"
GRUB_TERMINAL_OUTPUT="gfxterm serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --unit=1 --speed=115200"
EOF
chroot ${target} grub-install --force --target=${bios_target} ${target_disk} >&2
chroot ${target} grub-mkconfig -o /boot/grub/grub.cfg >&2
echo "done."

echo -n "Adding module blacklists... "
for module in ${target_module_blacklist[@]}; do
    echo "blacklist ${module}" >> ${target}/etc/modprobe.d/blacklist.conf
done
chroot ${target} update-initramfs -u -k all >&2
echo "done."

DONE="y"

seed_postinst() {
    cleanup
    echo "Temporary root password: ${root_password}"
    echo
    seed_checkin end

    echo "Rebooting in 10 seconds."
    sleep 10
    reboot
}

interactive_postinst() {
    set +o errexit
    echo
    echo -n "Edit the /etc/network/interfaces file in the target before completing setup? If you plan to use bonding, it is prudent to set this up in basic form now! [y/N] "
    read edit_ifaces
    if [[ ${edit_ifaces} == 'y' || ${edit_ifaces} == 'Y' ]]; then
        vim ${target}/etc/network/interfaces
    fi
    echo

    echo -n "Launch a chroot shell in the target environment? [y/N] "
    read launch_chroot
    if [[ ${launch_chroot} == 'y' || ${edit_ifaces} == 'Y' ]]; then
        echo "Type 'exit' or Ctrl+D to exit chroot."
        chroot ${target} /bin/bash
    fi

    cleanup

    echo "-------------------------------------------------------------------------------------"
    echo "| PVC node installation finished. Next steps:                                       |"
    echo "| 1. Press <enter> to reboot the system.                                            |"
    echo "| 2. Boot the system verify SSH access (IP shown on login screen).                  |"
    echo "| 3. Proceed with system deployment via PVC Ansible.                                |"
    echo "|                                                                                   |"
    echo "| The INSECURE temporary root password if the system will not boot is: ${root_password}     |"
    echo "-------------------------------------------------------------------------------------"
    echo
    read

    reboot
}

case ${install_option} in
    on)
        seed_postinst
    ;;
    *)
        interactive_postinst
    ;;
esac
