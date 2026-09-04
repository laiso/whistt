#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
version_script="$root/.github/scripts/release-version.sh"
body_script="$root/.github/scripts/generate-release-body.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

assert_equal() {
  [ "$1" = "$2" ] || { printf 'expected: %s\nactual: %s\n' "$1" "$2" >&2; exit 1; }
}

assert_contains() {
  grep -Fq -- "$2" "$1" || { printf 'missing %s in %s\n' "$2" "$1" >&2; exit 1; }
}

assert_equal v1.3.0 "$($version_script v1.2.3 'Merge pull request #42 from feature')"
assert_equal v1.3.0 "$($version_script v1.2.3 'Add feature (#42)')"
assert_equal v1.2.4 "$($version_script v1.2.3 'Direct maintenance change')"

cd "$test_dir"
git init -q
git config user.email test@example.com
git config user.name 'Release Test'
printf 'first\n' > fixture.txt
git add fixture.txt
git commit -q -m 'Initial release'
git tag v1.0.0
printf 'second\n' >> fixture.txt
git commit -qam 'Add dictation mode'

: > empty-summary.md
$body_script v1.0.0 Whistt-v1.1.0.zip laiso/whistt empty-summary.md fallback.md
assert_contains fallback.md '## Changes'
assert_contains fallback.md 'Add dictation mode'
assert_contains fallback.md 'Whistt-v1.1.0.zip'

printf 'Faster and more reliable dictation.\n' > summary.md
$body_script v1.0.0 Whistt-v1.1.0.zip laiso/whistt summary.md generated.md
assert_contains generated.md '## Release summary'
assert_contains generated.md 'Faster and more reliable dictation.'
if grep -Fq 'Add dictation mode' generated.md; then
  echo 'commit fallback must not appear when a summary exists' >&2
  exit 1
fi

echo 'Release script tests passed.'
