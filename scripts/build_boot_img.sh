#!/usr/bin/env bash
set -euo pipefail

OUT="${OUT:-out}"
BOOTIMG_SIZE="${BOOTIMG_SIZE:-96M}"

FW_BOOT="$OUT/rpi-firmware/boot"

mkdir -p "$OUT"

# Create FAT image
rm -f "$OUT/boot.img"
truncate -s "$BOOTIMG_SIZE" "$OUT/boot.img"
mkfs.vfat -F32 -n BOOT "$OUT/boot.img"

# Copy required items into boot.img (using mtools)
sudo apt-get update
sudo apt-get install -y mtools dosfstools

# Firmware + DTB + overlays + kernel
mcopy -i "$OUT/boot.img" "$FW_BOOT"/start4.elf ::
mcopy -i "$OUT/boot.img" "$FW_BOOT"/fixup4.dat ::
mcopy -i "$OUT/boot.img" "$FW_BOOT"/bcm2712-rpi-5-b.dtb ::
mcopy -i "$OUT/boot.img" "$FW_BOOT"/kernel_2712.img ::

mmd  -i "$OUT/boot.img" ::/overlays
mcopy -i "$OUT/boot.img" -s "$FW_BOOT"/overlays/* ::/overlays/

# Your boot config + initramfs
mcopy -i "$OUT/boot.img" boot/config.txt ::
mcopy -i "$OUT/boot.img" boot/cmdline.txt ::
mcopy -i "$OUT/boot.img" "$OUT/initramfs.gz" ::initramfs.gz

echo "Built $OUT/boot.img"
