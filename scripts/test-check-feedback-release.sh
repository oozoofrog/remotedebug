#!/usr/bin/env bash
# Self-test of scripts/check-feedback-release.sh: builds small folders and archives in a temporary folder and
# checks the exit status and the message of every branch. Needs no built app.
#
# Usage:
#   scripts/test-check-feedback-release.sh
#
# Exit status: 0 every case passed, 1 a case failed. The temporary folder is removed at the end.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-feedback-release.sh"

base="$(mktemp -d "${TMPDIR:-/tmp}/rd-feedback-check-test.XXXXXX")" || exit 1
trap 'chmod -R u+rwx "$base" 2>/dev/null; rm -rf "$base"' EXIT
# The script under test puts its own temporary folder here, so a leftover is visible at the end.
export TMPDIR="$base/tmp"
mkdir -p "$TMPDIR"

failed=0
passed=0
# expect <name> <wanted status> <text the output must contain, or ""> <arguments…>
expect() {
  local name="$1" want="$2" text="$3" output status
  shift 3
  output="$("$CHECK" "$@" 2>&1)"
  status=$?
  if [ "$status" -ne "$want" ]; then
    echo "FAIL: $name: exit $status, wanted $want"
    printf '%s\n' "$output" | sed 's/^/    /'
    failed=$((failed + 1))
  elif [ -n "$text" ] && ! printf '%s' "$output" | grep -q -F -- "$text"; then
    echo "FAIL: $name: output lacks \"$text\""
    printf '%s\n' "$output" | sed 's/^/    /'
    failed=$((failed + 1))
  else
    passed=$((passed + 1))
  fi
}

# A folder that looks like a release build: it links the package and has none of the Debug-only markers.
make_release() {
  mkdir -p "$1/Sample.app/RemoteDebugFeedback_RemoteDebugFeedback.bundle"
  printf 'binary\000RemoteDebugFeedback\000FeedbackSheet\000' > "$1/Sample.app/Sample"
  printf '<plist/>' > "$1/Sample.app/RemoteDebugFeedback_RemoteDebugFeedback.bundle/PrivacyInfo.xcprivacy"
}

make_release "$base/release"
expect "clean release build" 0 "OK: no Debug-only feedback marker" "$base/release/Sample.app"
expect "single executable" 0 "OK:" "$base/release/Sample.app/Sample"

# Debug-only marker.
make_release "$base/marker"
printf 'x\000FeedbackCheckStore\000' >> "$base/marker/Sample.app/Sample"
expect "marker in the executable" 1 'Debug-only marker "FeedbackCheckStore"' "$base/marker/Sample.app"

# Host names in any letter case.
make_release "$base/host"
printf 'https://RD-MAC-1A2B3C4D.Tail0001.TS.NET/v1' > "$base/host/Sample.app/Config.plist"
expect "upper-case host name" 1 "a Mac host name is in the build" "$base/host/Sample.app"
make_release "$base/named"
printf 'host=Example-Mac.Example.COM' > "$base/named/Sample.app/Config.plist"
expect "--host in another letter case" 1 'host name "example-mac.example.com"' --host example-mac.example.com "$base/named/Sample.app"
expect "--host not present" 0 "OK:" --host other.example.com "$base/named/Sample.app"

# A build without the package.
mkdir -p "$base/absent/Other.app"
printf 'nothing here' > "$base/absent/Other.app/Other"
expect "package absent" 1 "RemoteDebugFeedback is not in this build" "$base/absent/Other.app"
expect "package absent, allowed" 0 "note: RemoteDebugFeedback is not in this build" --allow-absent "$base/absent/Other.app"
printf 'https://rd-mac-0000.example.ts.net' > "$base/absent/Other.app/Config.plist"
expect "host name without the package" 1 "a Mac host name is in the build" --allow-absent "$base/absent/Other.app"

# Archives: the contents are compressed, so they are unpacked first.
make_release "$base/zipped-clean/Payload"
(cd "$base/zipped-clean" && /usr/bin/zip -q -r "$base/clean.ipa" Payload)
expect "clean .ipa" 0 "OK:" "$base/clean.ipa"
make_release "$base/zipped-marker/Payload"
# Compressible, so the marker is not visible in the archive's own bytes.
{ printf 'FeedbackClient'; head -c 20000 /dev/zero; } >> "$base/zipped-marker/Payload/Sample.app/Sample"
(cd "$base/zipped-marker" && /usr/bin/zip -q -r "$base/marker.ipa" Payload && /usr/bin/zip -q -r "$base/Marker.ZIP" Payload)
if LC_ALL=C grep -a -q -F "FeedbackClient" "$base/marker.ipa"; then
  echo "FAIL: fixture: the marker is visible in the archive bytes, the archive cases prove nothing"
  failed=$((failed + 1))
fi
expect "marker inside an .ipa" 1 'Debug-only marker "FeedbackClient"' "$base/marker.ipa"
expect "marker inside a .ZIP" 1 'Debug-only marker "FeedbackClient"' "$base/Marker.ZIP"
make_release "$base/nested"
cp "$base/marker.ipa" "$base/nested/Sample.app/Inner.zip"
expect "marker inside an archive under the folder" 1 'Debug-only marker "FeedbackClient"' "$base/nested/Sample.app"
printf 'this is not a zip archive' > "$base/broken.ipa"
expect "archive that cannot be unpacked" 3 "cannot unpack" "$base/broken.ipa"

# More files than fit on one command line (the names add up to well over 1 MB).
make_release "$base/many"
long="$(printf 'd%.0s' $(seq 1 200))"
mkdir -p "$base/many/Sample.app/$long"
for index in $(seq 1 6000); do : > "$base/many/Sample.app/$long/$index-$long"; done
printf 'RemoteDebugFeedbackChecks' > "$base/many/Sample.app/$long/6000-$long"
expect "more files than one command line holds" 1 'Debug-only marker "RemoteDebugFeedbackChecks"' "$base/many/Sample.app"

# A file that cannot be read makes the result untrustworthy.
if [ "$(id -u)" -ne 0 ]; then
  make_release "$base/unreadable"
  printf 'FeedbackReport' > "$base/unreadable/Sample.app/Hidden"
  chmod 000 "$base/unreadable/Sample.app/Hidden"
  expect "unreadable file" 3 "cannot read every file" "$base/unreadable/Sample.app"
  chmod 600 "$base/unreadable/Sample.app/Hidden"
  mkdir "$base/unreadable/Sample.app/Closed"
  rm "$base/unreadable/Sample.app/Hidden"
  chmod 000 "$base/unreadable/Sample.app/Closed"
  expect "unreadable folder" 3 "cannot list files" "$base/unreadable/Sample.app"
  chmod 700 "$base/unreadable/Sample.app/Closed"
fi

# --expect-debug: every marker must be there.
make_release "$base/debug"
{
  printf 'FeedbackCheckStore\000FeedbackCheckItem\000FeedbackCheckRow\000RemoteDebugFeedbackChecks\000/v1/feedback/checklist/\000'
  printf 'FeedbackClient\000FeedbackReport\000개발자의 Mac으로 보내는 중\000지금은 개발자의 Mac에 닿지 않습니다\000저장하고 나중에 보내기\000'
} >> "$base/debug/Sample.app/Sample"
expect "debug build lacks one marker" 1 "marker not found in the Debug build" --expect-debug "$base/debug/Sample.app"
printf '답하지 않은 것만 보기' >> "$base/debug/Sample.app/Sample"
expect "debug build has every marker" 0 "OK: all 11 Debug-only markers" --expect-debug "$base/debug/Sample.app"
expect "debug build fails the release check" 1 "Debug-only marker" "$base/debug/Sample.app"
expect "--expect-debug without the package" 1 "needs a build that links the package" --expect-debug "$base/absent/Other.app"

# Usage errors.
expect "no target" 2 "Usage:"
expect "missing target" 2 "not found" "$base/nosuch"
expect "unknown option" 2 "unknown option" --nope "$base/release/Sample.app"
mkdir "$base/empty"
expect "empty folder" 2 "no files under" "$base/empty"

leftover="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
if [ "$leftover" -ne 0 ]; then
  echo "FAIL: the check left $leftover temporary folder(s) behind"
  failed=$((failed + 1))
fi

echo "passed $passed, failed $failed"
[ "$failed" -eq 0 ]
