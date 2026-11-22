#!/bin/bash
# Fetch the latest MGKeys headers compiled by Native/MGKeysBridge.m.
#
# Usage:
#   ./fetch_MGKeys.sh
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$ROOT_DIR/Vendor/MGKeys"
REF="master"
BASE_URL="https://raw.githubusercontent.com/PoomSmart/MGKeys/$REF"
FILES=(mapping.h mapping-legacy.h struct.h LICENSE)

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required." >&2
    exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mgkeys.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

for file in "${FILES[@]}"; do
    echo "Fetching $REF/$file"
    if ! curl -fsSL --retry 2 "$BASE_URL/$file" -o "$TMP_DIR/$file"; then
        echo "Error: failed to fetch $file from $BASE_URL" >&2
        exit 1
    fi
done

require_marker() {
    if ! grep -q "$2" "$TMP_DIR/$1"; then
        echo "Error: $1 does not look like the expected upstream file." >&2
        exit 1
    fi
}

require_marker mapping.h 'keyMappingTable'
require_marker mapping-legacy.h 'keyMappingTableLegacy'
require_marker struct.h 'struct tKeyMapping'
require_marker LICENSE 'MIT License'

mkdir -p "$DEST_DIR"
for file in "${FILES[@]}"; do
    cp "$TMP_DIR/$file" "$DEST_DIR/$file"
done

RESOLVED_SHA="$(git ls-remote https://github.com/PoomSmart/MGKeys.git "$REF" 2>/dev/null | awk '{print $1}' | head -n 1 || true)"
if [[ -z "$RESOLVED_SHA" ]]; then
    RESOLVED_SHA="unknown"
fi

echo
echo "Updated: $DEST_DIR"
echo "Upstream: $REF @ $RESOLVED_SHA"
