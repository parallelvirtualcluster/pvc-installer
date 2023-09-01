#!/usr/bin/env bash

# Generate a PVC autoinstaller ISO

# This ISO makes a number of assumptions about the system and asks
# minimal questions in order to streamline the install process versus
# using a standard Debian intaller ISO. The end system is suitable
# for immediate bootstrapping with the PVC Ansible roles.

fail() {
    echo "$@"
    exit 1
}

fail=""
which debootstrap &>/dev/null || fail="y"
which mksquashfs &>/dev/null || fail="y"
which xorriso &>/dev/null || fail="y"
test -f /usr/lib/ISOLINUX/isohdpfx.bin &>/dev/null || fail="y"
if [[ -n ${fail} ]]; then
    fail "This script requires debootstrap, xorriso, squashfs-tools, and isolinux"
fi

isofilename="pvc-installer_$(date +%Y-%m-%d).iso"
deployusername="deploy"

show_help() {
    echo -e "PVC install ISO generator"
    echo
    echo -e " Generates a mostly-automated installer ISO for a PVC node base system. The ISO"
    echo -e " boots, then runs 'install.sh' to perform the installation to a target server."
    echo -e " This script prompts for a few questions on startup to configure the system, then"
    echo -e " performs the remaining installation to PVC node specifications unattended,"
    echo -e " including configuring networking on the selected interface, wiping the selected"
    echo -e " disk, partitioning, installing the base OS, and performing some initial"
    echo -e " configuration to allow the PVC Ansible role to take over after completion."
    echo
    echo -e "Usage: $0 [-h] [-o <output_filename>] [-s <liveiso_source_url>] [-a] [-u username]"
    echo
    echo -e "   -h: Display this help message."
    echo -e "   -o: Create the ISO as <output_filename> instead of the default."
    echo -e "   -s: Obtain the source Debian Live ISO from <liveiso_source_url> instead of"
    echo -e "       the default."
    echo -e "   -a: Use cached squashfs artifact during rebuild (cached ISO and debootstrap"
    echo -e "       artifacts are always used)."
    echo -e "   -u: Change 'deploy' user to a new username."
}

while getopts "h?o:s:au:" opt; do
    case "$opt" in
        h|\?)
            show_help
            exit 0
        ;;
        o)
            isofilename=$OPTARG
        ;;
        s)
            srcliveisourl=$OPTARG
        ;;
        a)
            usecachedsquashfs='y'
        ;;
        u)
            deployusername=$OPTARG
        ;;
    esac
done

srcliveisopath="https://cdimage.debian.org/mirror/cdimage/release/current-live/amd64/iso-hybrid"
srcliveisofilename="$( wget -O- ${srcliveisopath}/ | grep 'debian-live-.*-amd64-standard.iso' | awk -F '"' '{ print $6 }' )"
srcliveisourl="${srcliveisopath}/${srcliveisofilename}"
srcliveisofile="$( basename ${srcliveisourl} )"

tempdir=$( mktemp -d )

cleanup() {
    echo -n "Cleaning up... "
    sudo rm -rf ${tempdir} &>/dev/null
    echo "done."
    echo
}

fail() {
    echo $@
    cleanup
    exit 1
}

prepare_iso() {
    echo -n "Creating temporary directories... "
    if [[ ! -d artifacts ]]; then
        mkdir artifacts &>/dev/null || fail "Error creating artifacts directory."
    fi
    mkdir ${tempdir}/rootfs/ ${tempdir}/installer/ &>/dev/null || fail "Error creating temporary directories."
    echo "done."

    if [[ ! -f artifacts/${srcliveisofile} ]]; then
        echo -n "Downloading Debian Live ISO... "
        wget -O artifacts/${srcliveisofile} ${srcliveisourl} &>/dev/null || { rm -f artifacts/${srcliveisofile}; fail "Error downloading source ISO."; }
        echo "done."
    fi

    echo -n "Extracting Debian Live ISO files... "
    iso_tempdir=$( mktemp -d )
    sudo mount artifacts/${srcliveisofile} ${iso_tempdir} &>/dev/null || fail "Error mounting Live ISO file."
    sudo rsync -a --exclude live/filesystem.squashfs --exclude isolinux/menu.cfg --exclude isolinux/stdmenu.cfg ${iso_tempdir}/ ${tempdir}/installer/ &>/dev/null || fail "Error extracting Live ISO files."
    sudo umount ${iso_tempdir} &>/dev/null || fail "Error unmounting Live ISO file."
    rmdir ${iso_tempdir} &>/dev/null
    echo "done."
}

prepare_rootfs() {
    echo -n "Preparing Debian live installation via debootstrap... "
    SQUASHFS_PKGLIST="mdadm,lvm2,parted,gdisk,debootstrap,grub-pc,grub-efi-amd64,linux-image-amd64,sipcalc,live-boot,dosfstools,vim,ca-certificates,vlan"
    if [[ ! -d artifacts/debootstrap ]]; then
        sudo mkdir -p artifacts/debootstrap/var/cache/apt/archives &>/dev/null
        clean_me="y"
        sudo mount --bind /var/cache/apt/archives artifacts/debootstrap/var/cache/apt/archives &>/dev/null && clean_me=""
        sudo /usr/sbin/debootstrap \
            --include=${SQUASHFS_PKGLIST} \
            buster \
            artifacts/debootstrap/ \
            http://ftp.ca.debian.org/debian &>debootstrap.log || fail "Error performing debootstrap."
        # Grab some additional files in non-free
        sudo wget http://ftp.ca.debian.org/debian/pool/non-free/f/firmware-nonfree/firmware-bnx2_20190114-2_all.deb -O artifacts/debootstrap/var/cache/apt/archives/firmware-bnx2_20190114-2_all.deb
        sudo chroot artifacts/debootstrap/ dpkg -i /var/cache/apt/archives/firmware-bnx2_20190114-2_all.deb || fail "Error installing supplemental package firmware-bnx2"
        sudo wget http://ftp.ca.debian.org/debian/pool/non-free/f/firmware-nonfree/firmware-bnx2x_20190114-2_all.deb -O artifacts/debootstrap/var/cache/apt/archives/firmware-bnx2x_20190114-2_all.deb
        sudo chroot artifacts/debootstrap/ dpkg -i /var/cache/apt/archives/firmware-bnx2x_20190114-2_all.deb || fail "Error installing supplemental package firmware-bnx2x"
        if [[ -n ${clean_me} ]]; then
            sudo chroot artifacts/debootstrap/ apt clean &>/dev/null || fail "Error cleaning apt cache in debootstrap."
        else
            sudo umount artifacts/debootstrap/var/cache/apt/archives &>/dev/null
        fi
    fi
    sudo rsync -au artifacts/debootstrap/ ${tempdir}/rootfs/ &>/dev/null || fail "Error copying debootstrap to tempdir."
    echo "done."
   
    echo -n "Configuring Debian live installation... "
    sudo cp -a artifacts/debootstrap/boot/vmlinuz* ${tempdir}/installer/live/vmlinuz &>/dev/null || fail "Error copying kernel."
    sudo cp -a artifacts/debootstrap/boot/initrd.img* ${tempdir}/installer/live/initrd.img &>/dev/null || fail "Error copying initrd."
    sudo cp ${tempdir}/rootfs/lib/systemd/system/getty\@.service ${tempdir}/rootfs/etc/systemd/system/getty@tty1.service &>/dev/null || fail "Error copying getty override to tempdir."
    sudo sed -i 's|/sbin/agetty|/sbin/agetty --autologin root|g' \
         ${tempdir}/rootfs/etc/systemd/system/getty@tty1.service &>/dev/null || fail "Error setting autologin in getty override."
    sudo tee ${tempdir}/rootfs/etc/hostname <<<"pvc-node-installer" &>/dev/null || fail "Error setting hostname."
    sudo tee ${tempdir}/rootfs/etc/resolv.conf <<<"nameserver 8.8.8.8" &>/dev/null || fail "Error setting resolv.conf"
    sudo tee -a ${tempdir}/rootfs/root/.bashrc <<<"/install.sh" &>/dev/null || fail "Error setting bashrc."
    sudo chroot ${tempdir}/rootfs/ /usr/bin/passwd -d root &>/dev/null || fail "Error disabling root password."
    sudo cp install.sh ${tempdir}/rootfs/ &>/dev/null || fail "Error copying install.sh to tempdir."
    sudo sed -i "s/XXISOXX/${isofilename}/g" ${tempdir}/rootfs/install.sh &>/dev/null || fail "Error editing install.sh script."
    sudo sed -i "s/XXDEPLOYUSERXX/${deployusername}/g" ${tempdir}/rootfs/install.sh &>/dev/null || fail "Error editing install.sh script."
    echo "done."
    
    echo -n "Generating squashfs image of live installation... "
    if [[ ! -f artifacts/filesystem.squashfs || -z ${usecachedsquashfs} ]]; then
        if [[ -f artifacts/filesystem.squashfs ]]; then
            rm -f artifacts/filesystem.squashfs &>/dev/null
        fi
        sudo nice mksquashfs ${tempdir}/rootfs/ artifacts/filesystem.squashfs -e boot &>/dev/null || fail "Error generating squashfs."
    fi
    sudo rsync -a artifacts/filesystem.squashfs ${tempdir}/installer/live/filesystem.squashfs &>/dev/null || fail "Error copying squashfs to tempdir."
    echo "done."
}

build_iso() {
    echo -n "Copying live boot configurations... "
    sudo cp -a grub.cfg ${tempdir}/installer/boot/grub/grub.cfg &>/dev/null || fail "Error copying grub.cfg file."
    sudo cp -a theme.txt ${tempdir}/installer/boot/grub/theme.txt &>/dev/null || fail "Error copying theme.txt file."
    sudo cp -a isolinux.cfg ${tempdir}/installer/isolinux/isolinux.cfg &>/dev/null || fail "Error copying isolinux.cfg file."
    sudo cp -a splash.png ${tempdir}/installer/splash.png &>/dev/null || fail "Error copying splash.png file."
    echo "done."

    echo -n "Creating LiveCD ISO... "
    pushd ${tempdir}/installer &>/dev/null
    xorriso \
        -as mkisofs \
        -iso-level 3 \
        -o ../${isofilename} \
        -full-iso9660-filenames \
        -volid "PVC_NODE_INSTALLER" \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -eltorito-boot \
            isolinux/isolinux.bin \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --eltorito-catalog isolinux/isolinux.cat \
        -eltorito-alt-boot \
            -e boot/grub/efi.img \
            -no-emul-boot \
            -isohybrid-gpt-basdat \
        -append_partition 2 0xef boot/grub/efi.img \
       . &>/dev/null || fail "Error creating ISO file."
    popd &>/dev/null
    echo "done."

    echo -n "Moving generated ISO to './${isofilename}'... "
    mv ${tempdir}/${isofilename} ${isofilename} &>/dev/null || fail "Error moving ISO file."
    echo "done."
}

prepare_iso
prepare_rootfs
build_iso
cleanup

echo "PVC Live Installer ISO generation complete."
