# PVC Live Node Installer

**NOTICE FOR GITHUB**: This repository is a read-only mirror of the PVC repositories from my personal GitLab instance. Pull requests submitted here will not be merged. Issues submitted here will however be treated as authoritative.

This repository contains the generator and configurations for the PVC Live Node Installer ISO. This ISO provides a quick and convenient way to install a PVC base system to a physical server, ready to then be provisioned using the [PVC Ansible](https://github.com/parallelvirtualcluster/pvc-ansible) configuration framework. Part of the [Parallel Virtual Cluster system](https://github.com/parallelvirtualcluster/pvc).

## Using

Run `./buildiso.sh`. This will pull down the Debian LiveCD image, extract it, debootstrap a fresh install environment, copy in the configurations, generate a squashfs, then finally generate an ISO for use via CD-ROM, Virtual Media, or USB/SDCard flash.

Note that artifacts of the build (the LiveCD ISO, debootstrap directory, and squashfs) are cached in `artifacts/` for future reuse.

## Booting

The built ISO can be booted in either BIOS (traditional ISOLinux) or UEFI (Grub2) modes. It is strongly recommended to use the latter if the system supports it for maximum flexibility.

## Installing

The installer script will ask several questions to configure the bare minimum system needed for [`pvc-ansible`](https://github.com/parallelvirtualcluster/pvc-ansible) to configure the node.

Follow the prompts carefully; if you make a mistake, you can ^C to cancel the installer, then re-run via `/install.sh` from the resulting root shell.

## License

Copyright (C) 2018-2021  Joshua M. Boniface <joshua@boniface.me>

This repository, and all contained files, is free software: you can
redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation, version 3.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
