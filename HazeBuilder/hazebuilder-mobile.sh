#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIM_DIR="$ROOT/.build/hazebuilder-mobile-tools"
mkdir -p "$SHIM_DIR"

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
printf '\n'

exec env PATH="$SHIM_DIR:$PATH" \
  bash "$ROOT/HazeBuilder/hazebuilder.sh" "$@" "${extra[@]}"
