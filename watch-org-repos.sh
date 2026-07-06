#!/bin/bash
# Batch watch/unwatch or inspect subscriptions for all repos in a GitHub org.
#
# Uses the GitHub REST API via `gh api`. Requires bash 4+, gh, python3.
# Run check_dependencies at startup; install hints are printed if anything is missing.
# Authenticate once: gh auth login
# For read/write subscription state, refresh the notifications scope once:
#   gh auth refresh -h github.com -s notifications
#
# Boolean API fields must use gh's typed -F flag (not -f), or JSON via --input.
# GitHub has NO org-wide "watch" REST endpoint: not even for org owners.
# The UI org-watch button is not exposed via API. This script applies the
# chosen level to every repository in the org individually.
#
# Subscription levels map to PUT/DELETE /repos/{owner}/{repo}/subscription:
#   all       Watch: receive notifications (subscribed=true, ignored=false)
#   ignore    Mute: block notifications but keep a subscription record (ignored=true)
#   none      Unwatch: DELETE repository subscription entirely
#
# Note: GitHub UI levels like "Participating only" or per-event custom watches
# are not exposed on this REST endpoint; use `all` or configure those in the UI.
#
# Usage:
#   ./watch-org-repos.sh los-tv-x86
#   ./watch-org-repos.sh --owned-orgs --level=all
#   ./watch-org-repos.sh --level=ignore Bliss-Bass
#   ./watch-org-repos.sh --status los-tv-x86
#   ./watch-org-repos.sh --subscriptions
#   ./watch-org-repos.sh --subscriptions Bliss-Bass
#   ./watch-org-repos.sh --events --limit=20 los-tv-x86
#   ./watch-org-repos.sh --dry-run --level=none los-tv-x86
#   ./watch-org-repos.sh --owned-orgs --exclude=android_art,external_*
#   ./watch-org-repos.sh --owned-orgs
#     (auto-loads watch-org-excludes.txt from this script's directory, if present)
#   ./watch-org-repos.sh los-tv-x86 --exclude-file=watch-org-excludes.txt
#
# Exclude file (watch-org-excludes.txt beside this script, or --exclude-file):
#   One pattern per line. Blank lines; lines starting with # are ignored.
#
#   Example watch-org-excludes.txt (same directory as this script):
#     # Skip vendor mirror / external trees
#     external_*
#     android_external_*
#
#     # Skip by repo name in every org (--owned-orgs)
#     android_art
#     lineage_bass_android
#
#     # Org-qualified: only that owner/repo
#     los-tv-x86/android_bionic
#     Bliss-Bass/some-archived-repo
#
#   Same patterns work with --exclude= on the command line (comma-separated).
#
# See: https://docs.github.com/en/rest/activity/watching

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_EXCLUDE_FILE="${SCRIPT_DIR}/watch-org-excludes.txt"

LEVEL="all"
ORG=""
DRY_RUN=0
SHOW_STATUS=0
SHOW_EVENTS=0
SHOW_SUBSCRIPTIONS=0
OWNED_ORGS=0
REPO_LIMIT=1000
EVENT_LIMIT=30
EXCLUDE_PATTERNS=()
EXCLUDE_FILE_LOADED=0
EXCLUDE_FILE_PATH=""

usage() {
    sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  -l, --level=LEVEL    Subscription level: all, ignore, none (default: all)
  --owned-orgs         Process every org you own (admin role), one org at a time
  --status             Print current subscription for each repo (no changes)
  --subscriptions      List all repos you are subscribed to (optional ORG filter)
  --events             Print recent public org events, then exit
  --limit=N            Max repos to process per org (default: 1000)
  --event-limit=N      Max events with --events (default: 30)
  --exclude=PAT[,PAT]  Skip repos (repeatable; comma-separated). See below.
  --exclude-file=PATH  Exclude patterns file (relative paths resolve from script dir)
  --dry-run            Print actions without calling the API
  -h, --help           Show this help

Levels:
  all     Watch all activity (subscribed=true, ignored=false)
  ignore  Ignore notifications (ignored=true)
  none    Unwatch: remove subscription (DELETE)

Org-wide watch:
  There is no GitHub REST API to watch an entire organization in one call.
  Use --owned-orgs to run the chosen level against every repo in each org
  where your membership role is admin (owner).

Exclude patterns ( --exclude / --exclude-file ):
  - owner/repo     exact match (e.g. los-tv-x86/android_art)
  - repo           matches that repo name in any org (e.g. android_art)
  - glob           fnmatch on full name or repo name (e.g. external_*, android_*)
EOF
    echo ""
    echo "Default exclude file:"
    echo "  ${DEFAULT_EXCLUDE_FILE} is loaded automatically when present."
    echo "  Pass --exclude-file to use a different file (relative paths are under script dir)."
}

die() {
    echo "watch-org-repos.sh: $*" >&2
    exit 1
}

warn() {
    echo "watch-org-repos.sh: $*" >&2
}

install_hint() {
    local cmd="$1"

    case "$cmd" in
        gh)
            cat <<'EOF' >&2
Install GitHub CLI (gh):
  Debian/Ubuntu:  sudo apt update && sudo apt install gh
  Fedora/RHEL:    sudo dnf install gh
  Arch:           sudo pacman -S github-cli
  macOS:          brew install gh
  Other:          https://github.com/cli/cli#installation

Then authenticate:  gh auth login
EOF
            ;;
        python3)
            cat <<'EOF' >&2
Install Python 3:
  Debian/Ubuntu:  sudo apt update && sudo apt install python3
  Fedora/RHEL:    sudo dnf install python3
  Arch:           sudo pacman -S python
  macOS:          brew install python3
EOF
            ;;
        sed)
            cat <<'EOF' >&2
Install sed (usually preinstalled):
  Debian/Ubuntu:  sudo apt install sed
  Fedora/RHEL:    sudo dnf install sed
EOF
            ;;
        *)
            echo "Install ${cmd} using your system package manager." >&2
            ;;
    esac
}

check_dependencies() {
    local cmd missing=0

    if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
        die "bash 4+ is required (current: ${BASH_VERSION:-unknown})"
    fi

    for cmd in gh python3 sed; do
        if command -v "$cmd" >/dev/null 2>&1; then
            continue
        fi
        echo "watch-org-repos.sh: missing required command: ${cmd}" >&2
        install_hint "$cmd"
        echo "" >&2
        missing=1
    done

    if [ "$missing" -ne 0 ]; then
        exit 1
    fi

    if ! gh auth status >/dev/null 2>&1; then
        die "gh is not authenticated: run: gh auth login"
    fi
}

has_notifications_scope() {
    gh auth status -t 2>&1 | grep -q 'notifications'
}

require_notifications_scope() {
    if has_notifications_scope; then
        return 0
    fi
    die "token lacks 'notifications' scope: run: gh auth refresh -h github.com -s notifications"
}

list_owned_orgs() {
    gh api user/memberships/orgs --paginate \
        -q '.[] | select(.role=="admin" and .state=="active") | .organization.login'
}

show_org_membership() {
    local info role state

    if ! info=$(gh api "user/memberships/orgs/${ORG}" 2>/dev/null); then
        warn "not an active member of ${ORG} (per-repo public watch may still work)"
        return 0
    fi

    role=$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("role","?"))')
    state=$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state","?"))')
    echo "=> membership: ${ORG} role=${role} state=${state}"
}

list_org_repos() {
    gh repo list "$ORG" --limit "$REPO_LIMIT" --json nameWithOwner \
        -q '.[].nameWithOwner'
}

list_user_subscriptions() {
    local query='.[].full_name'

    if [ -n "$ORG" ]; then
        query=".[] | select(.owner.login==\"${ORG}\") | .full_name"
    fi

    if [ "$REPO_LIMIT" -lt 1000 ]; then
        gh api user/subscriptions --paginate -q "$query" | head -n "$REPO_LIMIT"
    else
        gh api user/subscriptions --paginate -q "$query"
    fi
}

print_subscription_summary() {
    local -a repos=("$@")

    [ "${#repos[@]}" -eq 0 ] && return 0

    python3 - "${repos[@]}" <<'PY'
import sys
from collections import Counter

repos = sys.argv[1:]
counts = Counter(r.split("/", 1)[0] for r in repos)
print("=> by owner:")
for owner, count in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
    print(f"   {owner}: {count}")
PY
}

add_exclude_patterns() {
    local raw="$1" part
    local -a parts
    IFS=',' read -r -a parts <<< "$raw"
    for part in "${parts[@]}"; do
        part="${part#"${part%%[![:space:]]*}"}"
        part="${part%"${part##*[![:space:]]}"}"
        [ -n "$part" ] && EXCLUDE_PATTERNS+=("$part")
    done
}

load_exclude_file() {
    local file="$1"
    local line

    case "$file" in
        /*) ;;
        *) file="${SCRIPT_DIR}/${file}" ;;
    esac

    EXCLUDE_FILE_LOADED=1
    EXCLUDE_FILE_PATH="$file"
    [ -f "$file" ] || die "exclude file not found: $file"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] && EXCLUDE_PATTERNS+=("$line")
    done < "$file"
}

is_repo_excluded() {
    local repo="$1"

    [ "${#EXCLUDE_PATTERNS[@]}" -eq 0 ] && return 1

    python3 - "$repo" "${EXCLUDE_PATTERNS[@]}" <<'PY'
import fnmatch
import sys

repo = sys.argv[1]
name = repo.split("/", 1)[-1]
for pat in sys.argv[2:]:
    if pat in (repo, name):
        raise SystemExit(0)
    if fnmatch.fnmatchcase(repo, pat) or fnmatch.fnmatchcase(name, pat):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

print_exclude_summary() {
    local pat

    [ "${#EXCLUDE_PATTERNS[@]}" -eq 0 ] && return 0

    if [ -n "$EXCLUDE_FILE_PATH" ]; then
        echo "=> exclude file: ${EXCLUDE_FILE_PATH}"
    fi
    echo "=> exclude patterns (${#EXCLUDE_PATTERNS[@]}):"
    for pat in "${EXCLUDE_PATTERNS[@]}"; do
        echo "   - ${pat}"
    done
}

apply_repo_level() {
    local repo="$1"
    local endpoint="repos/${repo}/subscription"
    local err

    case "$LEVEL" in
        all)
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[dry-run] PUT ${endpoint} subscribed=true ignored=false"
                return 0
            fi
            if err=$(gh api -X PUT "$endpoint" \
                -F subscribed=true \
                -F ignored=false 2>&1); then
                echo "=> ${repo}: watch=all"
            else
                echo "=> ${repo}: failed to set watch=all: ${err}" >&2
            fi
            ;;
        ignore)
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[dry-run] PUT ${endpoint} ignored=true"
                return 0
            fi
            if err=$(gh api -X PUT "$endpoint" \
                -F subscribed=true \
                -F ignored=true 2>&1); then
                echo "=> ${repo}: watch=ignore"
            else
                echo "=> ${repo}: failed to set watch=ignore: ${err}" >&2
            fi
            ;;
        none)
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[dry-run] DELETE ${endpoint}"
                return 0
            fi
            if gh api -X DELETE "$endpoint" 2>/dev/null; then
                echo "=> ${repo}: unwatch"
            else
                echo "=> ${repo}: already unwatched or not found"
            fi
            ;;
        *)
            die "unknown level: ${LEVEL} (use all, ignore, or none)"
            ;;
    esac
}

repo_subscription_line() {
    local repo="$1"

    gh api "repos/${repo}/subscription" \
        -q '"\(.repository_url | split("/") | .[-2] + "/" + .[-1]) subscribed=\(.subscribed) ignored=\(.ignored)"' \
        2>/dev/null
}

show_repo_status() {
    local repo="$1"
    local line

    if line=$(repo_subscription_line "$repo"); then
        echo "=> ${line}"
        return 0
    fi
    echo "=> ${repo}: not subscribed"
}

show_org_events() {
    gh api "orgs/${ORG}/events" --paginate \
        -q ".[] | \"\(.created_at)\t\(.type)\t\(.repo.name)\"" \
        | head -n "$EVENT_LIMIT"
}

show_user_subscriptions() {
    local -a repos=()
    local -a listed_repos=()
    local repo processed=0 skipped=0 ignored=0

    mapfile -t repos < <(list_user_subscriptions)

    local count="${#repos[@]}"
    if [ -n "$ORG" ]; then
        echo "=> user subscriptions filtered to org: ${ORG} (${count} repos)"
    else
        echo "=> user subscriptions (${count} repos)"
    fi

    if [ "$count" -eq 0 ]; then
        echo "=> none"
        return 0
    fi

    for repo in "${repos[@]}"; do
        if is_repo_excluded "$repo"; then
            echo "=> ${repo}: skipped (excluded)"
            skipped=$((skipped + 1))
            continue
        fi

        if line=$(repo_subscription_line "$repo"); then
            echo "=> ${line}"
            [[ "$line" == *"ignored=true"* ]] && ignored=$((ignored + 1))
        else
            echo "=> ${repo}: not subscribed"
        fi
        listed_repos+=("$repo")
        processed=$((processed + 1))
    done

    echo ""
    print_subscription_summary "${listed_repos[@]}"

    if [ "$skipped" -gt 0 ] || [ "$ignored" -gt 0 ]; then
        echo "=> done (${processed} listed, ${ignored} ignored, ${skipped} excluded)"
    else
        echo "=> done (${processed} listed)"
    fi
}

process_one_org() {
    local repo processed=0 skipped=0

    echo "=> org: ${ORG}"
    show_org_membership

    if [ "$SHOW_EVENTS" -eq 1 ]; then
        echo "=> recent public events (limit ${EVENT_LIMIT}):"
        show_org_events
        return 0
    fi

    mapfile -t repos < <(list_org_repos)
    local count="${#repos[@]}"
    if [ "$count" -eq 0 ]; then
        warn "no repositories returned for org ${ORG}; skipping"
        return 0
    fi

    echo "=> repos listed: ${count} (limit ${REPO_LIMIT})"
    echo "=> mode: per-repo (level=${LEVEL}): GitHub has no single org-watch API"

    for repo in "${repos[@]}"; do
        if is_repo_excluded "$repo"; then
            echo "=> ${repo}: skipped (excluded)"
            skipped=$((skipped + 1))
            continue
        fi

        if [ "$SHOW_STATUS" -eq 1 ]; then
            show_repo_status "$repo"
        else
            apply_repo_level "$repo"
        fi
        processed=$((processed + 1))
    done

    if [ "$skipped" -gt 0 ]; then
        echo "=> done (${processed} processed, ${skipped} excluded in ${ORG})"
    else
        echo "=> done (${processed} repos in ${ORG})"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        -l|--level)
            [ $# -ge 2 ] || die "missing value for $1"
            LEVEL="${2,,}"
            shift 2
            ;;
        --level=*)
            LEVEL="${1#*=}"
            LEVEL="${LEVEL,,}"
            shift
            ;;
        --owned-orgs)
            OWNED_ORGS=1
            shift
            ;;
        --status)
            SHOW_STATUS=1
            shift
            ;;
        --subscriptions)
            SHOW_SUBSCRIPTIONS=1
            shift
            ;;
        --events)
            SHOW_EVENTS=1
            shift
            ;;
        --org-level)
            die "--org-level is unsupported: GitHub has no org-wide watch REST API. Run without that flag to watch each repo in the org."
            ;;
        --limit=*)
            REPO_LIMIT="${1#*=}"
            shift
            ;;
        --event-limit=*)
            EVENT_LIMIT="${1#*=}"
            shift
            ;;
        --exclude=*)
            add_exclude_patterns "${1#*=}"
            shift
            ;;
        --exclude)
            [ $# -ge 2 ] || die "missing value for --exclude"
            add_exclude_patterns "$2"
            shift 2
            ;;
        --exclude-file=*)
            load_exclude_file "${1#*=}"
            shift
            ;;
        --exclude-file)
            [ $# -ge 2 ] || die "missing value for --exclude-file"
            load_exclude_file "$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            die "unknown option: $1 (try --help)"
            ;;
        *)
            [ -z "$ORG" ] || die "unexpected extra argument: $1 (use --owned-orgs without ORG)"
            ORG="$1"
            shift
            ;;
    esac
done

if [ "$EXCLUDE_FILE_LOADED" -eq 0 ] && [ -f "$DEFAULT_EXCLUDE_FILE" ]; then
    load_exclude_file "$DEFAULT_EXCLUDE_FILE"
fi

if [ "$SHOW_SUBSCRIPTIONS" -eq 1 ]; then
    if [ "$OWNED_ORGS" -eq 1 ]; then
        die "--subscriptions cannot be combined with --owned-orgs"
    fi
    if [ "$SHOW_EVENTS" -eq 1 ] || [ "$SHOW_STATUS" -eq 1 ]; then
        die "--subscriptions cannot be combined with --status or --events"
    fi
elif [ "$OWNED_ORGS" -eq 0 ] && [ -z "$ORG" ]; then
    die "ORG is required (example: los-tv-x86) or pass --owned-orgs or --subscriptions"
fi

if [ "$OWNED_ORGS" -eq 1 ] && [ -n "$ORG" ]; then
    die "pass either --owned-orgs or a single ORG, not both"
fi

case "$LEVEL" in
    all|ignore|none) ;;
    participating)
        warn "note: 'participating' is not available via REST; using 'all'"
        LEVEL="all"
        ;;
    unwatch)
        LEVEL="none"
        ;;
    watch)
        LEVEL="all"
        ;;
    *)
        die "unknown level: ${LEVEL} (use all, ignore, none, watch, or unwatch)"
        ;;
esac

check_dependencies
print_exclude_summary

if [ "$SHOW_STATUS" -eq 1 ] || [ "$SHOW_SUBSCRIPTIONS" -eq 1 ]; then
    require_notifications_scope
elif [ "$DRY_RUN" -eq 0 ] && [ "$SHOW_EVENTS" -eq 0 ]; then
    require_notifications_scope
fi

if [ "$SHOW_SUBSCRIPTIONS" -eq 1 ]; then
    show_user_subscriptions
    exit 0
fi

if [ "$OWNED_ORGS" -eq 1 ]; then
    mapfile -t owned_orgs < <(list_owned_orgs)
    org_count="${#owned_orgs[@]}"
    [ "$org_count" -gt 0 ] || die "no owned orgs found (admin role, active membership)"

    echo "=> owned orgs: ${org_count}"
    for ORG in "${owned_orgs[@]}"; do
        echo ""
        echo "======== ${ORG} ========"
        process_one_org
    done
    echo ""
    echo "=> finished all owned orgs (${org_count})"
    exit 0
fi

process_one_org
