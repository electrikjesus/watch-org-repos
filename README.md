# watch-org-repos

Batch watch, unwatch, mute, or inspect GitHub repository subscriptions for every repo in an organization.

GitHub has **no REST API to watch an entire org in one call**: not even for org owners. The org-wide watch button in the UI is not exposed via API. This script applies your chosen subscription level to each repository individually using [`gh api`](https://cli.github.com/).

## Requirements

- bash 4+
- [GitHub CLI](https://cli.github.com/) (`gh`)
- Python 3
- `sed` (usually preinstalled)

The script checks dependencies at startup; prints install hints if anything is missing.

## Setup

Authenticate once:

```bash
gh auth login
```

For reading or changing subscription state, grant the `notifications` scope once:

```bash
gh auth refresh -h github.com -s notifications
```

## Quick start

Watch every repo in one org:

```bash
./watch-org-repos.sh los-tv-x86
```

Watch every repo in all orgs where you are an admin:

```bash
./watch-org-repos.sh --owned-orgs --level=all
```

Preview changes without calling the API:

```bash
./watch-org-repos.sh --dry-run --owned-orgs
```

Show current subscription state for each repo in an org:

```bash
./watch-org-repos.sh --status Bliss-Bass
```

List every repository you are subscribed to (across all orgs), with a per-owner summary:

```bash
./watch-org-repos.sh --subscriptions
```

Filter that list to one org:

```bash
./watch-org-repos.sh --subscriptions Bliss-Bass
```

## Subscription levels

| Level | Effect |
|-------|--------|
| `all` | Watch: receive notifications (`subscribed=true`, `ignored=false`) |
| `ignore` | Mute: block notifications but keep a subscription record (`ignored=true`) |
| `none` | Unwatch: remove the repository subscription entirely |

Aliases: `watch` → `all`, `unwatch` → `none`.

GitHub UI options such as “Participating only” or per-event custom watches are not available on this REST endpoint. Use `all` here, or configure those repos in the GitHub UI.

## Options

| Option | Description |
|--------|-------------|
| `-l`, `--level=LEVEL` | Subscription level: `all`, `ignore`, `none` (default: `all`) |
| `--owned-orgs` | Process every org where your membership role is `admin` |
| `--status` | Print current subscription for each repo in an org (no changes) |
| `--subscriptions` | List all repos you are subscribed to; optional `ORG` filters by owner |
| `--events` | Print recent public org events, then exit |
| `--limit=N` | Max repos per org, or max subscriptions listed (default: 1000) |
| `--event-limit=N` | Max events with `--events` (default: 30) |
| `--exclude=PAT[,PAT]` | Skip matching repos (repeatable; comma-separated) |
| `--exclude-file=PATH` | Load exclude patterns from a file |
| `--dry-run` | Print actions without calling the API |
| `-h`, `--help` | Show full help (includes script header examples) |

Run from anywhere: the script resolves its own directory at startup.

## Excluding repos

Large orgs (for example AOSP-style vendor trees) often include mirror repos you do not want notifications for. Use `--exclude` on the command line or maintain an exclude file beside the script.

### Default exclude file

If `watch-org-excludes.txt` exists beside this script, it is loaded automatically. You do not need to pass `--exclude-file` unless you want a different file.

Create it from the example:

```bash
cp watch-org-excludes.example.txt watch-org-excludes.txt
# edit patterns as needed
```

`watch-org-excludes.txt` is not checked into git (local-only). The example file documents common patterns.

### Pattern syntax

| Pattern | Matches |
|---------|---------|
| `owner/repo` | Exact full name (e.g. `los-tv-x86/android_art`) |
| `repo` | That repo name in any org (e.g. `android_art`) |
| `glob` | `fnmatch` on full name or repo name (e.g. `external_*`, `android_*`) |

One pattern per line in the exclude file. Blank lines; lines starting with `#` are ignored.

Example `watch-org-excludes.txt`:

```text
# Skip vendor mirror / external trees
external_*
android_external_*

# Skip by repo name in every org (--owned-orgs)
android_art
lineage_bass_android

# Org-qualified: only that owner/repo
los-tv-x86/android_bionic
Bliss-Bass/some-archived-repo
```

Same patterns work with `--exclude=` on the command line (comma-separated):

```bash
./watch-org-repos.sh --owned-orgs --exclude=android_art,external_*
```

Relative paths passed to `--exclude-file` resolve from the script directory, not your current working directory.

## Examples

```bash
# Mute all repos in an org
./watch-org-repos.sh --level=ignore Bliss-Bass

# Unwatch every repo in an org (dry run first)
./watch-org-repos.sh --dry-run --level=none los-tv-x86

# Watch all owned orgs, skipping patterns from the default exclude file
./watch-org-repos.sh --owned-orgs

# Recent public activity for an org
./watch-org-repos.sh --events --event-limit=20 los-tv-x86

# Audit your full watch list (first 50)
./watch-org-repos.sh --subscriptions --limit=50
```

## API reference

Per-repo subscription endpoints:

- `GET /user/subscriptions`: list repositories the authenticated user is watching
- `GET /repos/{owner}/{repo}/subscription`: read subscription state
- `PUT /repos/{owner}/{repo}/subscription`: set watch or ignore
- `DELETE /repos/{owner}/{repo}/subscription`: unwatch

See [GitHub REST: Watching](https://docs.github.com/en/rest/activity/watching).

## Gaps GitHub does not fill (future ideas)

GitHub’s UI/API are built around **per-repo** actions. This script already covers batch org watch, exclude patterns. Possible next features:

| Idea | What it would do |
|------|------------------|
| **Coverage diff** | Compare an org’s repo list against your subscriptions: show unwatched repos in an org you care about, or subscriptions you have outside a target org set |
| **Prune stale watches** | Unwatch archived repos, or repos with no pushes in N months |
| **Prune by pattern** | Bulk-unwatch everything matching `external_*` across *all* your subscriptions (inverse of today’s exclude-on-apply) |
| **Sync from file** | Export subscription state to JSON; re-apply after account migration or to a second machine |
| **Owned-org audit** | For each owned org: “watching X of Y repos” with a one-command gap report |
| **Mute vs watch report** | Summary-only mode: counts of `ignored=true` vs active watches per org, without per-repo lines |
| **Watch only matching** | Apply `--level=all` only to repos matching an include list (exclude is already the inverse) |

Coverage diff, owned-org audit are probably the highest value for large vendor orgs. Shoot me message using the Issues tab if you want to let me know what matters most to you. 
