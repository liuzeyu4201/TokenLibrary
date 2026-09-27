#!/bin/sh
# Reads APP_VERSION and APP_BUILD without sourcing .env, then writes the xcconfig the app builds with.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
OUT="$SCRIPT_DIR/../Config/AppVersion.local.xcconfig"

read_key() {
  file=$1
  key=$2
  [ -f "$file" ] || return 0
  awk -F= -v k="$key" '
    /^[[:space:]]*#/ { next }
    {
      name=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != k) next
      val=substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (val ~ /^["'"'"'].*["'"'"']$/) val=substr(val, 2, length(val) - 2)
      found=val
    }
    END { if (found != "") print found }
  ' "$file"
}

value_for() {
  key=$1
  from_env=$(read_key "$ROOT/.env" "$key" || true)
  if [ -n "$from_env" ]; then
    printf '%s' "$from_env"
    return
  fi
  from_example=$(read_key "$ROOT/.env.example" "$key" || true)
  if [ -n "$from_example" ]; then
    printf '%s' "$from_example"
    return
  fi
  echo "missing $key in .env and .env.example" >&2
  exit 1
}

VERSION=$(value_for APP_VERSION)
BUILD=$(value_for APP_BUILD)
printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){1,3}$' || {
  echo "APP_VERSION must look like 1.0.0" >&2
  exit 1
}
printf '%s' "$BUILD" | grep -Eq '^[0-9]+$' || {
  echo "APP_BUILD must be a number" >&2
  exit 1
}

mkdir -p "$(dirname "$OUT")"
tmp="$OUT.tmp"
cat > "$tmp" <<EOF
// Generated from .env. Do not edit.
APP_VERSION = $VERSION
APP_BUILD = $BUILD
MARKETING_VERSION = $VERSION
CURRENT_PROJECT_VERSION = $BUILD
EOF
mv "$tmp" "$OUT"
