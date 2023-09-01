#!/bin/bash

# Generate a PVC autoinstaller ISO

# This ISO makes a number of assumptions about the system and asks
# minimal questions in order to streamline the install process versus
# using a standard Debian intaller ISO. The end system is suitable
# for immediate bootstrapping with the PVC Ansible roles.

liveisofile="debian-live-buster-DI-rc1-amd64-standard.iso"
liveisourl="https://cdimage.debian.org/mirror/cdimage/buster_di_rc1-live/amd64/iso-hybrid/${liveisofile}"

which debootstrap &>/dev/null || fail "This script requires debootstrap."
which mksquashfs &>/dev/null || fail "This script requires squashfs."
which xorriso &>/dev/null || fail "This script requires xorriso."

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
    mkdir ${tempdir}/rootfs/ ${tempdir}/installer/ || fail "Error creating temporary directories."
    echo "done."

    if [[ ! -f ${liveisofile} ]]; then
        echo -n "Downloading Debian LiveISO... "
        wget -O ${liveisofile} ${liveisourl}
        echo "done."
    fi

    echo -n "Extracting Debian LiveISO files... "
    iso_tempdir=$( mktemp -d )
    sudo mount ${liveisofile} ${iso_tempdir} &>/dev/null || fail "Error mounting LiveISO file."
	sudo rsync -au --exclude live/filesystem.squashfs ${iso_tempdir}/ ${tempdir}/installer/ &>/dev/null || fail "Error extracting LiveISO files."
    sudo umount ${iso_tempdir} &>/dev/null || fail "Error unmounting LiveISO file."
    rmdir ${iso_tempdir} &>/dev/null
    echo "done."
}

prepare_rootfs() {
    echo -n "Preparing Debian live installation via debootstrap... "
    SQUASHFS_PKGLIST="mdadm,lvm2,parted,gdisk,debootstrap,grub-pc,linux-image-amd64,sipcalc,live-boot,dosfstools"
    test -d debootstrap/ || \
    sudo /usr/sbin/debootstrap \
        --include=${SQUASHFS_PKGLIST} \
        buster \
        debootstrap/ \
        http://localhost:3142/ftp.ca.debian.org/debian &>/dev/null || fail "Error performing debootstrap."
    sudo chroot debootstrap/ apt clean &>/dev/null || fail "Error cleaning apt cache in debootstrap."
    sudo rsync -au debootstrap/ ${tempdir}/rootfs/ &>/dev/null || fail "Error copying debootstrap to tempdir."
    echo "done."
   
    echo -n "Configuring Debian live installation... "
    sudo cp -a debootstrap/boot/vmlinuz* ${tempdir}/installer/live/vmlinuz &>/dev/null || fail "Error copying kernel."
    sudo cp -a debootstrap/boot/initrd.img* ${tempdir}/installer/live/initrd.img &>/dev/null || fail "Error copying initrd."
    sudo cp ${tempdir}/rootfs/lib/systemd/system/getty\@.service ${tempdir}/rootfs/etc/systemd/system/getty@tty1.service &>/dev/null || fail "Error copying getty override to tempdir."
    sudo sed -i \
        's|/sbin/agetty|/sbin/agetty --autologin root|g' \
         ${tempdir}/rootfs/etc/systemd/system/getty@tty1.service &>/dev/null || fail "Error setting autologin in getty override."
    sudo tee ${tempdir}/rootfs/etc/hostname <<<"pvc-node-installer" &>/dev/null || fail "Error setting hostname."
    sudo tee -a ${tempdir}/rootfs/root/.bashrc <<<"/install.sh" &>/dev/null || fail "Error setting bashrc."
    sudo chroot ${tempdir}/rootfs/ /usr/bin/passwd -d root &>/dev/null || fail "Error disabling root password."
	sudo cp install.sh ${tempdir}/rootfs/ &>/dev/null || fail "Error copying install.sh to tempdir."
    echo "done."
    
    echo -n "Generating squashfs image of live installation... "
    if [[ ! -f filesystem.squashfs ]]; then
        sudo nice mksquashfs ${tempdir}/rootfs/ filesystem.squashfs -e boot &>/dev/null || fail "Error generating squashfs."
    fi
    sudo cp filesystem.squashfs ${tempdir}/installer/live/filesystem.squashfs &>/dev/null || fail "Error copying squashfs to tempdir."
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
       -o ../pvc-installer.iso \
       . &>/dev/null || fail "Error creating ISO file."
    popd &>/dev/null
    echo "done."

    echo -n "Moving generated ISO to '$(pwd)/pvc-installer.iso'... "
    mv ${tempdir}/pvc-installer.iso pvc-installer.iso &>/dev/null || fail "Error moving ISO file."
    echo "done."
}

prepare_iso
prepare_rootfs
build_iso
cleanup

echo "PVC Live Installer ISO generation complete."
