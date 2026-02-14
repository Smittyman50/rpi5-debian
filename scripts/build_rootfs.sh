#!/usr/bin/env bash
set -euo pipefail

ARCH=arm64
SUITE=bookworm
MIRROR=http://deb.debian.org/debian

ROOTFS_DIR="${ROOTFS_DIR:-out/rootfs}"
OUT_TAR="${OUT_TAR:-out/artifacts/debian-bookworm-arm64-rootfs.tar.zst}"

FALLBACK_USER="smittyman"
FALLBACK_PASSWD_HASH='***REMOVED***'

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

export FALLBACK_USER FALLBACK_PASSWD_HASH

sudo chroot "$ROOTFS_DIR" bash -s <<'CHROOT'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

apt-get update

enable_unit() {
  local u="$1"
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf "/lib/systemd/system/$u" "/etc/systemd/system/multi-user.target.wants/$u" || true
}

mask_unit() {
  local u="$1"
  mkdir -p /etc/systemd/system
  ln -sf /dev/null "/etc/systemd/system/$u" || true
  find /etc/systemd/system -type l -name "$u" -path "*/wants/*" -delete 2>/dev/null || true
}

# Locale
apt-get install -y --no-install-recommends locales
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Core packages: keep ifupdown for DHCP bootstrap on first NVMe boot
apt-get install -y --no-install-recommends \
  systemd-sysv ca-certificates openssh-server sudo \
  cloud-init ifupdown \
  systemd-resolved fake-hwclock chrony kmod iptables nftables \
  iputils-ping libcap2-bin

# ---- IFUPDOWN DHCP BOOTSTRAP (FIRST BOOT FROM NVME) ----
mkdir -p /etc/network/interfaces.d
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

source /etc/network/interfaces.d/*.cfg
EOF

cat > /etc/network/interfaces.d/10-end0-dhcp.cfg <<'EOF'
allow-hotplug end0
iface end0 inet dhcp
EOF

# Enable ifupdown service
enable_unit networking.service

# resolved stub resolver
enable_unit systemd-resolved.service
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true

# serial console getty
enable_unit serial-getty@ttyAMA10.service

# ---- Cloud-init datasource + networking renderer ----
mkdir -p /etc/cloud/cloud.cfg.d

# Ensure NoCloudNet is allowed (matches ds=nocloud-net in cmdline)
cat > /etc/cloud/cloud.cfg.d/99-datasource.cfg <<'EOF'
datasource_list: [ NoCloudNet, None ]
EOF

# Tell cloud-init to use ENI (ifupdown) networking, not netplan
cat > /etc/cloud/cloud.cfg.d/99-network-eni.cfg <<'EOF'
system_info:
  network:
    renderers: ['eni']
EOF

# ---- Kill wait-online delays ----
mask_unit systemd-networkd-wait-online.service
mask_unit systemd-networkd.service

# ---- Fix permissions for cloud-init written files (safe default) ----
for svc in cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service; do
  mkdir -p "/etc/systemd/system/${svc}.d"
  cat > "/etc/systemd/system/${svc}.d/umask.conf" <<'EOF'
[Service]
UMask=0077
EOF
done

# Disable RightScale datasource noise
cat > /etc/cloud/cloud.cfg.d/90-disable-rightscale.cfg <<'EOF'
datasource:
  RightScale: {enabled: false}
EOF

# Ensure ping works for non-root
if [ -x /usr/bin/ping ] && command -v setcap >/dev/null 2>&1; then
  setcap cap_net_raw+ep /usr/bin/ping || true
fi

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

# ---- FALLBACK CONSOLE USER ----
FALLBACK_USER="${FALLBACK_USER:-smittyman}"
FALLBACK_PASSWD_HASH="${FALLBACK_PASSWD_HASH:-}"

if ! id -u "$FALLBACK_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "$FALLBACK_USER"
fi

if [ -n "${FALLBACK_PASSWD_HASH:-}" ]; then
  usermod -p "$FALLBACK_PASSWD_HASH" "$FALLBACK_USER" || true
  passwd -u "$FALLBACK_USER" 2>/dev/null || true
else
  passwd -l "$FALLBACK_USER" 2>/dev/null || true
fi

echo "$FALLBACK_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-fallback-user
chmod 0440 /etc/sudoers.d/90-fallback-user

echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /etc/rootfs-build-info

apt-get clean
rm -rf /var/lib/apt/lists/*

# sanitize for true first boot
rm -rf /var/lib/cloud
rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log
rm -f /etc/machine-id
rm -f /var/lib/dbus/machine-id
CHROOT

cleanup_mounts
trap - EXIT

sudo tar --xattrs --acls --numeric-owner -C "$ROOTFS_DIR" -cpf - . \
  | zstd -19 -T0 -o "$OUT_TAR"
echo "Wrote $OUT_TAR"
