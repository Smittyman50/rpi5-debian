#!/usr/bin/env bash
set -euo pipefail

ARCH=arm64
SUITE=bookworm
MIRROR=http://deb.debian.org/debian

ROOTFS_DIR="${ROOTFS_DIR:-out/rootfs}"
OUT_TAR="${OUT_TAR:-out/artifacts/debian-bookworm-arm64-rootfs.tar.zst}"

mkdir -p out/artifacts
rm -rf "$ROOTFS_DIR"

sudo apt-get update
sudo apt-get install -y debootstrap qemu-user-static binfmt-support zstd

sudo debootstrap --arch="$ARCH" --foreign "$SUITE" "$ROOTFS_DIR" "$MIRROR"
sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"

# Complete debootstrap inside the target rootfs
sudo chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage

# --- prepare chroot runtime mounts (prevents /dev/pts + /proc warnings) ---
sudo mkdir -p "$ROOTFS_DIR"/{proc,sys,dev,dev/pts,run}

sudo mount -t proc proc "$ROOTFS_DIR/proc"
sudo mount -t sysfs sys "$ROOTFS_DIR/sys"
sudo mount --bind /dev "$ROOTFS_DIR/dev"
# devpts mount can fail on some constrained runners; keep going if it does
sudo mount -t devpts devpts "$ROOTFS_DIR/dev/pts" -o gid=5,mode=620 2>/dev/null || true
# /run helps some postinst scripts; safe to ignore failure
sudo mount -t tmpfs tmpfs "$ROOTFS_DIR/run" 2>/dev/null || true

cleanup_mounts() {
  set +e
  sudo umount -lf "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
  sudo umount -lf "$ROOTFS_DIR/dev"     2>/dev/null || true
  sudo umount -lf "$ROOTFS_DIR/proc"    2>/dev/null || true
  sudo umount -lf "$ROOTFS_DIR/sys"     2>/dev/null || true
  sudo umount -lf "$ROOTFS_DIR/run"     2>/dev/null || true
}

sudo chroot "$ROOTFS_DIR" bash -lc "
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# Use a safe UTF-8 locale during package installs (exists without generating locales)
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

apt-get update

# Install locales early so later postinst scripts stop complaining
apt-get install -y --no-install-recommends locales

# Generate and set default locale (adjust if you prefer en_GB, etc.)
sed -i 's/^# *\\(en_US.UTF-8 UTF-8\\)/\\1/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Core packages for your image
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

# tear down mounts BEFORE packaging
cleanup_mounts
trap - EXIT

# Create compressed artifact
sudo tar -C "$ROOTFS_DIR" -cpf - . | zstd -19 -T0 -o "$OUT_TAR"
echo "Wrote $OUT_TAR"
