#!/usr/bin/env bash
# Bump minor version, update VERSION file, tag, and push
set -euo pipefail

VERSION_FILE="$(git rev-parse --show-toplevel)/VERSION"
CURRENT=$(cat "$VERSION_FILE" | tr -d '[:space:]')

IFS='.' read -r major minor _patch <<< "$CURRENT"
NEW_MINOR=$((minor + 1))
NEW_VERSION="${major}.${NEW_MINOR}.0"

echo "$NEW_VERSION" > "$VERSION_FILE"

# Patch version into dashboard footer and README
ROOT="$(git rev-parse --show-toplevel)"
sed -i '' "s/TagBag v${CURRENT}/TagBag v${NEW_VERSION}/" "${ROOT}/web/index.html"
sed -i '' "s/v${CURRENT}/v${NEW_VERSION}/" "${ROOT}/README.md"

git add "$VERSION_FILE" "${ROOT}/web/index.html" "${ROOT}/README.md"
git commit -m "bump version to v${NEW_VERSION}"
git tag -a "v${NEW_VERSION}" -m "v${NEW_VERSION}"

echo "Bumped ${CURRENT} → ${NEW_VERSION}"
echo "Run 'git push && git push --tags' to publish"
