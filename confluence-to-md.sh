#!/usr/bin/env bash
# confluence-to-md.sh — Download a Confluence page as Markdown
#
# Reads credentials from the jira-cli config (~/.config/.jira/.config.yml)
# and the JIRA_API_TOKEN environment variable.
#
# Usage:
#   ./confluence-to-md.sh <PAGE_ID> [output.md]
#
# Dependencies: curl, jq, pandoc
#
# Examples:
#   ./confluence-to-md.sh 123456789
#   ./confluence-to-md.sh 123456789 my-page.md

set -euo pipefail

JIRA_CONFIG="${HOME}/.config/.jira/.config.yml"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() { echo "Error: $*" >&2; exit 1; }

require() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
  done
}

# Read a key from the jira-cli YAML config (no yq needed)
read_config() {
  local key="$1"
  grep -m1 "^${key}:" "$JIRA_CONFIG" 2>/dev/null | sed "s/^${key}:[[:space:]]*//" | tr -d "'\""
}

# ── Validate dependencies ─────────────────────────────────────────────────────

require curl jq pandoc

# ── Load credentials ──────────────────────────────────────────────────────────

[[ -f "$JIRA_CONFIG" ]] || die "jira-cli config not found at $JIRA_CONFIG. Run 'jira init' first."

TOKEN="${JIRA_API_TOKEN:-}"
[[ -n "$TOKEN" ]] || die "JIRA_API_TOKEN is not set. Add it to your shell profile."

LOGIN="$(read_config login)"
SERVER="$(read_config server)"

[[ -n "$LOGIN" ]] || die "Could not read 'login' from $JIRA_CONFIG"
[[ -n "$SERVER" ]] || die "Could not read 'server' from $JIRA_CONFIG"

# Confluence lives on the same host as Jira
CONFLUENCE_BASE="$SERVER"

# ── Arguments ─────────────────────────────────────────────────────────────────

[[ $# -ge 1 ]] || {
  echo "Usage: $(basename "$0") <PAGE_ID> [output.md]"
  exit 1
}

PAGE_ID="$1"
OUTPUT="${2:-confluence-${PAGE_ID}.md}"

# ── Fetch page ────────────────────────────────────────────────────────────────

API_URL="${CONFLUENCE_BASE}/wiki/rest/api/content/${PAGE_ID}?expand=body.view,title"

echo "Fetching page ${PAGE_ID} from ${CONFLUENCE_BASE}..."

RESPONSE=$(curl --silent --fail \
  --config - \
  --header "Accept: application/json" \
  "$API_URL" \
  <<< "user = \"${LOGIN}:${TOKEN}\"") || die "Failed to fetch page. Check the PAGE_ID and your credentials."

TITLE=$(echo "$RESPONSE" | jq -r '.title // "Untitled"')
HTML=$(echo "$RESPONSE" | jq -r '.body.view.value')

[[ -n "$HTML" && "$HTML" != "null" ]] || die "Page returned empty content."

# ── Convert to Markdown ───────────────────────────────────────────────────────

echo "Converting to Markdown..."

{
  printf "# %s\n\n" "$TITLE"
  echo "$HTML" | pandoc \
    --from html \
    --to gfm-raw_html \
    --wrap none \
    --strip-comments
} > "$OUTPUT"

echo "Saved: $OUTPUT"
