#!/usr/bin/env bash

which sudo >&2 && SUDO="sudo" || SUDO=""

logfile="/tmp/pvc-install.log"
debrelease="buster"
debmirror="http://debian.mirror.rafal.ca/debian"
debpkglist="lvm2,parted,gdisk,grub-pg,linux-image-amd64,sudo,vim,gpg,gpg-agent,aptitude,openssh-server"

clear

titlestring_text="| Preparing to install a PVC node base system. |"
titlestring_len="$( wc -c <<<"${titlestring_text}" )"
for i in $( seq 2 ${titlestring_len} ); do echo -n "-"; done; echo
echo "${titlestring_text}"
for i in $( seq 2 ${titlestring_len} ); do echo -n "-"; done; echo
echo

echo "1) Please enter a fully-qualified hostname for the system."
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
    for disk in /dev/sd?; do
        gdisk_data="$( $SUDO gdisk -l ${disk} )"
        echo -n "${disk}"
        echo -n "\t$( grep "^Model:" <<<"${gdisk_data}" | awk '{ $1=""; print $0 }' )"
        echo -n "\t$( grep "^Disk ${disk}:" <<<"${gdisk_data}" | awk '{ $1=$2=""; print $0 }' )"
        echo
    done
)"

echo "2) Please enter the disk to install the PVC base system to. This disk will be"
echo "wiped, an LVM PV created on it, and the system installed to this LVM."
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
    echo
done

for interface in $( ip address | grep '^[0-9]' | grep 'enp\|ens\|wlp' | awk '{ print $2 }' | tr -d ':' ); do
    $SUDO ip link set ${interface} up
done
sleep 2
interfaces="$(
    ip address | grep '^[0-9]' | grep 'enp\|ens\|wlp' | awk '{ print $2"\t"$3 }' | tr -d ':'
)"
echo "3a) Please enter the primary network interface for external connectivity."
echo
echo "Available interfaces:"
echo
echo -e "$( sed 's/\(.*\)/  \1/' <<<"${interfaces[@]}" )"
while [[ -z ${target_interface} ]]; do
    echo
    echo -n "> "
    read target_interface
    if ! grep -qw "${target_interface}" <<<"${interfaces[@]}"; then
        echo
        echo "Please enter a valid interface."
        target_interface=""
        continue
    fi
    echo
done

echo "3b) Please enter the IP address, in CIDR format [X.X.X.X/YY], of the primary network interface."
echo "Leave blank for DHCP configuration of the interface on boot."
echo
echo -n "> "
read target_ipaddr
if [[ -n ${target_ipaddr} ]]; then
    target_netformat="static"
    echo
    echo "3c) Please enter the default gateway IP address of the primary"
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

echo "4) Please enter an HTTP URL containing a text list of SSH authorized keys to"
echo "fetch. These keys will be allowed access to the 'deploy' user via SSH."
echo "Leave blank to bypass this and use a password instead."
echo
echo -n "> "
read target_keys_url
if [[ -z ${target_keys_url} ]]; then
    echo
    echo "No SSH keys URL specified. Falling back to password configuration."
    echo
    echo "5) Please enter a password (hidden), twice, for the 'deploy' user."
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
fi
echo

titlestring_text="| Proceeding with installation of host '${target_hostname}' to disk '${target_disk}'. |"
titlestring_len="$( wc -c <<<"${titlestring_text}" )"
for i in $( seq 2 ${titlestring_len} ); do echo -n "-"; done; echo
echo "${titlestring_text}"
for i in $( seq 2 ${titlestring_len} ); do echo -n "-"; done; echo
echo

### Script begins ###
echo "LOGFILE: ${logfile}"
echo

set -o errexit
exec 1> >( tee -ia ${logfile} )
exec 2> >( tee -ia ${logfile} >/dev/null )

echo -n "Bringing up primary network interface in ${target_netformat} mode... "
case ${target_netformat} in
    'static')
        $SUDO ip link set ${target_interface} up >&2
        $SUDO ip address add ${target_ipaddr} dev ${target_interface} >&2
        $SUDO ip route add default via ${target_defgw} >&2
        formatted_ipaddr="$( sipcalc ${target_ipaddr} | grep -v '(' | awk '/Host address/{ print $NF }' )"
        formatted_netmask="$( sipcalc ${target_ipaddr} | grep -v '(' | awk '/Network mask/{ print $NF }' )"
        target_interfaces_block="auto ${target_interface}\niface ${target_interface} inet ${target_netformat}\n\taddress ${formatted_ipaddr}\n\tnetmask ${formatted_netmask}\n\tgateway ${target_defgw}"
    ;;
    'dhcp')
        $SUDO dhclient ${target_interface} >&2
        target_interfaces_block="auto ${target_interface}\niface ${target_interface} inet ${target_netformat}"
    ;;
esac
echo "done."

echo -n "Zeroing block device... "
$SUDO dd if=/dev/zero of=${target_disk} bs=4M >&2 || true
echo "done."

echo -n "Preparing block device... "
# New GPT, part 1 64MB ESP, part 2 960MB BOOT, part 3 inf LVM PV
echo -e "o\ny\nn\n1\n\n64M\nEF00\nn\n2\n\n960M\n8300\nn\n3\n\n\n8E00\nw\ny\n" | $SUDO gdisk ${target_disk} >&2
echo "done."

echo -n "Rescanning disks... "
$SUDO partprobe >&2
echo "done."

echo -n "Creating LVM PV... "
$SUDO pvcreate -ff ${target_disk}3 >&2
echo "done."

echo -n "Creating LVM VG named 'vgx'... "
$SUDO vgcreate vgx ${target_disk}3 >&2
echo "done."

echo -n "Creating root logical volume (16GB, ext4)... "
$SUDO lvcreate -L 16G -n root vgx >&2
$SUDO mkfs.ext4 -f /dev/vgx/root >&2
echo "done."

echo -n "Creating ceph logical volume (16GB, ext4)... "
$SUDO lvcreate -L 16G -n ceph vgx >&2
$SUDO mkfs.ext4 -f /dev/vgx/ceph >&2
echo "done."

echo -n "Creating swap logical volume (8GB)... "
$SUDO lvcreate -L 8G -n swap vgx >&2
$SUDO mkswap -f /dev/vgx/swap >&2
echo "done."

echo -n "Mounting disks on temporary target... "
target=$( mktemp -d )
$SUDO mount /dev/vgx/root ${target} >&2
$SUDO mkdir -p ${target}/boot >&2
$SUDO mount ${target_disk}2 ${target}/boot >&2
$SUDO mkdir -p ${target}/boot/efi >&2
$SUDO mount ${target_disk}1 ${target}/boot/efi >&2
$SUDO mkdir -p ${target}/var/lib/ceph >&2
$SUDO mount /dev/vgx/ceph ${target}/var/lib/ceph >&2
echo "done."

echo -n "Running debootstrap install... "
$SUDO debootstrap --include=${debpkglist} ${debrelease} ${target}/ ${debmirror} >&2
echo "done."

# Determine the bypath name of the specified system disk
for disk in /dev/disk/by-path/*; do
    bypathlink="$( readlink ${disk} | awk -F'/' '{ print $NF }' )"
    enteredname="$( awk -F'/' '{ print $NF }' <<<"${target_disk}" )"
    if [[ ${bypathlink} == ${enteredname} ]]; then
        bypath_disk="${disk}"
    fi
done

echo -n "Adding fstab entries... "
echo "/dev/mapper/vgx-root / ext4 errors=remount-ro 0 1" | $SUDO tee -a ${target}/etc/fstab >&2
echo "/dev/mapper/vgx-ceph /var/lib/ceph ext4 errors=remount-ro 0 2" | $SUDO tee -a ${target}/etc/fstab >&2
echo "/dev/mapper/vgx-swap nonde swap sw 0 0" | $SUDO tee -a ${target}/etc/fstab >&2
echo "${bypath_disk}2 /boot ext2 defaults 0 2" | $SUDO tee -a ${target}/etc/fstab >&2
echo "${bypath_disk}1 /boot/efi vfat umask=0077 0 2" | $SUDO tee -a ${target}/etc/fstab >&2
echo "done."

echo -n "Adding interface segment... "
echo -e "${target_interfaces_block}" | $SUDO tee -a ${target}/etc/network/interfaces >&2
echo "done."

echo -n "Adding 'deploy' user... "
$SUDO mv ${target}/home ${target}/var/home >&2
$SUDO chroot ${target} useradd -u 200 -d /var/home/deploy -m -s /bin/bash -g operator -G sudo deploy >&2
$SUDO chroot ${target} mkdir -p /var/home/deploy/.ssh
if [[ -n ${target_keys_url} ]]; then
$SUDO wget -O ${target}/var/home/deploy/.ssh/authorized_keys ${target_keys_url}
else
echo "${target_password}" | $SUDO chroot ${target} passwd --stdin deploy >&2
fi

echo -n "Setting hostname... "
echo "${target_hostname}" | sudo tee ${target}/etc/hostname >&2
echo "done."

echo -n "Installing GRUB bootloader... "
$SUDO mount --bind /dev ${target}/dev >&2
$SUDO mount --bind /dev/pts ${target}/dev/pts >&2
$SUDO mount --bind /proc ${target}/proc >&2
$SUDO mount --bind /sys ${target}/sys >&2
$SUDO chroot ${target} grub-install --target=x86_64-efi ${target_disk} >&2
$SUDO chroot ${target} update-grub >&2
echo "done."

echo -n "Cleaning up... "
$SUDO umount ${target}/sys >&2
$SUDO umount ${target}/proc >&2
$SUDO umount ${target}/dev/pts >&2
$SUDO umount ${target}/dev >&2
$SUDO umount ${target}/var/lib/ceph >&2
$SUDO umount ${target}/boot/efi >&2
$SUDO umount ${target}/boot >&2
$SUDO umount ${target} >&2
echo "done."
echo

titlestring_text="| PVC node installation finished. Press <Enter> to reboot into the installed system. |"
titlestring_len="$( wc -c <<<"${titlestring_text}" )"
for i in $( seq 2 ${titlestring_len} ); do echo -n "-"; done; echo
echo "${titlestring_text}"
echo "Verify the system is configured as you would expect, add any additional interfaces"
echo "to the /etc/network/interfaces file, and then run the PVC Ansible role in"
echo "'bootstrap=yes' mode to continue deploying the PVC system."
for i in $( seq 2 ${titlestring_len} ); do echo -n "-"; done; echo
echo
read

$SUDO reboot
