#!/usr/bin/env bash

if [[ $( whoami ) != "root" ]]; then
    echo "This script is designed to run as root within the installer only!"
    exit 1
fi

logfile="/tmp/pvc-install.log"
debrelease="buster"
debmirror="http://debian.mirror.rafal.ca/debian"
debpkglist="lvm2,parted,gdisk,grub-pc,grub-efi-amd64,linux-image-amd64,sudo,vim,gpg,gpg-agent,aptitude,openssh-server,vlan,ifenslave,python,python2,python3,ca-certificates,ntp"

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
        disk_data="$( fdisk -l ${disk} 2>/dev/null )"
        echo -n "${disk}"
        echo -en "\t$( grep "^Disk model:" <<<"${disk_data}" | awk '{ $1=""; print $0 }' )"
        echo -en "  $( grep "^Disk ${disk}:" <<<"${disk_data}" | awk '{ $1=""; $2="size:"; print $0 }' )"
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
    ip link set ${interface} up
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

echo "3b) Please enter the IP address, in CIDR format [X.X.X.X/YY], of the primary"
echo "network interface. Leave blank for DHCP configuration of the interface on boot."
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
else
    while ! wget -O /dev/null ${target_keys_url} &>/dev/null; do
        echo
        echo "Please enter a valid SSH keys URL."
        echo
        echo -n "> "
        read target_keys_url
    done
fi
echo

titlestring_text="| Proceeding with installation of host '${target_hostname}'. |"
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

cleanup() {
    set +o errexit
    echo -n "Cleaning up... "
    umount ${target}/run >&2
    umount ${target}/sys >&2
    umount ${target}/proc >&2
    umount ${target}/dev/pts >&2
    umount ${target}/dev >&2
    umount ${target}/var/lib/ceph >&2
    umount ${target}/boot/efi >&2
    umount ${target}/boot >&2
    umount ${target} >&2
    vgchange -an >&2
    rmdir ${target} >&2
    echo "done."
    echo
}
trap cleanup EXIT

echo -n "Bringing up primary network interface in ${target_netformat} mode... "
case ${target_netformat} in
    'static')
        ip link set ${target_interface} up >&2 || true
        ip address add ${target_ipaddr} dev ${target_interface} >&2 || true
        ip route add default via ${target_defgw} >&2 || true
        formatted_ipaddr="$( sipcalc ${target_ipaddr} | grep -v '(' | awk '/Host address/{ print $NF }' )"
        formatted_netmask="$( sipcalc ${target_ipaddr} | grep -v '(' | awk '/Network mask/{ print $NF }' )"
        target_interfaces_block="auto ${target_interface}\niface ${target_interface} inet ${target_netformat}\n\taddress ${formatted_ipaddr}\n\tnetmask ${formatted_netmask}\n\tgateway ${target_defgw}"
    ;;
    'dhcp')
        dhclient ${target_interface} >&2
        target_interfaces_block="auto ${target_interface}\niface ${target_interface} inet ${target_netformat}"
    ;;
esac
echo "done."

echo -n "Disabing existing volume groups... "
vgchange -an >&2 || true
echo "done."

echo -n "Zeroing block device '${target_disk}'... "
dd if=/dev/zero of=${target_disk} bs=4M >&2 || true
echo "done."

echo -n "Preparing block device '${target_disk}'... "
# New GPT, part 1 64MB ESP, part 2 960MB BOOT, part 3 inf LVM PV
echo -e "o\ny\nn\n1\n\n64M\nEF00\nn\n2\n\n960M\n8300\nn\n3\n\n\n8E00\nw\ny\n" | gdisk ${target_disk} >&2
echo "done."

echo -n "Rescanning disks... "
partprobe >&2
echo "done."

echo -n "Creating LVM PV... "
yes | pvcreate -ffy ${target_disk}3 >&2
echo "done."

echo -n "Creating LVM VG named 'vgx'... "
yes | vgcreate vgx ${target_disk}3 >&2
echo "done."

echo -n "Creating root logical volume (16GB)... "
lvcreate -L 16G -n root vgx >&2
echo "done."
echo -n "Creating filesystem on root logical volume (ext4)... "
yes | mkfs.ext4 /dev/vgx/root >&2
echo "done."

echo -n "Creating ceph logical volume (16GB, ext4)... "
yes | lvcreate -L 16G -n ceph vgx >&2
echo "done."
echo -n "Creating filesystem on ceph logical volume (ext4)... "
mkfs.ext4 /dev/vgx/ceph >&2
echo "done."

echo -n "Creating swap logical volume (8GB)... "
lvcreate -L 8G -n swap vgx >&2
echo "done."
echo -n "Creating swap on swap logical volume... "
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
mount ${target_disk}2 ${target}/boot >&2
mkdir -p ${target}/boot/efi >&2
mount ${target_disk}1 ${target}/boot/efi >&2
mkdir -p ${target}/var/lib/ceph >&2
mount /dev/vgx/ceph ${target}/var/lib/ceph >&2
echo "done."

echo -n "Running debootstrap install... "
debootstrap --include=${debpkglist} ${debrelease} ${target}/ ${debmirror} >&2
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
echo "/dev/mapper/vgx-root / ext4 errors=remount-ro 0 1" | tee -a ${target}/etc/fstab >&2
echo "/dev/mapper/vgx-ceph /var/lib/ceph ext4 errors=remount-ro 0 2" | tee -a ${target}/etc/fstab >&2
echo "/dev/mapper/vgx-swap nonde swap sw 0 0" | tee -a ${target}/etc/fstab >&2
echo "${bypath_disk}-part2 /boot ext2 defaults 0 2" | tee -a ${target}/etc/fstab >&2
echo "${bypath_disk}-part1 /boot/efi vfat umask=0077 0 2" | tee -a ${target}/etc/fstab >&2
echo "done."

echo -n "Adding interface segment... "
echo -e "${target_interfaces_block}" | tee -a ${target}/etc/network/interfaces >&2
echo "done."

echo -n "Adding 'deploy' user... "
mv ${target}/home ${target}/var/home >&2
chroot ${target} useradd -u 200 -d /var/home/deploy -m -s /bin/bash -g operator -G sudo deploy >&2
chroot ${target} mkdir -p /var/home/deploy/.ssh
if [[ -n ${target_keys_url} ]]; then
wget -O ${target}/var/home/deploy/.ssh/authorized_keys ${target_keys_url}
else
echo "${target_password}" | chroot ${target} passwd --stdin deploy >&2
fi
echo "done."

echo -n "Setting NOPASSWD for sudo group... "
sed -i 's/^%sudo\tALL=(ALL:ALL) ALL/%sudo\tALL=(ALL:ALL) NOPASSWD: ALL/' ${target}/etc/sudoers
echo "done."

echo -n "Setting /etc/issue generator... "
mkdir -p ${target}/etc/network/if-up.d >&2
echo -e "#!/bin/sh
IP=\"\$( ip -4 addr show dev ${target_interface} | grep inet | awk '{ print \$2 }' | head -1 )\"
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
chroot ${target} grub-install --target=${bios_target} ${target_disk} >&2
chroot ${target} grub-mkconfig -o /boot/grub/grub.cfg >&2
echo "done."

cleanup

titlestring_text="| PVC node installation finished. Next steps:                                       |"
titlestring_len="$( wc -c <<<"${titlestring_text}" )"
for i in $( seq 2 86 ); do echo -n "-"; done; echo
echo "${titlestring_text}"
echo "| 1. Press <enter> to reboot the system.                                            |"
echo "| 2. Boot the PVC base hypervisor and verify SSH access (IP shown on login screen). |"
echo "| 3. Configure /etc/network/interfaces to the cluster specifications. Remember to   |"
echo "|    remove the static or DHCP specification of the primary interface; the daemon   |"
echo "|    manages this automatically.                                                    |"
echo "| 4. Proceed with system deployment via PVC Ansible.                                |"
for i in $( seq 2 86 ); do echo -n "-"; done; echo
echo
read

reboot
