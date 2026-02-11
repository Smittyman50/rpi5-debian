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
  systemd-sysv ca-certificates openssh-server sudo cloud-init netplan.io \
  fake-hwclock chrony

apt-get clean
rm -rf /var/lib/apt/lists/*

# Seed fake-hwclock with build time so first boot isn't 1970
date -u '+%Y-%m-%d %H:%M:%S' > /etc/fake-hwclock.data

# Chrony config (Debian)
mkdir -p /etc/chrony/conf.d

cat >/etc/chrony/conf.d/10-local-sources.conf <<'EOF'
server 192.168.3.5 iburst prefer
pool pool.ntp.org iburst
makestep 1.0 -1
rtcsync
EOF

# Ensure chrony.conf includes conf.d (usually does, but make it explicit if missing)
if ! grep -qE '^[[:space:]]*include[[:space:]]+/etc/chrony/conf.d/\\*\\.conf' /etc/chrony/chrony.conf 2>/dev/null; then
  echo 'include /etc/chrony/conf.d/*.conf' >> /etc/chrony/chrony.conf
fi

# Lock root account
passwd -l root || true

# Enable services (prefer systemctl; fallback to symlinks)
enable_unit() {
  u=\"\$1\"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable \"\$u\" >/dev/null 2>&1 && return 0
  fi
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf \"/lib/systemd/system/\$u\" \"/etc/systemd/system/multi-user.target.wants/\$u\" || true
}

enable_unit ssh.service
enable_unit fake-hwclock.service
enable_unit chrony.service

echo \"built=\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" > /etc/rootfs-build-info

# --- sanitize image so first boot is truly first boot ---
rm -rf /var/lib/cloud
rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log
rm -f /etc/machine-id
rm -f /var/lib/dbus/machine-id
"

sudo tar -C "$ROOTFS_DIR" -cpf - . | zstd -19 -T0 -o "$OUT_TAR"
echo "Wrote $OUT_TAR"
