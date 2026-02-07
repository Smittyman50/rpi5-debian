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
cp -f out/initramfs.gz dist/initramfs.gz
cp -f boot/config.txt dist/config.txt
cp -f boot/cmdline.txt dist/cmdline.txt

# Debian rootfs artifact
cp -f out/artifacts/debian-bookworm-arm64-rootfs.tar.zst dist/artifacts/

# Bundle firmware for NVMe /boot/firmware install
tar -C out/rpi-firmware/boot -cpf - \
  start*.elf fixup*.dat overlays bcm2712-*.dtb kernel_2712.img \
  | zstd -19 -T0 -o dist/artifacts/pi-firmware.tar.zst

# Per-Pi seeds
rsync -a out/seeds/ dist/seeds/

echo "Staged publish payload into ./dist"
