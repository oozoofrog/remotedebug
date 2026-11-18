#!/usr/bin/env bash
# Check that a release build of an app carries none of the Debug-only parts of the RemoteDebugFeedback package.
#
# Usage:
#   scripts/check-feedback-release.sh [--host <name>]... <App.app | executable | folder>
#   scripts/check-feedback-release.sh --expect-debug <App.app | executable | folder>
#
# What it looks for (all of these are compiled only under #if DEBUG in the package):
#   - the checklist: its type names, its folder name and the checklist path on the Mac
#   - the Mac upload client: its type names and the labels of the "send to the Mac" route
#   - a Mac host name: rd-mac-… names, any *.ts.net name, and every name given with --host
#     (the package never contains a host name; this catches a macHost literal the app left outside #if DEBUG)
#
# It reads every regular file under the path as bytes, so it also sees resource bundles and property lists.
# Swift keeps short string literals (15 bytes or less) inside instructions, where a byte search cannot see
# them. That is why the upload path "/v1/crashes" is not a marker: the client type names stand in for it.
#
# --expect-debug turns the check around: every marker must be present. Run it against a Debug build of the
# same app when the package changes, so a renamed type cannot make the release check pass by accident.
#
# Exit status: 0 nothing found (or, with --expect-debug, everything found), 1 otherwise, 2 wrong usage.
# The check does not run the app and changes nothing.
set -euo pipefail

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

expect_debug=0
hosts=()
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) [ $# -ge 2 ] || usage; hosts+=("$2"); shift 2 ;;
    --expect-debug) expect_debug=1; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [ -z "$target" ] || usage; target="$1"; shift ;;
  esac
done
[ -n "$target" ] || usage
[ -e "$target" ] || { echo "not found: $target" >&2; exit 2; }

# Markers that exist only in the package's #if DEBUG code. Keep in step with
# Packages/RemoteDebugFeedback/Sources/RemoteDebugFeedback (FeedbackChecklist.swift, FeedbackClient.swift,
# FeedbackSheet.swift). Each one is longer than 15 bytes or is a type name stored as plain text.
markers=(
  "FeedbackCheckStore"
  "FeedbackCheckItem"
  "FeedbackCheckRow"
  "RemoteDebugFeedbackChecks"
  "/v1/feedback/checklist/"
  "FeedbackClient"
  "FeedbackReport"
  "개발자의 Mac으로 보내는 중"
  "지금은 개발자의 Mac에 닿지 않습니다"
  "저장하고 나중에 보내기"
  "답하지 않은 것만 보기"
)
# Host names. Extended regular expressions, matched on bytes.
host_patterns=(
  "rd-mac-[0-9a-z]+"
  "[0-9a-z-]+\\.ts\\.net"
)

files=()
while IFS= read -r -d '' file; do files+=("$file"); done < <(find "$target" -type f -print0)
[ ${#files[@]} -gt 0 ] || { echo "no files under: $target" >&2; exit 2; }

# Prints the files under the target that contain the fixed string.
containing() { LC_ALL=C grep -a -l -F -- "$1" "${files[@]}" 2>/dev/null || true; }
# Prints the distinct byte strings under the target that match the pattern.
matching() { LC_ALL=C grep -a -o -h -E -- "$1" "${files[@]}" 2>/dev/null | sort -u || true; }

status=0
if [ -z "$(containing "RemoteDebugFeedback")" ]; then
  echo "note: RemoteDebugFeedback is not in this build (${#files[@]} files read)."
  [ "$expect_debug" -eq 0 ] || { echo "FAIL: --expect-debug needs a build that links the package."; exit 1; }
fi

if [ "$expect_debug" -eq 1 ]; then
  for marker in "${markers[@]}"; do
    if [ -z "$(containing "$marker")" ]; then
      echo "FAIL: marker not found in the Debug build (renamed or removed? update this script): $marker"
      status=1
    fi
  done
  [ "$status" -ne 0 ] || echo "OK: all ${#markers[@]} Debug-only markers are present in ${#files[@]} files."
  exit "$status"
fi

for marker in "${markers[@]}"; do
  found="$(containing "$marker")"
  if [ -n "$found" ]; then
    echo "FAIL: Debug-only marker \"$marker\" is in:"
    echo "$found" | sed 's/^/  /'
    status=1
  fi
done
for pattern in "${host_patterns[@]}"; do
  found="$(matching "$pattern")"
  if [ -n "$found" ]; then
    echo "FAIL: a Mac host name is in the build (pattern $pattern):"
    echo "$found" | sed 's/^/  /'
    status=1
  fi
done
if [ ${#hosts[@]} -gt 0 ]; then
  for host in "${hosts[@]}"; do
    found="$(containing "$host")"
    if [ -n "$found" ]; then
      echo "FAIL: host name \"$host\" is in:"
      echo "$found" | sed 's/^/  /'
      status=1
    fi
  done
fi

if [ -d "$target" ] && [ -n "$(containing "RemoteDebugFeedback")" ]; then
  if ! find "$target" -path '*RemoteDebugFeedback*' -name PrivacyInfo.xcprivacy -print -quit | grep -q .; then
    echo "note: the package's PrivacyInfo.xcprivacy is not in this folder. In an app it is inside RemoteDebugFeedback_RemoteDebugFeedback.bundle."
  fi
fi

[ "$status" -ne 0 ] || echo "OK: no Debug-only feedback marker and no Mac host name in ${#files[@]} files."
exit "$status"
