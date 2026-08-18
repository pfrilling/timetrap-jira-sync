#!/usr/bin/env bash
# jira_timelog_report.sh — Summarize your Jira worklogs by project
#
# Reports hours logged today and for the current Sat–Fri week, grouped by
# project. Read-only: it never writes to Jira.
#
# jira-cli (v1.7.0) only implements 'jira issue worklog add', so this script
# talks to the Jira Cloud REST API directly, reading credentials from the
# jira-cli config (~/.config/.jira/.config.yml) and the JIRA_API_TOKEN
# environment variable — same approach as confluence-to-md.sh.
#
# Usage:
#   ./jira_timelog_report.sh [OPTIONS]
#
# Dependencies: curl, jq, awk

set -euo pipefail

JIRA_CONFIG="${HOME}/.config/.jira/.config.yml"

# ── Options ───────────────────────────────────────────────────────────────────

REF_DATE=""
SHOW_TODAY=true
SHOW_WEEK=true
SHOW_DETAIL=false
SHOW_DAYS=false
CSV_MODE=false
VERBOSE=false

# ── Colors (only when stdout is a terminal) ───────────────────────────────────

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  DIM='\033[2m'
  NC='\033[0m'
else
  GREEN=''; YELLOW=''; BLUE=''; DIM=''; NC=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

die() { echo "Error: $*" >&2; exit 1; }

log_verbose() {
  [[ "$VERBOSE" == true ]] && echo -e "${DIM}[debug] $*${NC}" >&2 || true
}

require() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
  done
}

# Read a key from the jira-cli YAML config (no yq needed)
read_config() {
  local key="$1"
  grep -m1 "^${key}:" "$JIRA_CONFIG" 2>/dev/null | sed "s/^${key}:[[:space:]]*//" | tr -d "'\"" || true
}

show_help() {
  cat << EOF
Jira Worklog Report — hours logged, grouped by project

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -d, --date YYYY-MM-DD   Reference date. Both the "today" section and the
                            Sat–Fri week window derive from it. Default: today
    -t, --today             Show only the daily section
    -w, --week              Show only the weekly section
    -D, --detail            Add a per-issue breakdown under each project
        --days              Add a per-day totals table for the week
        --csv               Machine-readable output:
                            scope,project_key,project_name,issue_key,date,hours
    -v, --verbose           Log API activity to stderr

WEEK DEFINITION:
    Weeks run Saturday through Friday. For a Tuesday reference date, the window
    is the preceding Saturday through the following Friday.

EXAMPLES:
    $0                        # Today + this week, grouped by project
    $0 -D                     # ...with a per-issue breakdown
    $0 -d 2026-08-14          # The Sat–Fri week containing 2026-08-14
    $0 -w --days              # Week totals plus a day-by-day table
    $0 --csv > timelog.csv    # Export for a spreadsheet

REQUIREMENTS:
    - jira-cli configured (run 'jira init') for $JIRA_CONFIG
    - JIRA_API_TOKEN exported in your shell profile
    - curl, jq, awk
EOF
}

# ── Cross-platform date handling ──────────────────────────────────────────────
# Matches the gdate → GNU date → BSD date cascade used in timetrap_jira_sync.sh.

if command -v gdate &>/dev/null; then
  DATE_KIND="gnu"; DATE_BIN="gdate"
elif date -d "2000-01-01" +%F &>/dev/null; then
  DATE_KIND="gnu"; DATE_BIN="date"
else
  DATE_KIND="bsd"; DATE_BIN="date"
fi

# date_fmt YYYY-MM-DD FORMAT → formatted date
date_fmt() {
  local d="$1" fmt="$2"
  if [[ "$DATE_KIND" == "gnu" ]]; then
    "$DATE_BIN" -d "$d" +"$fmt"
  else
    "$DATE_BIN" -j -f "%Y-%m-%d" "$d" +"$fmt"
  fi
}

# date_shift YYYY-MM-DD DAYS → YYYY-MM-DD (DAYS may be negative)
date_shift() {
  local d="$1" days="$2"
  [[ "$days" =~ ^[-+] ]] || days="+$days"
  if [[ "$DATE_KIND" == "gnu" ]]; then
    "$DATE_BIN" -d "$d $days days" +%F
  else
    "$DATE_BIN" -j -v"${days}d" -f "%Y-%m-%d" "$d" +%F
  fi
}

# epoch_ms YYYY-MM-DD → epoch milliseconds at local midnight
epoch_ms() {
  local d="$1" secs
  if [[ "$DATE_KIND" == "gnu" ]]; then
    secs=$("$DATE_BIN" -d "$d 00:00:00" +%s)
  else
    secs=$("$DATE_BIN" -j -f "%Y-%m-%d %H:%M:%S" "$d 00:00:00" +%s)
  fi
  echo $(( secs * 1000 ))
}

# URL-encode a string
urlencode() { printf '%s' "$1" | jq -sRr @uri; }

# ── Parse arguments ───────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)   show_help; exit 0 ;;
    -d|--date)
      [[ $# -ge 2 ]] || die "-d/--date requires a YYYY-MM-DD argument."
      REF_DATE="$2"; shift 2 ;;
    -t|--today)  SHOW_WEEK=false;  shift ;;
    -w|--week)   SHOW_TODAY=false; shift ;;
    -D|--detail) SHOW_DETAIL=true; shift ;;
    --days)      SHOW_DAYS=true;   shift ;;
    --csv)       CSV_MODE=true;    shift ;;
    -v|--verbose) VERBOSE=true;    shift ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

# ── Validate environment ──────────────────────────────────────────────────────

require curl jq awk

[[ -f "$JIRA_CONFIG" ]] || die "jira-cli config not found at $JIRA_CONFIG. Run 'jira init' first."

TOKEN="${JIRA_API_TOKEN:-}"
[[ -n "$TOKEN" ]] || die "JIRA_API_TOKEN is not set. Add it to your shell profile."

LOGIN="$(read_config login)"
SERVER="$(read_config server)"
[[ -n "$LOGIN" ]]  || die "Could not read 'login' from $JIRA_CONFIG"
[[ -n "$SERVER" ]] || die "Could not read 'server' from $JIRA_CONFIG"

# ── Resolve the date window ───────────────────────────────────────────────────

if [[ -n "$REF_DATE" ]]; then
  [[ "$REF_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "Invalid date '$REF_DATE'. Expected YYYY-MM-DD."
  date_fmt "$REF_DATE" %F >/dev/null 2>&1 || die "Invalid date '$REF_DATE'."
else
  REF_DATE=$(date +%F)
fi

# Weeks run Saturday → Friday. %u is 1=Mon … 7=Sun, so (dow + 1) % 7 is the
# number of days back to the week's Saturday: Sat→0, Sun→1, Mon→2 … Fri→6.
DOW=$(date_fmt "$REF_DATE" %u)
WEEK_START=$(date_shift "$REF_DATE" "-$(( (DOW + 1) % 7 ))")
WEEK_END=$(date_shift "$WEEK_START" 6)

log_verbose "reference date $REF_DATE (dow=$DOW) → week $WEEK_START .. $WEEK_END"

# ── Fetch worklogs ────────────────────────────────────────────────────────────

api_get() {
  curl --silent --fail --config - --header "Accept: application/json" "$1" \
    <<< "user = \"${LOGIN}:${TOKEN}\""
}

ACCOUNT_ID=$(api_get "${SERVER}/rest/api/3/myself" | jq -r '.accountId') \
  || die "Failed to authenticate against $SERVER. Check JIRA_API_TOKEN."
[[ -n "$ACCOUNT_ID" && "$ACCOUNT_ID" != "null" ]] || die "Could not determine your Jira accountId."
log_verbose "accountId $ACCOUNT_ID"

# BSD/macOS mktemp requires an explicit template, so always pass one.
TMP_BASE="${TMPDIR:-/tmp}"
TMPDIR_WORK=$(mktemp -d "${TMP_BASE%/}/jira_timelog_report.XXXXXX")
trap 'rm -rf "$TMPDIR_WORK"' EXIT
ISSUES_TSV="$TMPDIR_WORK/issues.tsv"
ENTRIES_TSV="$TMPDIR_WORK/entries.tsv"
: > "$ISSUES_TSV"
: > "$ENTRIES_TSV"

# Candidate issues: worklogDate/worklogAuthor match at the *issue* level, so
# this only narrows the set — the exact author/date filter happens per worklog.
JQL="worklogAuthor = \"${ACCOUNT_ID}\" AND worklogDate >= \"${WEEK_START}\" AND worklogDate <= \"${WEEK_END}\""
log_verbose "JQL: $JQL"

PAGE_TOKEN=""
while :; do
  url="${SERVER}/rest/api/3/search/jql?jql=$(urlencode "$JQL")&fields=project&maxResults=100"
  [[ -n "$PAGE_TOKEN" ]] && url+="&nextPageToken=$(urlencode "$PAGE_TOKEN")"
  page=$(api_get "$url") || die "Issue search failed. Check your credentials and JQL support."
  jq -r '.issues[]? | [.key, .fields.project.key, .fields.project.name] | @tsv' <<< "$page" >> "$ISSUES_TSV"
  PAGE_TOKEN=$(jq -r '.nextPageToken // empty' <<< "$page")
  [[ -n "$PAGE_TOKEN" ]] || break
  log_verbose "paging issue search…"
done

ISSUE_COUNT=$(wc -l < "$ISSUES_TSV" | tr -d ' ')
log_verbose "$ISSUE_COUNT candidate issue(s)"

# startedAfter is exclusive, so step back 1ms from the window's midnight.
STARTED_AFTER=$(( $(epoch_ms "$WEEK_START") - 1 ))

while IFS=$'\t' read -r issue_key project_key project_name; do
  [[ -n "$issue_key" ]] || continue
  start_at=0
  while :; do
    wl=$(api_get "${SERVER}/rest/api/3/issue/${issue_key}/worklog?startedAfter=${STARTED_AFTER}&startAt=${start_at}&maxResults=1000") \
      || die "Failed to fetch worklogs for $issue_key."
    jq -r --arg me "$ACCOUNT_ID" --arg ik "$issue_key" --arg pk "$project_key" --arg pn "$project_name" '
      .worklogs[]? | select(.author.accountId == $me)
      | [ (.started[0:10]), $pk, $pn, $ik, .timeSpentSeconds ] | @tsv' <<< "$wl" >> "$ENTRIES_TSV"
    total=$(jq -r '.total // 0' <<< "$wl")
    got=$(jq -r '.worklogs | length' <<< "$wl")
    start_at=$(( start_at + got ))
    (( got > 0 && start_at < total )) || break
    log_verbose "paging worklogs for $issue_key ($start_at/$total)"
  done
  log_verbose "fetched worklogs for $issue_key"
done < "$ISSUES_TSV"

# Trim to the window: an issue matched by JQL can still carry worklogs outside it.
awk -F'\t' -v ws="$WEEK_START" -v we="$WEEK_END" '$1 >= ws && $1 <= we' "$ENTRIES_TSV" \
  > "$TMPDIR_WORK/week.tsv"
awk -F'\t' -v d="$REF_DATE" '$1 == d' "$TMPDIR_WORK/week.tsv" > "$TMPDIR_WORK/today.tsv"

# ── Render ────────────────────────────────────────────────────────────────────

# CSV export: both scopes, one row per worklog.
if [[ "$CSV_MODE" == true ]]; then
  echo "scope,project_key,project_name,issue_key,date,hours"
  csv_rows() {
    awk -F'\t' -v scope="$1" 'BEGIN { OFS="" }
      {
        name = $3; gsub(/"/, "\"\"", name)
        printf "%s,%s,\"%s\",%s,%s,%.2f\n", scope, $2, name, $4, $1, $5/3600
      }' "$2" | sort -t, -k2,2 -k4,4
  }
  [[ "$SHOW_TODAY" == true ]] && csv_rows today "$TMPDIR_WORK/today.tsv"
  [[ "$SHOW_WEEK"  == true ]] && csv_rows week  "$TMPDIR_WORK/week.tsv"
  exit 0
fi

# Group a TSV by project (optionally with a per-issue breakdown), sorted by
# hours descending, with a total line.
render_group() {
  local file="$1" detail="$2"
  awk -F'\t' -v detail="$detail" '
    {
      secs[$2] += $5; cnt[$2]++; name[$2] = $3
      if (detail == "true") { isecs[$2 SUBSEP $4] += $5 }
      grand += $5; gcnt++
      if (length($2) > kw) kw = length($2)
      if (length($3) > nw) nw = length($3)
    }
    END {
      if (gcnt == 0) { print "  (no time logged)"; exit }
      if (nw > 34) nw = 34
      n = 0
      for (p in secs) { keys[++n] = p }
      # selection sort by hours desc, project key asc on ties
      for (i = 1; i <= n; i++) {
        m = i
        for (j = i + 1; j <= n; j++) {
          if (secs[keys[j]] > secs[keys[m]] || (secs[keys[j]] == secs[keys[m]] && keys[j] < keys[m])) m = j
        }
        t = keys[i]; keys[i] = keys[m]; keys[m] = t
      }
      for (i = 1; i <= n; i++) {
        p = keys[i]
        printf "  %-*s  %-*.*s  %6.2fh  %3d %s\n", kw, p, nw, nw, name[p], secs[p]/3600, cnt[p], (cnt[p] == 1 ? "entry" : "entries")
        if (detail == "true") {
          in_ = 0
          for (k in isecs) {
            split(k, parts, SUBSEP)
            if (parts[1] == p) { ikeys[++in_] = parts[2]; ivals[parts[2]] = isecs[k] }
          }
          for (a = 1; a <= in_; a++) {
            b = a
            for (c = a + 1; c <= in_; c++) {
              if (ivals[ikeys[c]] > ivals[ikeys[b]] || (ivals[ikeys[c]] == ivals[ikeys[b]] && ikeys[c] < ikeys[b])) b = c
            }
            t = ikeys[a]; ikeys[a] = ikeys[b]; ikeys[b] = t
          }
          for (a = 1; a <= in_; a++) printf "  %-*s  %-*s  %6.2fh\n", kw, "", nw, ikeys[a], ivals[ikeys[a]]/3600
          delete ikeys; delete ivals
        }
      }
      dashes = ""
      for (i = 0; i < kw + nw + 2; i++) dashes = dashes "─"
      printf "  %s  %6.2fh  %3d %s\n", dashes, grand/3600, gcnt, (gcnt == 1 ? "entry" : "entries")
    }' "$file"
}

if [[ "$SHOW_TODAY" == true ]]; then
  echo -e "${BLUE}Today — ${REF_DATE} ($(date_fmt "$REF_DATE" %a))${NC}"
  render_group "$TMPDIR_WORK/today.tsv" "$SHOW_DETAIL"
  echo
fi

if [[ "$SHOW_WEEK" == true ]]; then
  echo -e "${BLUE}Week — ${WEEK_START} (Sat) .. ${WEEK_END} (Fri)${NC}"
  render_group "$TMPDIR_WORK/week.tsv" "$SHOW_DETAIL"

  if [[ "$SHOW_DAYS" == true ]]; then
    echo
    echo -e "${YELLOW}By day${NC}"
    if [[ -s "$TMPDIR_WORK/week.tsv" ]]; then
      awk -F'\t' '{ secs[$1] += $5; cnt[$1]++ } END { for (d in secs) printf "%s\t%.2f\t%d\n", d, secs[d]/3600, cnt[d] }' \
        "$TMPDIR_WORK/week.tsv" | sort | while IFS=$'\t' read -r d h c; do
          printf "  %s (%s)  %6.2fh  %3d %s\n" "$d" "$(date_fmt "$d" %a)" "$h" "$c" "$([[ "$c" == 1 ]] && echo "entry" || echo "entries")"
        done
    else
      echo "  (no time logged)"
    fi
  fi
  echo
fi
