#!/usr/bin/env bash

# Generate a PVC autoinstaller ISO via live-build

# This ISO makes a number of assumptions about the system and asks
# minimal questions in order to streamline the install process versus
# using a standard Debian intaller ISO. The end system is suitable
# for immediate bootstrapping with the PVC Ansible roles.

fail() {
    echo "$@"
    exit 1
}

which lb &>/dev/null || fail "This script requires live-build"
sudo -n true &>/dev/null || fail "The user running this script must have sudo privileges."

isofilename="pvc-installer_$(date +%Y-%m-%d).iso"
deployusername="deploy"

show_help() {
    echo -e "PVC install ISO generator"
    echo
    echo -e " Generates a mostly-automated installer ISO for a PVC node base system via lb."
    echo
    echo -e "Usage: $0 [-h] [-o <output_filename>] [-u username] [-a]"
    echo
    echo -e "   -h: Display this help message."
    echo -e "   -o: Create the ISO as <output_filename> instead of the default."
    echo -e "   -u: Change 'deploy' user to a new username."
    echo -e "   -a: Preserve live-build artifacts."
    echo -e "   -k: Preserve live-build config."
}

while [ $# -gt 0 ]; do
    case "${1}" in
        -h|\?)
            show_help
            exit 0
        ;;
        -o)
            isofilename="${2}"
            shift 2
        ;;
        -u)
            deployusername="${2}"
            shift 2
        ;;
        -a)
            preserve_artifacts='y'
            shift
        ;;
        -k)
            preserve_livebuild='y'
            shift
        ;;
        *)
            echo "Invalid option: ${1}"
            echo
            show_help
            exit 1
        ;;
    esac
done

PACKAGE_LIST_MAIN="live-tools linux-image-amd64 mdadm lvm2 parted gdisk debootstrap grub-pc-bin grub-efi-amd64 sipcalc vim ca-certificates vlan tftp-hpa"
PACKAGE_LIST_NONFREE="firmware-bnx2 firmware-bnx2x"

mkdir -p artifacts/lb
pushd artifacts/lb &>/dev/null

echo "Pre-cleaning live-build environment..."
sudo lb clean

echo "Initializing config..."
# Initialize the live-build config
lb config --distribution buster --architectures amd64 --archive-areas "main contrib non-free" --apt-recommends false

# Configure the "standard" live task (no GUI)
echo "live-task-standard" > config/package-lists/desktop.list.chroot

# Add additional live packages
echo ${PACKAGE_LIST_MAIN} > config/package-lists/installer.list.chroot
echo ${PACKAGE_LIST_NONFREE} > config/package-lists/nonfree.list.chroot

# Add root password hook
mkdir -p config/includes.chroot/lib/live/config/
cat <<EOF > config/includes.chroot/lib/live/config/2000-remove-root-pw
#!/bin/sh
echo "I: remove root password"
passwd --delete root
EOF
chmod +x config/includes.chroot/lib/live/config/2000-remove-root-pw

# Set root bashrc
mkdir -p config/includes.chroot/root
echo "/install.sh" > config/includes.chroot/root/.bashrc

# Set hostname and resolv.conf
mkdir -p config/includes.chroot/etc
echo "pvc-live-installer" > config/includes.chroot/etc/hostname
echo "nameserver 8.8.8.8" > config/includes.chroot/etc/resolv.conf

# Set single vty
mkdir -p config/includes.chroot/etc/systemd/
cat <<EOF > config/includes.chroot/etc/systemd/logind.conf
[Login]
NAutoVTs=2
EOF

mkdir -p config/includes.chroot/etc/systemd/system/getty@.service.d
cat <<EOF > config/includes.chroot/etc/systemd/system/getty@.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\\u' --autologin root --noclear %I \$TERM
EOF

mkdir -p config/includes.chroot/etc/systemd/system/serial-getty@.service.d
cat <<EOF > config/includes.chroot/etc/systemd/system/serial-getty@.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\\u' --autologin root --noclear --keep-baud 115200,38400,9600 %I \$TERM
EOF

# Install GRUB config, theme, and splash
mkdir -p config/includes.chroot/boot/grub
cp ../../grub.cfg config/includes.chroot/boot/grub/grub.cfg
cp ../../theme.txt config/includes.chroot/boot/grub/theme.txt
cp ../../splash.png config/includes.chroot/splash.png

# Install install.sh script
cp ../../install.sh config/includes.chroot/install.sh
chmod +x config/includes.chroot/install.sh

# Customize install.sh script
sed -i "s/XXDATEXX/$(date)/g" config/includes.chroot/install.sh
sed -i "s/XXDEPLOYUSERXX/${deployusername}/g" config/includes.chroot/install.sh

# Build the live image
echo "Building live image..."
sudo lb build

# Move the ISO image out
cp live-image-amd64.hybrid.iso ../../${isofilename}

# Clean up the artifacts
if [[ -z ${preserve_artifacts} ]]; then
    echo "Cleaning live-build environment..."
    sudo lb clean
fi

popd &>/dev/null

# Clean up the config
if [[ -z ${preserve_livebuild} ]]; then
    echo -n "Removing artifacts... "
    sudo rm -rf artifacts/lb
    echo "done."
fi

echo
echo "Build completed. ISO file: ${isofilename}"
