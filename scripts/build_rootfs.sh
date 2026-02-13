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
  # Unmount in reverse order
  is_mounted "$ROOTFS_DIR/dev/pts" && sudo umount -lf "$ROOTFS_DIR/dev/pts"
  is_mounted "$ROOTFS_DIR/dev"     && sudo umount -lf "$ROOTFS_DIR/dev"
  is_mounted "$ROOTFS_DIR/proc"    && sudo umount -lf "$ROOTFS_DIR/proc"
  is_mounted "$ROOTFS_DIR/sys"     && sudo umount -lf "$ROOTFS_DIR/sys"
  is_mounted "$ROOTFS_DIR/run"     && sudo umount -lf "$ROOTFS_DIR/run"
  true
}
trap cleanup_mounts EXIT

# Mount only if not already mounted; tolerate failures where appropriate
is_mounted "$ROOTFS_DIR/proc" || sudo mount -t proc  proc  "$ROOTFS_DIR/proc"
is_mounted "$ROOTFS_DIR/sys"  || sudo mount -t sysfs sys   "$ROOTFS_DIR/sys"
is_mounted "$ROOTFS_DIR/dev"  || sudo mount --bind /dev    "$ROOTFS_DIR/dev"

# devpts can fail on some constrained runners; keep going if it does
is_mounted "$ROOTFS_DIR/dev/pts" || sudo mount -t devpts devpts "$ROOTFS_DIR/dev/pts" -o gid=5,mode=620 2>/dev/null || true

# /run helps some postinst scripts; safe to ignore failure
is_mounted "$ROOTFS_DIR/run" || sudo mount -t tmpfs tmpfs "$ROOTFS_DIR/run" 2>/dev/null || true

# --- CHROOT CONFIG (fed via single-quoted heredoc to prevent host-side $ expansion) ---
sudo chroot "$ROOTFS_DIR" bash -s <<'CHROOT'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# Safe UTF-8 locale for noninteractive installs
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
  # best-effort: remove any existing wants symlinks that may pull it in
  find /etc/systemd/system -type l -name "$u" -path "*/wants/*" -delete 2>/dev/null || true
}

# Install locales early so postinst scripts stop complaining
apt-get install -y --no-install-recommends locales

# Generate and set default locale (adjust if you prefer)
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Core packages for your image
apt-get install -y --no-install-recommends \
  systemd-sysv ca-certificates openssh-server sudo cloud-init netplan.io \
  systemd-resolved fake-hwclock chrony kmod iptables nftables \
  iputils-ping libcap2-bin

# Remove/disable ifupdown networking so it can't override netplan
apt-get purge -y ifupdown || true
mask_unit networking.service

printf "auto lo\niface lo inet loopback\n" > /etc/network/interfaces
rm -rf /etc/network/interfaces.d/* 2>/dev/null || true

# Enable networkd/resolved and set resolv.conf symlink (do not rely on systemctl in chroot)
enable_unit systemd-networkd.service
enable_unit systemd-resolved.service
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true

# Prefer netplan renderer in cloud-init
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-renderer.cfg <<'EOF'
system_info:
  network:
    renderers: ['netplan']
EOF

# --- FIRST BOOT DHCP BOOTSTRAP (so NoCloud HTTP seed can be fetched) ---

# Ensure networkd/resolved are enabled (do not rely on systemctl in chroot)
enable_unit systemd-networkd.service
enable_unit systemd-resolved.service

# Allow wait-online, but cap it so we don't hang forever
# (NoCloudNet needs a real IPv4 before cloud-init tries to fetch seed)
mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d
cat > /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf <<'EOF'
[Service]
TimeoutStartSec=20s
EOF

enable_unit systemd-networkd-wait-online.service

# Make cloud-init-local wait for network-online (provided by wait-online)
# mkdir -p /etc/systemd/system/cloud-init-local.service.d
# cat > /etc/systemd/system/cloud-init-local.service.d/network-online.conf <<'EOF'
# [Unit]
# Wants=network-online.target
# After=network-online.target
# EOF

# (Optional but recommended) Also apply to cloud-init.service
# mkdir -p /etc/systemd/system/cloud-init.service.d
# cat > /etc/systemd/system/cloud-init.service.d/network-online.conf <<'EOF'
# [Unit]
# Wants=network-online.target
# After=network-online.target
# EOF

# Bootstrap DHCP on end0 for initial seed fetch
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/05-bootstrap-dhcp.network <<'EOF'
[Match]
Name=end0
Name=eth0
Name=en*

[Link]
RequiredForOnline=yes

[Network]
DHCP=ipv4
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=true
UseRoutes=true
EOF

# Make sure resolv.conf points at resolved (safe even if you later override)
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true

# After cloud-init succeeds (boot-finished + netplan exists), remove bootstrap DHCP
cat > /usr/local/sbin/disable-bootstrap-dhcp.sh <<'EOF'
#!/bin/sh
set -eu

BOOTFINISHED="/var/lib/cloud/instance/boot-finished"
NETPLAN_CI="/etc/netplan/50-cloud-init.yaml"
BOOTSTRAP="/etc/systemd/network/05-bootstrap-dhcp.network"

# Only act after cloud-init completed at least once
[ -e "$BOOTFINISHED" ] || exit 0

# Only remove bootstrap if cloud-init actually produced netplan
[ -s "$NETPLAN_CI" ] || exit 0

if [ -e "$BOOTSTRAP" ]; then
  rm -f "$BOOTSTRAP"
  # Best-effort restart; if systemctl works at runtime, fine, otherwise just exit.
  systemctl restart systemd-networkd.service 2>/dev/null || true
fi

# Disable the service by removing the wants symlink (works without systemctl)
rm -f /etc/systemd/system/multi-user.target.wants/disable-bootstrap-dhcp.service 2>/dev/null || true
exit 0
EOF
chmod 0755 /usr/local/sbin/disable-bootstrap-dhcp.sh

cat > /etc/systemd/system/disable-bootstrap-dhcp.service <<'EOF'
[Unit]
Description=Disable first-boot DHCP bootstrap after cloud-init finishes
After=cloud-final.service
Wants=cloud-final.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/disable-bootstrap-dhcp.sh

[Install]
WantedBy=multi-user.target
EOF

enable_unit disable-bootstrap-dhcp.service

# Ensure ping works for non-root by setting cap_net_raw (stored in xattrs)
if [ -x /usr/bin/ping ] && command -v setcap >/dev/null 2>&1; then
  setcap cap_net_raw+ep /usr/bin/ping || true
fi

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

# Ensure chrony.conf includes conf.d
if ! grep -qE '^[[:space:]]*include[[:space:]]+/etc/chrony/conf.d/\*\.conf' /etc/chrony/chrony.conf 2>/dev/null; then
  echo 'include /etc/chrony/conf.d/*.conf' >> /etc/chrony/chrony.conf
fi

# Lock root account
passwd -l root || true

enable_unit ssh.service
enable_unit fake-hwclock.service
enable_unit chrony.service

mkdir -p /etc/cloud/cloud.cfg.d

cat > /etc/cloud/cloud.cfg.d/90-keyboard-disabled.cfg <<'EOF'
keyboard:
  config: disabled
EOF

cat > /etc/cloud/cloud.cfg.d/90-disable-rightscale.cfg <<'EOF'
datasource:
  RightScale: {enabled: false}
EOF

echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /etc/rootfs-build-info

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

# --- sanitize image so first boot is truly first boot ---
rm -rf /var/lib/cloud
rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log
rm -f /etc/machine-id
rm -f /var/lib/dbus/machine-id
CHROOT

# tear down mounts BEFORE packaging (prevents tar walking /proc)
cleanup_mounts
trap - EXIT

# Create compressed artifact
sudo tar --xattrs --acls --numeric-owner -C "$ROOTFS_DIR" -cpf - . \
  | zstd -19 -T0 -o "$OUT_TAR"
echo "Wrote $OUT_TAR"
