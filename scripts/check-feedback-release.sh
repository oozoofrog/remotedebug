#!/usr/bin/env bash
# Check that a release build of an app carries none of the Debug-only parts of the RemoteDebugFeedback package.
#
# Usage:
#   scripts/check-feedback-release.sh [--host <name>]... [--allow-absent] <App.app | App.ipa | App.zip | executable | folder>
#   scripts/check-feedback-release.sh --expect-debug <App.app | App.ipa | App.zip | executable | folder>
#
# What it looks for (all of these are compiled only under #if DEBUG in the package):
#   - the checklist: its type names, its folder name and the checklist path on the Mac
#   - the Mac upload client: its type names and the labels of the "send to the Mac" route
#   - a Mac host name: rd-mac-… names, any *.ts.net name, and every name given with --host, in any letter case
#     (the package never contains a host name; this catches a macHost literal the app left outside #if DEBUG)
#
# It reads every regular file under the path as bytes, so it also sees resource bundles and property lists.
# An .ipa or .zip (the target itself, or one found under the target, up to three levels deep) is unpacked into
# a temporary folder first, because its contents are compressed and a byte search of the archive sees nothing.
# The temporary folder is removed when the script ends. An archive that cannot be unpacked is an error.
#
# Swift keeps short string literals (15 bytes or less) inside instructions, where a byte search cannot see
# them. That is why the upload path "/v1/crashes" is not a marker: the client type names stand in for it.
#
# The build must link the package: when the name RemoteDebugFeedback is nowhere under the path the check
# fails, because that usually means the wrong folder was given (a build without the package has nothing to
# check). Pass --allow-absent to accept such a build.
#
# --expect-debug turns the check around: every marker must be present. Run it against a Debug build of the
# same app when the package changes, so a renamed type cannot make the release check pass by accident.
#
# Check the exact configuration you ship. The package decides by the DEBUG compilation condition, not by the
# configuration name: a custom configuration that sets DEBUG (for example a "Beta" copied from Debug) compiles
# the Mac client in and skips the consent switch. Archive with the store configuration and check that archive.
#
# Exit status: 0 nothing found (or, with --expect-debug, everything found), 1 a marker or host name was found,
# a marker is missing with --expect-debug, or the package is absent without --allow-absent, 2 wrong usage,
# 3 a file could not be listed, read or unpacked (the result would not be trustworthy).
# The check does not run the app and changes nothing under the path.
#
# Self-test: scripts/test-check-feedback-release.sh builds small folders and archives and runs every branch.
set -euo pipefail

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# A problem that makes the result untrustworthy.
broken() {
  echo "ERROR: $*" >&2
  exit 3
}

expect_debug=0
allow_absent=0
hosts=()
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) [ $# -ge 2 ] || usage; [ -n "$2" ] || usage; hosts+=("$2"); shift 2 ;;
    --expect-debug) expect_debug=1; shift ;;
    --allow-absent) allow_absent=1; shift ;;
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
# Host names. Extended regular expressions, matched on bytes without regard to letter case.
host_patterns=(
  "rd-mac-[0-9a-z]+"
  "[0-9a-z-]+\\.ts\\.net"
)

work="$(mktemp -d "${TMPDIR:-/tmp}/rd-feedback-check.XXXXXX")" || broken "cannot make a temporary folder"
trap 'rm -rf "$work"' EXIT
list="$work/files"       # NUL-separated paths of every regular file to read
: > "$list"

is_archive() {
  case "$1" in
    *.[iI][pP][aA]|*.[zZ][iI][pP]) return 0 ;;
    *) return 1 ;;
  esac
}

unpacked=0
into=""
# Unpacks the archive into a new folder under $work and leaves that folder's path in $into.
unpack() {
  unpacked=$((unpacked + 1))
  into="$work/unpacked-$unpacked"
  mkdir "$into" || broken "cannot make a folder for $1"
  /usr/bin/ditto -x -k "$1" "$into" >/dev/null 2>"$work/unpack.err" \
    || broken "cannot unpack $1: $(head -n 1 "$work/unpack.err")"
}

# Appends the regular files under the root to the list, and the archives among them to $work/archives.
list_files() {
  find "$1" -type f -print0 >> "$list" 2>"$work/find.err" || broken "cannot list files under $1: $(head -n 1 "$work/find.err")"
  [ ! -s "$work/find.err" ] || broken "cannot list files under $1: $(head -n 1 "$work/find.err")"
  find "$1" -type f \( -iname '*.ipa' -o -iname '*.zip' \) -print0 > "$work/archives" 2>"$work/find.err" \
    || broken "cannot list files under $1: $(head -n 1 "$work/find.err")"
}

if [ -f "$target" ] && is_archive "$target"; then
  unpack "$target"
  roots=("$into")
else
  roots=("$target")
fi
level=0
while [ ${#roots[@]} -gt 0 ]; do
  next=()
  for root in "${roots[@]}"; do
    list_files "$root"
    # Archives inside this root: their contents are compressed, so unpack and read those too.
    while IFS= read -r -d '' inner; do
      [ "$level" -lt 3 ] || broken "archives are nested more than three levels deep: $inner"
      unpack "$inner"
      next+=("$into")
    done < "$work/archives"
  done
  level=$((level + 1))
  if [ ${#next[@]} -gt 0 ]; then roots=("${next[@]}"); else roots=(); fi
done

count="$(tr -cd '\000' < "$list" | wc -c | tr -d ' ')"
[ "$count" -gt 0 ] || { echo "no files under: $target" >&2; exit 2; }

# Runs grep over every listed file, a batch at a time (xargs keeps each command line under the system limit).
# grep's "no match" (1) is not an error; anything above it is, and stops the run.
search() {
  LC_ALL=C xargs -0 sh -c 'LC_ALL=C grep -a "$@"; rc=$?; [ "$rc" -le 1 ] || exit 255' sh "$@" < "$list" 2>"$work/grep.err"
}
# Prints the files that contain the fixed string. Extra grep options come first.
containing() {
  local out
  out="$(search -l -F "$@")" || broken "cannot read every file while looking for a marker: $(head -n 1 "$work/grep.err")"
  [ ! -s "$work/grep.err" ] || broken "cannot read every file while looking for a marker: $(head -n 1 "$work/grep.err")"
  printf '%s' "$out"
}
# Prints the distinct byte strings that match the pattern, without regard to letter case.
matching() {
  local out
  out="$(search -o -h -i -E -- "$1")" || broken "cannot read every file while looking for a host name: $(head -n 1 "$work/grep.err")"
  [ ! -s "$work/grep.err" ] || broken "cannot read every file while looking for a host name: $(head -n 1 "$work/grep.err")"
  printf '%s' "$out" | sort -u
}
# Shows a path without the temporary folder in front of it.
shown() { sed "s|^$work/|(unpacked) |; s/^/  /"; }

status=0
package="$(containing -- "RemoteDebugFeedback")"
if [ -z "$package" ]; then
  if [ "$expect_debug" -eq 1 ]; then
    echo "FAIL: --expect-debug needs a build that links the package ($count files read, RemoteDebugFeedback not found)."
    exit 1
  fi
  if [ "$allow_absent" -eq 0 ]; then
    echo "FAIL: RemoteDebugFeedback is not in this build ($count files read). Is this the right path?"
    echo "  Give the built .app, the .ipa or the archive. To accept a build without the package, pass --allow-absent."
    exit 1
  fi
  echo "note: RemoteDebugFeedback is not in this build ($count files read)."
fi

if [ "$expect_debug" -eq 1 ]; then
  for marker in "${markers[@]}"; do
    found="$(containing -- "$marker")"
    if [ -z "$found" ]; then
      echo "FAIL: marker not found in the Debug build (renamed or removed? update this script): $marker"
      status=1
    fi
  done
  [ "$status" -ne 0 ] || echo "OK: all ${#markers[@]} Debug-only markers are present in $count files."
  exit "$status"
fi

for marker in "${markers[@]}"; do
  found="$(containing -- "$marker")"
  if [ -n "$found" ]; then
    echo "FAIL: Debug-only marker \"$marker\" is in:"
    printf '%s\n' "$found" | shown
    status=1
  fi
done
for pattern in "${host_patterns[@]}"; do
  found="$(matching "$pattern")"
  if [ -n "$found" ]; then
    echo "FAIL: a Mac host name is in the build (pattern $pattern, any letter case):"
    printf '%s\n' "$found" | sed 's/^/  /'
    status=1
  fi
done
if [ ${#hosts[@]} -gt 0 ]; then
  for host in "${hosts[@]}"; do
    found="$(containing -i -- "$host")"
    if [ -n "$found" ]; then
      echo "FAIL: host name \"$host\" (any letter case) is in:"
      printf '%s\n' "$found" | shown
      status=1
    fi
  done
fi

if [ -n "$package" ]; then
  manifest="$(LC_ALL=C tr '\000' '\n' < "$list" | grep -c 'RemoteDebugFeedback.*PrivacyInfo\.xcprivacy$' || true)"
  if [ "$manifest" = "0" ] && { [ -d "$target" ] || is_archive "$target"; }; then
    echo "note: the package's PrivacyInfo.xcprivacy is not in this build. In an app it is inside RemoteDebugFeedback_RemoteDebugFeedback.bundle."
  fi
fi

[ "$status" -ne 0 ] || echo "OK: no Debug-only feedback marker and no Mac host name in $count files."
exit "$status"
