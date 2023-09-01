#!/bin/bash

# Generate a PVC autoinstaller ISO

# This ISO makes a number of assumptions about the system and asks
# minimal questions in order to streamline the install process versus
# using a standard Debian intaller ISO. The end system is suitable
# for immediate bootstrapping with the PVC Ansible roles.

which debootstrap &>/dev/null || fail "This script requires debootstrap."
which mksquashfs &>/dev/null || fail "This script requires squashfs."
which xorriso &>/dev/null || fail "This script requires xorriso."

isofilename="pvc-installer.iso"
srcliveisourl="https://cdimage.debian.org/mirror/cdimage/buster_di_rc1-live/amd64/iso-hybrid/debian-live-buster-DI-rc1-amd64-standard.iso"

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
    echo -e "Usage: $0 [-h] [-o <output_filename>] [-s <liveiso_source_url>]"
    echo
    echo -e "   -h: Display this help message."
    echo -e "   -o: Create the ISO as <output_filename> instead of the default."
    echo -e "   -s: Obtain the source Debian Live ISO from <liveiso_source_url> instead of"
    echo -e "       the default."
    echo -e "   -i: Ignore cached squashfs artifact during rebuild (ISO and debootstrap"
    echo -e "       artifacts are never ignored)."
}

while getopts "h?o:s:i" opt; do
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
        i)
            ignorecachedsquashfs='y'
        ;;
    esac
done

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
        wget -O artifacts/${srcliveisofile} ${srcliveisourl} &>/dev/null || fail "Error downloading source ISO."
        echo "done."
    fi

    echo -n "Extracting Debian Live ISO files... "
    iso_tempdir=$( mktemp -d )
    sudo mount artifacts/${srcliveisofile} ${iso_tempdir} &>/dev/null || fail "Error mounting Live ISO file."
	sudo rsync -au --exclude live/filesystem.squashfs ${iso_tempdir}/ ${tempdir}/installer/ &>/dev/null || fail "Error extracting Live ISO files."
    sudo umount ${iso_tempdir} &>/dev/null || fail "Error unmounting Live ISO file."
    rmdir ${iso_tempdir} &>/dev/null
    echo "done."
}

prepare_rootfs() {
    echo -n "Preparing Debian live installation via debootstrap... "
    SQUASHFS_PKGLIST="mdadm,lvm2,parted,gdisk,debootstrap,grub-pc,linux-image-amd64,sipcalc,live-boot,dosfstools"
    if [[ ! -d artifacts/debootstrap ]]; then
        sudo /usr/sbin/debootstrap \
            --include=${SQUASHFS_PKGLIST} \
            buster \
            artifacts/debootstrap/ \
            http://localhost:3142/ftp.ca.debian.org/debian &>/dev/null || fail "Error performing debootstrap."
            sudo chroot artifacts/debootstrap/ apt clean &>/dev/null || fail "Error cleaning apt cache in debootstrap."
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
    sudo tee -a ${tempdir}/rootfs/root/.bashrc <<<"/install.sh" &>/dev/null || fail "Error setting bashrc."
    sudo chroot ${tempdir}/rootfs/ /usr/bin/passwd -d root &>/dev/null || fail "Error disabling root password."
	sudo cp install.sh ${tempdir}/rootfs/ &>/dev/null || fail "Error copying install.sh to tempdir."
    echo "done."
    
    echo -n "Generating squashfs image of live installation... "
    if [[ ! -f artifacts/filesystem.squashfs && -n ${ignorecachedsquashfs} ]]; then
        sudo nice mksquashfs ${tempdir}/rootfs/ artifacts/filesystem.squashfs -e boot &>/dev/null || fail "Error generating squashfs."
    fi
    sudo cp artifacts/filesystem.squashfs ${tempdir}/installer/live/filesystem.squashfs &>/dev/null || fail "Error copying squashfs to tempdir."
    echo "done."
}

build_iso() {
    echo -n "Copying live boot configurations... "
    sudo cp -a grub.cfg ${tempdir}/installer/boot/grub/grub.cfg &>/dev/null || fail "Error copying grub.cfg file."
    sudo cp -a isolinux.cfg ${tempdir}/installer/isolinux/isolinux.cfg &>/dev/null || fail "Error copying isolinux.cfg file."
    sudo cp -a splash.png ${tempdir}/installer/isolinux/splash.png &>/dev/null || fail "Error copying splash.png file."
    echo "done."

    echo -n "Creating LiveCD ISO... "
    pushd ${tempdir}/installer &>/dev/null
    xorriso -as mkisofs \
       -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
       -c isolinux/boot.cat \
       -b isolinux/isolinux.bin \
       -no-emul-boot \
       -boot-load-size 4 \
       -boot-info-table \
       -eltorito-alt-boot \
       -e boot/grub/efi.img \
       -no-emul-boot \
       -isohybrid-gpt-basdat \
       -o ../${isofilename} \
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
