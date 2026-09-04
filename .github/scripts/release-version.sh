#!/bin/sh
set -eu

latest_tag=${1:?usage: release-version.sh LATEST_TAG COMMIT_MESSAGE}
commit_message=${2:?usage: release-version.sh LATEST_TAG COMMIT_MESSAGE}
version=${latest_tag#v}

old_ifs=$IFS
IFS=.
set -- $version
IFS=$old_ifs

[ "$#" -eq 3 ] || { echo "invalid semantic version tag: $latest_tag" >&2; exit 1; }
major=$1
minor=$2
patch=$3

case $major:$minor:$patch in
  *[!0-9:]*|::*|*::*|*:) echo "invalid semantic version tag: $latest_tag" >&2; exit 1 ;;
esac

if printf '%s' "$commit_message" | grep -qE '^Merge pull request #[0-9]+|\(#[0-9]+\)'; then
  printf 'v%s.%s.0\n' "$major" "$((minor + 1))"
else
  printf 'v%s.%s.%s\n' "$major" "$minor" "$((patch + 1))"
fi
