#!/usr/bin/env bash
set -euo pipefail

OUT="${OUT:-out}"
SUITE="${SUITE:-bookworm}"
ARCH="${ARCH:-arm64}"
HTTP_BASE="${HTTP_BASE:-http://192.168.3.26/rpi/httpboot}"

ROOT="${OUT}/installer-root"
INIT_SRC="installer/init"

ART_DIR="${OUT}/artifacts"
INITRD_OUT="${ART_DIR}/initramfs.gz"

mkdir -p "${OUT}" "${ART_DIR}"
sudo rm -rf "${ROOT}"
sudo mkdir -p "${ROOT}"

sudo apt-get update
sudo apt-get install -y \
  debootstrap qemu-user-static binfmt-support \
  ca-certificates gzip cpio zstd

# 1) Bootstrap minimal Debian arm64 root
sudo debootstrap --arch="${ARCH}" --foreign "${SUITE}" "${ROOT}" http://deb.debian.org/debian

# 2) Enable second-stage using qemu
sudo cp /usr/bin/qemu-aarch64-static "${ROOT}/usr/bin/"
sudo chroot "${ROOT}" /debootstrap/debootstrap --second-stage

# (Optional) avoids some debconf/devpts noise; not strictly required
sudo mkdir -p "${ROOT}/dev/pts"
sudo mount -t devpts devpts "${ROOT}/dev/pts" 2>/dev/null || true

# 3) Install tools the installer needs (keep this lean)
sudo chroot "${ROOT}" bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  busybox \
  ca-certificates \
  iproute2 \
  isc-dhcp-client \
  wget \
  parted \
  dosfstools \
  e2fsprogs \
  tar \
  zstd
apt-get clean
rm -rf /var/lib/apt/lists/*
'

# 4) Drop in /init (bake HTTP_BASE)
sudo install -m 0755 /dev/null "${ROOT}/init"
sudo sed "s|^HTTP_BASE=.*|HTTP_BASE=\"${HTTP_BASE}\"|g" "${INIT_SRC}" | sudo tee "${ROOT}/init" >/dev/null
sudo chmod 0755 "${ROOT}/init"

# 5) Ensure minimal dirs exist in initramfs image
sudo mkdir -p "${ROOT}"/{proc,sys,dev,run,tmp,mnt,sysroot}

# 6) Pack initramfs -> out/artifacts/initramfs.gz
# Use an absolute path so "cd ROOT" doesn't affect output location
INITRD_OUT_ABS="$(readlink -f "${INITRD_OUT}")"
sudo bash -lc "set -e; cd '${ROOT}'; find . -print0 | cpio --null -H newc -o | gzip -9 > '${INITRD_OUT_ABS}'"

# Cleanup devpts mount (if it was mounted)
sudo umount "${ROOT}/dev/pts" 2>/dev/null || true

sudo chown "$(id -u):$(id -g)" "${INITRD_OUT}"
ls -lh "${INITRD_OUT}"
echo "Wrote: ${INITRD_OUT}"

# Optional compatibility copy (remove once build_boot_img.sh uses artifacts path)
cp -f "${INITRD_OUT}" "${OUT}/initramfs.gz"
