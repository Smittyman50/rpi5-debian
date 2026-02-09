#!/usr/bin/env bash
set -euo pipefail

# Inputs expected in ./out from prior steps:
#   out/boot.img
#   out/initramfs.gz
#   out/artifacts/debian-bookworm-arm64-rootfs.tar.zst
#   out/rpi-firmware/boot/... (for pi-firmware bundle)
#   out/seeds/<serial>/{user-data,meta-data}

rm -rf dist
mkdir -p dist/artifacts dist/seeds

# Shared EEPROM HTTP boot payload
cp -f out/boot.img dist/boot.img

# Optional: if you are doing signed boot later, you can drop boot.sig here too
# (For now, leave it absent unless you build it.)
if [[ -f out/boot.sig ]]; then
  cp -f out/boot.sig dist/boot.sig
fi

# Everything the installer initramfs needs at runtime
cp -f out/artifacts/initramfs.gz dist/artifacts/initramfs.gz
cp -f boot/config.txt dist/config.txt
cp -f boot/cmdline.txt dist/cmdline.txt

# Debian rootfs artifact
cp -f out/artifacts/debian-bookworm-arm64-rootfs.tar.zst dist/artifacts/

# Bundle firmware for NVMe /boot/firmware install (explicit file list)
FW_BOOT="out/rpi-firmware/boot"
test -d "$FW_BOOT" || { echo "Missing $FW_BOOT"; exit 1; }

# Required Pi 5 firmware/kernel payloads
REQ_FILES=(
  "start4.elf"
  "fixup4.dat"
  "kernel_2712.img"
  "bcm2712-rpi-5-b.dtb"
)

for f in "${REQ_FILES[@]}"; do
  test -f "${FW_BOOT}/${f}" || { echo "Missing firmware file: ${FW_BOOT}/${f}"; ls -la "$FW_BOOT" | head -50; exit 1; }
done

test -d "${FW_BOOT}/overlays" || { echo "Missing overlays dir"; ls -la "$FW_BOOT" | head -50; exit 1; }

# Create bundle
tar -C "$FW_BOOT" -cpf - \
  start4.elf fixup4.dat kernel_2712.img bcm2712-rpi-5-b.dtb overlays \
  | zstd -19 -T0 -o dist/artifacts/pi-firmware.tar.zst

# Per-Pi seeds
rsync -a out/seeds/ dist/seeds/

echo "Staged publish payload into ./dist"
