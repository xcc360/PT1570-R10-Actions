#!/bin/bash
# Shared CI helpers for the PT1570-H10-CU rtw89 experimental workflow.
# Usage:
#   bash rtw89-h10/wb-build-common.sh key ROOT
#   bash rtw89-h10/wb-build-common.sh dlkey ROOT
#   bash rtw89-h10/wb-build-common.sh prepare ROOT
#   bash rtw89-h10/wb-build-common.sh jobs ROOT
#   bash rtw89-h10/wb-build-common.sh check-packages ROOT PROFILE
#   bash rtw89-h10/wb-build-common.sh diagnose LOG
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
    SRC_REF="${SOURCE_REF:-2df200550b73}"
    SRC_HASH="${SOURCE_HASH:-unknown}"
    SLUG=$(printf '%s' "$SRC_REF" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')
    [ -n "$SLUG" ] || SLUG=unknown
    emit KEY "rtw89-h10-${SLUG}-${SRC_HASH}"
    emit PREFIX "rtw89-h10-${SLUG}-"
    ;;

  dlkey)
    WEEK=$(date -u +%Y%W)
    emit DL_KEY "rtw89-h10-dl-${WEEK}"
    emit DL_PREFIX "rtw89-h10-dl-"
    ;;

  prepare)
    # actions/cache restores files only. Touch stamps and write tmp/.build so
    # the restored toolchain is not rebuilt from scratch ("fake hit").
    mkdir -p "$ROOT/.ccache" \
             "$ROOT/staging_dir/host" \
             "$ROOT/staging_dir/hostpkg" \
             "$ROOT/staging_dir/toolchain" \
             "$ROOT/tmp"
    find "$ROOT/staging_dir" \
         \( -path '*/staging_dir/host*' -o -path '*/staging_dir/tool*' \) \
         -type f -name '*stamp*' -exec touch {} + 2>/dev/null || true
    echo 1 > "$ROOT/tmp/.build"
    echo "cache prepared: stamps touched, tmp/.build written"
    ;;

  jobs)
    awk -v p="$(nproc)" '/^MemAvailable:/{m=int($2/2097152)+1}
      END{n=(m<p?m:p); if(n<1)n=1; print n}' /proc/meminfo
    ;;

  check-packages)
    PROFILE="${1:-youhua_pt1570_h10_cu_rtw89_exp}"
    TI="$ROOT/tmp/.targetinfo"
    if [ ! -f "$TI" ]; then
      echo "::error::missing $TI -- defconfig did not run successfully"
      exit 1
    fi
    DEVPKGS=$(awk -v p="DEVICE_${PROFILE}" '
      $0 == "Target-Profile: " p { f = 1; next }
      f && /^Target-Profile:/ { f = 0 }
      f && /^Target-Profile-Packages:/ { sub(/^Target-Profile-Packages:[ \t]*/, ""); print; exit }
    ' "$TI")
    if [ -z "$DEVPKGS" ]; then
      echo "::warning::$TI has no Target-Profile-Packages for DEVICE_${PROFILE}"
      grep '^Target-Profile: ' "$TI" | sed 's/^/    /' | head -20 || true
      exit 0
    fi

    MISS_DEV=""
    MOD_ONLY=""
    CHK=0
    for p in $DEVPKGS; do
      case "$p" in -*) continue ;; esac
      p=${p%%:*}
      CHK=$((CHK + 1))
      if grep -qx "CONFIG_PACKAGE_${p}=y" "$ROOT/.config"; then
        continue
      elif grep -qx "CONFIG_PACKAGE_${p}=m" "$ROOT/.config"; then
        MOD_ONLY="$MOD_ONLY $p"
      else
        MISS_DEV="$MISS_DEV $p"
      fi
    done

    if [ -n "$MOD_ONLY" ]; then
      echo "::warning::DEVICE_PACKAGES built as =m (not installed by default):$MOD_ONLY"
    fi
    if [ -n "$MISS_DEV" ]; then
      echo "::error::DEVICE_PACKAGES of ${PROFILE} were not selected:$MISS_DEV"
      echo "::error::image assembly will fail at target/linux/install; failing early."
      for p in $MISS_DEV; do
        echo "  - $p: packageinfo=$(grep -c "^Package: ${p}\$" "$ROOT/tmp/.packageinfo" 2>/dev/null || echo 0)"
        echo "    kconfig=$(grep -c "config PACKAGE_${p}\$" "$ROOT/tmp/.config-package.in" 2>/dev/null || echo 0)"
      done
      exit 1
    fi
    echo "device package closure OK: ${CHK} DEVICE_PACKAGES entries selected"
    ;;

  diagnose)
    LOG="${1:-}"
    if [ ! -f "$LOG" ]; then
      echo "::warning::build log $LOG missing"
      exit 0
    fi
    FAILED_SUB=$(grep -oE 'ERROR: [^ ]+ failed to build' "$LOG" \
      | tail -1 | sed 's/^ERROR: //; s/ failed to build$//' || true)
    if [ -n "$FAILED_SUB" ]; then
      emit FAILED_SUB "$FAILED_SUB"
      echo "::error::build failed in $FAILED_SUB (rerunning that target with V=s)"
    fi
    echo "::group::candidate error lines"
    grep -nE '(^|[[:space:]])(ERROR:|error:|\*\*\* .*Error [0-9]+|make(\[[0-9]+\])?: \*\*\*)|unable to select packages|no such package|Image too big|not found' \
      "$LOG" | tail -40 || echo '(no ERROR/Error line matched)'
    echo "::endgroup::"
    ;;

  *)
    echo "unknown command: $CMD" >&2
    exit 2
    ;;
esac
