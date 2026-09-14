# Automated Upstream Release Guide

How to run a Submariner upstream release using the release engineer agent
and the `/create-release` skill in Claude Code.

## Prerequisites

### Tools

Install these before your first release:

- **Docker** — `make release` runs inside a Dapper container
- **gh** — GitHub CLI for API queries and authentication
- **yq** — YAML parser (used to read release state)
- **skopeo** — container image inspection (used for final verification)

### Repository

```bash
cd ~/go/src/github.com/submariner-io/releases
git checkout devel
git pull
```

### Authentication

```bash
gh auth login            # one-time setup
gh auth status           # verify you're logged in
```

## Step-by-Step Release

### 1. Export your GitHub token

```bash
export GITHUB_TOKEN=$(gh auth token)
```

This is required by `make release`, which runs inside Docker and needs the
token passed through.

### 2. Verify Docker is running

```bash
docker info >/dev/null && echo "Docker: OK"
```

### 3. Check pre-release readiness (optional)

```bash
/create-release 0.24.0-rc0 --status
```

This is read-only. It shows whether a release is already in progress, what
stage it's at, and whether there are any open dependency PRs.

### 4. Start the release

```bash
/loop 10m /create-release 0.24.0-rc0
```

This does two things:

1. On the first run, creates the release YAML and opens the initial PR
2. Every 10 minutes after that, checks the current stage and advances
   when all prerequisites for the next stage are met

### 5. Wait

The release runs itself from here. A typical release takes **20-24 hours**,
almost entirely CI wait time. You can close your laptop — just leave the
Claude Code session running.

What happens automatically at each stage:

| Stage | What CI Does | What the Agent Does Next |
|---|---|---|
| branch | Creates `release-X.Y` branches in all repos | Verifies branches exist, advances to shipyard |
| shipyard | Tags Shipyard, creates Admiral dependency PR | Waits for Admiral PR to merge, advances to admiral |
| admiral | Tags Admiral, creates 3 project dependency PRs | Waits for all 3 to merge, advances to projects |
| projects | Tags 3 projects, creates Operator dependency PR | Waits for Operator PR to merge, advances to installers |
| installers | Tags Operator, creates subctl + charts PRs | Waits for both to merge, advances to released |
| released | Tags remaining repos, builds subctl, pushes images | Verifies all artifacts, reports completion |

### 6. Check status anytime

Open a separate terminal or Claude Code session:

```bash
/create-release 0.24.0-rc0 --status
```

### 7. Start downstream (after completion)

When the agent reports the release is complete:

```bash
cd ~/konflux/submariner-release-management
/bundle-image-update 0.24.0-rc0
```

## Dry Run

Test the process without creating real PRs or tags:

```bash
/create-release 0.24.0-rc0 --dry-run
```

This passes `DRY_RUN=true` to `make release`.

## Troubleshooting

### CI fails on a dependency PR

The agent reports which checks failed and provides log URLs. You need to:

1. Investigate the failure in the failing repo
2. Push a fix to the PR branch
3. The auto-merge picks up the fix, and the next poll continues the release

The agent does not retry or fix CI failures — it waits for you.

### `make release` fails

Common causes:

- **Git tree not clean** — commit or stash your changes, pull latest devel
- **Docker not running** — start Docker
- **Token expired** — re-export: `export GITHUB_TOKEN=$(gh auth token)`

The agent prints the error and waits. Fix the issue, and the next poll retries.

### Release stuck (no progress for hours)

Run `--status` to see what's waiting. Possible causes:

- A dependency PR is open but CI hasn't started (check GitHub Actions queue)
- The `do-release` GitHub Actions workflow failed (check the Actions tab)
- A repo's CI is flaky and needs a manual re-run

### Wrong version

If you started with the wrong version and no PRs have merged yet, close the
open PR on `submariner-io/releases`, delete the release YAML, and start over.

If PRs have already merged, you'll need to manually clean up tags and branches.
This is rare and requires careful manual intervention.

## What the Agent Will Never Do

These guardrails are enforced by the skill:

- Run `make do-release` (that's GitHub Actions' job)
- Force-push to any branch
- Approve or merge PRs (auto-merge handles this)
- Modify CI workflows
- Store or print credentials
- Delete tags or releases
- Retry failed CI without human decision

## File Locations

| File | Purpose |
|---|---|
| `.claude/skills/create-release/SKILL.md` | The skill that drives the state machine |
| `.claude/agents/release-engineer.md` | Agent persona with full context and constraints |
| `releases/v{VERSION}.yaml` | Release state file (created and updated by `make release`) |
| `scripts/release.sh` | Creates/advances the release YAML and PR |
| `scripts/do-release.sh` | Tags repos, pushes images (runs in GitHub Actions only) |
| `scripts/validate.sh` | Validates release YAML before merge |
