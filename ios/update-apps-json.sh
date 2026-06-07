#!/usr/bin/env bash
# update-apps-json.sh — regenerate ios/apps.json from a built IPA + release info.
#
# Used by .github/workflows/ios.yml (job `archive-ipa`) on a version-tag build,
# and runnable by hand. It rewrites the per-app version / versionDate /
# downloadURL / size fields of the AltStore source manifest so SideStore sees the
# new build. The static fields (name, bundleIdentifier, iconURL, localized
# description, the <OWNER>/<REPO> in sourceURL) are left untouched — fill those
# in once, by hand, per ios/SIDESTORE.md.
#
# Inputs (env vars; CI sets them, override locally as needed):
#   IPA_PATH      path to the built PoseDeck.ipa            (required)
#   VERSION       marketing version, e.g. 0.1.0             (required; CI strips
#                 the leading 'v' from the git tag)
#   OWNER         GitHub owner/org      (default: from GITHUB_REPOSITORY)
#   REPO          GitHub repo name      (default: from GITHUB_REPOSITORY)
#   APPS_JSON     manifest to edit      (default: alongside this script)
#   VERSION_DATE  ISO date             (default: today, UTC)
#   DESCRIPTION   versionDescription   (default: "Build <VERSION>.")
#
# Requires: jq.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_JSON="${APPS_JSON:-$here/apps.json}"

: "${IPA_PATH:?set IPA_PATH to the built PoseDeck.ipa}"
: "${VERSION:?set VERSION (e.g. 0.1.0)}"

# Derive OWNER/REPO from GITHUB_REPOSITORY ("owner/repo") if not given.
if [[ -z "${OWNER:-}" || -z "${REPO:-}" ]]; then
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    OWNER="${OWNER:-${GITHUB_REPOSITORY%%/*}}"
    REPO="${REPO:-${GITHUB_REPOSITORY##*/}}"
  fi
fi
: "${OWNER:?set OWNER or run in GitHub Actions (GITHUB_REPOSITORY)}"
: "${REPO:?set REPO or run in GitHub Actions (GITHUB_REPOSITORY)}"

VERSION_DATE="${VERSION_DATE:-$(date -u +%Y-%m-%d)}"
DESCRIPTION="${DESCRIPTION:-Build ${VERSION}.}"

# Byte size of the IPA (portable: GNU stat -c vs BSD stat -f).
SIZE="$(stat -c%s "$IPA_PATH" 2>/dev/null || stat -f%z "$IPA_PATH")"

DOWNLOAD_URL="https://github.com/${OWNER}/${REPO}/releases/download/v${VERSION}/PoseDeck.ipa"
SOURCE_URL="https://github.com/${OWNER}/${REPO}/releases/latest/download/apps.json"

tmp="$(mktemp)"
jq \
  --arg version "$VERSION" \
  --arg date "$VERSION_DATE" \
  --arg desc "$DESCRIPTION" \
  --arg url "$DOWNLOAD_URL" \
  --arg source "$SOURCE_URL" \
  --argjson size "$SIZE" \
  '
  .sourceURL = $source
  | .apps[0].version = $version
  | .apps[0].versionDate = $date
  | .apps[0].versionDescription = $desc
  | .apps[0].downloadURL = $url
  | .apps[0].size = $size
  ' "$APPS_JSON" > "$tmp"
mv "$tmp" "$APPS_JSON"

echo "Updated $APPS_JSON:"
echo "  version=$VERSION date=$VERSION_DATE size=$SIZE"
echo "  downloadURL=$DOWNLOAD_URL"
