#!/bin/bash

# Tiempo (timetrap) to Jira Worklog Sync Script
# Syncs today's time entries from tiempo-rs to Jira CLI worklogs

set -e

# Configuration
TIEMPO_CMD="t"
JIRA_CMD="jira"
DATE_FORMAT="%Y-%m-%d"
TODAY=$(date +"$DATE_FORMAT")
NON_INTERACTIVE=false
VERBOSE_MODE=false
SINGLE_ENTRY_MODE=false
ENTRY_ID=""
FORCE_SYNC=false
SYNC_DB_PATH="$HOME/.timetrap_jira_sync.db"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    if [ "$VERBOSE_MODE" = true ]; then
        echo -e "${BLUE}[INFO]${NC} $1" >&2
    fi
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warning() {
    if [ "$VERBOSE_MODE" = true ]; then
        echo -e "${YELLOW}[WARNING]${NC} $1" >&2
    fi
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if required commands exist
check_dependencies() {
    local missing_deps=()

    if ! command -v "$TIEMPO_CMD" &> /dev/null; then
        missing_deps+=("tiempo-rs")
    fi

    if ! command -v "$JIRA_CMD" &> /dev/null; then
        missing_deps+=("jira-cli")
    fi

    if ! command -v "jq" &> /dev/null; then
        missing_deps+=("jq")
    fi

    if ! command -v "sqlite3" &> /dev/null; then
        missing_deps+=("sqlite3")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_error "Please install the required tools:"
        log_error "- tiempo-rs: https://gitlab.com/categulario/tiempo-rs"
        log_error "- jira-cli: https://github.com/ankitpokhrel/jira-cli"
        log_error "- jq: for JSON parsing"
        log_error "- sqlite3: for tracking synced entries"
        exit 1
    fi
}

# Initialize the sync database
init_sync_database() {
    log_info "Initializing sync database at $SYNC_DB_PATH"

    # Create the database and synced_entries table if they don't exist
    sqlite3 "$SYNC_DB_PATH" <<EOF
CREATE TABLE IF NOT EXISTS synced_entries (
    entry_id INTEGER PRIMARY KEY,
    synced_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
EOF

    if [ $? -ne 0 ]; then
        log_error "Failed to initialize sync database"
        return 1
    fi

    log_info "Sync database initialized successfully"
    return 0
}

# Check if an entry has been synced
is_entry_synced() {
    local entry_id="$1"

    # Check if the entry exists in the synced_entries table
    local result
    result=$(sqlite3 "$SYNC_DB_PATH" "SELECT COUNT(*) FROM synced_entries WHERE entry_id = $entry_id;")

    if [ "$result" -gt 0 ]; then
        return 0  # Entry is synced
    else
        return 1  # Entry is not synced
    fi
}

# Mark an entry as synced
mark_entry_synced() {
    local entry_id="$1"

    # Insert the entry into the synced_entries table
    sqlite3 "$SYNC_DB_PATH" "INSERT OR REPLACE INTO synced_entries (entry_id) VALUES ($entry_id);"

    if [ $? -ne 0 ]; then
        log_error "Failed to mark entry $entry_id as synced"
        return 1
    fi

    log_info "Entry $entry_id marked as synced"
    return 0
}

# Parse time entry format: '@JIRA-123: Description'
parse_time_entry() {
    local entry="$1"
    local jira_ticket=""
    local description=""

    # Extract JIRA ticket (e.g., @JIRA-123)
    if [[ "$entry" =~ @([A-Za-z0-9]+-[0-9]+) ]]; then
        jira_ticket="${BASH_REMATCH[1]}"
        # Extract description (everything after the colon)
        if [[ "$entry" =~ @[A-Za-z0-9]+-[0-9]+:[[:space:]]*(.*) ]]; then
            description="${BASH_REMATCH[1]}"
        else
            description="Work logged via timetrap sync"
        fi
    else
        # Entry doesn't match format, prompt for issue key
        jira_ticket=$(prompt_for_issue_key "$entry")
        if [ $? -ne 0 ] || [ -z "$jira_ticket" ]; then
            return 1
        fi
        description="$entry"
    fi

    echo "$jira_ticket|$description"
}

# Prompt user for JIRA issue key when entry doesn't match expected format
prompt_for_issue_key() {
    local entry="$1"
    local jira_ticket=""

    # If running in non-interactive mode, skip the entry
    if [ "$NON_INTERACTIVE" = true ]; then
        log_warning "Skipping entry (non-interactive mode): $entry"
        return 1
    fi

    echo
    log_warning "Time entry doesn't match expected format '@XXX-123: Description/notes'"
    echo "Entry: $entry"
    echo

    while true; do
        echo -n "Enter JIRA issue key (e.g., PROJ-123) or 's' to skip: "
        read -r input

        case "$input" in
            s|S|skip|SKIP)
                log_info "Skipping entry: $entry"
                return 1
                ;;
            "")
                log_warning "Please enter a valid issue key or 's' to skip"
                continue
                ;;
            *)
                # Validate issue key format
                if [[ "$input" =~ ^[A-Za-z]+-[0-9]+$ ]]; then
                    jira_ticket="$input"
                    break
                else
                    log_warning "Invalid issue key format. Expected format: PROJ-123"
                    continue
                fi
                ;;
        esac
    done

    echo "$jira_ticket"
}

# Convert duration to Jira format (e.g., "1h 30m")
format_duration() {
    local total_seconds="$1"
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))

    local duration=""
    if [ $hours -gt 0 ]; then
        duration="${hours}h"
    fi
    if [ $minutes -gt 0 ]; then
        if [ -n "$duration" ]; then
            duration="$duration ${minutes}m"
        else
            duration="${minutes}m"
        fi
    fi

    # If duration is empty (less than a minute), set to 1 minute
    if [ -z "$duration" ]; then
        duration="1m"
    fi

    echo "$duration"
}

# Get today's time entries from Timetrap
get_todays_entries() {
    log_info "Fetching today's time entries from Timetrap..."

    # Calculate end date (next day)
    local end_date
    if command -v gdate &> /dev/null; then
        # macOS with GNU coreutils
        end_date=$(gdate -d "$TODAY + 1 day" +"$DATE_FORMAT")
    elif date --version &> /dev/null 2>&1 && date --version | grep -q "GNU"; then
        # GNU date (Linux)
        end_date=$(date -d "$TODAY + 1 day" +"$DATE_FORMAT")
    else
        # BSD date (macOS default)
        end_date=$(date -j -v+1d -f "$DATE_FORMAT" "$TODAY" +"$DATE_FORMAT")
    fi

    log_info "Querying timetrap from $TODAY to $end_date"

    # Get today's entries using tiempo-rs display command in JSON format
    local entries
    local cmd_output
    local cmd_exit_code

    # Capture both stdout and stderr
    cmd_output=$(printf '%s' "$($TIEMPO_CMD d --start "$TODAY" --end "$end_date" --format=json 2>&1)")
    cmd_exit_code=$?

    if [ $cmd_exit_code -ne 0 ]; then
        log_error "Command failed with exit code $cmd_exit_code"
        log_error "Command output: $cmd_output"
        return 1
    fi

    log_info "Raw command output received"

    # Check if output is empty
    if [ -z "$cmd_output" ]; then
        log_warning "Empty response from timetrap command"
        return 1
    fi

    # Try to validate JSON before proceeding
    if ! echo "$cmd_output" | jq '.' >/dev/null 2>&1; then
        log_error "Invalid JSON response from timetrap command"

        # Try alternative command formats
        log_info "Trying alternative command format..."
        cmd_output=$($TIEMPO_CMD display --start "$TODAY" --end "$end_date" --format=json 2>&1) || {
            log_error "Alternative command also failed"
            return 1
        }

        if ! echo "$cmd_output" | jq '.' >/dev/null 2>&1; then
            log_error "Alternative command also returned invalid JSON"
            return 1
        fi
    fi

    entries="$cmd_output"

    if [ "$entries" = "[]" ] || [ "$entries" = "null" ]; then
        log_warning "No time entries found for today ($TODAY)"
        return 1
    fi

    echo "$entries"
}

# Process and sync entries to Jira
sync_entries() {
    local raw_entries="$1"
    # Use jq to properly parse the JSON instead of grep
    local entries="$raw_entries"
    local synced_count=0
    local failed_count=0
    local processed_count=0
    local skipped_count=0

    log_info "Processing time entries..."

        # Try to validate JSON before processing
        if ! echo "$entries" | jq '.' >/dev/null 2>&1; then
            log_error "Invalid JSON input - attempting to extract valid JSON"
            # Try to extract valid JSON array if possible
            entries=$(echo "$entries" | grep -o '\[{.*}\]' || echo "[]")
            log_info "Extracted JSON array"
            # Validate extracted JSON
            if ! echo "$entries" | jq '.' >/dev/null 2>&1; then
                log_error "Failed to extract valid JSON. Aborting."
                return 1
            fi
        fi

        # Check if we have any entries
        local entry_count
        entry_count=$(echo "$entries" | jq '. | length')

        # Ensure entry_count is a valid number
        if ! [[ "$entry_count" =~ ^[0-9]+$ ]]; then
            log_error "Invalid entry count: $entry_count"
            return 1
        fi

        log_info "Found $entry_count entries to process"

        # Process each entry using jq to parse JSON
        for i in $(seq 0 $((entry_count - 1))); do
            log_info "Processing entry $((i+1)) of $entry_count"

            # Debug: Print the current entry index
            log_info "Debug: Processing entry index $i"

            local entry_json
            entry_json=$(echo "$entries" | jq -r ".[$i]")
            log_info "Processing JSON: $entry_json"

            # Extract fields from JSON
            local entry_id
            local description
            local start_time
            local end_time

            entry_id=$(echo "$entry_json" | jq -r '.id // empty')
            log_info "Extracted entry ID: $entry_id"

            # Check if entry has already been synced
            if [ -n "$entry_id" ] && is_entry_synced "$entry_id" && [ "$FORCE_SYNC" != true ]; then
                log_success "⚠ ✓ Entry $entry_id has already been synced, skipping"
                skipped_count=$((skipped_count + 1))
                continue
            fi

            description=$(echo "$entry_json" | jq -r '.note // empty')
            log_info "Extracted description: $description"

            start_time=$(echo "$entry_json" | jq -r '.start // empty')
            log_info "Extracted start time: $start_time"

            end_time=$(echo "$entry_json" | jq -r '.end // empty')
            log_info "Extracted end time: $end_time"

            # Calculate duration
            local duration_seconds=0
            if [ -n "$start_time" ] && [ -n "$end_time" ]; then
                # Temporarily disable exit on error for date calculations
                set +e

                # Use date -d for Linux or gdate for macOS
                if command -v gdate >/dev/null 2>&1; then
                    # macOS with GNU date installed
                    local end_seconds=$(gdate -d "$end_time" +%s)
                    local start_seconds=$(gdate -d "$start_time" +%s)
                    if [ $? -eq 0 ]; then
                        duration_seconds=$((end_seconds - start_seconds))
                    else
                        log_error "Failed to calculate duration with gdate"
                    fi
                else
                    # Linux date command
                    local end_seconds
                    local start_seconds

                    # Try Linux date format first
                    end_seconds=$(date -d "$end_time" +%s 2>/dev/null)
                    if [ $? -ne 0 ]; then
                        # Try BSD/macOS date format
                        end_seconds=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$end_time" +%s 2>/dev/null)
                        if [ $? -ne 0 ]; then
                            log_error "Failed to parse end time: $end_time"
                        fi
                    fi

                    start_seconds=$(date -d "$start_time" +%s 2>/dev/null)
                    if [ $? -ne 0 ]; then
                        # Try BSD/macOS date format
                        start_seconds=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" +%s 2>/dev/null)
                        if [ $? -ne 0 ]; then
                            log_error "Failed to parse start time: $start_time"
                        fi
                    fi

                    if [ -n "$end_seconds" ] && [ -n "$start_seconds" ]; then
                        duration_seconds=$((end_seconds - start_seconds))
                    else
                        log_error "Could not calculate duration due to date parsing errors"
                        duration_seconds=0
                    fi
                fi

                # Re-enable exit on error
                set -e
            fi

            # Temporarily disable exit on error for logging
            set +e
            # Ensure duration_seconds is a valid number
            if [[ "$duration_seconds" =~ ^[0-9]+$ ]]; then
                log_info "Calculated duration: $duration_seconds seconds"
            else
                log_warning "Invalid duration value: '$duration_seconds', setting to 0"
                duration_seconds=0
            fi
            set -e


            # Skip empty descriptions
            if [ -z "$description" ] || [ "$description" = "null" ]; then
                log_warning "Skipping entry with empty description"
                continue
            fi

            # Parse the entry to extract JIRA ticket and clean description
            local parsed
            # Temporarily disable exit on error for parsing
            set +e
            parsed=$(parse_time_entry "$description")
            local parse_status=$?
            set -e

            log_info "Parsed entry: $parsed"
            if [ $parse_status -ne 0 ]; then
                ((failed_count++))
                continue
            fi

            local jira_ticket=$(echo "$parsed" | cut -d'|' -f1)
            local clean_description=$(echo "$parsed" | cut -d'|' -f2)

            # Convert duration to Jira format
            local jira_duration
            jira_duration=$(format_duration "$duration_seconds")
            log_info "Jira duration: $jira_duration"

            # Format start time for Jira
            local started_time
            if command -v gdate >/dev/null 2>&1; then
                started_time=$(gdate -d "$start_time" +'%Y-%m-%dT%H:%M:00.000%z')
            else
                started_time=$(date -d "$start_time" +'%Y-%m-%dT%H:%M:00.000%z' 2>/dev/null ||
                             date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" +'%Y-%m-%dT%H:%M:00.000%z')
            fi
            log_info "Start time for Jira: $started_time"

            log_info "Adding worklog: $jira_ticket - $clean_description ($jira_duration) starting at $started_time"

            # Add worklog to Jira with timeout
            log_info "Executing Jira command: timeout 30s $JIRA_CMD issue worklog add \"$jira_ticket\" \"$jira_duration\" --comment=\"$clean_description\" --started=\"$started_time\" --no-input"

            # Execute command and capture output and exit code
            local jira_output
            local jira_exit_code

            # Debug: Print the Jira command that will be executed
            log_info "Debug: Executing Jira command for entry $((i+1)) of $entry_count"

            # Temporarily disable exit on error
            set +e
            jira_output=$(timeout 30s $JIRA_CMD issue worklog add "$jira_ticket" \
                "$jira_duration" \
                --comment="$clean_description" \
                --started="$started_time" \
                 --no-input 2>&1)
            jira_exit_code=$?

            # Debug: Print the exit code
            log_info "Debug: Jira command exit code: $jira_exit_code"

            # Keep set +e until after all commands in this iteration

            if [ $jira_exit_code -eq 0 ]; then
                log_success "✓ Added worklog to $jira_ticket"
                synced_count=$((synced_count + 1))

                # Mark entry as synced in the database
                if [ -n "$entry_id" ]; then
                    mark_entry_synced "$entry_id"
                fi
            else
                log_error "✗ Failed to add worklog to $jira_ticket (exit code: $jira_exit_code)"
                log_error "Command output: $jira_output"

                # Additional debugging for timeout
                if [ $jira_exit_code -eq 124 ]; then
                    log_error "Command timed out after 30 seconds"
                fi

                failed_count=$((failed_count + 1))
            fi

            # Increment the processed count
            processed_count=$((processed_count + 1))

            # Debug: Print the current counts
            log_info "Debug: Processed $processed_count of $entry_count entries so far (synced: $synced_count, failed: $failed_count)"

            # Re-enable exit on error at the end of each iteration
            set -e
        done

        # Debug: Print the number of entries processed
        log_info "Debug: Found $entry_count entries, processed $processed_count, synced $synced_count, failed $failed_count"

        # Summary
        echo
        log_info "Sync Summary:"
        log_info "Total entries found: $entry_count"
        log_info "Total entries processed: $processed_count"
        log_success "Successfully synced: $synced_count entries"
        if [ $skipped_count -gt 0 ]; then
            log_info "Skipped (already synced): $skipped_count entries"
        fi
        if [ $failed_count -gt 0 ]; then
            log_error "Failed to sync: $failed_count entries"
        fi

        # Check if all entries were processed
        if [ "$processed_count" -ne "$entry_count" ]; then
            log_warning "Not all entries were processed. Expected $entry_count, but processed $processed_count."
        fi

}

# Get a specific tiempo entry by ID
get_single_entry() {
    local entry_id="$1"
    log_info "Fetching tiempo entry with ID: $entry_id"

    local entries
    local cmd_output
    local cmd_exit_code

    # Get all entries in JSON format and filter by ID
    cmd_output=$($TIEMPO_CMD d --format=json 2>&1)
    cmd_exit_code=$?

    if [ $cmd_exit_code -ne 0 ]; then
        log_error "Command failed with exit code $cmd_exit_code"
        log_error "Command output: $cmd_output"
        return 1
    fi

    log_info "Raw command output received"

    # Check if output is empty
    if [ -z "$cmd_output" ]; then
        log_warning "Empty response from timetrap command"
        return 1
    fi

    # Try to validate JSON before proceeding
    if ! echo "$cmd_output" | jq '.' >/dev/null 2>&1; then
        log_error "Invalid JSON response from timetrap command"
        return 1
    fi

    entries="$cmd_output"

    if [ "$entries" = "[]" ] || [ "$entries" = "null" ]; then
        log_warning "No time entries found"
        return 1
    fi

    # Filter for the specific entry ID
    local single_entry
    single_entry=$(echo "$entries" | jq --arg id "$entry_id" '.[] | select(.id == ($id | tonumber))')

    if [ -z "$single_entry" ] || [ "$single_entry" = "null" ]; then
        log_error "No entry found with ID: $entry_id"
        return 1
    fi

    log_info "Found entry with ID: $entry_id"
    echo "$single_entry"
}

# Process and sync a single entry to Jira
sync_single_entry() {
    local entry_json="$1"
    log_info "Processing single time entry..."

    # Extract fields from JSON
    local entry_id
    local description
    local start_time
    local end_time

    entry_id=$(echo "$entry_json" | jq -r '.id // empty')
    log_info "Extracted entry ID: $entry_id"

    # Check if entry has already been synced
    if [ -n "$entry_id" ] && is_entry_synced "$entry_id" && [ "$FORCE_SYNC" != true ]; then
        log_success "⚠ ✓ Entry $entry_id has already been synced, skipping"
        return 0
    fi

    description=$(echo "$entry_json" | jq -r '.note // empty')
    log_info "Extracted description: $description"

    start_time=$(echo "$entry_json" | jq -r '.start // empty')
    log_info "Extracted start time: $start_time"

    end_time=$(echo "$entry_json" | jq -r '.end // empty')
    log_info "Extracted end time: $end_time"

    # Calculate duration
    local duration_seconds=0
    if [ -n "$start_time" ] && [ -n "$end_time" ]; then
        # Temporarily disable exit on error for date calculations
        set +e

        # Use date -d for Linux or gdate for macOS
        if command -v gdate >/dev/null 2>&1; then
            # macOS with GNU date installed
            local end_seconds=$(gdate -d "$end_time" +%s)
            local start_seconds=$(gdate -d "$start_time" +%s)
            if [ $? -eq 0 ]; then
                duration_seconds=$((end_seconds - start_seconds))
            else
                log_error "Failed to calculate duration with gdate"
            fi
        else
            # Linux date command
            local end_seconds
            local start_seconds

            # Try Linux date format first
            end_seconds=$(date -d "$end_time" +%s 2>/dev/null)
            if [ $? -ne 0 ]; then
                # Try BSD/macOS date format
                end_seconds=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$end_time" +%s 2>/dev/null)
                if [ $? -ne 0 ]; then
                    log_error "Failed to parse end time: $end_time"
                fi
            fi

            start_seconds=$(date -d "$start_time" +%s 2>/dev/null)
            if [ $? -ne 0 ]; then
                # Try BSD/macOS date format
                start_seconds=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" +%s 2>/dev/null)
                if [ $? -ne 0 ]; then
                    log_error "Failed to parse start time: $start_time"
                fi
            fi

            if [ -n "$end_seconds" ] && [ -n "$start_seconds" ]; then
                duration_seconds=$((end_seconds - start_seconds))
            else
                log_error "Could not calculate duration due to date parsing errors"
                duration_seconds=0
            fi
        fi

        # Re-enable exit on error
        set -e
    fi

    # Temporarily disable exit on error for logging
    set +e
    # Ensure duration_seconds is a valid number
    if [[ "$duration_seconds" =~ ^[0-9]+$ ]]; then
        log_info "Calculated duration: $duration_seconds seconds"
    else
        log_warning "Invalid duration value: '$duration_seconds', setting to 0"
        duration_seconds=0
    fi
    set -e

    # Skip empty descriptions
    if [ -z "$description" ] || [ "$description" = "null" ]; then
        log_error "Entry has empty description, cannot sync"
        return 1
    fi

    # Parse the entry to extract JIRA ticket and clean description
    local parsed
    # Temporarily disable exit on error for parsing
    set +e
    parsed=$(parse_time_entry "$description")
    local parse_status=$?
    set -e

    log_info "Parsed entry: $parsed"
    if [ $parse_status -ne 0 ]; then
        log_error "Failed to parse entry or entry was skipped"
        return 1
    fi

    local jira_ticket=$(echo "$parsed" | cut -d'|' -f1)
    local clean_description=$(echo "$parsed" | cut -d'|' -f2)

    # Convert duration to Jira format
    local jira_duration
    jira_duration=$(format_duration "$duration_seconds")
    log_info "Jira duration: $jira_duration"

    # Format start time for Jira
    local started_time
    if command -v gdate >/dev/null 2>&1; then
        started_time=$(gdate -d "$start_time" +'%Y-%m-%dT%H:%M:00.000%z')
    else
        started_time=$(date -d "$start_time" +'%Y-%m-%dT%H:%M:00.000%z' 2>/dev/null ||
                     date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" +'%Y-%m-%dT%H:%M:00.000%z')
    fi
    log_info "Start time for Jira: $started_time"

    log_info "Adding worklog: $jira_ticket - $clean_description ($jira_duration) starting at $started_time"

    # Add worklog to Jira with timeout
    log_info "Executing Jira command: timeout 30s $JIRA_CMD issue worklog add \"$jira_ticket\" \"$jira_duration\" --comment=\"$clean_description\" --started=\"$started_time\" --no-input"

    # Execute command and capture output and exit code
    local jira_output
    local jira_exit_code

    # Temporarily disable exit on error
    set +e
    jira_output=$(timeout 30s $JIRA_CMD issue worklog add "$jira_ticket" \
        "$jira_duration" \
        --comment="$clean_description" \
        --started="$started_time" \
         --no-input 2>&1)
    jira_exit_code=$?

    if [ $jira_exit_code -eq 0 ]; then
        log_success "✓ Added worklog to $jira_ticket"

        # Mark entry as synced in the database
        if [ -n "$entry_id" ]; then
            mark_entry_synced "$entry_id"
        fi

        set -e
        return 0
    else
        log_error "✗ Failed to add worklog to $jira_ticket (exit code: $jira_exit_code)"
        log_error "Command output: $jira_output"

        # Additional debugging for timeout
        if [ $jira_exit_code -eq 124 ]; then
            log_error "Command timed out after 30 seconds"
        fi

        set -e
        return 1
    fi
}

# Main function for single entry processing
main_single_entry() {
    log_info "Starting single entry sync for entry ID: $ENTRY_ID"

    # Check dependencies
    check_dependencies

    # Initialize the sync database
    init_sync_database

    # Get the specific entry
    local entry
    entry=$(get_single_entry "$ENTRY_ID")

    if [ $? -ne 0 ]; then
        log_error "Failed to retrieve entry with ID: $ENTRY_ID"
        exit 1
    fi

    # Sync the entry
    if sync_single_entry "$entry"; then
        log_success "Single entry sync completed successfully!"
    else
        log_error "Single entry sync failed!"
        exit 1
    fi
}

# Main function
main() {
    # Check if we're in single entry mode
    if [ "$SINGLE_ENTRY_MODE" = true ]; then
        main_single_entry
        return
    fi

    log_info "Starting Timetrap to Jira worklog sync for $TODAY"

    # Check dependencies
    check_dependencies

    # Get today's entries
    local entries
    entries=$(get_todays_entries)

    if [ $? -ne 0 ]; then
        exit 1
    fi

    # Sync entries
    sync_entries "$entries"

    log_success "Sync completed!"
}

# Show help
show_help() {
    cat << EOF
Tiempo (Timetrap) to Jira Worklog Sync Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -h, --help           Show this help message
    -d, --date           Sync entries for specific date (YYYY-MM-DD format)
                         Default: today
    -y, --yes            Skip prompts and auto-skip entries without valid format
                         (non-interactive mode)
    -v, --verbose        Enable verbose logging (shows detailed progress information)
    -s, --single-entry   Process only a single tiempo entry (requires -i/--id)
    -i, --id <ENTRY_ID>  Specify the tiempo entry ID to process (used with -s/--single-entry)
    -f, --force          Force sync of entries that have already been synced

EXAMPLES:
    $0                          # Sync today's entries (interactive)
    $0 -d 2024-01-15           # Sync entries for January 15, 2024
    $0 -y                      # Sync today's entries (skip invalid entries automatically)
    $0 -d 2024-01-15 -y        # Sync specific date in non-interactive mode
    $0 -v                      # Sync today's entries with verbose logging
    $0 -d 2024-01-15 -v        # Sync specific date with verbose logging
    $0 -s -i 123               # Sync only the tiempo entry with ID 123
    $0 --single-entry --id 123 # Sync single entry (long form)
    $0 -s -i 123 -v            # Sync single entry with verbose logging
    $0 -f                      # Force sync of already synced entries
    $0 -s -i 123 -f            # Force sync of a specific entry even if already synced

REQUIREMENTS:
    - tiempo-rs: https://gitlab.com/categulario/tiempo-rs (installed as 't')
    - jira-cli: https://github.com/ankitpokhrel/jira-cli
    - jq: for JSON parsing
    - sqlite3: for tracking synced entries
    - Time entries must follow format: '@XXX-123: Description/notes'

SETUP:
    1. Install and configure tiempo-rs
    2. Install and configure jira-cli (run 'jira init')
    3. Install jq: apt-get install jq (Linux) or brew install jq (macOS)
    4. Install sqlite3: apt-get install sqlite3 (Linux) or brew install sqlite3 (macOS)
    5. Make sure this script is executable: chmod +x $0
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -d|--date)
            if [[ -n "$2" && "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                TODAY="$2"
                shift 2
            else
                log_error "Invalid date format. Use YYYY-MM-DD"
                exit 1
            fi
            ;;
        -y|--yes)
            NON_INTERACTIVE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE_MODE=true
            shift
            ;;
        -s|--single-entry)
            SINGLE_ENTRY_MODE=true
            shift
            ;;
        -i|--id)
            if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                ENTRY_ID="$2"
                shift 2
            else
                log_error "Invalid entry ID. Must be a number"
                exit 1
            fi
            ;;
        -f|--force)
            FORCE_SYNC=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate single entry mode arguments
if [ "$SINGLE_ENTRY_MODE" = true ] && [ -z "$ENTRY_ID" ]; then
    log_error "-s/--single-entry requires -i/--id <ENTRY_ID>"
    show_help
    exit 1
fi

if [ -n "$ENTRY_ID" ] && [ "$SINGLE_ENTRY_MODE" != true ]; then
    log_error "-i/--id can only be used with -s/--single-entry"
    show_help
    exit 1
fi

# Run main function
main
