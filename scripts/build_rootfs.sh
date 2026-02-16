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
sudo chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage

# --- prepare chroot runtime mounts ---
sudo mkdir -p "$ROOTFS_DIR"/{proc,sys,dev,dev/pts,run}

is_mounted() { mountpoint -q "$1" 2>/dev/null; }

cleanup_mounts() {
  set +e
  is_mounted "$ROOTFS_DIR/dev/pts" && sudo umount -lf "$ROOTFS_DIR/dev/pts"
  is_mounted "$ROOTFS_DIR/run"     && sudo umount -lf "$ROOTFS_DIR/run"
  is_mounted "$ROOTFS_DIR/dev"     && sudo umount -lf "$ROOTFS_DIR/dev"
  is_mounted "$ROOTFS_DIR/proc"    && sudo umount -lf "$ROOTFS_DIR/proc"
  is_mounted "$ROOTFS_DIR/sys"     && sudo umount -lf "$ROOTFS_DIR/sys"
  true
}
trap cleanup_mounts EXIT

is_mounted "$ROOTFS_DIR/proc" || sudo mount -t proc  proc  "$ROOTFS_DIR/proc"
is_mounted "$ROOTFS_DIR/sys"  || sudo mount -t sysfs sys   "$ROOTFS_DIR/sys"
is_mounted "$ROOTFS_DIR/dev"  || sudo mount --bind /dev    "$ROOTFS_DIR/dev"
is_mounted "$ROOTFS_DIR/dev/pts" || sudo mount -t devpts devpts "$ROOTFS_DIR/dev/pts" -o gid=5,mode=620 2>/dev/null || true
is_mounted "$ROOTFS_DIR/run" || sudo mount -t tmpfs tmpfs "$ROOTFS_DIR/run" 2>/dev/null || true

sudo chroot "$ROOTFS_DIR" bash -s <<'CHROOT'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Enable services (prefer systemctl; fallback to symlinks)
enable_unit() {
  u="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable "$u" >/dev/null 2>&1 && return 0
  fi
  mkdir -p /etc/systemd/system/multi-user.target.wants
  for p in "/lib/systemd/system/$u" "/usr/lib/systemd/system/$u"; do
    if [ -e "$p" ]; then
      ln -sf "$p" "/etc/systemd/system/multi-user.target.wants/$u" || true
      return 0
    fi
  done
  return 0
}

apt-get update

# Locale
apt-get install -y --no-install-recommends locales
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Core packages
apt-get install -y --no-install-recommends \
  systemd-sysv ca-certificates openssh-server sudo cloud-init ifupdown \
  fake-hwclock chrony kmod iptables nftables iputils-ping libcap2-bin

apt-get clean
rm -rf /var/lib/apt/lists/*

# Ensure ping works for non-root
if [ -x /usr/bin/ping ] && command -v setcap >/dev/null 2>&1; then
  setcap cap_net_raw+ep /usr/bin/ping || true
fi

# serial console getty
enable_unit serial-getty@ttyAMA10.service

# Force datasource selection
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-datasource.cfg <<'EOF'
datasource_list: [ NoCloud, NoCloudNet ]
EOF

cat > /etc/cloud/cloud.cfg.d/99-hostname.cfg <<'EOF'
preserve_hostname: false
EOF

# Disable RightScale datasource noise
cat > /etc/cloud/cloud.cfg.d/90-disable-rightscale.cfg <<'EOF'
datasource:
  RightScale: {enabled: false}
EOF

# Seed fake-hwclock so first boot isn't 1970
date -u '+%Y-%m-%d %H:%M:%S' > /etc/fake-hwclock.data

# Chrony config
mkdir -p /etc/chrony/conf.d
cat >/etc/chrony/conf.d/10-local-sources.conf <<'EOF'
server 192.168.3.5 iburst prefer
pool pool.ntp.org iburst
makestep 1.0 -1
rtcsync
EOF
if ! grep -qE '^[[:space:]]*include[[:space:]]+/etc/chrony/conf.d/\*\.conf' /etc/chrony/chrony.conf 2>/dev/null; then
  echo 'include /etc/chrony/conf.d/*.conf' >> /etc/chrony/chrony.conf
fi

# Lock root
passwd -l root || true

enable_unit ssh.service
enable_unit fake-hwclock.service
enable_unit chrony.service

echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /etc/rootfs-build-info

# sanitize for true first boot
rm -rf /var/lib/cloud
rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log
# Ensure machine-id will be generated on first boot
rm -f /etc/machine-id /var/lib/dbus/machine-id
install -d -m 0755 /var/lib/dbus
: > /etc/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
chmod 0444 /etc/machine-id
CHROOT

cleanup_mounts
trap - EXIT

sudo tar --xattrs --acls --numeric-owner -C "$ROOTFS_DIR" -cpf - . \
  | zstd -19 -T0 -o "$OUT_TAR"
echo "Wrote $OUT_TAR"
