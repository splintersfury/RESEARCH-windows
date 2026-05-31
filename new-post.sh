#!/usr/bin/env bash
# Usage: ./new-post.sh "Article Title" ["https://source-url"]
set -euo pipefail

TITLE="${1:-}"
SOURCE="${2:-}"

if [ -z "$TITLE" ]; then
  echo "Usage: $0 \"Article Title\" [\"https://source-url\"]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$ROOT/templates/post.md"
[ -f "$TEMPLATE" ] || { echo "Template not found: $TEMPLATE" >&2; exit 1; }

DATE_YMD="$(date +%Y-%m-%d)"
DATE_FULL="$(date '+%Y-%m-%d %H:%M:%S %z')"

SLUG="$(printf '%s' "$TITLE" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"

OUT="$ROOT/_posts/${DATE_YMD}-${SLUG}.md"
[ -e "$OUT" ] && { echo "Refusing to overwrite existing file: $OUT" >&2; exit 1; }

mkdir -p "$ROOT/_posts"

sed \
  -e "s|TITLE_PLACEHOLDER|${TITLE}|g" \
  -e "s|DATE_PLACEHOLDER|${DATE_FULL}|g" \
  -e "s|SOURCE_PLACEHOLDER|${SOURCE}|g" \
  "$TEMPLATE" > "$OUT"

echo "Created: $OUT"
