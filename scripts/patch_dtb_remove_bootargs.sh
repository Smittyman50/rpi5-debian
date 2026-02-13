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
DTB_OUT="$TMPD/out.dtb"

dtc -I dtb -O dts -o "$DTS" "$DTB"

# Remove any 'bootargs = "...";' line(s) in the chosen node.
# This is intentionally simple; if you want structural editing, we can do that too.
sed -E '/^\s*bootargs\s*=\s*".*";\s*$/d' "$DTS" > "$DTS2"

dtc -I dts -O dtb -o "$DTB_OUT" "$DTS2"

# Replace original
cp -f "$DTB_OUT" "$DTB"

echo "Patched DTB (removed chosen/bootargs): $DTB"
