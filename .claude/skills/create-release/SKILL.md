---
name: create-release
description: Drive the Submariner upstream release state machine (branch → shipyard → admiral → projects → installers → released). Monitors dependency PRs and CI, advances stages when ready. Use with /loop for hands-free operation.
version: 2.0.0
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

## Step 1: Parse Arguments and Validate

Extract VERSION and flags from `$ARGUMENTS`.

```bash
set -euo pipefail
ARGS="$ARGUMENTS"
VERSION=$(echo "$ARGS" | awk '{print $1}')
STATUS_ONLY=false
DRY_RUN_FLAG=""

[[ " $ARGS " == *" --status "* ]] && STATUS_ONLY=true
[[ " $ARGS " == *" --dry-run "* ]] && DRY_RUN_FLAG="DRY_RUN=true"

if [ -z "$VERSION" ]; then
    echo "ERROR: Version required."
    echo "Usage: /create-release 0.24.0-rc0 [--status] [--dry-run]"
    exit 1
fi

# Reject unknown arguments — fail closed rather than silently ignoring typos
REMAINING=$(echo "$ARGS" | sed "s/${VERSION}//" | sed 's/--status//' | sed 's/--dry-run//' | xargs)
if [ -n "$REMAINING" ]; then
    echo "ERROR: Unrecognized argument(s): ${REMAINING}"
    echo "Usage: /create-release <version> [--status] [--dry-run]"
    exit 1
fi

# Validate semver format (matches validate_semver in scripts/lib/utils)
if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9a-zA-Z.-]*)?$ ]]; then
    echo "ERROR: '${VERSION}' is not valid semver. Examples: 0.24.0-rc0, 1.0.0"
    exit 1
fi

RELEASE_FILE="releases/v${VERSION}.yaml"
ORG="${ORG:-submariner-io}"
STABLE_BRANCH="release-$(echo "$VERSION" | cut -d. -f1-2)"
```

## Step 2: Verify Prerequisites

Run these checks. If any fail, stop and report clearly.

```bash
# 1. Verify we are in the releases repo root
if [ ! -f releases/example.yaml ]; then
    echo "ERROR: Not in submariner-io/releases root."
    echo "Run: cd ~/go/src/github.com/submariner-io/releases"
    exit 1
fi

# 2. Verify gh is authenticated (do NOT print the token)
if ! gh auth status 2>&1 | grep -q "Logged in"; then
    echo "ERROR: gh CLI not authenticated."
    echo "Run: gh auth login"
    exit 1
fi
echo "gh auth: OK"

# 3. Verify GITHUB_TOKEN is set (required by make release inside Dapper, not needed for --status)
if [ "$STATUS_ONLY" = false ] && [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "ERROR: GITHUB_TOKEN not set."
    echo "Run: export GITHUB_TOKEN=\$(gh auth token)"
    exit 1
fi
[ "$STATUS_ONLY" = false ] && echo "GITHUB_TOKEN: set"

# 4. Verify Docker is available (make release runs inside Dapper container)
if [ "$STATUS_ONLY" = false ]; then
    if ! docker info >/dev/null 2>&1; then
        echo "ERROR: Docker not available. make release requires Docker (Dapper)."
        exit 1
    fi
    echo "Docker: OK"
fi

# 5. Verify skopeo is available (used for quay.io image verification)
if ! command -v skopeo >/dev/null 2>&1; then
    echo "ERROR: skopeo not found. Install skopeo."
    exit 1
fi

# 6. Verify jq is available (used for parsing GitHub API responses in final verification)
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not found. Install jq."
    exit 1
fi

# 7. Verify yq is available (used to read release YAML)
if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: yq not found. Install yq."
    exit 1
fi
```

## Step 3: Determine Current State

Read the release YAML to find the current stage.

```bash
BRANCH_VAL="${STABLE_BRANCH}"
STATUS=""
if [ ! -f "$RELEASE_FILE" ]; then
    echo "STATE: not-started"
    echo "Release file $RELEASE_FILE does not exist."
else
    STATUS=$(grep '^status:' "$RELEASE_FILE" | awk '{print $2}')
    BRANCH_VAL=$(grep '^branch:' "$RELEASE_FILE" | awk '{print $2}')
    BRANCH_VAL="${BRANCH_VAL:-devel}"
    echo "STATE: $STATUS"
    echo "BRANCH: $BRANCH_VAL"
    echo "---"
    cat "$RELEASE_FILE"
fi
```

Then check for any in-flight release PRs:

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

The release file doesn't exist yet. Create it.

```bash
if [ "$STATUS_ONLY" = true ]; then
    echo "STATUS: Release not yet initiated. Run without --status to create."
    exit 0
fi

# Guard: if a release PR already exists remotely (local file absent due to fresh checkout),
# do not call make release again — it would force-push the branch and may fail to create a duplicate PR.
OPEN_INIT_PR=$(gh pr list --repo "${ORG}/releases" --label automated --state open \
    --json number,title \
    --jq ".[] | select(.title | contains(\"${VERSION}\")) | .number" | wc -l | xargs)
if [ "${OPEN_INIT_PR:-0}" -gt 0 ]; then
    echo "WAITING: A release PR for ${VERSION} is already open — not calling make release again."
    exit 0
fi

echo ">>> Initiating release v${VERSION}..."
make release VERSION="${VERSION}" $DRY_RUN_FLAG
echo ">>> Initial release PR created. Waiting for CI + merge."
```

### branch → Wait for Branch Creation, Then Advance

The `branch` stage creates `release-X.Y` branches across all repos. This happens inside
`do-release.sh` after the initial release PR merges via GitHub Actions.

**Check if branch-stage `do-release` has completed:**

```bash
# Check that stable branches were created across key repos
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

echo ""
echo "Branches: ${BRANCH_COUNT}/${BRANCH_TOTAL}"
```

**Advance when all branches exist:**

If `BRANCH_COUNT == BRANCH_TOTAL` and there are no open release PRs for this version in
`submariner-io/releases`, and `STATUS_ONLY` is false, advance:

```bash
OPEN_RELEASE_PR=$(gh pr list --repo "${ORG}/releases" --label automated --state open \
    --json number,title \
    --jq ".[] | select(.title | contains(\"${VERSION}\")) | .number" | wc -l | xargs)
if [ "${OPEN_RELEASE_PR:-0}" -gt 0 ]; then
    echo "WAITING: ${OPEN_RELEASE_PR} open release PR(s) for ${VERSION} still in progress — not advancing."
elif [ "$STATUS_ONLY" = true ]; then
    echo "STATUS: All branches exist. Run without --status to advance to shipyard."
else
    echo ">>> All branches created. Advancing to shipyard..."
    make release VERSION="${VERSION}" $DRY_RUN_FLAG
fi
```

If branches are not all created, report waiting and exit.

### shipyard → Wait for Admiral Dependency PR, Then Advance

The `shipyard` stage: `do-release.sh` tags Shipyard and creates an Admiral dependency
update PR.

**Check Shipyard release and Admiral dependency PR:**

```bash
echo "--- Shipyard release ---"
SHIPYARD_RELEASE_OK=false
if SHIPYARD_REL=$(gh release view "v${VERSION}" --repo "${ORG}/shipyard" \
    --json tagName,publishedAt \
    --jq '"\(.tagName) published \(.publishedAt)"' \
    2>/dev/null); then
    echo "$SHIPYARD_REL"
    SHIPYARD_RELEASE_OK=true
else
    echo "NOT YET RELEASED"
fi

echo ""
echo "--- Admiral dependency PR ---"

# Primary: get the exact PR URL from the do-release.sh comment posted on the releases repo
# stage PR after it finishes. This avoids false positives from prior-release merged PRs.
STAGE_PR_NUM=$(gh pr list --repo "${ORG}/releases" --state merged \
    --search "\"Advancing ${VERSION} release to status: shipyard\" in:title" \
    --json number,title \
    --jq ".[] | select(.title == \"Advancing ${VERSION} release to status: shipyard\") | .number" \
    | head -1)

ADMIRAL_PR_URL=""
if [ -n "$STAGE_PR_NUM" ]; then
    ADMIRAL_PR_URL=$(gh api "repos/${ORG}/releases/pulls/${STAGE_PR_NUM}/reviews" \
        --jq '.[] | select(.body | test("Release for status .shipyard. finished")) | .body' \
        | grep -oE 'https://github.com/[^[:space:]]+' | head -1 || true)
    if [ -z "$ADMIRAL_PR_URL" ]; then
        echo "(stage PR #${STAGE_PR_NUM} found but no dep PR comment yet — do-release may still be running)"
    fi
fi

# Fallback: version-scoped search on the release base branch
if [ -z "$ADMIRAL_PR_URL" ]; then
    ADMIRAL_PR_URL=$(gh pr list --repo "${ORG}/admiral" \
        --base "${BRANCH_VAL}" --label automated --state open \
        --json url,title \
        --jq ".[] | select(.title == \"Update Submariner dependencies to v${VERSION}\") | .url" \
        2>/dev/null | head -1 || true)
    if [ -z "$ADMIRAL_PR_URL" ]; then
        ADMIRAL_PR_URL=$(gh pr list --repo "${ORG}/admiral" \
            --base "${BRANCH_VAL}" --label automated --state merged \
            --limit 20 --json url,title \
            --jq ".[] | select(.title == \"Update Submariner dependencies to v${VERSION}\") | .url" \
            2>/dev/null | head -1 || true)
    fi
fi

READY=false
if [ -z "$ADMIRAL_PR_URL" ]; then
    echo "NOT YET CREATED (do-release may still be running)"
else
    PR_STATE=$(gh pr view "$ADMIRAL_PR_URL" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
    if [ "$PR_STATE" = "MERGED" ]; then
        echo "MERGED: $ADMIRAL_PR_URL"
        READY=true
    elif [ "$PR_STATE" = "OPEN" ]; then
        echo "OPEN (waiting for CI): $ADMIRAL_PR_URL"
        # Approve only when: not status-only, not dry-run, CI not failing, not already approved
        if [ "$STATUS_ONLY" = false ] && [ -z "$DRY_RUN_FLAG" ]; then
            PR_HEAD=$(gh pr view "$ADMIRAL_PR_URL" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
            if [ -z "$PR_HEAD" ] || [[ "$PR_HEAD" != "update-dependencies-${BRANCH_VAL}" ]]; then
                echo "WARN: PR head '${PR_HEAD}' != 'update-dependencies-${BRANCH_VAL}' — skipping approval"
            elif ! CI_STATUS=$(gh pr checks "$ADMIRAL_PR_URL" 2>/dev/null); then
                echo "WARN: Could not read CI checks for ${ADMIRAL_PR_URL} — skipping approval"
            elif echo "$CI_STATUS" | grep -i "fail" | grep -qi "(Required)"; then
                echo "  Required CI check(s) failing — not approving:"
                echo "$CI_STATUS" | grep -i "fail" | grep -i "(Required)" || true
            elif ! APPROVED=$(gh pr view "$ADMIRAL_PR_URL" --json reviews \
                    --jq '[.reviews[] | select(.state=="APPROVED")] | length' 2>/dev/null); then
                echo "WARN: Could not read approval state for ${ADMIRAL_PR_URL} — skipping approval"
            elif [ "${APPROVED}" -eq 0 ]; then
                APPROVE_ERR=$(gh pr review "$ADMIRAL_PR_URL" --approve \
                    --body "Approved by automated release process" 2>&1) \
                    || echo "WARN: Approval failed for ${ADMIRAL_PR_URL}: ${APPROVE_ERR}"
            fi
        fi
        if ALL_FAILS=$(gh pr checks "$ADMIRAL_PR_URL" 2>/dev/null | grep -i "fail"); then
            REQ=$(echo "$ALL_FAILS" | grep -i "(Required)" || true)
            NON_REQ=$(echo "$ALL_FAILS" | grep -iv "(Required)" | wc -l | xargs)
            [ -n "$REQ" ] && echo "$REQ"
            [ "${NON_REQ:-0}" -gt 0 ] && echo "  (${NON_REQ} non-required failure(s) — ignored for approval)"
        fi
    else
        echo "WARN: Unexpected PR state '${PR_STATE}' for ${ADMIRAL_PR_URL} — check manually, not approving"
    fi
fi
```

**Advance when Admiral dependency PR is merged** and `STATUS_ONLY` is false:

```bash
if [ "$READY" = true ] && [ "$STATUS_ONLY" = false ]; then
    if [ "$SHIPYARD_RELEASE_OK" = false ]; then
        echo "WAITING: Shipyard GitHub release not yet published — will retry next poll."
        exit 0
    fi
    IMAGE_TAG="${VERSION#v}"
    IMAGES_OK=true
    echo "--- Verifying Shipyard images on quay.io before advancing ---"
    for IMAGE in shipyard-dapper-base; do
        if skopeo inspect --raw "docker://quay.io/submariner/${IMAGE}:${IMAGE_TAG}" >/dev/null 2>&1; then
            echo "  OK  quay.io/submariner/${IMAGE}:${IMAGE_TAG}"
        else
            echo "  MISSING  quay.io/submariner/${IMAGE}:${IMAGE_TAG}"
            IMAGES_OK=false
        fi
    done
    if [ "$IMAGES_OK" = false ]; then
        echo "WAITING: Shipyard images not yet on quay.io — will retry next poll."
    else
        echo ">>> Images verified. Advancing to admiral..."
        make release VERSION="${VERSION}" $DRY_RUN_FLAG
    fi
fi
```

### admiral → Wait for 3 Project Dependency PRs, Then Advance

The `admiral` stage: `do-release.sh` tags Admiral and creates dependency update PRs in
cloud-prepare, lighthouse, and submariner.

**Check all 3 project dependency PRs:**

```bash
echo "--- Admiral release ---"
ADMIRAL_RELEASE_OK=false
if ADMIRAL_REL=$(gh release view "v${VERSION}" --repo "${ORG}/admiral" \
    --json tagName,publishedAt \
    --jq '"\(.tagName) published \(.publishedAt)"' \
    2>/dev/null); then
    echo "$ADMIRAL_REL"
    ADMIRAL_RELEASE_OK=true
else
    echo "NOT YET RELEASED"
fi

# Primary: get exact PR URLs from the do-release.sh comment on the releases repo stage PR
ADMIRAL_STAGE_PR_NUM=$(gh pr list --repo "${ORG}/releases" --state merged \
    --search "\"Advancing ${VERSION} release to status: admiral\" in:title" \
    --json number,title \
    --jq ".[] | select(.title == \"Advancing ${VERSION} release to status: admiral\") | .number" \
    | head -1)

STAGE_DEP_PRS=""
if [ -n "$ADMIRAL_STAGE_PR_NUM" ]; then
    STAGE_DEP_PRS=$(gh api "repos/${ORG}/releases/pulls/${ADMIRAL_STAGE_PR_NUM}/reviews" \
        --jq '.[] | select(.body | test("Release for status .admiral. finished")) | .body' \
        | grep -oE 'https://github.com/[^[:space:]]+' || true)
    if [ -z "$STAGE_DEP_PRS" ]; then
        echo "(stage PR #${ADMIRAL_STAGE_PR_NUM} found but no dep PR comment yet — do-release may still be running)"
    fi
fi

PROJECTS_READY=0
PROJECTS_TOTAL=3
for REPO in cloud-prepare lighthouse submariner; do
    echo ""
    echo "--- ${REPO} dependency PR ---"

    # Try to get the exact URL from the comment first (scoped to this release/repo)
    PR_URL=$(echo "$STAGE_DEP_PRS" | grep "/${REPO}/" | head -1 || true)

    # Fallback: version-scoped search on the release base branch
    if [ -z "$PR_URL" ]; then
        PR_URL=$(gh pr list --repo "${ORG}/${REPO}" \
            --base "${BRANCH_VAL}" --label automated --state open \
            --json url,title \
            --jq ".[] | select(.title == \"Update Submariner dependencies to v${VERSION}\") | .url" \
            2>/dev/null | head -1 || true)
        if [ -z "$PR_URL" ]; then
            PR_URL=$(gh pr list --repo "${ORG}/${REPO}" \
                --base "${BRANCH_VAL}" --label automated --state merged \
                --limit 20 --json url,title \
                --jq ".[] | select(.title == \"Update Submariner dependencies to v${VERSION}\") | .url" \
                2>/dev/null | head -1 || true)
        fi
    fi

    if [ -z "$PR_URL" ]; then
        echo "NOT YET CREATED"
    else
        PR_STATE=$(gh pr view "$PR_URL" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
        if [ "$PR_STATE" = "MERGED" ]; then
            echo "MERGED: $PR_URL"
            PROJECTS_READY=$((PROJECTS_READY + 1))
        elif [ "$PR_STATE" = "OPEN" ]; then
            echo "OPEN: $PR_URL"
            # Approve only when: not status-only, not dry-run, CI not failing, not already approved
            if [ "$STATUS_ONLY" = false ] && [ -z "$DRY_RUN_FLAG" ]; then
                PR_HEAD=$(gh pr view "$PR_URL" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
                if [ -z "$PR_HEAD" ] || [[ "$PR_HEAD" != "update-dependencies-${BRANCH_VAL}" ]]; then
                    echo "WARN: PR head '${PR_HEAD}' != 'update-dependencies-${BRANCH_VAL}' — skipping approval"
                elif ! CI_STATUS=$(gh pr checks "$PR_URL" 2>/dev/null); then
                    echo "WARN: Could not read CI checks for ${PR_URL} — skipping approval"
                elif echo "$CI_STATUS" | grep -i "fail" | grep -qi "(Required)"; then
                    echo "  Required CI check(s) failing — not approving:"
                    echo "$CI_STATUS" | grep -i "fail" | grep -i "(Required)" || true
                elif ! APPROVED=$(gh pr view "$PR_URL" --json reviews \
                        --jq '[.reviews[] | select(.state=="APPROVED")] | length' 2>/dev/null); then
                    echo "WARN: Could not read approval state for ${PR_URL} — skipping approval"
                elif [ "${APPROVED}" -eq 0 ]; then
                    APPROVE_ERR=$(gh pr review "$PR_URL" --approve \
                        --body "Approved by automated release process" 2>&1) \
                        || echo "WARN: Approval failed for ${PR_URL}: ${APPROVE_ERR}"
                fi
            fi
            if ALL_FAILS=$(gh pr checks "$PR_URL" 2>/dev/null | grep -i "fail"); then
                REQ=$(echo "$ALL_FAILS" | grep -i "(Required)" || true)
                NON_REQ=$(echo "$ALL_FAILS" | grep -iv "(Required)" | wc -l | xargs)
                [ -n "$REQ" ] && echo "$REQ"
                [ "${NON_REQ:-0}" -gt 0 ] && echo "  (${NON_REQ} non-required failure(s) — ignored for approval)"
            fi
        else
            echo "WARN: Unexpected PR state '${PR_STATE}' for ${PR_URL} — check manually, not approving"
        fi
    fi
done

echo ""
echo "Project dependency PRs: ${PROJECTS_READY}/${PROJECTS_TOTAL} merged"
```

**Advance when all 3 are merged:**

```bash
if [ "$PROJECTS_READY" -eq "$PROJECTS_TOTAL" ] && [ "$STATUS_ONLY" = false ]; then
    if [ "$ADMIRAL_RELEASE_OK" = false ]; then
        echo "WAITING: Admiral GitHub release not yet published — will retry next poll."
        exit 0
    fi
    echo ">>> All project dependency PRs merged. Advancing to projects..."
    make release VERSION="${VERSION}" $DRY_RUN_FLAG
fi
```

### projects → Wait for Operator Dependency PR, Then Advance

The `projects` stage: `do-release.sh` tags cloud-prepare, lighthouse, submariner and
creates a dependency + version update PR in submariner-operator.

**Check project releases and operator dependency PR:**

```bash
echo "--- Project releases ---"
PROJECTS_RELEASE_OK=true
for REPO in cloud-prepare lighthouse submariner; do
    if PROJ_REL=$(gh release view "v${VERSION}" --repo "${ORG}/${REPO}" \
        --json tagName \
        --jq "\"${REPO}: \(.tagName)\"" \
        2>/dev/null); then
        echo "$PROJ_REL"
    else
        echo "${REPO}: NOT YET RELEASED"
        PROJECTS_RELEASE_OK=false
    fi
done

echo ""
echo "--- Operator dependency PR ---"

# Primary: get exact PR URL from the do-release.sh comment on the releases repo stage PR
PROJECTS_STAGE_PR_NUM=$(gh pr list --repo "${ORG}/releases" --state merged \
    --search "\"Advancing ${VERSION} release to status: projects\" in:title" \
    --json number,title \
    --jq ".[] | select(.title == \"Advancing ${VERSION} release to status: projects\") | .number" \
    | head -1)

OPERATOR_PR_URL=""
if [ -n "$PROJECTS_STAGE_PR_NUM" ]; then
    OPERATOR_PR_URL=$(gh api "repos/${ORG}/releases/pulls/${PROJECTS_STAGE_PR_NUM}/reviews" \
        --jq '.[] | select(.body | test("Release for status .projects. finished")) | .body' \
        | grep -oE 'https://github.com/[^[:space:]]+' | head -1 || true)
    if [ -z "$OPERATOR_PR_URL" ]; then
        echo "(stage PR #${PROJECTS_STAGE_PR_NUM} found but no dep PR comment yet — do-release may still be running)"
    fi
fi

# Fallback: version-scoped search on the release base branch
if [ -z "$OPERATOR_PR_URL" ]; then
    OPERATOR_PR_URL=$(gh pr list --repo "${ORG}/submariner-operator" \
        --base "${BRANCH_VAL}" --label automated --state open \
        --json url,title \
        --jq ".[] | select(.title == \"Update Submariner dependencies to v${VERSION}\") | .url" \
        2>/dev/null | head -1 || true)
    if [ -z "$OPERATOR_PR_URL" ]; then
        OPERATOR_PR_URL=$(gh pr list --repo "${ORG}/submariner-operator" \
            --base "${BRANCH_VAL}" --label automated --state merged \
            --limit 20 --json url,title \
            --jq ".[] | select(.title == \"Update Submariner dependencies to v${VERSION}\") | .url" \
            2>/dev/null | head -1 || true)
    fi
fi

READY=false
if [ -z "$OPERATOR_PR_URL" ]; then
    echo "NOT YET CREATED (do-release may still be running)"
else
    PR_STATE=$(gh pr view "$OPERATOR_PR_URL" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
    if [ "$PR_STATE" = "MERGED" ]; then
        echo "MERGED: $OPERATOR_PR_URL"
        READY=true
    elif [ "$PR_STATE" = "OPEN" ]; then
        echo "OPEN: $OPERATOR_PR_URL"
        # Approve only when: not status-only, not dry-run, CI not failing, not already approved
        if [ "$STATUS_ONLY" = false ] && [ -z "$DRY_RUN_FLAG" ]; then
            PR_HEAD=$(gh pr view "$OPERATOR_PR_URL" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
            if [ -z "$PR_HEAD" ] || [[ "$PR_HEAD" != "update-dependencies-${BRANCH_VAL}" ]]; then
                echo "WARN: PR head '${PR_HEAD}' != 'update-dependencies-${BRANCH_VAL}' — skipping approval"
            elif ! CI_STATUS=$(gh pr checks "$OPERATOR_PR_URL" 2>/dev/null); then
                echo "WARN: Could not read CI checks for ${OPERATOR_PR_URL} — skipping approval"
            elif echo "$CI_STATUS" | grep -i "fail" | grep -qi "(Required)"; then
                echo "  Required CI check(s) failing — not approving:"
                echo "$CI_STATUS" | grep -i "fail" | grep -i "(Required)" || true
            elif ! APPROVED=$(gh pr view "$OPERATOR_PR_URL" --json reviews \
                    --jq '[.reviews[] | select(.state=="APPROVED")] | length' 2>/dev/null); then
                echo "WARN: Could not read approval state for ${OPERATOR_PR_URL} — skipping approval"
            elif [ "${APPROVED}" -eq 0 ]; then
                APPROVE_ERR=$(gh pr review "$OPERATOR_PR_URL" --approve \
                    --body "Approved by automated release process" 2>&1) \
                    || echo "WARN: Approval failed for ${OPERATOR_PR_URL}: ${APPROVE_ERR}"
            fi
        fi
        if ALL_FAILS=$(gh pr checks "$OPERATOR_PR_URL" 2>/dev/null | grep -i "fail"); then
            REQ=$(echo "$ALL_FAILS" | grep -i "(Required)" || true)
            NON_REQ=$(echo "$ALL_FAILS" | grep -iv "(Required)" | wc -l | xargs)
            [ -n "$REQ" ] && echo "$REQ"
            [ "${NON_REQ:-0}" -gt 0 ] && echo "  (${NON_REQ} non-required failure(s) — ignored for approval)"
        fi
    else
        echo "WARN: Unexpected PR state '${PR_STATE}' for ${OPERATOR_PR_URL} — check manually, not approving"
    fi
fi
```

**Advance when merged:**

```bash
if [ "$READY" = true ] && [ "$STATUS_ONLY" = false ]; then
    if [ "$PROJECTS_RELEASE_OK" = false ]; then
        echo "WAITING: One or more project GitHub releases not yet published — will retry next poll."
        exit 0
    fi
    echo "--- Release Image workflows ---"
    IMAGE_TAG="${VERSION#v}"
    for REPO in cloud-prepare lighthouse submariner; do
        RUN=$(gh run list --repo "${ORG}/${REPO}" \
            --event push --limit 20 \
            --json status,conclusion,headBranch,displayTitle \
            --jq ".[] | select(.headBranch == \"v${IMAGE_TAG}\")" \
            2>/dev/null | jq -s '.[0]' 2>/dev/null || true)
        if [ -z "$RUN" ] || [ "$RUN" = "null" ]; then
            echo "  ${REPO}: release workflow not yet triggered"
        else
            WSTATUS=$(echo "$RUN" | jq -r '"\(.displayTitle // "release"): \(.status)/\(.conclusion // "—")"' 2>/dev/null || echo "unknown")
            echo "  ${REPO}: ${WSTATUS}"
        fi
    done
    IMAGES_OK=true
    PATCH=$(echo "$VERSION" | cut -d. -f3 | cut -d- -f1)
    echo "--- Verifying project images on quay.io before advancing ---"
    if [ "$PATCH" -gt 0 ]; then
        # z-release: images tagged release-X.Y-<12-char-commit>; use YAML component hashes
        SUBMARINER_SHA=$(grep "^  submariner:" "$RELEASE_FILE" | awk '{print $2}' | cut -c1-12)
        LIGHTHOUSE_SHA=$(grep "^  lighthouse:" "$RELEASE_FILE" | awk '{print $2}' | cut -c1-12)
        for IMAGE in submariner-gateway submariner-route-agent submariner-globalnet; do
            ITAG="${STABLE_BRANCH}-${SUBMARINER_SHA}"
            skopeo inspect --raw "docker://quay.io/submariner/${IMAGE}:${ITAG}" >/dev/null 2>&1 \
                && echo "  OK  ${IMAGE}:${ITAG}" || { echo "  MISSING  ${IMAGE}:${ITAG}"; IMAGES_OK=false; }
        done
        for IMAGE in lighthouse-agent lighthouse-coredns; do
            ITAG="${STABLE_BRANCH}-${LIGHTHOUSE_SHA}"
            skopeo inspect --raw "docker://quay.io/submariner/${IMAGE}:${ITAG}" >/dev/null 2>&1 \
                && echo "  OK  ${IMAGE}:${ITAG}" || { echo "  MISSING  ${IMAGE}:${ITAG}"; IMAGES_OK=false; }
        done
    else
        IMAGE_TAG="${VERSION#v}"
        for IMAGE in submariner-gateway submariner-route-agent submariner-globalnet \
                     lighthouse-agent lighthouse-coredns; do
            skopeo inspect --raw "docker://quay.io/submariner/${IMAGE}:${IMAGE_TAG}" >/dev/null 2>&1 \
                && echo "  OK  ${IMAGE}:${IMAGE_TAG}" || { echo "  MISSING  ${IMAGE}:${IMAGE_TAG}"; IMAGES_OK=false; }
        done
    fi
    if [ "$IMAGES_OK" = false ]; then
        echo "WAITING: Project images not yet on quay.io — will retry next poll."
    else
        echo ">>> Images verified. Advancing to installers..."
        make release VERSION="${VERSION}" $DRY_RUN_FLAG
    fi
fi
```

### installers → Wait for Subctl + Charts Dependency PRs, Then Advance

The `installers` stage: `do-release.sh` tags submariner-operator and creates dependency
update PRs in subctl and submariner-charts.

**Check both dependency PRs:**

```bash
echo "--- Operator release ---"
OPERATOR_RELEASE_OK=false
if OPERATOR_REL=$(gh release view "v${VERSION}" --repo "${ORG}/submariner-operator" \
    --json tagName,publishedAt \
    --jq '"\(.tagName) published \(.publishedAt)"' \
    2>/dev/null); then
    echo "$OPERATOR_REL"
    OPERATOR_RELEASE_OK=true
else
    echo "NOT YET RELEASED"
fi

# Primary: get exact PR URLs from the do-release.sh comment on the releases repo stage PR
INST_STAGE_PR_NUM=$(gh pr list --repo "${ORG}/releases" --state merged \
    --search "\"Advancing ${VERSION} release to status: installers\" in:title" \
    --json number,title \
    --jq ".[] | select(.title == \"Advancing ${VERSION} release to status: installers\") | .number" \
    | head -1)

INST_DEP_PRS=""
if [ -n "$INST_STAGE_PR_NUM" ]; then
    INST_DEP_PRS=$(gh api "repos/${ORG}/releases/pulls/${INST_STAGE_PR_NUM}/reviews" \
        --jq '.[] | select(.body | test("Release for status .installers. finished")) | .body' \
        | grep -oE 'https://github.com/[^[:space:]]+' || true)
    if [ -z "$INST_DEP_PRS" ]; then
        echo "(stage PR #${INST_STAGE_PR_NUM} found but no dep PR comment yet — do-release may still be running)"
    fi
fi

INST_READY=0
INST_TOTAL=2
for REPO in subctl submariner-charts; do
    echo ""
    echo "--- ${REPO} dependency PR ---"

    # Try to get the exact URL from the comment first (scoped to this release/repo)
    PR_URL=$(echo "$INST_DEP_PRS" | grep "/${REPO}/" | head -1 || true)

    # Fallback: version-scoped search on the release base branch
    if [ -z "$PR_URL" ]; then
        PR_URL=$(gh pr list --repo "${ORG}/${REPO}" \
            --base "${BRANCH_VAL}" --label automated --state open \
            --json url,title \
            --jq ".[] | select(.title == \"Update Submariner dependencies to v${VERSION}\") | .url" \
            2>/dev/null | head -1 || true)
        if [ -z "$PR_URL" ]; then
            PR_URL=$(gh pr list --repo "${ORG}/${REPO}" \
                --base "${BRANCH_VAL}" --label automated --state merged \
                --limit 20 --json url,title \
                --jq ".[] | select(.title == \"Update Submariner dependencies to v${VERSION}\") | .url" \
                2>/dev/null | head -1 || true)
        fi
    fi

    if [ -z "$PR_URL" ]; then
        echo "NOT YET CREATED"
    else
        PR_STATE=$(gh pr view "$PR_URL" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
        if [ "$PR_STATE" = "MERGED" ]; then
            echo "MERGED: $PR_URL"
            INST_READY=$((INST_READY + 1))
        elif [ "$PR_STATE" = "OPEN" ]; then
            echo "OPEN: $PR_URL"
            # Approve only when: not status-only, not dry-run, CI not failing, not already approved
            if [ "$STATUS_ONLY" = false ] && [ -z "$DRY_RUN_FLAG" ]; then
                PR_HEAD=$(gh pr view "$PR_URL" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
                if [ -z "$PR_HEAD" ] || [[ "$PR_HEAD" != "update-dependencies-${BRANCH_VAL}" ]]; then
                    echo "WARN: PR head '${PR_HEAD}' != 'update-dependencies-${BRANCH_VAL}' — skipping approval"
                elif ! CI_STATUS=$(gh pr checks "$PR_URL" 2>/dev/null); then
                    echo "WARN: Could not read CI checks for ${PR_URL} — skipping approval"
                elif echo "$CI_STATUS" | grep -i "fail" | grep -qi "(Required)"; then
                    echo "  Required CI check(s) failing — not approving:"
                    echo "$CI_STATUS" | grep -i "fail" | grep -i "(Required)" || true
                elif ! APPROVED=$(gh pr view "$PR_URL" --json reviews \
                        --jq '[.reviews[] | select(.state=="APPROVED")] | length' 2>/dev/null); then
                    echo "WARN: Could not read approval state for ${PR_URL} — skipping approval"
                elif [ "${APPROVED}" -eq 0 ]; then
                    APPROVE_ERR=$(gh pr review "$PR_URL" --approve \
                        --body "Approved by automated release process" 2>&1) \
                        || echo "WARN: Approval failed for ${PR_URL}: ${APPROVE_ERR}"
                fi
            fi
            if ALL_FAILS=$(gh pr checks "$PR_URL" 2>/dev/null | grep -i "fail"); then
                REQ=$(echo "$ALL_FAILS" | grep -i "(Required)" || true)
                NON_REQ=$(echo "$ALL_FAILS" | grep -iv "(Required)" | wc -l | xargs)
                [ -n "$REQ" ] && echo "$REQ"
                [ "${NON_REQ:-0}" -gt 0 ] && echo "  (${NON_REQ} non-required failure(s) — ignored for approval)"
            fi
        else
            echo "WARN: Unexpected PR state '${PR_STATE}' for ${PR_URL} — check manually, not approving"
        fi
    fi
done

echo ""
echo "Installer dependency PRs: ${INST_READY}/${INST_TOTAL} merged"
```

**Advance when both merged:**

```bash
if [ "$INST_READY" -eq "$INST_TOTAL" ] && [ "$STATUS_ONLY" = false ]; then
    if [ "$OPERATOR_RELEASE_OK" = false ]; then
        echo "WAITING: Operator GitHub release not yet published — will retry next poll."
        exit 0
    fi
    echo "--- Release Image workflows ---"
    IMAGE_TAG="${VERSION#v}"
    for REPO in submariner-operator subctl; do
        RUN=$(gh run list --repo "${ORG}/${REPO}" \
            --event push --limit 20 \
            --json status,conclusion,headBranch,displayTitle \
            --jq ".[] | select(.headBranch == \"v${IMAGE_TAG}\")" \
            2>/dev/null | jq -s '.[0]' 2>/dev/null || true)
        if [ -z "$RUN" ] || [ "$RUN" = "null" ]; then
            echo "  ${REPO}: release workflow not yet triggered"
        else
            WSTATUS=$(echo "$RUN" | jq -r '"\(.displayTitle // "release"): \(.status)/\(.conclusion // "—")"' 2>/dev/null || echo "unknown")
            echo "  ${REPO}: ${WSTATUS}"
        fi
    done
    IMAGES_OK=true
    PATCH=$(echo "$VERSION" | cut -d. -f3 | cut -d- -f1)
    echo "--- Verifying installer images on quay.io before advancing ---"
    if [ "$PATCH" -gt 0 ]; then
        # z-release: submariner-operator from YAML hash; subctl fetched from GitHub API
        OPERATOR_SHA=$(grep "^  submariner-operator:" "$RELEASE_FILE" | awk '{print $2}' | cut -c1-12)
        SUBCTL_SHA=$(gh api "repos/${ORG}/subctl/commits/${BRANCH_VAL}" --jq '.sha' | cut -c1-12)
        for IMAGE_ENTRY in "submariner-operator:${OPERATOR_SHA}" "subctl:${SUBCTL_SHA}"; do
            IMAGE="${IMAGE_ENTRY%%:*}"; COMMIT="${IMAGE_ENTRY##*:}"
            ITAG="${STABLE_BRANCH}-${COMMIT}"
            skopeo inspect --raw "docker://quay.io/submariner/${IMAGE}:${ITAG}" >/dev/null 2>&1 \
                && echo "  OK  ${IMAGE}:${ITAG}" || { echo "  MISSING  ${IMAGE}:${ITAG}"; IMAGES_OK=false; }
        done
    else
        IMAGE_TAG="${VERSION#v}"
        for IMAGE in submariner-operator subctl; do
            skopeo inspect --raw "docker://quay.io/submariner/${IMAGE}:${IMAGE_TAG}" >/dev/null 2>&1 \
                && echo "  OK  ${IMAGE}:${IMAGE_TAG}" || { echo "  MISSING  ${IMAGE}:${IMAGE_TAG}"; IMAGES_OK=false; }
        done
    fi
    if [ "$IMAGES_OK" = false ]; then
        echo "WAITING: Installer images not yet on quay.io — will retry next poll."
    else
        echo ">>> Images verified. Advancing to released..."
        make release VERSION="${VERSION}" $DRY_RUN_FLAG
    fi
fi
```

### released → Verify Final Artifacts

The `released` stage: `do-release.sh` cross-compiles subctl, creates the final GitHub
release with binaries, and tags all remaining projects.

**Verify everything landed:**

```bash
echo "=== Final Release Verification ==="
echo ""

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
            echo "  MISSING  ${PLATFORM}"
            BINARIES_OK=false
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
        echo "  OK  ${REPO}"
        TAG_COUNT=$((TAG_COUNT + 1))
    else
        echo "  --  ${REPO}: not tagged"
    fi
done
echo "Tags: ${TAG_COUNT}/${TAG_TOTAL}"

# Container images on quay.io (spot check — only checks tag existence, not content)
echo ""
echo "--- Container Images (quay.io) ---"
IMAGE_TAG="${VERSION#v}"  # quay.io tags don't have 'v' prefix

echo "--- Release Image workflows ---"
for REPO in submariner lighthouse submariner-operator subctl; do
    RUN=$(gh run list --repo "${ORG}/${REPO}" \
        --event push --limit 20 \
        --json status,conclusion,headBranch,displayTitle \
        --jq ".[] | select(.headBranch == \"v${IMAGE_TAG}\")" \
        2>/dev/null | jq -s '.[0]' 2>/dev/null || true)
    if [ -z "$RUN" ] || [ "$RUN" = "null" ]; then
        echo "  ${REPO}: release workflow not found for v${IMAGE_TAG}"
    else
        WSTATUS=$(echo "$RUN" | jq -r '"\(.displayTitle // "release"): \(.status)/\(.conclusion // "—")"' 2>/dev/null || echo "unknown")
        echo "  ${REPO}: ${WSTATUS}"
    fi
done

IMAGES_COMPLETE=true
for IMAGE in submariner-gateway submariner-route-agent submariner-globalnet \
             lighthouse-agent lighthouse-coredns submariner-operator subctl; do
    if skopeo inspect --raw "docker://quay.io/submariner/${IMAGE}:${IMAGE_TAG}" >/dev/null 2>&1; then
        echo "  OK  quay.io/submariner/${IMAGE}:${IMAGE_TAG}"
    else
        echo "  --  quay.io/submariner/${IMAGE}:${IMAGE_TAG} NOT FOUND"
        IMAGES_COMPLETE=false
    fi
done

# Post-release workflow (krew index update)
echo ""
echo "--- Post-Release Workflow ---"
POST_RELEASE_OK=false
POST_RUN=$(gh run list --repo "${ORG}/releases" --workflow "post-release.yml" --limit 5 \
    --json status,conclusion,createdAt,displayTitle \
    --jq ".[] | select(.displayTitle | contains(\"${VERSION}\"))" 2>/dev/null | head -1 || true)
if [ -z "$POST_RUN" ]; then
    echo "No post-release workflow run found for ${VERSION} (may not have started yet — not a blocker for RCs)"
    POST_RELEASE_OK=true
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

If all 8 tags exist, the GitHub release is published, all 7 images show OK, all 3 platform binaries are present, AND the post-release workflow succeeded (or is absent for RC releases):

```
Release v${VERSION} COMPLETE.

(If any image showed NOT FOUND above or the post-release workflow failed, do NOT start downstream.)

Downstream next steps (Step 7 in release workflow):
  cd ~/konflux/submariner-release-management
  /bundle-image-update ${VERSION}
```

If the do-release workflow is still running, report waiting.

---

## Error Handling

When a dependency PR has failing CI checks, report the failure clearly but do NOT
attempt to fix it. The human needs to investigate.

```bash
# Example: show failing checks on an open PR
gh pr checks "$PR_URL" 2>/dev/null \
    | grep -i "fail" || true
```

When `make release` fails:
- Print the error output
- Do NOT retry automatically
- Suggest the user check `git status` and ensure their branch is clean and up-to-date

When `do-release` GitHub Actions fails:
```bash
# Show the failed run
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
- Auto-merge is enabled on all release PRs — they merge once CI passes
- Dependency update PRs are labeled `automated` and have auto-merge
- CI typically takes 20-40 minutes per repo
- Full release typically takes 20-24 hours (mostly CI wait time)
- A 10-minute `/loop` interval keeps polling under GitHub API rate limits
  (~72 calls/hr vs 5000/hr limit)
- On transient errors (`make release` fails, approval fails), the skill reports and waits — the next `/loop` tick retries automatically. On persistent failures (CI blocked, do-release workflow failed), human intervention is required.
