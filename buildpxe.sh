#!/usr/bin/env bash

# Generate a PVC autoinstaller PXE configuration

fail() {
    echo "$@"
    exit 1
}

test -f /usr/lib/PXELINUX/pxelinux.0 &>/dev/null || fail "This script requires pxelinux and syslinux-common"
test -f /usr/lib/syslinux/modules/bios/ldlinux.c32 &>/dev/null || fail "This script requires pxelinux and syslinux-common"
sudo -n true &>/dev/null || fail "The user running this script must have sudo privileges."

outputdir="pvc-installer-pxe_$(date +%Y-%m-%d)/"
deployusername="deploy"

show_help() {
    echo -e "PVC install PXE generator"
    echo
    echo -e " Generates a mostly-automated installer PXE image for a PVC node base system."
    echo -e " This setup is designed to be used with the pvcbootstrapd system; for a normal"
    echo -e " installation, use buildiso.sh instead."
    echo
    echo -e "Usage: $0 [-h] [-o <outputdirectory>] [-u username]"
    echo
    echo -e "   -h: Display this help message."
    echo -e "   -o: Create the PXE images under <outputdirectory> instead of the default."
    echo -e "   -u: Change 'deploy' user to a new username."
    echo -e "   -a: Preserve live-build artifacts (passed through to buildiso.sh)."
    echo -e "   -k: Preserve live-build config (passed through to buildiso.sh)."
    echo -e "   -i: Preserve live-build ISO image."
}

while [ $# -gt 0 ]; do
    case "${1}" in
        -h|\?)
            show_help
            exit 0
        ;;
        -o)
            outputdir="${2}"
            shift 2
        ;;
        -u)
            deployusername="${2}"
            shift 2
        ;;
        -a)
            preserve_artifacts='-a'
            shift
        ;;
        -k)
            preserve_livebuild='-k'
            shift
        ;;
        -i)
            preserve_liveiso='y'
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

cleanup() {
    echo -n "Cleaning up... "
    echo "done."
    echo
}

fail() {
    echo $@
    cleanup
    exit 1
}

build_iso() {
    if [[ ! -f pvc-installer_pxe-tmp.iso ]]; then
        ./buildiso.sh \
            -o pvc-installer_pxe-tmp.iso \
            -u ${deployusername} \
            ${preserve_artifacts} \
            ${preserve_livebuild} || fail "Failed to build ISO."
        echo
    fi
}

build_pxe() {
    mkdir -p ${outputdir} ${outputdir}/host

    echo -n "Mounting temporary ISO file... "
    tmpdir=$( mktemp -d )
    sudo mount pvc-installer_pxe-tmp.iso ${tmpdir} &>/dev/null
    echo "done."

    echo -n "Copying live boot files... "
    cp ${tmpdir}/live/filesystem.squashfs ${outputdir}/
    cp ${tmpdir}/live/vmlinuz ${outputdir}/
    cp ${tmpdir}/live/initrd.img ${outputdir}/
    echo "done."

    echo -n "Unmounting and removing temporary ISO file... "
    sudo umount ${tmpdir}
    rmdir ${tmpdir}
    echo "done."

    echo -n "Creating base iPXE configuration... "
    cat <<EOF > ${outputdir}/boot.pxe
#!ipxe

# Set global variables
set root-url tftp://\${next-server}

set menu-default pvc-installer
set submenu-default pvc-installer

:pvc-installer
kernel \${root-url}/vmlinuz
initrd \${root-url}/initrd.img
imgargs vmlinuz console=tty0 console=ttyS0,115200n8 vga=normal nomodeset boot=live components ethdevice-timeout=600 timezone=America/Toronto fetch=\${root-url}/filesystem.squashfs username=root pvcinstall.preseed=on pvcinstall.seed_host=\${next-server} pvcinstall.seed_file=/host/mac-\${mac:hexraw}.preseed

boot
EOF
    echo "done."

    echo -n "Downloading iPXE binary undionly.kpxe (chainloads arbitrary PXE clients)... "
    pushd ${outputdir} &>/dev/null
    wget -O undionly.kpxe https://boot.ipxe.org/undionly.kpxe &>/dev/null || fail "failed to download undionly.kpxe."
    popd &>/dev/null
    echo "done."

    echo -n "Downloading iPXE binary undionly.kpxe (chainloads UEFI clients)... "
    pushd ${outputdir} &>/dev/null
    wget -O ipxe.efi https://boot.ipxe.org/ipxe.efi &>/dev/null || fail "failed to download ipxe.efi."
    popd &>/dev/null
    echo "done."

    sudo chown -R $(whoami) ${outputdir}
    sudo chmod -R u+w ${outputdir}

    if [[ -z ${preserve_liveiso} ]]; then
        echo -n "Removing temporary ISO... "
        rm pvc-installer_pxe-tmp.iso &>/dev/null
        echo "done."
    fi
}

build_iso
build_pxe
cleanup

echo "PVC Live Installer PXE generation complete."
