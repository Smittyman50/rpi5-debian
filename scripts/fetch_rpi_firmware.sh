#!/usr/bin/env bash
set -euo pipefail

OUT="${OUT:-out}"
FW_DIR="$OUT/rpi-firmware"

mkdir -p "$OUT"
rm -rf "$FW_DIR"

git clone --depth=1 --filter=blob:none https://github.com/raspberrypi/firmware.git "$FW_DIR"

# Sanity checks for Pi 5 payloads (boot.img is built later, not sourced here)
test -f "$FW_DIR/boot/kernel_2712.img"
test -f "$FW_DIR/boot/bcm2712-rpi-5-b.dtb"
test -d "$FW_DIR/boot/overlays"
test -f "$FW_DIR/boot/start4.elf"
test -f "$FW_DIR/boot/fixup4.dat"

echo "Firmware fetched OK: $FW_DIR"
