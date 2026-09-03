#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIM_DIR="$ROOT/.build/hazebuilder-mobile-tools"
MODE="${1:-build}"
LOG_FILE="$ROOT/.build/hazebuilder-${MODE}.log"
mkdir -p "$SHIM_DIR" "$ROOT/.build"

# Haze's upstream Makefile requires ldid even when we intentionally export an
# unsigned IPA. On Android/Linux the final IPA is re-signed later with
# KravaSigner, so this shim satisfies the Makefile without embedding a stale
# ad-hoc signature.
cat > "$SHIM_DIR/ldid" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod +x "$SHIM_DIR/ldid"

cat > "$SHIM_DIR/vtool" <<EOF
#!/usr/bin/env sh
exec python3 "$ROOT/HazeBuilder/patch_macho_platform.py" "\$@"
EOF
chmod +x "$SHIM_DIR/vtool"

# Auto-select the Haze checkout if the caller did not provide --project.
has_project=0
for arg in "$@"; do
  if [[ "$arg" == "--project" ]]; then
    has_project=1
    break
  fi
done

extra=()
if [[ $has_project -eq 0 ]]; then
  for candidate in /root/Haze /root/haze "$HOME/Haze" "$HOME/haze"; do
    if [[ -f "$candidate/Makefile" && -d "$candidate/Natives" && -d "$candidate/JavaApp" ]]; then
      extra=(--project "$candidate")
      break
    fi
  done
fi

printf 'HazeBuilder mobile tools:\n'
printf '  ldid:  unsigned-output shim\n'
printf '  vtool: Linux Mach-O platform patcher\n'
if [[ ${#extra[@]} -gt 0 ]]; then
  printf '  Haze:   %s\n' "${extra[1]}"
fi
printf '  log:    %s\n\n' "$LOG_FILE"

set +e
env PATH="$SHIM_DIR:$PATH" \
  bash "$ROOT/HazeBuilder/hazebuilder.sh" "$@" "${extra[@]}" 2>&1 | tee "$LOG_FILE"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  printf '\nHazeBuilder failed (exit %d). Full log saved to:\n  %s\n' "$status" "$LOG_FILE" >&2
fi

exit "$status"
