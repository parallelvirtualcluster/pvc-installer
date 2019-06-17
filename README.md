# PVC Live Installer

This repository contains the generator and configurations for the PVC Live Installer ISO. This ISO provides a quick and convenient way to install a PVC base system to a physical server, ready to then be provisioned using the [`pvc-ansible`](https://git.bonifacelabs.ca/parallelvirtualcluster/pvc-ansible) configuration framework.

## Using

Run `./buildiso.sh`. This will pull down the Debian LiveCD image, extract it, deboostrap a fresh install environment, copy in the configurations, generate a squashfs, then finally generate an ISO for use via CD-ROM, Virtual Media, or USB/SDCard flash.

Note that artifacts of the build (the LiveCD ISO, debootstrap directory, and squashfs) are cached in `artifacts/` for future reuse.

## Booting

The built ISO can be booted in either BIOS (traditional ISOLinux) or UEFI (Grub2) modes. It is strongly recommended to use the latter if the system supports it for maximum flexibility.
