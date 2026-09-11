#!/usr/bin/env bash
# install-vsix.sh <vsix> - install the Shepherd tab bridge with VS Code's own CLI (no
# Marketplace). Skips when the stamped version already matches, so `make install` only
# reinstalls on a version bump (FORCE=1 reinstalls anyway). Warn-only: a machine without
# VS Code, or a CLI that can't be found, never fails a deploy.
#
# The CLI: $CC_CODE_CLI, else `code` on PATH, else the one inside the app bundle found by
# bundle id (VS Code run from Downloads has no `code` on PATH, and macOS launches it from
# a randomized translocated copy -- the bundle's own path is the stable one).
set -u

VSIX="${1:?usage: install-vsix.sh <vsix>}"
BRIDGE_DIR="${CC_BRIDGE_DIR:-$HOME/.claude/cc-bridge}"
STAMP="$BRIDGE_DIR/.installed"
VER="$(basename "$VSIX" .vsix)"; VER="${VER##*-}"

if [ "${FORCE:-0}" != "1" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$VER" ]; then
  echo "✅ Shepherd tab bridge $VER already installed in VS Code"
  exit 0
fi

CLI="${CC_CODE_CLI:-}"
if [ -z "$CLI" ]; then CLI="$(command -v code 2>/dev/null || true)"; fi
if { [ -z "$CLI" ] || [ ! -x "$CLI" ]; } && [ -z "${CC_BRIDGE_NO_MDFIND:-}" ] && [ -z "${CC_CODE_CLI:-}" ]; then
  APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.microsoft.VSCode'" 2>/dev/null | head -n 1)"
  if [ -n "$APP" ]; then CLI="$APP/Contents/Resources/app/bin/code"; fi
fi
if [ -z "$CLI" ] || [ ! -x "$CLI" ]; then
  echo "⚠️  Shepherd tab bridge not installed: couldn't find VS Code's command-line tool (set CC_CODE_CLI to its path)"
  exit 0
fi

echo "🚀 installing Shepherd tab bridge $VER with $CLI"
if "$CLI" --install-extension "$VSIX" --force; then
  mkdir -p "$BRIDGE_DIR" && chmod 700 "$BRIDGE_DIR" 2>/dev/null
  printf '%s' "$VER" > "$STAMP"
  echo "✅ Shepherd tab bridge $VER installed (a window that doesn't pick it up needs Developer: Reload Window once)"
else
  echo "⚠️  Shepherd tab bridge install failed -- VS Code's CLI returned an error (see above)"
fi
exit 0
