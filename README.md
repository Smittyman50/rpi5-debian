# Raspberry Pi 5 Debian HTTP-boot installer

This repository builds and publishes an unattended Debian 12 (Bookworm) installer for Raspberry Pi 5 systems. A Pi boots a small signed FAT image over the network, runs an installer from an initramfs, replaces the contents of its first NVMe drive with Debian, and then uses a serial-specific cloud-init seed to configure the installed system.

The repository is tailored to the network and services named in the source files. It is not a generic Raspberry Pi image project without first changing those site-specific values.

> [!CAUTION]
> The installer unconditionally repartitions and formats `/dev/nvme0n1`. Booting the installer on a Pi with data on that device destroys that data.

## How the system works

The end-to-end flow is:

1. The build fetches the current Raspberry Pi firmware repository and patches the Pi 5 device tree so firmware-provided `chosen/bootargs` do not override this project's command line.
2. It builds a minimal arm64 Debian root filesystem and a separate installer initramfs.
3. It creates `boot.img`, a FAT image containing Pi firmware, the Pi 5 kernel, the patched DTB, overlays, the installer initramfs, and the files in `boot/`.
4. CI signs `boot.img` with `rpi-eeprom-digest` and publishes the boot payload and installer artifacts.
5. A Pi configured for EEPROM HTTP boot downloads that image. Its kernel starts `/init` from RAM and obtains network configuration through DHCP.
6. The installer identifies the Pi using the serial number from `/proc/cpuinfo`, partitions `/dev/nvme0n1`, and downloads the root filesystem, Pi boot firmware, and matching kernel modules from the configured HTTP server.
7. The installer writes the installed system's boot configuration and a NoCloud seed URL of the form `seeds/<serial>/`, then reboots.
8. On first boot, cloud-init downloads that Pi's `meta-data`, `user-data`, and `vendor-data`, and applies its hostname, network, user, packages, CA certificate, Docker setting, and optional roles.

The boot artifacts and per-device seeds have separate CI workflows. This allows inventory or template changes to be deployed without rebuilding the kernel, root filesystem, or installer.

## Repository layout

```text
.
|-- .gitea/workflows/
|   |-- pi5-httpboot-kernel.yml  # Scheduled/manual boot-artifact build and MinIO publish
|   `-- pi5-seeds.yml            # Seed render/deploy on relevant main-branch changes
|-- boot/
|   |-- config.txt               # Firmware configuration for the RAM-based installer
|   `-- cmdline.txt              # Installer kernel command line
|-- files/
|   `-- step-ca-root.crt         # Private CA installed by cloud-init
|-- installer/
|   `-- init                     # PID 1 for the destructive NVMe installer
|-- inventory/
|   `-- pis.yml                  # Serial-to-machine provisioning inventory
|-- scripts/
|   |-- fetch_rpi_firmware.sh    # Clone Raspberry Pi firmware and validate Pi 5 files
|   |-- patch_pi5_dtb.sh         # Remove embedded bootargs from the Pi 5 DTB
|   |-- build_rootfs.sh          # Build the Debian Bookworm arm64 rootfs archive
|   |-- build_installer_initramfs.sh # Build the installer initramfs
|   |-- build_boot_img.sh        # Assemble the EEPROM HTTP-boot FAT image
|   |-- render_seeds.py          # Render serial-specific NoCloud seed directories
|   `-- publish.sh               # Stage boot artifacts and/or seeds in dist/
`-- templates/
    |-- meta-data.j2             # NoCloud instance ID and local hostname
    `-- user-data.j2             # First-boot cloud-init configuration
```

Generated `out/` and `dist/` directories are build products and are not tracked.

## Components

### Installer boot image

`boot/config.txt` selects the Pi 5 `kernel_2712.img`, enables the UART, and loads `initramfs.gz`. `boot/cmdline.txt` directs the kernel to use the RAM filesystem as root, run `/init`, request DHCP, and expose both serial and local consoles.

`scripts/build_boot_img.sh` packages those files with the firmware, kernel, DTB, and overlays in a 96 MiB FAT image by default. Set `BOOTIMG_SIZE` to override the size or `OUT` to use a build directory other than `out`.

### Installer initramfs

`scripts/build_installer_initramfs.sh` uses `debootstrap` and QEMU user emulation to create a lean arm64 Debian environment containing the disk, filesystem, network, archive, and compression tools needed by `installer/init`. The `HTTP_BASE` environment variable is baked into the copied `/init`; its current default is `http://192.168.3.26/rpi/httpboot`.

At runtime, `installer/init`:

- initializes `/proc`, `/sys`, `/dev`, and networking on `eth0`;
- synchronizes time from the site's HTTP endpoint;
- obtains the Pi serial number;
- creates a GPT on `/dev/nvme0n1` with a 511 MiB FAT32 boot partition and an ext4 root partition;
- downloads and extracts the Debian rootfs, Pi firmware, and Pi kernel modules;
- verifies that a `*-v8-16k+` module tree is present;
- writes `cmdline.txt`, `config.txt`, `autoboot.txt`, and `/etc/fstab`; and
- configures cloud-init to read `HTTP_BASE/seeds/<serial>/` on first boot.

Failures drop to an emergency shell on the installer console. The installed boot configuration enables the serial UART, disables Bluetooth, and boots the ext4 root by PARTUUID.

### Debian root filesystem

`scripts/build_rootfs.sh` bootstraps arm64 Bookworm from `deb.debian.org` and produces `out/artifacts/debian-bookworm-arm64-rootfs.tar.zst`. Its base system includes systemd, SSH, sudo, cloud-init, ifupdown, chrony, fake-hwclock, and basic network tooling. It also:

- enables SSH, chrony, fake-hwclock, and the `ttyAMA10` serial getty;
- limits cloud-init discovery to NoCloud/NoCloudNet;
- configures the local NTP source `192.168.3.5` with `pool.ntp.org` as a fallback;
- locks the root account; and
- clears cloud-init state and machine identity for first boot.

The script requires a Debian/Ubuntu-style Linux build host with root privileges, `debootstrap`, and working arm64 binfmt/QEMU support. It installs its host dependencies with `apt-get`.

### Per-device cloud-init seeds

`inventory/pis.yml` maps each Pi serial to its desired configuration. Supported fields are:

| Field | Purpose | Default |
| --- | --- | --- |
| `hostname` | Required machine hostname | none |
| `username` | Administrative user | `smittyman` |
| `passwd_hash` | Crypt-format password hash | empty |
| `ssh_authorized_keys` | SSH public keys for the user | `[]` |
| `timezone` | System timezone | `UTC` |
| `packages` | Additional apt packages | `[]` |
| `docker` | Install Docker CE and add the user to its group | `false` |
| `roles` | Docker deployment roles consumed by the downstream Ansible repository | `[]` |
| `net.ifname` | Installed-system interface name | `end0` |
| `net.mode` | `dhcp` or `static` | `dhcp` |
| `net.address` | Static address, with `/24` added if no prefix is supplied | required for static mode |
| `net.gateway` | Static default gateway | required for static mode |
| `net.dns` | DNS server string or list | unset |
| `net.search` | Search-domain string or list | unset |

Render seeds from the repository root with:

```bash
python3 -m pip install pyyaml jinja2
python3 scripts/render_seeds.py
```

This writes the following files for every inventory serial:

```text
out/seeds/<serial>/meta-data
out/seeds/<serial>/user-data
out/seeds/<serial>/vendor-data
```

Relative `lookup('file', ...)` paths in templates resolve from the current repository root. `LOOKUP_BASE_DIR` can override that base. Rendering uses strict undefined-variable handling, so missing or misspelled template values fail the build.

The current user-data template installs a standard utility set and the private CA in `files/step-ca-root.crt`. When `docker: true`, it configures Docker's Debian Bookworm repository and installs Docker CE. If `roles` is also non-empty, it installs Ansible, writes `/etc/docker-roles.yml`, and invokes the configured `ansible-pull` repository. Cloud-init finishes by writing `/etc/provisioned.txt` and rebooting.

## Building locally

Run the scripts from the repository root on a Debian/Ubuntu Linux host. Several steps use `sudo`, install host packages, access the network, and produce large files.

```bash
bash scripts/fetch_rpi_firmware.sh
sudo bash scripts/patch_pi5_dtb.sh
bash scripts/build_rootfs.sh
HTTP_BASE=http://your-server/rpi/httpboot bash scripts/build_installer_initramfs.sh
bash scripts/build_boot_img.sh
python3 scripts/render_seeds.py
PUBLISH_MODE=all bash scripts/publish.sh
```

The order matters: the boot image needs fetched firmware and the installer initramfs, while publishing needs all requested build outputs. The scripts are stored without executable mode in Git, so either invoke them with `bash scripts/<name>.sh` or make them executable first.

Useful build overrides are:

| Variable | Used by | Meaning |
| --- | --- | --- |
| `OUT` | firmware, initramfs, and boot-image scripts | Build directory; default `out` |
| `ROOTFS_DIR` | `build_rootfs.sh` | Temporary root filesystem directory |
| `OUT_TAR` | `build_rootfs.sh` | Rootfs archive path |
| `SUITE`, `ARCH` | `build_installer_initramfs.sh` | Installer Debian suite and architecture |
| `HTTP_BASE` | `build_installer_initramfs.sh` | Artifact and seed URL baked into `/init` |
| `BOOTIMG_SIZE` | `build_boot_img.sh` | FAT boot-image size; default `96M` |
| `DTB` | `patch_pi5_dtb.sh` | DTB to patch |
| `KVER` | `publish.sh` | Kernel module version to package |
| `PUBLISH_MODE` | `publish.sh` | `all`, `boot`, or `seeds` |

### Staged output

`scripts/publish.sh` recreates `dist/` on every run. Depending on `PUBLISH_MODE`, it produces:

```text
dist/
|-- boot.img
|-- boot.sig                         # only when supplied or added by CI
|-- config.txt
|-- cmdline.txt
|-- artifacts/
|   |-- initramfs.gz
|   |-- debian-bookworm-arm64-rootfs.tar.zst
|   |-- pi-firmware.tar.zst
|   `-- pi-modules.tar.zst
`-- seeds/
    `-- <serial>/
        |-- meta-data
        |-- user-data
        `-- vendor-data
```

`boot.img` already contains the initramfs and boot configuration. The copies under `artifacts/` and at the root of `dist/` are also staged for serving and inspection; the runtime installer downloads the rootfs, firmware, and module archives from `HTTP_BASE/artifacts/`.

## CI workflows

`.gitea/workflows/pi5-httpboot-kernel.yml` runs manually or every Sunday at 08:00 UTC. It builds the firmware, rootfs, installer, and boot image; signs the boot image with the `RPI_HTTPBOOT_PRIVATE_PEM` secret; publishes both a stable `latest/` tree and an immutable timestamp/SHA tree to MinIO; writes `latest.json`; and retains the six newest immutable builds.

`.gitea/workflows/pi5-seeds.yml` runs manually or when seed-related files change on `main`. It renders only the seed data and uses SSH/rsync to replace the seed tree under `/srv/http/rpi/httpboot/seeds` on `ironhide.home.arpa`. It requires the `ANSIBLE_PRIVATE_KEY` secret.

The boot workflow's MinIO endpoint, bucket, and prefix, and the seed workflow's deployment host and directory, are environment-specific. Publishing to MinIO does not by itself explain how the hard-coded installer HTTP URL is mapped to those objects; the surrounding HTTP service must expose this layout.

## Site-specific settings and security

Before using this repository elsewhere, review at least:

- `HTTP_BASE` in the initramfs build and the installer time endpoint;
- the temporary DNS resolver and NTP server addresses;
- Docker and Ansible repository URLs in `templates/user-data.j2`;
- MinIO, SSH, and HTTP deployment destinations in `.gitea/workflows/`;
- the serial numbers, static addresses, usernames, password hashes, and SSH keys in `inventory/pis.yml`; and
- the private trust anchor in `files/step-ca-root.crt`.

Although password hashes and public keys are not plaintext passwords, the inventory is still security-sensitive. Keep the HTTP boot and seed endpoints on a trusted network, protect CI signing and deployment keys as secrets, and restrict write access to published boot artifacts. The installer downloads runtime archives over plain HTTP and does not verify their signatures or checksums; integrity therefore depends on the trusted network and publication path.
