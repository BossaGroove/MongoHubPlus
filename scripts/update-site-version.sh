#!/bin/bash
# Writes a release's version into the landing page (docs/index.html). The
# release workflow runs this too and fails if it changes anything, so the
# site can't be left showing an older release.
#
#   scripts/update-site-version.sh 4.5.0
set -euo pipefail

VERSION="${1:?usage: $0 <version>}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
  echo "'$VERSION' is not a version like 4.5.0." >&2
  exit 1
fi
cd "$(dirname "$0")/.."

# Each pattern must match exactly once — if the page's markup changes, fail
# rather than silently leave an old version behind.
replace() {
  local pattern=$1 replacement=$2 file=docs/index.html
  local count
  count=$(grep -cE "$pattern" "$file" || true)
  if [ "$count" != 1 ]; then
    echo "$file: expected one match for /$pattern/, found $count." >&2
    exit 1
  fi
  sed -E -i '' "s#$pattern#$replacement#" "$file"
}

replace '"softwareVersion": "[^"]*"' "\"softwareVersion\": \"$VERSION\""
replace '<span class="js-version">Version [^<]*</span>' \
  "<span class=\"js-version\">Version $VERSION</span>"
replace '<dd class="js-version-plain">[^<]*</dd>' \
  "<dd class=\"js-version-plain\">$VERSION</dd>"
