#!/usr/bin/env bash
set -euo pipefail

ARCH=arm64
SUITE=bookworm
ROOTFS_DIR="${ROOTFS_DIR:-out/rootfs}"
OUT_TAR="${OUT_TAR:-out/artifacts/debian-bookworm-arm64-rootfs.tar.zst}"

mkdir -p out/artifacts
rm -rf "$ROOTFS_DIR"

sudo apt-get update
sudo apt-get install -y debootstrap qemu-user-static binfmt-support zstd

sudo debootstrap --arch="$ARCH" --foreign "$SUITE" "$ROOTFS_DIR" http://deb.debian.org/debian
sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"

sudo chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage

sudo chroot "$ROOTFS_DIR" bash -lc "
set -e
apt-get update
apt-get install -y --no-install-recommends \
  systemd-sysv ca-certificates openssh-server sudo cloud-init netplan.io
apt-get clean
rm -rf /var/lib/apt/lists/*
systemctl enable ssh || true
passwd -l root || true
"

sudo tar -C "$ROOTFS_DIR" -cpf - . | zstd -19 -T0 -o "$OUT_TAR"
echo "Wrote $OUT_TAR"
