# Timetrap-Jira Sync

A bash script to synchronize time entries from [Tiempo](https://gitlab.com/categulario/tiempo-rs) to Jira worklogs.

## Features

- Syncs time entries from Tiempo to Jira worklogs
- Tracks which entries have been synced to avoid duplicates
- Supports interactive and non-interactive modes
- Can sync entries for a specific date or just today's entries
- Can sync a single entry by ID
- Verbose logging option for debugging

## Requirements

- [tiempo-rs](https://gitlab.com/categulario/tiempo-rs) (installed as 't')
- [jira-cli](https://github.com/ankitpokhrel/jira-cli)
- jq (for JSON parsing)
- sqlite3 (for tracking synced entries)

## Setup

1. Install and configure tiempo-rs
2. Install and configure jira-cli (run 'jira init')
3. Install jq:
   - Linux: `apt-get install jq`
   - macOS: `brew install jq`
4. Install sqlite3:
   - Linux: `apt-get install sqlite3`
   - macOS: `brew install sqlite3`
5. Make sure the script is executable: `chmod +x timetrap_jira_sync.sh`
6. Initialize the sync database: `./timetrap_jira_sync.sh init`

## Usage

### Time Entry Format

Time entries must follow this format to be automatically recognized:
```
@XXX-123: Description/notes
```

Where:
- `XXX-123` is your Jira issue key
- `Description/notes` is the comment for the worklog

If an entry doesn't follow this format, you'll be prompted to enter a Jira issue key (unless in non-interactive mode).

### Commands

```
./timetrap_jira_sync.sh [COMMAND] [OPTIONS]
```

#### Commands:
- `init` - Initialize the sync database (must be run before first sync)
- (default) - Sync time entries with Jira

#### Options:
- `-h, --help` - Show help message
- `-d, --date DATE` - Sync entries for specific date (YYYY-MM-DD format)
- `-y, --yes` - Skip prompts and auto-skip entries without valid format (non-interactive mode)
- `-v, --verbose` - Enable verbose logging
- `-s, --single-entry` - Process only a single tiempo entry (requires -i/--id)
- `-i, --id ENTRY_ID` - Specify the tiempo entry ID to process (used with -s/--single-entry)
- `-f, --force` - Force sync of entries that have already been synced

### Examples

```bash
# Initialize the sync database (required before first use)
./timetrap_jira_sync.sh init

# Sync today's entries (interactive)
./timetrap_jira_sync.sh

# Sync entries for January 15, 2024
./timetrap_jira_sync.sh -d 2024-01-15

# Sync today's entries (skip invalid entries automatically)
./timetrap_jira_sync.sh -y

# Sync specific date in non-interactive mode
./timetrap_jira_sync.sh -d 2024-01-15 -y

# Sync today's entries with verbose logging
./timetrap_jira_sync.sh -v

# Sync only the tiempo entry with ID 123
./timetrap_jira_sync.sh -s -i 123

# Force sync of already synced entries
./timetrap_jira_sync.sh -f
```

## Troubleshooting

- If you get errors about invalid JSON, make sure your tiempo-rs installation is working correctly
- If Jira sync fails, check your jira-cli configuration
- Use the `-v` flag to enable verbose logging for more detailed error messages
