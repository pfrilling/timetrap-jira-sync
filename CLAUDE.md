# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Scripts

| Script | Purpose |
|--------|---------|
| `timetrap_jira_sync.sh` | Main script: syncs tiempo-rs time entries to Jira worklogs |
| `confluence-to-md.sh` | Downloads a Confluence page as Markdown |

## Running the scripts

```bash
# One-time setup
./timetrap_jira_sync.sh init

# Common usage
./timetrap_jira_sync.sh              # Sync today's entries (interactive)
./timetrap_jira_sync.sh -d YYYY-MM-DD  # Sync a specific date
./timetrap_jira_sync.sh -s -i <ID>   # Sync a single entry by tiempo ID
./timetrap_jira_sync.sh -y           # Non-interactive (skip unparseable entries)
./timetrap_jira_sync.sh -f           # Force re-sync already-synced entries
./timetrap_jira_sync.sh -v           # Verbose logging

# Confluence download
./confluence-to-md.sh <PAGE_ID> [output.md]
```

## Architecture

### timetrap_jira_sync.sh

**Data flow:** tiempo-rs → JSON → parse → Jira CLI → SQLite

1. Calls `t d --start DATE --end DATE --format=json` to get time entries as JSON
2. Parses each entry's `note` field for the pattern `@XXX-123: Description`
3. Calculates duration from `start`/`end` ISO timestamps
4. Calls `jira issue worklog add <TICKET> <DURATION> --comment=... --started=...`
5. Records synced entry IDs in SQLite at `~/.timetrap_jira_sync.db`

**Duplicate prevention:** The `synced_entries` table (keyed by tiempo entry ID) prevents re-syncing. The `-f` flag bypasses this check.

**Two sync modes:**
- Batch mode (`get_todays_entries` + `sync_entries`): processes all entries for a date
- Single mode (`get_single_entry` + `sync_single_entry`): fetches **all** entries (no date filter) then filters by ID client-side; `sync_single_entry` returns exit code 2 (not 1) when an entry is already synced, so callers can distinguish "already done" from "error"

**Cross-platform date handling:** The scripts detect `gdate` (macOS with GNU coreutils), GNU `date` (Linux), and BSD `date` (macOS default) and branch accordingly for date arithmetic and formatting.

### confluence-to-md.sh

Reads credentials from the jira-cli config at `~/.config/.jira/.config.yml` (for `login` and `server`) using plain `grep`/`sed` (no yq/python3 needed) and the `JIRA_API_TOKEN` environment variable. Fetches the Confluence REST API (`/wiki/rest/api/content/<PAGE_ID>?expand=body.view,title`) and converts the HTML response to GitHub-flavored Markdown using `pandoc --from html --to gfm+raw_html --wrap none --strip-comments`. The `+raw_html` extension preserves HTML that pandoc cannot convert cleanly (common in Confluence content). Output is written to a temp file and moved into place atomically so a failed conversion never leaves a truncated output file.

## Dependencies

- `t` (tiempo-rs) — time tracker
- `jira` (jira-cli) — must be configured via `jira init`
- `jq` — JSON parsing
- `sqlite3` — sync state tracking
- `pandoc` — HTML-to-Markdown conversion (confluence-to-md.sh only)
- `curl` — HTTP requests (confluence-to-md.sh only)

## Time entry format

Entries must be noted in tiempo-rs as:
```
@XXX-123: Description/notes
```
Entries not matching this format trigger an interactive prompt (or are skipped with `-y`).
