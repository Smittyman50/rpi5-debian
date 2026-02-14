#!/usr/bin/env bash
set -euo pipefail

ARCH=arm64
SUITE=bookworm
MIRROR=http://deb.debian.org/debian

ROOTFS_DIR="${ROOTFS_DIR:-out/rootfs}"
OUT_TAR="${OUT_TAR:-out/artifacts/debian-bookworm-arm64-rootfs.tar.zst}"

FALLBACK_USER="smittyman"
FALLBACK_PASSWD_HASH="***REMOVED***"

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

# Pass fallback hash into chroot safely
export FALLBACK_USER FALLBACK_PASSWD_HASH

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
apt-get install -y --no-install-recommends \
  systemd-sysv ca-certificates openssh-server sudo cloud-init netplan.io \
  ifupdown \
  systemd-resolved fake-hwclock chrony kmod iptables nftables \
  iputils-ping libcap2-bin

# ---- IFUPDOWN BOOTSTRAP DHCP (FIRST BOOT FROM NVME) ----
# IMPORTANT: do NOT run DHCP on a possibly-nonexistent interface name, or networking.service can fail.
# DHCP ONLY on end0; keep eth0 present but manual so ifupdown doesn't error out.
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto end0
iface end0 inet dhcp
EOF

rm -rf /etc/network/interfaces.d/* 2>/dev/null || true

# Enable classic ifupdown service (deterministic in chroot)
enable_unit networking.service

# resolved provides stub resolver; fine with ifupdown
enable_unit systemd-resolved.service
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true

# Make sure serial console login works
enable_unit serial-getty@ttyAMA10.service

# Prefer netplan renderer for later (when cloud-init writes 50-cloud-init.yaml)
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-renderer.cfg <<'EOF'
#cloud-config
system_info:
  network:
    renderers: ['netplan']
EOF

# ---- DO NOT GATE CLOUD-INIT ON WAIT-ONLINE ----
rm -f /etc/systemd/system/cloud-init-local.service.d/network-online.conf 2>/dev/null || true
rm -f /etc/systemd/system/cloud-init.service.d/network-online.conf 2>/dev/null || true
rm -rf /etc/systemd/system/systemd-networkd-wait-online.service.d 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/systemd-networkd-wait-online.service 2>/dev/null || true

# Do not pre-enable networkd in the base image (you can enable later from seed)
rm -f /etc/systemd/system/multi-user.target.wants/systemd-networkd.service 2>/dev/null || true

# ---- Fix netplan "permissions too open" (cloud-init writes netplan files) ----
for svc in cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service; do
  mkdir -p "/etc/systemd/system/${svc}.d"
  cat > "/etc/systemd/system/${svc}.d/umask.conf" <<'EOF'
[Service]
UMask=0077
EOF
done

# ---- Reduce cloud-init module fragility (optional but helps minimal images) ----
# If you keep keyboard in your user-data, ensure cloud-init doesn't hard-fail on it.
# We do NOT remove major modules; just avoid known breakage in minimal console contexts.
cat > /etc/cloud/cloud.cfg.d/05-avoid-keyboard-failure.cfg <<'EOF'
#cloud-config
# Leave defaults, but if keyboard module breaks your build you can switch to an explicit module list.
EOF

# Disable RightScale datasource noise
cat > /etc/cloud/cloud.cfg.d/90-disable-rightscale.cfg <<'EOF'
#cloud-config
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

# Lock root account (keep locked; use fallback user instead)
passwd -l root || true

enable_unit ssh.service
enable_unit fake-hwclock.service
enable_unit chrony.service

# ---- FALLBACK CONSOLE USER (so you can recover even if cloud-init fails) ----
# Uses env FALLBACK_PASSWD_HASH passed from host. If empty, we create the user locked.
FALLBACK_USER="${FALLBACK_USER:-smittyman}"
FALLBACK_PASSWD_HASH="${FALLBACK_PASSWD_HASH:-}"

if ! id -u "$FALLBACK_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "$FALLBACK_USER"
fi

if [ -n "${FALLBACK_PASSWD_HASH:-}" ]; then
  usermod -p "$FALLBACK_PASSWD_HASH" "$FALLBACK_USER" || true
  passwd -u "$FALLBACK_USER" 2>/dev/null || true
else
  # locked unless you provide a hash
  passwd -l "$FALLBACK_USER" 2>/dev/null || true
fi

# Allow sudo without password for recovery (adjust later if desired)
echo "$FALLBACK_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-fallback-user
chmod 0440 /etc/sudoers.d/90-fallback-user

echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /etc/rootfs-build-info

apt-get clean
rm -rf /var/lib/apt/lists/*

# --- sanitize image so first boot is truly first boot ---
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
