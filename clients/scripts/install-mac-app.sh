#!/bin/sh
# Replaces the one Mac app the user opens. Build products elsewhere are not extra copies.
set -eu
SRC="${BUILT_PRODUCTS_DIR:-}/TokenLibrary.app"
DEST="${HOME}/Applications/TokenLibrary.app"
if [ ! -d "$SRC" ]; then
  echo "No built TokenLibrary.app to install." >&2
  exit 0
fi
mkdir -p "${HOME}/Applications"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
codesign --force --deep --sign - "$DEST" >/dev/null
echo "Updated $DEST"
