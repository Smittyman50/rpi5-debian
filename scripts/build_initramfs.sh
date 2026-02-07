#!/usr/bin/env bash
set -euo pipefail

OUT="${OUT:-out}"
HTTP_BASE="${HTTP_BASE:-http://10.0.10.10/pi5}"

rm -rf "$OUT/initramfs"
mkdir -p "$OUT/initramfs"/{bin,sbin,etc,proc,sys,dev,tmp,run}

# REQUIRED: provide a static busybox at installer/busybox-static
install -m 0755 installer/busybox-static "$OUT/initramfs/bin/busybox"
ln -sf busybox "$OUT/initramfs/bin/sh"
ln -sf busybox "$OUT/initramfs/bin/wget"
ln -sf busybox "$OUT/initramfs/bin/ip"
ln -sf busybox "$OUT/initramfs/bin/udhcpc"

# template init to bake HTTP_BASE
sed "s|^HTTP_BASE=.*|HTTP_BASE=\"${HTTP_BASE}\"|g" installer/init > "$OUT/initramfs/init"
chmod +x "$OUT/initramfs/init"

( cd "$OUT/initramfs" && find . -print0 | cpio --null -H newc -o ) | gzip -9 > "$OUT/initramfs.gz"
echo "Wrote $OUT/initramfs.gz"
