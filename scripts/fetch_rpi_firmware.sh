#!/usr/bin/env bash
set -euo pipefail

OUT="${OUT:-out}"
FW_DIR="$OUT/rpi-firmware"

mkdir -p "$OUT"
rm -rf "$FW_DIR"

git clone --depth=1 https://github.com/raspberrypi/firmware.git "$FW_DIR"

# sanity checks for Pi 5
test -f "$FW_DIR/boot/boot.img"
test -f "$FW_DIR/boot/kernel_2712.img"
test -f "$FW_DIR/boot/bcm2712-rpi-5-b.dtb"
test -d "$FW_DIR/boot/overlays"

echo "Firmware fetched to $FW_DIR"
