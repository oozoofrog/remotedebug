#!/usr/bin/env bash
# Regenerate the keys of Localization/Localizable.xcstrings from the Swift sources.
#
# Usage: scripts/sync-strings.sh            (no arguments)
#
# Method
#   1. Builds the schemes RemoteDebugMac, RemoteDebugPhone (with RemoteDebugTunnel and RemoteDebugWidgets)
#      and RemoteDebugVPN (with RemoteDebugVPNTunnel) for Debug with SWIFT_EMIT_LOC_STRINGS=YES on the
#      command line. The Swift compiler then writes one .stringsdata file per source file for every target,
#      the local package targets (MacHostKit, MacHostUI, PhoneClientKit, RDModels, ...) included, with the
#      exact format specifiers of interpolations (%@ for String, %lld for Int, ...).
#      Signing is off (CODE_SIGNING_ALLOWED=NO), so no development team is needed.
#   2. The build writes into its own folder (OBJROOT/SYMROOT/derived data overridden), and its
#      intermediates folder is deleted before building, so only files of this run are read: nothing from
#      other configurations, the IDE build folder, or source files that no longer exist.
#   3. Keys listed in Localization/manual-keys.txt are added to the catalog with extractionState "manual"
#      (strings behind #if branches that a Debug device build does not compile, such as #else of DEBUG or
#      targetEnvironment(simulator)). xcstringstool never marks or removes a manual key.
#   4. One `xcrun xcstringstool sync` call merges the .stringsdata of all three builds, so a key used
#      only on iOS is never marked stale by the macOS build or the other way round.
#      sync adds new keys, removes keys that are gone from the code and have no translation, and keeps a
#      key that is gone but has a translation, marked "extractionState": "stale". No translation is lost.
#   5. Fails when a build fails or when an expected module contributed no key.
#
# Xcode IDE builds: the project sets SWIFT_EMIT_LOC_STRINGS = NO (project.yml), so building in Xcode
# does not extract strings and does not rewrite the catalog per target (which would mark the other
# platform's keys stale). Run this script after changing user-visible text. The catalog may still be
# edited in Xcode's catalog editor to add translations.
#
# Tried and not used: `xcstringstool extract` (lightweight parsing, cannot know the format specifier of
# an interpolation without the type checker, misses String(localized:) defaults in package code) and
# per-target syncing in the IDE (marks keys of the other platform stale).
#
# Build folder: `eyebuild dir l10n-sync` when eyebuild is installed, otherwise $RD_L10N_BUILD_DIR, otherwise
# Build/l10n-sync in the repository (ignored by git).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/Localization/Localizable.xcstrings"
MANUAL="$ROOT/Localization/manual-keys.txt"
PROJECT="$ROOT/RemoteDebug.xcodeproj"

if [ $# -ne 0 ]; then
    echo "usage: scripts/sync-strings.sh" >&2
    exit 2
fi

if [ -n "${RD_L10N_BUILD_DIR:-}" ]; then
    BUILD="$RD_L10N_BUILD_DIR"
elif command -v eyebuild >/dev/null 2>&1; then
    BUILD="$(cd "$ROOT" && eyebuild -p remotedebug dir l10n-sync)"
else
    BUILD="$ROOT/Build/l10n-sync"
fi
mkdir -p "$BUILD"

cd "$ROOT"
if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --spec project.yml --quiet
elif [ ! -d "$PROJECT" ]; then
    echo "sync-strings: RemoteDebug.xcodeproj is missing and xcodegen is not installed" >&2
    exit 1
fi

# A fresh intermediates folder makes every Swift file compile again, so every .stringsdata is written by
# this run (deleting only the .stringsdata does not make an up-to-date build compile again).
INTERMEDIATES="$BUILD/Intermediates"
rm -rf "$INTERMEDIATES"

build() {  # scheme destination
    local scheme="$1" destination="$2" log="$BUILD/$1.log"
    echo "sync-strings: building $scheme"
    if ! xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration Debug \
        -destination "$destination" -derivedDataPath "$BUILD/DerivedData" \
        OBJROOT="$INTERMEDIATES" SYMROOT="$BUILD/Products" \
        SWIFT_EMIT_LOC_STRINGS=YES CODE_SIGNING_ALLOWED=NO build >"$log" 2>&1; then
        grep -E 'error:|BUILD FAILED' "$log" | tail -20 >&2 || true
        echo "sync-strings: $scheme failed to build; full log: $log" >&2
        exit 1
    fi
}

build RemoteDebugMac 'generic/platform=macOS'
build RemoteDebugPhone 'generic/platform=iOS'
build RemoteDebugVPN 'generic/platform=iOS'

if [ ! -f "$CATALOG" ]; then
    mkdir -p "$(dirname "$CATALOG")"
    printf '{\n  "sourceLanguage" : "ko",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n' >"$CATALOG"
fi

LIST="$BUILD/stringsdata.txt"
find "$INTERMEDIATES" -name '*.stringsdata' -print0 | sort -z | tr '\0' '\n' >"$LIST"

# Check the expected modules and add the manual keys before syncing (sync then writes the file in
# Xcode's own format).
python3 -I - "$LIST" "$CATALOG" "$MANUAL" <<'PY'
import json, re, sys

list_path, catalog_path, manual_path = sys.argv[1:4]
SENTINEL = "__sync-strings: removed by xcstringstool sync__"
expected = ["MacHostKit", "MacHostUI", "PhoneClientKit", "RDModels", "RemoteDebugMac", "RemoteDebugPhone",
            "RemoteDebugTunnel", "RemoteDebugWidgets", "RemoteDebugVPN", "RemoteDebugVPNTunnel"]
counts = {name: 0 for name in expected}
with open(list_path, encoding="utf-8") as handle:
    paths = [line.rstrip("\n") for line in handle if line.strip()]
for path in paths:
    match = re.search(r"/([^/]+?)(?:-t)?\.build/Objects-normal/", path)
    if not match or match.group(1) not in counts:
        continue
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    counts[match.group(1)] += len((data.get("tables") or {}).get("Localizable") or [])
empty = [name for name, count in counts.items() if count == 0]
if empty:
    sys.exit("sync-strings: no key extracted from: " + ", ".join(empty))

with open(catalog_path, encoding="utf-8") as handle:
    catalog = json.load(handle)
if catalog.get("sourceLanguage") != "ko":
    sys.exit("sync-strings: the catalog's sourceLanguage must be ko")
strings = catalog.setdefault("strings", {})
try:
    with open(manual_path, encoding="utf-8") as handle:
        manual = [line.rstrip("\n") for line in handle if line.strip() and not line.startswith("#")]
except FileNotFoundError:
    manual = []
for key in manual:
    entry = strings.setdefault(key, {})
    entry["extractionState"] = "manual"
# An empty entry that no source uses: sync always removes it, so the file always changes and sync
# writes it out in Xcode's own formatting (sync leaves an unchanged file as it is).
strings[SENTINEL] = {}
with open(catalog_path, "w", encoding="utf-8") as handle:
    json.dump(catalog, handle, ensure_ascii=False, indent=2)
print("sync-strings: %d stringsdata files; keys per module: %s" % (
    len(paths), ", ".join("%s %d" % item for item in counts.items())))
PY

STRINGSDATA=()
while IFS= read -r line; do STRINGSDATA+=("$line"); done <"$LIST"
xcrun xcstringstool sync "$CATALOG" --stringsdata "${STRINGSDATA[@]}"

python3 -I - "$CATALOG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    strings = json.load(handle)["strings"]
if any(key.startswith("__sync-strings:") for key in strings):
    sys.exit("sync-strings: xcstringstool sync did not remove the sentinel key")
stale = sorted(key for key, entry in strings.items() if entry.get("extractionState") == "stale")
manual = sum(1 for entry in strings.values() if entry.get("extractionState") == "manual")
print("sync-strings: %d keys (%d manual, %d stale)" % (len(strings), manual, len(stale)))
for key in stale:
    print("  stale (no longer in the code, translation kept): %s" % key)
PY
