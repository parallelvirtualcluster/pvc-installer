<p align="center">
<img alt="Logo banner" src="https://docs.parallelvirtualcluster.org/en/latest/images/pvc_logo_black.png"/>
<br/><br/>
<a href="https://www.parallelvirtualcluster.org"><img alt="Website" src="https://img.shields.io/badge/visit-website-blue"/></a>
<a href="https://github.com/parallelvirtualcluster/pvc"><img alt="License" src="https://img.shields.io/github/license/parallelvirtualcluster/pvc"/></a>
<a href="https://github.com/psf/black"><img alt="Code style: Black" src="https://img.shields.io/badge/code%20style-black-000000.svg"/></a>
<a href="https://github.com/parallelvirtualcluster/pvc/releases"><img alt="Latest Release" src="https://img.shields.io/github/release-pre/parallelvirtualcluster/pvc"/></a>
<a href="https://docs.parallelvirtualcluster.org/en/latest/?badge=latest"><img alt="Documentation Status" src="https://readthedocs.org/projects/parallelvirtualcluster/badge/?version=latest"/></a>
</p>

## What is PVC?

PVC is a Linux KVM-based hyperconverged infrastructure (HCI) virtualization cluster solution that is fully Free Software, scalable, redundant, self-healing, self-managing, and designed for administrator simplicity. It is an alternative to other HCI solutions such as Ganeti, Harvester, Nutanix, and VMWare, as well as to other common virtualization stacks such as ProxMox and OpenStack.

PVC is a complete HCI solution, built from well-known and well-trusted Free Software tools, to assist an administrator in creating and managing a cluster of servers to run virtual machines, as well as self-managing several important aspects including storage failover, node failure and recovery, virtual machine failure and recovery, and network plumbing. It is designed to act consistently, reliably, and unobtrusively, letting the administrator concentrate on more important things.

PVC is highly scalable. From a minimum (production) node count of 3, up to 12 or more, and supporting many dozens of VMs, PVC scales along with your workload and requirements. Deploy a cluster once and grow it as your needs expand.

As a consequence of its features, PVC makes administrating very high-uptime VMs extremely easy, featuring VM live migration, built-in always-enabled shared storage with transparent multi-node replication, and consistent network plumbing throughout the cluster. Nodes can also be seamlessly removed from or added to service, with zero VM downtime, to facilitate maintenance, upgrades, or other work.

PVC also features an optional, fully customizable VM provisioning framework, designed to automate and simplify VM deployments using custom provisioning profiles, scripts, and CloudInit userdata API support.

Installation of PVC is accomplished by two main components: a [Node installer ISO](https://github.com/parallelvirtualcluster/pvc-installer) which creates on-demand installer ISOs, and an [Ansible role framework](https://github.com/parallelvirtualcluster/pvc-ansible) to configure, bootstrap, and administrate the nodes. Installation can also be fully automated with a companion [cluster bootstrapping system](https://github.com/parallelvirtualcluster/pvc-bootstrap). Once up, the cluster is managed via an HTTP REST API, accessible via a Python Click CLI client ~~or WebUI~~ (eventually).

Just give it physical servers, and it will run your VMs without you having to think about it, all in just an hour or two of setup time.

More information about PVC, its motivations, the hardware requirements, and setting up and managing a cluster [can be found over at our docs page](https://docs.parallelvirtualcluster.org).

# PVC Live Node Installer

This repository contains the generator and configurations for the PVC Live Node Installer ISO. This ISO provides a quick and convenient way to install a PVC base system to a physical server, ready to then be provisioned using the [PVC Ansible](https://github.com/parallelvirtualcluster/pvc-ansible) configuration framework. Part of the [Parallel Virtual Cluster system](https://github.com/parallelvirtualcluster/pvc).

# Using the PVC Installer

## Preparing

1. Run `./buildiso.sh` from the root of the repository. This will pull down the Debian LiveCD image, extract it, debootstrap a fresh install environment, copy in the configurations, generate a squashfs, then finally generate an ISO file.

Note that artifacts of the build (the LiveCD ISO, debootstrap directory, and squashfs) are cached in `artifacts/` for future reuse.

2. Load the ISO via virtual media or write it to a USB drive.

3. Boot the server from the ISO, ideally in UEFI mode.

## Booting

The built ISO can be booted in either BIOS (traditional ISOLinux) or UEFI (Grub2) modes. It is strongly recommended to use the latter if the system supports it for maximum flexibility.

## Installing

The installer script will ask several questions to configure the bare minimum system needed for [`pvc-ansible`](https://github.com/parallelvirtualcluster/pvc-ansible) to configure the node.

Follow the prompts carefully; if you make a mistake, you can ^C to cancel the installer, then re-run via `/install.sh` from the resulting root shell.
