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
  systemd-sysv ca-certificates openssh-server sudo cloud-init netplan.io fake-hwclock chrony

apt-get clean
rm -rf /var/lib/apt/lists/*

# Seed fake-hwclock with build time so first boot isn't 1970
date -u +%Y-%m-%d\ %H:%M:%S > /etc/fake-hwclock.data

# Create chrony source file
cat >/etc/chrony/conf.d/10-local-sources.conf <<'EOF'
server 192.168.3.5 iburst prefer
pool pool.ntp.org iburst
makestep 1.0 -1
rtcsync
EOF

# Lock root account
passwd -l root || true

# Enable ssh without systemctl (safe in chroot)
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service || true

# Enable fake-hwclock without systemctl
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /lib/systemd/system/fake-hwclock.service \
  /etc/systemd/system/multi-user.target.wants/fake-hwclock.service || true

mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /lib/systemd/system/chrony.service \
  /etc/systemd/system/multi-user.target.wants/chrony.service || true

echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /etc/rootfs-build-info

# --- CRITICAL: sanitize image so first boot is truly first boot ---
rm -rf /var/lib/cloud
rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log
rm -f /etc/machine-id
rm -f /var/lib/dbus/machine-id
"

sudo tar -C "$ROOTFS_DIR" -cpf - . | zstd -19 -T0 -o "$OUT_TAR"
echo "Wrote $OUT_TAR"
