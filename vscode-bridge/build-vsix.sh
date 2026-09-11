#!/usr/bin/env bash
# build-vsix.sh <outdir> - package the Shepherd tab bridge as a .vsix with plain `zip`: no
# npm, no network, no Marketplace. A .vsix is a zip holding [Content_Types].xml, an
# extension.vsixmanifest and the extension under extension/. Prints the package path.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: build-vsix.sh <outdir>}"
command -v zip >/dev/null 2>&1 || { echo "❌ build-vsix: zip not found" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "❌ build-vsix: jq not found" >&2; exit 1; }

field() { jq -r "$1" "$HERE/package.json"; }
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
NAME="$(field .name)"; PUB="$(field .publisher)"; VER="$(field .version)"
DISPLAY="$(field .displayName)"; DESC="$(field .description)"; ENGINE="$(field .engines.vscode)"

STAGE="$(mktemp -d 2>/dev/null || mktemp -d -t ccbridge)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/extension" "$OUT"
cp "$HERE/package.json" "$HERE/extension.js" "$HERE/lib.js" "$STAGE/extension/"

cat > "$STAGE/[Content_Types].xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
</Types>
EOF

cat > "$STAGE/extension.vsixmanifest" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="$(xml "$NAME")" Version="$(xml "$VER")" Publisher="$(xml "$PUB")"/>
    <DisplayName>$(xml "$DISPLAY")</DisplayName>
    <Description xml:space="preserve">$(xml "$DESC")</Description>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="$(xml "$ENGINE")"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace"/>
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
EOF

VSIX="$(cd "$OUT" && pwd)/$NAME-$VER.vsix"
rm -f "$VSIX"
# -nw: "[Content_Types].xml" is a literal name, not a wildcard; -X: no extra file attributes
(cd "$STAGE" && zip -q -X -r -nw "$VSIX" "[Content_Types].xml" extension.vsixmanifest extension)
echo "$VSIX"
