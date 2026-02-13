#!/usr/bin/env bash
set -euo pipefail

OUT="${OUT:-out}"
DTB="${DTB:-$OUT/rpi-firmware/boot/bcm2712-rpi-5-b.dtb}"

apt-get update
apt-get install -y device-tree-compiler

test -f "$DTB"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

DTS="$TMPD/in.dts"
DTS2="$TMPD/out.dts"
DTB2="$TMPD/out.dtb"

# Decompile
dtc -I dtb -O dts -o "$DTS" "$DTB"

# Remove any chosen bootargs assignment line(s)
# This targets lines like: bootargs = "...";
sed -E '/^\s*bootargs\s*=\s*".*";\s*$/d' "$DTS" > "$DTS2"

# Recompile
dtc -I dts -O dtb -o "$DTB2" "$DTS2"

# Replace original
cp -f "$DTB2" "$DTB"

echo "Patched DTB: removed chosen/bootargs from $DTB"
