#!/usr/bin/env bash
# bridge-build.test.sh - the Shepherd companion extension packages and installs locally,
# with no Marketplace and no npm (2026-09-11). build-vsix.sh zips vscode-bridge/ into a
# .vsix; install-vsix.sh hands it to VS Code's own CLI, only when the version changed.
# Side-effect-free: a temp output dir, a temp CC_BRIDGE_DIR, and a FAKE `code` CLI that
# records its arguments -- the real VS Code is never touched.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
B="$ROOT/vscode-bridge"

VSIX="$(bash "$B/build-vsix.sh" "$TMP/out" 2>"$TMP/build.err")"
VER="$(jq -r .version "$B/package.json")"
NAME="$(jq -r .name "$B/package.json")"
PUB="$(jq -r .publisher "$B/package.json")"
assert_eq "build prints the package it made" "$TMP/out/$NAME-$VER.vsix" "$VSIX"
[ -f "$VSIX" ] && got=yes || got=no
assert_eq "the .vsix exists" "yes" "$got"

LIST="$(unzip -Z1 "$VSIX" 2>/dev/null | sort | tr '\n' ' ')"
for f in '[Content_Types].xml' extension.vsixmanifest extension/package.json extension/extension.js extension/lib.js; do
  case " $LIST " in *" $f "*) got=yes ;; *) got=no ;; esac
  assert_eq "the package holds $f" "yes" "$got"
done
case " $LIST " in *"tests/"*|*".sh "*) got=leaks ;; *) got=clean ;; esac
assert_eq "the package ships only the extension (no scripts or tests)" "clean" "$got"

MANIFEST="$(unzip -p "$VSIX" extension.vsixmanifest 2>/dev/null)"
case "$MANIFEST" in *"Id=\"$NAME\" Version=\"$VER\" Publisher=\"$PUB\""*) got=match ;; *) got=mismatch ;; esac
assert_eq "the manifest's identity matches package.json" "match" "$got"
assert_eq "package.json inside the package is the source one" "$(cat "$B/package.json")" "$(unzip -p "$VSIX" extension/package.json)"

# ---- install through a fake VS Code CLI ----
FAKE="$TMP/code"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/code.calls"\n' "$TMP" > "$FAKE"
chmod +x "$FAKE"
export CC_BRIDGE_DIR="$TMP/bridge"

CC_CODE_CLI="$FAKE" bash "$B/install-vsix.sh" "$VSIX" >/dev/null 2>&1
assert_eq "install hands the package to VS Code's CLI" "--install-extension $VSIX --force" "$(cat "$TMP/code.calls" 2>/dev/null)"
assert_eq "...and stamps the installed version" "$VER" "$(cat "$CC_BRIDGE_DIR/.installed" 2>/dev/null)"

CC_CODE_CLI="$FAKE" bash "$B/install-vsix.sh" "$VSIX" >/dev/null 2>&1
assert_eq "the same version again is skipped (a deploy doesn't reinstall)" "1" "$(wc -l < "$TMP/code.calls" | tr -d ' ')"

FORCE=1 CC_CODE_CLI="$FAKE" bash "$B/install-vsix.sh" "$VSIX" >/dev/null 2>&1
assert_eq "FORCE=1 reinstalls" "2" "$(wc -l < "$TMP/code.calls" | tr -d ' ')"

rm -f "$CC_BRIDGE_DIR/.installed"
CC_CODE_CLI="$TMP/missing-code" CC_BRIDGE_NO_MDFIND=1 bash "$B/install-vsix.sh" "$VSIX" >"$TMP/miss.out" 2>&1
assert_eq "no VS Code CLI is a warning, never a failed deploy" "0" "$?"
grep -q "VS Code's command-line tool" "$TMP/miss.out" && got=yes || got=no
assert_eq "...and it says what it couldn't find" "yes" "$got"
assert_absent "...and stamps nothing" "$CC_BRIDGE_DIR/.installed"

finish
