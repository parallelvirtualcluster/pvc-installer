# PVC Live Installer

This repository contains the generator and configurations for the PVC Live Installer ISO. This ISO provides a quick and convenient way to install a PVC base system to a physical server, ready to then be provisioned using the [`pvc-ansible`](https://git.bonifacelabs.ca/parallelvirtualcluster/pvc-ansible) configuration framework.

## Using

Run `./buildiso.sh`. This will pull down the Debian LiveCD image, extract it, deboostrap a fresh install environment, copy in the configurations, generate a squashfs, then finally generate an ISO for use via CD-ROM, Virtual Media, or USB/SDCard flash.

Note that artifacts of the build (the LiveCD ISO, debootstrap directory, and squashfs) are cached in `artifacts/` for future reuse.

## Booting

The built ISO can be booted in either BIOS (traditional ISOLinux) or UEFI (Grub2) modes. It is strongly recommended to use the latter if the system supports it for maximum flexibility.

## License

Copyright (C) 2018-2019  Joshua M. Boniface <joshua@boniface.me>

This repository, and all contained files, is free software: you can
redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
