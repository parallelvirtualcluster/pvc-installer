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

mkdir -p artifacts/lb
pushd artifacts/lb &>/dev/null

echo "Pre-cleaning live-build environment..."
sudo lb clean
echo

echo "Initializing config..."
# Initialize the live-build config
lb config --distribution buster --architectures amd64 --archive-areas "main contrib non-free" --apt-recommends false || fail "Failed to initialize live-build config"
echo

# Configure the package lists
echo -n "Copying package lists... "
cp ../../templates/installer.list.chroot config/package-lists/installer.list.chroot || fail "Failed to copy critical template file"
cp ../../templates/firmware.list.chroot config/package-lists/firmware.list.chroot || fail "Failed to copy critical template file"
echo "done."

# Add root password hook
echo -n "Copying live-boot templates... "
mkdir -p config/includes.chroot/lib/live/boot/
cp ../../templates/2000-remove-root-pw.sh config/includes.chroot/lib/live/boot/2000-remove-root-pw.sh || fail "Failed to copy critical template file"
chmod +x config/includes.chroot/lib/live/boot/2000-remove-root-pw.sh || fail "Failed to copy critical template file"
cp ../../templates/9990-initramfs-tools.sh config/includes.chroot/lib/live/boot/9990-initramfs-tools.sh || fail "Failed to copy critical template file"
chmod +x config/includes.chroot/lib/live/boot/9990-initramfs-tools.sh || fail "Failed to copy critical template file"
echo "done."

# Set root bashrc
echo -n "Copying root bashrc template... "
mkdir -p config/includes.chroot/root
cp ../../templates/root.bashrc config/includes.chroot/root/.bashrc || fail "Failed to copy critical template file"
echo "done."

# Set hostname and resolv.conf
echo -n "Copying networking templates... "
mkdir -p config/includes.chroot/etc
cp ../../templates/hostname config/includes.chroot/etc/hostname || fail "Failed to copy critical template file"
cp ../../templates/resolv.conf config/includes.chroot/etc/resolv.conf || fail "Failed to copy critical template file"
echo "done."

# Set single vty and autologin
echo -n "Copying getty templates... "
mkdir -p config/includes.chroot/etc/systemd/
cp ../../templates/logind.conf config/includes.chroot/etc/systemd/logind.conf || fail "Failed to copy critical template file"
mkdir -p config/includes.chroot/etc/systemd/system/getty@.service.d
cp ../../templates/getty-override.conf  config/includes.chroot/etc/systemd/system/getty@.service.d/override.conf || fail "Failed to copy critical template file"
mkdir -p config/includes.chroot/etc/systemd/system/serial-getty@.service.d
cp ../../templates/serial-getty-override.conf config/includes.chroot/etc/systemd/system/serial-getty@.service.d/override.conf || fail "Failed to copy critical template file"
echo "done."

# Install GRUB config, theme, and splash
echo -n "Copying GRUB templates... "
mkdir -p config/includes.chroot/boot/grub
cp ../../templates/grub.cfg config/includes.chroot/boot/grub/grub.cfg || fail "Failed to copy critical template file"
cp ../../templates/theme.txt config/includes.chroot/boot/grub/theme.txt || fail "Failed to copy critical template file"
cp ../../templates/splash.png config/includes.chroot/splash.png || fail "Failed to copy critical template file"
echo "done."

# Install install.sh script
echo -n "Copying PVC node installer script template... "
cp ../../templates/install.sh config/includes.chroot/install.sh || fail "Failed to copy critical template file"
chmod +x config/includes.chroot/install.sh
echo "done."

# Customize install.sh script
echo -n "Customizing PVC node installer script... "
sed -i "s/XXDATEXX/$(date)/g" config/includes.chroot/install.sh
sed -i "s/XXDEPLOYUSERXX/${deployusername}/g" config/includes.chroot/install.sh
echo "done."
echo

# Build the live image
echo "Building live image..."
sudo lb build || fail "Failed to build live image"
echo

# Move the ISO image out
echo -n "Copying generated ISO to repository root... "
cp live-image-amd64.hybrid.iso ../../${isofilename}
echo "done."

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
