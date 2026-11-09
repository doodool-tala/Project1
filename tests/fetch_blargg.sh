#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=tests/roms
if [ -d "$DEST/gb-test-roms-master" ]; then
    echo "Blargg ROMs already present in $DEST/gb-test-roms-master"
    exit 0
fi
mkdir -p "$DEST"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
echo "Downloading retrio/gb-test-roms..."
curl -fsSL -o "$tmp" https://github.com/retrio/gb-test-roms/archive/refs/heads/master.tar.gz
tar xzf "$tmp" -C "$DEST"
echo "Installed $DEST/gb-test-roms-master"
