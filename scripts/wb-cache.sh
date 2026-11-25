#!/bin/bash
# Shared cache helpers for the unified PT1570 rtw89 workflow.
# Usage:
#   BOARD=pt1570-r10 bash scripts/wb-cache.sh key ROOT
#   BOARD=pt1570-r10 bash scripts/wb-cache.sh prepare ROOT
#   BOARD=pt1570-r10 bash scripts/wb-cache.sh stats ROOT
set -e

CMD="${1:-}"; shift || true
ROOT="${1:-.}"; shift || true

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

case "$CMD" in
  key)
    BOARD="${BOARD:-board}"
    B=$(printf '%s' "$BOARD" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')
    SRC_HASH="${SOURCE_HASH:-unknown}"
    ASSET_HASH="${ASSET_HASH:-unknown}"
    S="${SRC_HASH:0:12}"
    A="${ASSET_HASH:0:12}"
    emit KEY "wb-${B}-build-${S}-${A}"
    emit PREFIX "wb-${B}-build-${S}-"
    emit CCACHE_KEY "wb-${B}-ccache-${S}-${A}"
    emit CCACHE_PREFIX "wb-${B}-ccache-${S}-"
    WEEK=$(date -u +%Y%W)
    emit DL_KEY "wb-${B}-dl-${WEEK}"
    emit DL_PREFIX "wb-${B}-dl-"
    ;;

  prepare)
    # actions/cache restores files only. Freshly checked-out source has "now"
    # mtimes while cached OpenWrt stamps are older, so make rebuilds the
    # toolchain even on a cache hit. Age source mtimes, then refresh stamps.
    OLD="2020-01-01 00:00:00 UTC"
    find "$ROOT" \
         -path "$ROOT/.git" -prune -o \
         -path "$ROOT/build_dir" -prune -o \
         -path "$ROOT/staging_dir" -prune -o \
         -path "$ROOT/.ccache" -prune -o \
         -path "$ROOT/dl" -prune -o \
         -path "$ROOT/bin" -prune -o \
         -path "$ROOT/tmp" -prune -o \
         -type f -exec touch -d "$OLD" {} + 2>/dev/null || true

    find "$ROOT/build_dir" "$ROOT/staging_dir" \
         -type f \( -name '.*' -o -name '*stamp*' -o -name '.built' \
                    -o -name '.prepared' -o -name '.configured' \
                    -o -name '.compiled' -o -name '.installed' \) \
         -exec touch {} + 2>/dev/null || true

    mkdir -p "$ROOT/tmp" "$ROOT/.ccache"
    echo 1 > "$ROOT/tmp/.build"
    echo "cache prepared: source mtimes aged, cached stamps refreshed"
    ;;

  stats)
    echo "=== ccache stats ==="
    if command -v ccache >/dev/null 2>&1; then
      CCACHE_DIR="$ROOT/.ccache" ccache -s 2>/dev/null || true
    fi
    echo "=== cache dirs ==="
    du -sh "$ROOT/.ccache" "$ROOT/dl" "$ROOT/build_dir" "$ROOT/staging_dir" 2>/dev/null || true
    ;;

  *)
    echo "unknown command: $CMD" >&2
    exit 2
    ;;
esac
