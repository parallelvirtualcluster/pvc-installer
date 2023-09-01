#!/usr/bin/env bash

if [[ $( whoami ) != "root" ]]; then
    echo "STOP! This script is designed to run as root within the installer only!"
    echo "Do not run it on your system. To build a PVC installer ISO, use './buildiso.sh' instead!"
    exit 1
fi

logfile="/tmp/pvc-install.log"
iso_name="XXDATEXX"
target_deploy_user="XXDEPLOYUSERXX"

supported_debrelease="buster bullseye"
default_debrelease="buster"
default_debmirror="http://debian.mirror.rafal.ca/debian"

debpkglist="lvm2,parted,gdisk,grub-pc,grub-efi-amd64,linux-image-amd64,sudo,vim,gpg,gpg-agent,aptitude,openssh-server,vlan,ifenslave,python2,python3,ca-certificates,ntp"
exclpkglist="systemd-timesyncd"
suppkglist="firmware-linux,firmware-linux-nonfree,firmware-bnx2,firmware-bnx2x"

# DANGER - THIS PASSWORD IS PUBLIC
# It should be used ONLY immediately after booting the PVC node in a SECURE environment
# to facilitate troubleshooting of a failed boot. It should NOT be exposed to the Internet,
# and it should NOT be left in place after system configuration. The PVC Ansible deployment
# roles will overwrite it by default during configuration.
root_password="hCb1y2PF"

# Obtain the mode from the kernel command line
kernel_cmdline=$( cat /proc/cmdline )
install_option="$( awk '{
    for(i=1; i<=NF; i++) {
        if($i ~ /pvcinstall.preseed/) {
            print $i;
        }
    }
}' <<<"${kernel_cmdline}" | awk -F'=' '{ print $NF }' )"

seed_config() {
    seed_host="$( awk '{
        for(i=1; i<=NF; i++) {
            if($i ~ /pvcinstall.seed_host=/) {
                print $i;
            }
        }
    }' <<<"${kernel_cmdline}" | awk -F'=' '{ print $NF }' )"
    seed_file="$( awk '{
        for(i=1; i<=NF; i++) {
            if($i ~ /pvcinstall.seed_file=/) {
                print $i;
            }
        }
    }' <<<"${kernel_cmdline}" | awk -F'=' '{ print $NF }' )"

    # Perform DHCP on all interfaces to come online
    for interface in $( ip address | grep '^[0-9]' | grep 'eno\|enp\|ens\|wlp' | awk '{ print $2 }' | tr -d ':' ); do
        ip link set ${interface} up
        dhclient ${interface}
    done

    # Fetch the seed config
    tftp -m binary "${seed_host}" -c get "${seed_file}" /tmp/install.seed

    . /tmp/install.seed || exit 1

    # Handle the target disk
    if [[ -n ${target_disk_path} ]]; then
        target_disk="$( realpath ${target_disk_path} )"
        if [[ ! -b ${target_disk} ]]; then
            echo "Invalid disk!"
            exit 1
        fi
    else
        # Find the (first) disk with the given model
        for disk in /dev/sd?; do
            disk_model="$( fdisk -l ${disk} | grep 'Disk model:' | sed 's/Disk model: //g' )"
            if [[ ${disk_model} == ${target_disk_model} ]]; then
                target_disk="${disk}"
                break
            fi
        done
    fi
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
    
    echo "2) Please enter the disk to install the PVC base system to. This disk will be"
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
                target_interfaces_block="auto ${vlan_interface}\niface ${vlan_interface} inet ${target_netformat}\n\tvlan_raw_device ${target_interface}\n\taddress ${formatted_ipaddr}\n\tnetmask ${formatted_netmask}\n\tgateway ${target_defgw}"
                real_interface="${vlan_interface}"
            else
                ip link set ${target_interface} up >&2 || true
                ip address add ${target_ipaddr} dev ${target_interface} >&2 || true
                ip route add default via ${target_defgw} >&2 || true
                formatted_ipaddr="$( sipcalc ${target_ipaddr} | grep -v '(' | awk '/Host address/{ print $NF }' )"
                formatted_netmask="$( sipcalc ${target_ipaddr} | grep -v '(' | awk '/Network mask/{ print $NF }' )"
                target_interfaces_block="auto ${target_interface}\niface ${target_interface} inet ${target_netformat}\n\taddress ${formatted_ipaddr}\n\tnetmask ${formatted_netmask}\n\tgateway ${target_defgw}"
                real_interface="${target_interface}"
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
                target_interfaces_block="auto ${vlan_interface}\niface ${vlan_interface} inet ${target_netformat}\n\tvlan_raw_device${target_interface}"
                dhclient ${vlan_interface} >&2
                real_interface="${vlan_interface}"
            else
                target_interfaces_block="auto ${target_interface}\niface ${target_interface} inet ${target_netformat}"
                dhclient ${target_interface} >&2
                real_interface="${target_interface}"
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

set -o errexit
exec 1> >( tee -ia ${logfile} )
exec 2> >( tee -ia ${logfile} >/dev/null )

cleanup() {
    set +o errexit
    echo -n "Cleaning up... "
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
    echo
}
trap cleanup EXIT

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

echo -n "Disabing existing volume groups... "
vgchange -an >&2 || true
echo "done."

blockcheck() {
    # Use for testing only
    if [[ -n ${SKIP_BLOCKCHECK} ]]; then
        return
    fi

    # Determine optimal block size for zeroing
    exponent=16
    remainder=1
    while [[ ${remainder} -gt 0 && ${exponent} -gt 0 ]]; do
        exponent=$(( ${exponent} - 1 ))
        size=$(( 2**9 * 2 ** ${exponent} ))
        count=$(( ${blockdev_size_bytes} / ${size} ))
        remainder=$(( ${blockdev_size_bytes} - ${count} * ${size} ))
    done
    if [[ ${remainder} -gt 0 ]]; then
        echo "Failed to find a suitable block size for wiping... skipping."
        return
    fi

    echo -n "Checking if block device '${target_disk}' is already wiped... "
    if ! cmp --silent --bytes ${blockdev_size_bytes} /dev/zero ${target_disk}; then
        echo "false."
        echo -n "Wiping block device '${target_disk}' (${count} blocks of ${size} bytes)... "
        dd if=/dev/zero of=${target_disk} bs=${size} count=${count} oflag=direct &>/dev/null
    fi
    echo "done."
}
blockcheck

echo -n "Preparing block device '${target_disk}'... "
# New GPT, part 1 64MB ESP, part 2 960MB BOOT, part 3 inf LVM PV
echo -e "o\ny\nn\n1\n\n64M\nEF00\nn\n2\n\n960M\n8300\nn\n3\n\n\n8E00\nw\ny\n" | gdisk ${target_disk} >&2
echo "done."

echo -n "Rescanning disks... "
partprobe >&2 || true
echo "done."

echo -n "Creating LVM PV... "
yes | pvcreate -ffy ${target_disk}3 >&2
echo "done."

echo -n "Creating LVM VG named 'vgx'... "
yes | vgcreate vgx ${target_disk}3 >&2
echo "done."

echo -n "Creating root logical volume (${size_root_lv}GB)... "
yes | lvcreate -L ${size_root_lv}G -n root vgx >&2
echo "done."
echo -n "Creating filesystem on root logical volume (ext4)... "
yes | mkfs.ext4 /dev/vgx/root >&2
echo "done."

echo -n "Creating ceph logical volume (${size_ceph_lv}GB)... "
yes | lvcreate -L ${size_ceph_lv}G -n ceph vgx >&2
echo "done."
echo -n "Creating filesystem on ceph logical volume (ext4)... "
yes | mkfs.ext4 /dev/vgx/ceph >&2
echo "done."

echo -n "Creating zookeeper logical volume (${size_zookeeper_lv}GB)... "
yes | lvcreate -L ${size_zookeeper_lv}G -n zookeeper vgx >&2
echo "done."
echo -n "Creating filesystem on zookeeper logical volume (ext4)... "
yes | mkfs.ext4 /dev/vgx/zookeeper >&2
echo "done."

echo -n "Creating swap logical volume (${size_swap_lv}GB)... "
yes | lvcreate -L ${size_swap_lv}G -n swap vgx >&2
echo "done."
echo -n "Creating swap space on swap logical volume... "
yes | mkswap -f /dev/vgx/swap >&2
echo "done."

echo -n "Creating filesystem on boot partition (ext2)... "
yes | mkfs.ext2 ${target_disk}2 >&2
echo "done."

echo -n "Creating filesystem on ESP partition (vfat)... "
yes | mkdosfs -F32 ${target_disk}1 >&2
echo "done."

echo -n "Mounting disks on temporary target... "
target=$( mktemp -d )
mount /dev/vgx/root ${target} >&2
mkdir -p ${target}/boot >&2
chattr +i ${target}/boot >&2
mount ${target_disk}2 ${target}/boot >&2
mkdir -p ${target}/boot/efi >&2
chattr +i ${target}/boot/efi >&2
mount ${target_disk}1 ${target}/boot/efi >&2
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
debootstrap --include=${debpkglist} --exclude=${exclpkglist} ${debrelease} ${target}/ ${debmirror} >&2
echo "done."

echo -n "Adding non-free repository (firmware, etc.)... "
mkdir -p ${target}/etc/apt/sources.list.d/ >&2
echo "deb ${debmirror} ${debrelease} contrib non-free" | tee -a ${target}/etc/apt/sources.list >&2
chroot ${target} apt update >&2
echo "done."

echo -n "Installing supplemental packages... "
chroot ${target} apt install -y --no-install-recommends $( sed 's/,/ /g' <<<"${suppkglist}" ) >&2
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
echo "/dev/mapper/vgx-root / ext4 errors=remount-ro 0 1" | tee -a ${target}/etc/fstab >&2
echo "/dev/mapper/vgx-ceph /var/lib/ceph ext4 errors=remount-ro 0 2" | tee -a ${target}/etc/fstab >&2
echo "/dev/mapper/vgx-zookeeper /var/lib/zookeeper ext4 errors=remount-ro 0 2" | tee -a ${target}/etc/fstab >&2
echo "/dev/mapper/vgx-swap none swap sw 0 0" | tee -a ${target}/etc/fstab >&2
echo "${bypath_disk}-part2 /boot ext2 defaults 0 2" | tee -a ${target}/etc/fstab >&2
echo "${bypath_disk}-part1 /boot/efi vfat umask=0077 0 2" | tee -a ${target}/etc/fstab >&2
echo "tmpfs /tmp tmpfs defaults 0 0" | tee -a ${target}/etc/fstab >&2
echo "done."

echo -n "Adding interface segment... "
echo -e "${target_interfaces_block}" | tee -a ${target}/etc/network/interfaces >&2
echo "done."

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
            wget -O ${target}/var/home/${target_deploy_user}/.ssh/authorized_keys ${target_keys_path}
        ;;
        tftp)
            tftp -m binary "${seed_host}" -c get "${target_keys_path}" ${target}/var/home/${target_deploy_user}/.ssh/authorized_keys
        ;;
    esac
    chroot ${target} chmod 0600 /var/home/${target_deploy_user}/.ssh/authorized_keys
    chroot ${target} chown -R ${target_deploy_user}:operator /var/home/${target_deploy_user}
else
    echo "${target_deploy_user}:${target_password}" | chroot ${target} chpasswd >&2
fi
echo "done."

echo -n "Setting NOPASSWD for sudo group... "
sed -i 's/^%sudo\tALL=(ALL:ALL) ALL/%sudo\tALL=(ALL:ALL) NOPASSWD: ALL/' ${target}/etc/sudoers
echo "done."

echo -n "Setting /etc/issue generator... "
mkdir -p ${target}/etc/network/if-up.d >&2
echo -e "#!/bin/sh
IP=\"\$( ip -4 addr show dev ${real_interface} | grep inet | awk '{ print \$2 }' | head -1 )\"
cat <<EOF >/etc/issue
Debian GNU/Linux 10 \\\\n \\\\l

Primary interface IP address: \$IP

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
chroot ${target} grub-install --force --target=${bios_target} ${target_disk} >&2
chroot ${target} grub-mkconfig -o /boot/grub/grub.cfg >&2
echo "done."

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
