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

is_mounted() { mountpoint -q "$1" 2>/dev/null; }

cleanup_mounts() {
  set +e
  # Unmount in reverse order (run before dev)
  is_mounted "$ROOTFS_DIR/dev/pts" && sudo umount -lf "$ROOTFS_DIR/dev/pts"
  is_mounted "$ROOTFS_DIR/run"     && sudo umount -lf "$ROOTFS_DIR/run"
  is_mounted "$ROOTFS_DIR/dev"     && sudo umount -lf "$ROOTFS_DIR/dev"
  is_mounted "$ROOTFS_DIR/proc"    && sudo umount -lf "$ROOTFS_DIR/proc"
  is_mounted "$ROOTFS_DIR/sys"     && sudo umount -lf "$ROOTFS_DIR/sys"
  true
}
trap cleanup_mounts EXIT

# Mount only if not already mounted; tolerate failures where appropriate
is_mounted "$ROOTFS_DIR/proc" || sudo mount -t proc  proc  "$ROOTFS_DIR/proc"
is_mounted "$ROOTFS_DIR/sys"  || sudo mount -t sysfs sys   "$ROOTFS_DIR/sys"
is_mounted "$ROOTFS_DIR/dev"  || sudo mount --bind /dev    "$ROOTFS_DIR/dev"
is_mounted "$ROOTFS_DIR/dev/pts" || sudo mount -t devpts devpts "$ROOTFS_DIR/dev/pts" -o gid=5,mode=620 2>/dev/null || true
is_mounted "$ROOTFS_DIR/run" || sudo mount -t tmpfs tmpfs "$ROOTFS_DIR/run" 2>/dev/null || true

# --- CHROOT CONFIG (single-quoted heredoc prevents host-side $ expansion) ---
sudo chroot "$ROOTFS_DIR" bash -s <<'CHROOT'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

apt-get update

# ---- systemd unit enable/mask helpers (work in chroot without PID1) ----
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

# Core packages
# NOTE: We intentionally include ifupdown for first-boot DHCP bootstrap.
# Netplan stays installed (for later), but is not relied on for initial seed fetch.
apt-get install -y --no-install-recommends \
  systemd-sysv ca-certificates openssh-server sudo cloud-init netplan.io \
  ifupdown \
  systemd-resolved fake-hwclock chrony kmod iptables nftables \
  iputils-ping libcap2-bin

# ---- IFUPDOWN BOOTSTRAP DHCP (FIRST BOOT) ----
# Keep it simple and deterministic: DHCP on likely interface names.
# (if one doesn't exist, ifupdown ignores it)
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

allow-hotplug end0
iface end0 inet dhcp

allow-hotplug eth0
iface eth0 inet dhcp
EOF

rm -rf /etc/network/interfaces.d/* 2>/dev/null || true

# Ensure classic ifupdown service is enabled (Debian uses networking.service)
enable_unit networking.service

# resolved is fine to run with ifupdown; provides stub resolver
enable_unit systemd-resolved.service
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true

# Prefer netplan renderer in cloud-init (kept for later when you switch)
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-renderer.cfg <<'EOF'
system_info:
  network:
    renderers: ['netplan']
EOF

# ---- REMOVE PREVIOUS "NETWORKD WAIT-ONLINE" GATING ----
# Do NOT force cloud-init to wait for network-online.target; it caused failures.
rm -f /etc/systemd/system/cloud-init-local.service.d/network-online.conf 2>/dev/null || true
rm -f /etc/systemd/system/cloud-init.service.d/network-online.conf 2>/dev/null || true
rm -rf /etc/systemd/system/systemd-networkd-wait-online.service.d 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/systemd-networkd-wait-online.service 2>/dev/null || true

# ---- STOP USING SYSTEMD-NETWORKD AS A BOOTSTRAP MECHANISM ----
# If you later switch to netplan+networkd in the seed, you can enable then.
rm -f /etc/systemd/system/multi-user.target.wants/systemd-networkd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/systemd-resolved.service 2>/dev/null || true
enable_unit systemd-resolved.service

# ---- Fix netplan "permissions too open" by forcing cloud-init to write secure perms ----
mkdir -p /etc/systemd/system/cloud-init.service.d
cat > /etc/systemd/system/cloud-init.service.d/umask.conf <<'EOF'
[Service]
UMask=0077
EOF

mkdir -p /etc/systemd/system/cloud-init-local.service.d
cat > /etc/systemd/system/cloud-init-local.service.d/umask.conf <<'EOF'
[Service]
UMask=0077
EOF

mkdir -p /etc/systemd/system/cloud-config.service.d
cat > /etc/systemd/system/cloud-config.service.d/umask.conf <<'EOF'
[Service]
UMask=0077
EOF

mkdir -p /etc/systemd/system/cloud-final.service.d
cat > /etc/systemd/system/cloud-final.service.d/umask.conf <<'EOF'
[Service]
UMask=0077
EOF

# ---- Cloud-init keyboard module failure: remove keyboard module instead of "disable" ----
# Minimal images often trip over keyboard config. This prevents cloud-config from failing.
cat > /etc/cloud/cloud.cfg.d/05-disable-keyboard-module.cfg <<'EOF'
#cloud-config
cloud_config_modules:
  - emit_upstart
  - disk_setup
  - mounts
  - set_hostname
  - update_hostname
  - update_etc_hosts
  - ca_certs
  - rsyslog
  - users_groups
  - ssh
EOF

# Remove prior keyboard disabled config if it existed
rm -f /etc/cloud/cloud.cfg.d/90-keyboard-disabled.cfg 2>/dev/null || true

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

# Chrony config (Debian)
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

# Lock root account
passwd -l root || true

enable_unit ssh.service
enable_unit fake-hwclock.service
enable_unit chrony.service

echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /etc/rootfs-build-info

apt-get clean
rm -rf /var/lib/apt/lists/*

# --- sanitize image so first boot is truly first boot ---
rm -rf /var/lib/cloud
rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log
rm -f /etc/machine-id
rm -f /var/lib/dbus/machine-id
CHROOT

# tear down mounts BEFORE packaging
cleanup_mounts
trap - EXIT

# Create compressed artifact
sudo tar --xattrs --acls --numeric-owner -C "$ROOTFS_DIR" -cpf - . \
  | zstd -19 -T0 -o "$OUT_TAR"
echo "Wrote $OUT_TAR"
