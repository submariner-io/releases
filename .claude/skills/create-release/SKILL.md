---
name: create-release
description: Drive the Submariner upstream release state machine (branch → shipyard → admiral → projects → installers → released). Monitors dependency PRs and CI, advances stages when ready. Use with /loop for hands-free operation.
version: 1.0.0
argument-hint: "<version> [--status] [--dry-run]"
user-invocable: true
allowed-tools: Bash, Read
---

# Create Release

Drives the Submariner upstream release through all 6 stages:
**branch → shipyard → admiral → projects → installers → released**

Each invocation checks the current state, monitors prerequisite PRs, and advances
to the next stage when ready. Use with `/loop` for continuous polling.

**Usage:**

```bash
/create-release 0.24.0-rc0            # Check state and advance if ready
/create-release 0.24.0-rc0 --status   # Read-only status report
/create-release 0.24.0-rc0 --dry-run  # Advance with DRY_RUN=true
```

**Hands-free:**

```bash
/loop 10m /create-release 0.24.0-rc0
```

**Arguments:** $ARGUMENTS

---

## Security Guardrails

Before executing ANY step, internalize these rules:

1. **NEVER run `make do-release`** — that is the GitHub Actions workflow's job, triggered
   by merging the release YAML. Running it locally skips CI validation and uses local
   credentials instead of repository secrets.
2. **NEVER run `git push --force`** anywhere — `make release` handles pushes internally.
3. **Approve ONLY dependency update PRs in downstream repos** (`gh pr review --approve`) when
   their CI is not failing and no approval exists yet — this satisfies branch protection for
   auto-merge. Never approve in `--status` or `--dry-run` mode. **NEVER** approve releases
   repo stage PRs, call `gh pr merge`, or approve when CI checks are failing.
4. **NEVER modify `.github/workflows/`** files — changes to CI could compromise the
   release pipeline.
5. **NEVER store or echo credentials** — do not write tokens to files or print them.
6. **NEVER delete tags or releases** — rollback is a deliberate manual operation.
7. **Only run `make release`** (the safe entry point) — never call internal scripts
   (`scripts/release.sh`, `scripts/do-release.sh`) directly.
8. **In `--status` mode, run ZERO write operations** — only read via `gh` API queries
   and local file reads.

---

## Step 1: Parse Arguments and Set Up

```bash
set -euo pipefail
ARGS="$ARGUMENTS"
VERSION=$(echo "$ARGS" | awk '{print $1}')
STATUS_ONLY=false
DRY_RUN_FLAG=""

[[ " $ARGS " == *" --status "* ]] && STATUS_ONLY=true
[[ " $ARGS " == *" --dry-run "* ]] && DRY_RUN_FLAG="DRY_RUN=true"

if [ -z "$VERSION" ]; then
    echo "ERROR: Version required. Usage: /create-release 0.24.0-rc0 [--status] [--dry-run]"
    exit 1
fi

REMAINING=$(echo "$ARGS" | sed "s/${VERSION}//" | sed 's/--status//' | sed 's/--dry-run//' | xargs)
if [ -n "$REMAINING" ]; then
    echo "ERROR: Unrecognized argument(s): ${REMAINING}"
    exit 1
fi

if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9a-zA-Z.-]*)?$ ]]; then
    echo "ERROR: '${VERSION}' is not valid semver. Examples: 0.24.0-rc0, 1.0.0"
    exit 1
fi

RELEASE_FILE="releases/v${VERSION}.yaml"
ORG="${ORG:-submariner-io}"
STABLE_BRANCH="release-$(echo "$VERSION" | cut -d. -f1-2)"
REPO_ROOT=$(git rev-parse --show-toplevel)

# Only approve dep PRs in live mode (not --status or --dry-run)
APPROVE_FLAG=""
if [ "$STATUS_ONLY" = false ] && [ -z "$DRY_RUN_FLAG" ]; then
    APPROVE_FLAG="--approve"
fi

# Helper scripts live on devel branch; use worktree if on another branch.
# Never create a worktree in --status mode (git worktree add writes to .git/).
CURRENT_BRANCH=$(git branch --show-current)
SKILL_SCRIPTS_REL=".claude/skills/create-release/scripts"
if [ "$CURRENT_BRANCH" = "devel" ]; then
    SCRIPTS="${REPO_ROOT}/${SKILL_SCRIPTS_REL}"
else
    WORKTREE_PATH="/tmp/releases-create-release-skill"
    if [ ! -d "$WORKTREE_PATH" ]; then
        if [ "$STATUS_ONLY" = true ]; then
            echo "ERROR: Worktree not initialised. Run /create-release ${VERSION} once (without --status) to set up the worktree, then re-run with --status."
            exit 1
        fi
        git worktree add "$WORKTREE_PATH" devel 2>/dev/null || true
    fi
    SCRIPTS="${WORKTREE_PATH}/${SKILL_SCRIPTS_REL}"
fi

if [ ! -d "$SCRIPTS" ]; then
    echo "ERROR: Scripts directory not found at ${SCRIPTS}"
    exit 1
fi

echo "VERSION=${VERSION} STATUS_ONLY=${STATUS_ONLY} DRY_RUN=${DRY_RUN_FLAG:-none}"
echo "SCRIPTS=${SCRIPTS}"
```

## Step 2: Verify Prerequisites

```bash
PREREQ_FLAGS=""
[ "$STATUS_ONLY" = true ] && PREREQ_FLAGS="--status-only"
[ -n "$DRY_RUN_FLAG" ] && PREREQ_FLAGS="$PREREQ_FLAGS --dry-run"
"$SCRIPTS/check-prereqs.sh" $PREREQ_FLAGS
```

## Step 3: Determine Current State

```bash
BRANCH_VAL="${STABLE_BRANCH}"
STATUS=""
if [ ! -f "$RELEASE_FILE" ]; then
    echo "STATE: not-started"
else
    STATUS=$(grep '^status:' "$RELEASE_FILE" | awk '{print $2}')
    BRANCH_VAL=$(grep '^branch:' "$RELEASE_FILE" | awk '{print $2}')
    BRANCH_VAL="${BRANCH_VAL:-devel}"
    echo "STATE: $STATUS  BRANCH: $BRANCH_VAL"
    echo "---"
    cat "$RELEASE_FILE"
fi
```

Check for in-flight PRs and recent workflow runs:

```bash
echo ""
echo "=== Open release PRs ==="
gh pr list --repo "${ORG}/releases" --label automated --state open \
    --json number,title,url,createdAt \
    --jq ".[] | select(.title | contains(\"${VERSION}\")) | \"\(.number) \(.title) \(.url)\""

echo ""
echo "=== Recent release workflow runs ==="
gh run list --repo "${ORG}/releases" --workflow "release.yml" --limit 10 \
    --json status,conclusion,createdAt,displayTitle \
    --jq ".[] | select(.displayTitle | contains(\"${VERSION}\")) | \"\(.status)/\(.conclusion // \"—\") \(.createdAt) \(.displayTitle)\""
```

After running the above, decide which state handler applies.

---

## State Handlers

### not-started → Initiate Release

```bash
if [ "$STATUS_ONLY" = true ]; then
    echo "STATUS: Release not yet initiated. Run without --status to create."
    exit 0
fi

OPEN_INIT_PR=$(gh pr list --repo "${ORG}/releases" --label automated --state open \
    --json number,title \
    --jq ".[] | select(.title | contains(\"${VERSION}\")) | .number" | wc -l | xargs)
if [ "${OPEN_INIT_PR:-0}" -gt 0 ]; then
    echo "WAITING: A release PR for ${VERSION} is already open."
    exit 0
fi

echo ">>> Initiating release v${VERSION}..."
make release VERSION="${VERSION}" $DRY_RUN_FLAG
echo ">>> Initial release PR created. Waiting for CI + merge."
```

### branch → Wait for Branch Creation, Then Advance

```bash
BRANCH_COUNT=0
BRANCH_TOTAL=8
for REPO in shipyard admiral submariner lighthouse cloud-prepare submariner-operator subctl submariner-charts; do
    if gh api "repos/${ORG}/${REPO}/branches/${STABLE_BRANCH}" --jq '.name' >/dev/null 2>&1; then
        echo "  ${REPO}: ${STABLE_BRANCH} exists"
        BRANCH_COUNT=$((BRANCH_COUNT + 1))
    else
        echo "  ${REPO}: ${STABLE_BRANCH} NOT FOUND"
    fi
done
echo "Branches: ${BRANCH_COUNT}/${BRANCH_TOTAL}"

if [ "$BRANCH_COUNT" -lt "$BRANCH_TOTAL" ]; then
    echo "WAITING: Not all branches created yet."
    exit 0
fi

OPEN_RELEASE_PR=$(gh pr list --repo "${ORG}/releases" --label automated --state open \
    --json number,title \
    --jq ".[] | select(.title | contains(\"${VERSION}\")) | .number" | wc -l | xargs)
if [ "${OPEN_RELEASE_PR:-0}" -gt 0 ]; then
    echo "WAITING: ${OPEN_RELEASE_PR} open release PR(s) for ${VERSION} still in progress."
elif [ "$STATUS_ONLY" = true ]; then
    echo "STATUS: All branches exist. Run without --status to advance to shipyard."
else
    echo ">>> All branches created. Advancing to shipyard..."
    make release VERSION="${VERSION}" $DRY_RUN_FLAG
fi
```

### shipyard → Wait for Admiral Dependency PR, Then Advance

```bash
# Check shipyard release
echo "--- Shipyard release ---"
SHIPYARD_RELEASE_OK=false
if REL_INFO=$(gh release view "v${VERSION}" --repo "${ORG}/shipyard" \
    --json tagName,publishedAt --jq '"\(.tagName) published \(.publishedAt)"' 2>/dev/null); then
    echo "$REL_INFO"; SHIPYARD_RELEASE_OK=true
else
    echo "NOT YET RELEASED"
fi

# Check admiral dep PR
echo ""
echo "--- Admiral dependency PR ---"
ADMIRAL_PR_URL=$("$SCRIPTS/find-dep-pr.sh" "$ORG" "$VERSION" "$BRANCH_VAL" "shipyard" "admiral")
READY=false
if "$SCRIPTS/check-dep-pr.sh" "$ORG" "admiral" "$VERSION" "$BRANCH_VAL" "${ADMIRAL_PR_URL:-"-"}" $APPROVE_FLAG; then
    READY=true
fi

# Advance when ready
if [ "$READY" = true ] && [ "$STATUS_ONLY" = false ]; then
    if [ "$SHIPYARD_RELEASE_OK" = false ]; then
        echo "WAITING: Shipyard GitHub release not yet published."; exit 0
    fi
    if "$SCRIPTS/verify-images.sh" "$ORG" "$VERSION" "shipyard"; then
        echo ">>> Images verified. Advancing to admiral..."
        make release VERSION="${VERSION}" $DRY_RUN_FLAG
    else
        echo "WAITING: Shipyard images not yet on quay.io."
    fi
fi
```

### admiral → Wait for 3 Project Dependency PRs, Then Advance

```bash
# Check admiral release
echo "--- Admiral release ---"
ADMIRAL_RELEASE_OK=false
if REL_INFO=$(gh release view "v${VERSION}" --repo "${ORG}/admiral" \
    --json tagName,publishedAt --jq '"\(.tagName) published \(.publishedAt)"' 2>/dev/null); then
    echo "$REL_INFO"; ADMIRAL_RELEASE_OK=true
else
    echo "NOT YET RELEASED"
fi

# Check dep PRs for cloud-prepare, lighthouse, submariner
PROJECTS_READY=0
PROJECTS_TOTAL=3
for REPO in cloud-prepare lighthouse submariner; do
    echo ""
    echo "--- ${REPO} dependency PR ---"
    PR_URL=$("$SCRIPTS/find-dep-pr.sh" "$ORG" "$VERSION" "$BRANCH_VAL" "admiral" "$REPO")
    if "$SCRIPTS/check-dep-pr.sh" "$ORG" "$REPO" "$VERSION" "$BRANCH_VAL" "${PR_URL:-"-"}" $APPROVE_FLAG; then
        PROJECTS_READY=$((PROJECTS_READY + 1))
    fi
done
echo ""
echo "Project dependency PRs: ${PROJECTS_READY}/${PROJECTS_TOTAL} merged"

# Advance when all 3 merged
if [ "$PROJECTS_READY" -eq "$PROJECTS_TOTAL" ] && [ "$STATUS_ONLY" = false ]; then
    if [ "$ADMIRAL_RELEASE_OK" = false ]; then
        echo "WAITING: Admiral GitHub release not yet published."; exit 0
    fi
    echo ">>> All project dependency PRs merged. Advancing to projects..."
    make release VERSION="${VERSION}" $DRY_RUN_FLAG
fi
```

### projects → Wait for Operator Dependency PR, Then Advance

```bash
# Check project releases
echo "--- Project releases ---"
PROJECTS_RELEASE_OK=true
for REPO in cloud-prepare lighthouse submariner; do
    if PROJ_REL=$(gh release view "v${VERSION}" --repo "${ORG}/${REPO}" \
        --json tagName --jq "\"${REPO}: \(.tagName)\"" 2>/dev/null); then
        echo "$PROJ_REL"
    else
        echo "${REPO}: NOT YET RELEASED"; PROJECTS_RELEASE_OK=false
    fi
done

# Check operator dep PR
echo ""
echo "--- Operator dependency PR ---"
OPERATOR_PR_URL=$("$SCRIPTS/find-dep-pr.sh" "$ORG" "$VERSION" "$BRANCH_VAL" "projects" "submariner-operator")
READY=false
if "$SCRIPTS/check-dep-pr.sh" "$ORG" "submariner-operator" "$VERSION" "$BRANCH_VAL" "${OPERATOR_PR_URL:-"-"}" $APPROVE_FLAG; then
    READY=true
fi

# Advance: verify project releases published + images ready
if [ "$READY" = true ] && [ "$STATUS_ONLY" = false ]; then
    if [ "$PROJECTS_RELEASE_OK" = false ]; then
        echo "WAITING: One or more project GitHub releases not yet published."; exit 0
    fi
    # Show release image workflow status
    echo "--- Release Image workflows ---"
    IMAGE_TAG="${VERSION#v}"
    for REPO in cloud-prepare lighthouse submariner; do
        RUN=$(gh run list --repo "${ORG}/${REPO}" --event push --limit 20 \
            --json status,conclusion,headBranch,displayTitle \
            --jq ".[] | select(.headBranch == \"v${IMAGE_TAG}\")" \
            2>/dev/null | jq -s '.[0]' 2>/dev/null || true)
        if [ -z "$RUN" ] || [ "$RUN" = "null" ]; then
            echo "  ${REPO}: release workflow not yet triggered"
        else
            echo "  ${REPO}: $(echo "$RUN" | jq -r '"\(.displayTitle // "release"): \(.status)/\(.conclusion // "—")"' 2>/dev/null || echo "unknown")"
        fi
    done
    if "$SCRIPTS/verify-images.sh" "$ORG" "$VERSION" "projects" "$RELEASE_FILE"; then
        echo ">>> Images verified. Advancing to installers..."
        make release VERSION="${VERSION}" $DRY_RUN_FLAG
    else
        echo "WAITING: Project images not yet on quay.io."
    fi
fi
```

### installers → Wait for Subctl + Charts Dependency PRs, Then Advance

```bash
# Check operator release
echo "--- Operator release ---"
OPERATOR_RELEASE_OK=false
if REL_INFO=$(gh release view "v${VERSION}" --repo "${ORG}/submariner-operator" \
    --json tagName,publishedAt --jq '"\(.tagName) published \(.publishedAt)"' 2>/dev/null); then
    echo "$REL_INFO"; OPERATOR_RELEASE_OK=true
else
    echo "NOT YET RELEASED"
fi

# Check dep PRs for subctl, submariner-charts
INST_READY=0
INST_TOTAL=2
for REPO in subctl submariner-charts; do
    echo ""
    echo "--- ${REPO} dependency PR ---"
    PR_URL=$("$SCRIPTS/find-dep-pr.sh" "$ORG" "$VERSION" "$BRANCH_VAL" "installers" "$REPO")
    if "$SCRIPTS/check-dep-pr.sh" "$ORG" "$REPO" "$VERSION" "$BRANCH_VAL" "${PR_URL:-"-"}" $APPROVE_FLAG; then
        INST_READY=$((INST_READY + 1))
    fi
done
echo ""
echo "Installer dependency PRs: ${INST_READY}/${INST_TOTAL} merged"

# Advance: verify operator release published + images ready
if [ "$INST_READY" -eq "$INST_TOTAL" ] && [ "$STATUS_ONLY" = false ]; then
    if [ "$OPERATOR_RELEASE_OK" = false ]; then
        echo "WAITING: Operator GitHub release not yet published."; exit 0
    fi
    echo "--- Release Image workflows ---"
    IMAGE_TAG="${VERSION#v}"
    for REPO in submariner-operator subctl; do
        RUN=$(gh run list --repo "${ORG}/${REPO}" --event push --limit 20 \
            --json status,conclusion,headBranch,displayTitle \
            --jq ".[] | select(.headBranch == \"v${IMAGE_TAG}\")" \
            2>/dev/null | jq -s '.[0]' 2>/dev/null || true)
        if [ -z "$RUN" ] || [ "$RUN" = "null" ]; then
            echo "  ${REPO}: release workflow not yet triggered"
        else
            echo "  ${REPO}: $(echo "$RUN" | jq -r '"\(.displayTitle // "release"): \(.status)/\(.conclusion // "—")"' 2>/dev/null || echo "unknown")"
        fi
    done
    if "$SCRIPTS/verify-images.sh" "$ORG" "$VERSION" "installers" "$RELEASE_FILE"; then
        echo ">>> Images verified. Advancing to released..."
        make release VERSION="${VERSION}" $DRY_RUN_FLAG
    else
        echo "WAITING: Installer images not yet on quay.io."
    fi
fi
```

### released → Verify Final Artifacts

The `released` stage: `do-release.sh` cross-compiles subctl, creates the final GitHub
release with binaries, and tags all remaining projects.

```bash
echo "=== Final Release Verification ==="

# GitHub release on releases repo (includes subctl binaries)
echo "--- GitHub Release (releases repo) ---"
RELEASES_RELEASE=$(gh release view "v${VERSION}" --repo "${ORG}/releases" \
    --json tagName,publishedAt,assets 2>/dev/null || true)
if [ -z "$RELEASES_RELEASE" ]; then
    echo "NOT FOUND — do-release may still be running"
    RELEASE_OK=false
else
    echo "$RELEASES_RELEASE" | jq '{tag: .tagName, published: .publishedAt, assets: [.assets[].name]}'
    RELEASE_OK=true
    BINARIES_OK=true
    echo "--- subctl binary assets ---"
    for PLATFORM in "subctl-linux-amd64" "subctl-darwin-amd64" "subctl-windows-amd64"; do
        if echo "$RELEASES_RELEASE" | jq -e ".assets[] | select(.name | contains(\"${PLATFORM}\"))" >/dev/null 2>&1; then
            echo "  OK  ${PLATFORM}"
        else
            echo "  MISSING  ${PLATFORM}"; BINARIES_OK=false
        fi
    done
fi

# All 8 projects should be tagged
echo ""
echo "--- Project Tags ---"
TAG_COUNT=0
TAG_TOTAL=8
for REPO in shipyard admiral cloud-prepare lighthouse submariner submariner-operator subctl submariner-charts; do
    if gh release view "v${VERSION}" --repo "${ORG}/${REPO}" --json tagName --jq '.tagName' >/dev/null 2>&1; then
        echo "  OK  ${REPO}"; TAG_COUNT=$((TAG_COUNT + 1))
    else
        echo "  --  ${REPO}: not tagged"
    fi
done
echo "Tags: ${TAG_COUNT}/${TAG_TOTAL}"

# Container images and release workflows
echo ""
echo "--- Container Images (quay.io) ---"
IMAGE_TAG="${VERSION#v}"
echo "--- Release Image workflows ---"
for REPO in submariner lighthouse submariner-operator subctl; do
    RUN=$(gh run list --repo "${ORG}/${REPO}" --event push --limit 20 \
        --json status,conclusion,headBranch,displayTitle \
        --jq ".[] | select(.headBranch == \"v${IMAGE_TAG}\")" \
        2>/dev/null | jq -s '.[0]' 2>/dev/null || true)
    if [ -z "$RUN" ] || [ "$RUN" = "null" ]; then
        echo "  ${REPO}: release workflow not found for v${IMAGE_TAG}"
    else
        echo "  ${REPO}: $(echo "$RUN" | jq -r '"\(.displayTitle // "release"): \(.status)/\(.conclusion // "—")"' 2>/dev/null || echo "unknown")"
    fi
done

"$SCRIPTS/verify-images.sh" "$ORG" "$VERSION" "released" || IMAGES_COMPLETE=false

# Post-release workflow (krew index update)
echo ""
echo "--- Post-Release Workflow ---"
POST_RELEASE_OK=false
POST_RUN=$(gh run list --repo "${ORG}/releases" --workflow "post-release.yml" --limit 5 \
    --json status,conclusion,createdAt,displayTitle \
    --jq ".[] | select(.displayTitle | contains(\"${VERSION}\"))" 2>/dev/null | head -1 || true)
if [ -z "$POST_RUN" ]; then
    if echo "$VERSION" | grep -q '\-rc'; then
        echo "No post-release workflow run found for ${VERSION} (not required for RCs)"
        POST_RELEASE_OK=true
    else
        echo "WAITING: Post-release workflow not yet triggered for stable release ${VERSION}"
    fi
else
    POST_STATUS=$(echo "$POST_RUN" | jq -r '"\(.status)/\(.conclusion // "—") \(.createdAt)"' 2>/dev/null || echo "unknown")
    echo "$POST_STATUS"
    if echo "$POST_RUN" | jq -e '.conclusion == "success"' >/dev/null 2>&1; then
        POST_RELEASE_OK=true
    elif echo "$POST_RUN" | jq -e '.status == "completed"' >/dev/null 2>&1; then
        echo "WARN: Post-release workflow completed but did not succeed — check manually"
    else
        echo "WAITING: Post-release workflow still running"
    fi
fi
```

If all 8 tags exist, GitHub release is published, images are OK, binaries present, and post-release succeeded (or absent for RCs):

```
Release v${VERSION} COMPLETE.

(If any image showed NOT FOUND or post-release failed, do NOT start downstream.)

Downstream next steps:
  cd ~/konflux/submariner-release-management
  /bundle-image-update ${VERSION}
```

If do-release is still running, report waiting.

---

## Error Handling

When a dependency PR has failing CI, report the failure but do NOT attempt to fix it.

When `make release` fails, print the error, do NOT retry, suggest checking `git status`.

When `do-release` GitHub Actions fails:
```bash
FAILED_RUN=$(gh run list --repo "${ORG}/releases" --workflow "release.yml" \
    --status failure --limit 1 --json databaseId --jq '.[0].databaseId')
if [ -n "$FAILED_RUN" ]; then
    echo "FAILED workflow run:"
    gh run view --repo "${ORG}/releases" "$FAILED_RUN" --log-failed 2>/dev/null | tail -30
fi
```

---

## Notes

- `make release` runs inside a Dapper container (Docker required)
- `do-release.sh` is idempotent: it skips already-tagged repos
- Auto-merge is enabled on all release PRs; dependency PRs are labeled `automated`
- CI typically takes 20-40 minutes per repo; full release takes 20-24 hours
- A 10-minute `/loop` interval stays under GitHub API rate limits (~72 calls/hr vs 5000/hr)
- Transient errors: skill reports and waits, next `/loop` tick retries. Persistent failures (CI blocked, do-release failed): human intervention required.
- Helper scripts loaded from `devel` branch via worktree at `/tmp/releases-create-release-skill/`
