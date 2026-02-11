#!/usr/bin/env bash
set -euo pipefail

# Modes:
#   PUBLISH_MODE=all   -> stage boot artifacts + seeds (default; matches current behavior)
#   PUBLISH_MODE=boot  -> stage only boot artifacts (no dist/seeds)
#   PUBLISH_MODE=seeds -> stage only seeds (no boot artifacts)
PUBLISH_MODE="${PUBLISH_MODE:-all}"

rm -rf dist
mkdir -p dist

want_boot=0
want_seeds=0
case "$PUBLISH_MODE" in
  all)   want_boot=1; want_seeds=1 ;;
  boot)  want_boot=1; want_seeds=0 ;;
  seeds) want_boot=0; want_seeds=1 ;;
  *) echo "ERROR: invalid PUBLISH_MODE='$PUBLISH_MODE' (use all|boot|seeds)"; exit 1 ;;
esac

# ---------------------------
# Boot/kernel artifacts stage
# ---------------------------
if [[ "$want_boot" -eq 1 ]]; then
  mkdir -p dist/artifacts

  # Shared EEPROM HTTP boot payload
  test -f out/boot.img || { echo "Missing out/boot.img"; exit 1; }
  cp -f out/boot.img dist/boot.img

  # Optional: signed boot
  if [[ -f out/boot.sig ]]; then
    cp -f out/boot.sig dist/boot.sig
  fi

  # Everything the installer initramfs needs at runtime
  test -f out/artifacts/initramfs.gz || { echo "Missing out/artifacts/initramfs.gz"; exit 1; }
  cp -f out/artifacts/initramfs.gz dist/artifacts/initramfs.gz

  test -f boot/config.txt || { echo "Missing boot/config.txt"; exit 1; }
  test -f boot/cmdline.txt || { echo "Missing boot/cmdline.txt"; exit 1; }
  cp -f boot/config.txt dist/config.txt
  cp -f boot/cmdline.txt dist/cmdline.txt

  # Debian rootfs artifact
  test -f out/artifacts/debian-bookworm-arm64-rootfs.tar.zst || {
    echo "Missing out/artifacts/debian-bookworm-arm64-rootfs.tar.zst"; exit 1;
  }
  cp -f out/artifacts/debian-bookworm-arm64-rootfs.tar.zst dist/artifacts/

  # Bundle firmware for NVMe /boot/firmware install (explicit file list)
  FW_BOOT="out/rpi-firmware/boot"
  test -d "$FW_BOOT" || { echo "Missing $FW_BOOT"; exit 1; }

  REQ_FILES=(
    "start4.elf"
    "fixup4.dat"
    "kernel_2712.img"
    "bcm2712-rpi-5-b.dtb"
  )

  for f in "${REQ_FILES[@]}"; do
    test -f "${FW_BOOT}/${f}" || {
      echo "Missing firmware file: ${FW_BOOT}/${f}"
      ls -la "$FW_BOOT" | head -50
      exit 1
    }
  done

  test -d "${FW_BOOT}/overlays" || {
    echo "Missing overlays dir"
    ls -la "$FW_BOOT" | head -50
    exit 1
  }

  tar -C "$FW_BOOT" -cpf - \
    start4.elf fixup4.dat kernel_2712.img bcm2712-rpi-5-b.dtb overlays \
    | zstd -19 -T0 -o dist/artifacts/pi-firmware.tar.zst

  # Bundle kernel modules that match the Pi kernel we ship
  FW_MOD="out/rpi-firmware/modules"
  test -d "$FW_MOD" || { echo "Missing $FW_MOD"; exit 1; }

  # Prefer the Pi 5 kernel flavor: v8-16k+
  if [ -z "${KVER:-}" ]; then
    KVER="$(ls -1 "$FW_MOD" 2>/dev/null | sort -V | grep -E '(^|-)v8-16k\+$' | tail -n1 || true)"
  fi

  # Fallback: any v8+ if v8-16k+ not present
  if [ -z "${KVER:-}" ]; then
    KVER="$(ls -1 "$FW_MOD" 2>/dev/null | sort -V | grep -E '(^|-)v8\+$' | tail -n1 || true)"
  fi

  # Last resort: latest directory at all
  if [ -z "${KVER:-}" ]; then
    KVER="$(ls -1 "$FW_MOD" 2>/dev/null | sort -V | tail -n1 || true)"
  fi

  test -n "${KVER:-}" || { echo "No module versions found under $FW_MOD"; exit 1; }

  test -d "$FW_MOD/$KVER" || {
    echo "Missing modules for $KVER at $FW_MOD/$KVER"
    echo "Available:"
    ls -la "$FW_MOD" || true
    exit 1
  }

  echo "Using KVER=$KVER"
  tar -C "$FW_MOD" -cpf - "$KVER" | zstd -19 -T0 -o dist/artifacts/pi-modules.tar.zst
fi

# -----------
# Seeds stage
# -----------
if [[ "$want_seeds" -eq 1 ]]; then
  mkdir -p dist/seeds
  test -d out/seeds || { echo "Missing out/seeds (run render_seeds.py first)"; exit 1; }
  rsync -a out/seeds/ dist/seeds/
fi

echo "Staged publish payload into ./dist (PUBLISH_MODE=$PUBLISH_MODE)"
