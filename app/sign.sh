#!/usr/bin/env bash
# Sign the packaged Sayso.app (package.sh's output) for other Macs, then
# notarise and staple it.
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=sayso ./sign.sh
#
# NOTARY_PROFILE is a notarytool keychain profile, made once with:
#   xcrun notarytool store-credentials sayso --apple-id you@example.com --team-id TEAMID
#
# Without a certificate, the signing half can still be tested: an ad-hoc
# signature with the same hardened runtime and entitlements, no notarising:
#   DEVELOPER_ID=- ./sign.sh
#
# Order matters: every nested library and executable first, the app last,
# since signing anything inside a bundle invalidates the bundle's signature.
set -euo pipefail
cd "$(dirname "$0")"
: "${DEVELOPER_ID:?set DEVELOPER_ID to your 'Developer ID Application: ...' identity, or - to test ad hoc}"
APP=${APP:-build/dist/Sayso.app}
ENGINE="$APP/Contents/Resources/engine"
[ -d "$ENGINE" ] || { echo "No packaged engine in $APP: run package.sh first."; exit 1; }

if [ "$DEVELOPER_ID" = "-" ]; then TIMESTAMP=--timestamp=none; else TIMESTAMP=--timestamp; fi
SIGN=(codesign --force "$TIMESTAMP" --options runtime --sign "$DEVELOPER_ID")

# Signing changes the engine's binaries, so it is a new version: every Mac
# installs it again rather than keeping an unsigned copy.
base=$(sed 's/+signed.*//' "$ENGINE/VERSION")
echo "${base}+signed" > "$ENGINE/VERSION"

# Every codesign call must succeed: a failure (a timestamp server hiccup, a
# bad file) stops the script here, never later at notarisation.
sign_or_die() {
  local out
  if ! out=$("${SIGN[@]}" "$@" 2>&1); then
    echo "codesign failed: $*"; echo "$out"; exit 1
  fi
}

echo "libraries"
while IFS= read -r -d '' f; do sign_or_die "$f"; done \
  < <(find "$ENGINE" -type f \( -name '*.so' -o -name '*.dylib' \) -print0)

echo "executables"
# Any other Mach-O file (checked, not guessed from its name). The Python
# interpreter itself gets the engine's entitlements; nothing else needs any.
PYTHON=$(cd "$ENGINE/python/bin" && pwd -P)/$(readlink "$ENGINE/python/bin/python3" 2>/dev/null || echo python3.13)
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  real=$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")
  if [ "$real" = "$PYTHON" ]; then
    sign_or_die --entitlements entitlements/python.entitlements "$f"
  else
    sign_or_die "$f"
  fi
done < <(find "$ENGINE" -type f -perm +111 ! -name '*.so' ! -name '*.dylib' -print0)

echo "app"
sign_or_die --entitlements entitlements/app.entitlements "$APP"

echo "verify"
codesign --verify --strict --deep "$APP"
# --deep doesn't check code under Resources/: check every Mach-O itself.
bad=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  info=$(codesign -dv "$f" 2>&1) || { echo "unsigned: $f"; bad=1; continue; }
  echo "$info" | grep -q 'runtime' || { echo "no hardened runtime: $f"; bad=1; }
  if [ "$DEVELOPER_ID" != "-" ]; then
    echo "$info" | grep -q '^Timestamp=' || { echo "no secure timestamp: $f"; bad=1; }
    echo "$info" | grep -q '^TeamIdentifier=' || { echo "no team: $f"; bad=1; }
  fi
done < <(find "$ENGINE" -type f \( -name '*.so' -o -name '*.dylib' -o -perm +111 \) -print0)
[ $bad -eq 0 ] || { echo "verification failed"; exit 1; }
codesign --display --entitlements - "$PYTHON" 2>/dev/null | grep -q allow-jit \
  || { echo "The interpreter is missing its entitlements"; exit 1; }
echo "signed $APP ($(cat "$ENGINE/VERSION"))"

if [ "$DEVELOPER_ID" = "-" ]; then
  echo "ad hoc: not notarised (runs on this Mac only)"
  exit 0
fi

: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile (see the top of this file)}"
echo "notarise"
ZIP=build/dist/Sayso.zip
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > build/dist/notary.plist; then
  echo "notarisation failed; the log says why:"
  id=$(/usr/libexec/PlistBuddy -c 'Print :id' build/dist/notary.plist 2>/dev/null || true)
  [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
  exit 1
fi
grep -q '<string>Accepted</string>' build/dist/notary.plist || {
  echo "notarisation not accepted:"; cat build/dist/notary.plist
  id=$(/usr/libexec/PlistBuddy -c 'Print :id' build/dist/notary.plist 2>/dev/null || true)
  [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
  exit 1
}
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"          # what to hand out: the stapled app
echo "notarised: $ZIP"
