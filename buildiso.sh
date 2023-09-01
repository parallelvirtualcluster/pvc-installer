#!/bin/bash

# Generate a PVC autoinstaller ISO

# This ISO makes a number of assumptions about the system and asks
# minimal questions in order to streamline the install process versus
# using a standard Debian intaller ISO. The end system is suitable
# for immediate bootstrapping with the PVC Ansible roles.

liveisofile="$( pwd )/debian-live-buster-DI-rc1-amd64-standard.iso"

fail() {
    echo $@
    exit 1
}

which debootstrap &>/dev/null || fail "This script requires debootstrap."
which mksquashfs &>/dev/null || fail "This script requires squashfs."
which xorriso &>/dev/null || fail "This script requires xorriso."

tempdir=$( mktemp -d )

prepare_iso() {
    echo -n "Creating directories... "
    mkdir ${tempdir}/rootfs/ ${tempdir}/installer/ || fail "Error creating temporary directories."
    echo "done."

    echo -n "Extracting Debian LiveISO files... "
    iso_tempdir=$( mktemp -d )
    sudo mount ${liveisofile} ${iso_tempdir} &>/dev/null || fail "Error mounting LiveISO file."
	sudo rsync -au --exclude live/filesystem.squashfs ${iso_tempdir}/ ${tempdir}/installer/ &>/dev/null || fail "Error extracting LiveISO files."
    sudo umount ${iso_tempdir} &>/dev/null || fail "Error unmounting LiveISO file."
    rmdir ${iso_tempdir} &>/dev/null
    sudo cp -a grub.cfg ${tempdir}/installer/boot/grub/grub.cfg &>/dev/null || fail "Error copying grub.cfg file."
    sudo cp -a menu.cfg ${tempdir}/installer/isolinux/menu.cfg &>/dev/null || fail "Error copying menu.cfg file."
    kernver=$( basename debootstrap/boot/vmlinuz* | head -1 | sed 's/vmlinuz-//' )
    sudo cp -a debootstrap/boot/vmlinuz-${kernver} ${tempdir}/installer/live/vmlinuz &>/dev/null || fail "Error copying kernel."
    sudo cp -a debootstrap/boot/initrd.img-${kernver} ${tempdir}/installer/live/initrd.img || fail "Error copying initrd."
    echo "done."
}

prepare_rootfs() {
    echo -n "Preparing Debian live installation via debootstrap... "
    SQUASHFS_PKGLIST="mdadm,lvm2,parted,gdisk,debootstrap,grub-pc,linux-image-amd64,sipcalc"
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
    sudo nice mksquashfs ${tempdir}/rootfs/ ${tempdir}/installer/live/install.squashfs -e boot &>/dev/null || fail "Error generating squashfs."
    echo "done."
}

build_iso() {
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
    mv ${tempdir}/pvc-installer.iso . &>/dev/null || fail "Error moving ISO file."
    echo "done."
}

prepare_iso
prepare_rootfs
build_iso

echo -n "Cleaning up... "
sudo rm -rf ${tempdir} &>/dev/null
echo "done."
echo
echo "PVC Live Installer ISO generation complete."
