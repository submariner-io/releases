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
3. **NEVER approve or merge PRs** — auto-merge is already enabled by the release scripts.
   Do not call `gh pr review --approve` or `gh pr merge`.
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

echo "$ARGS" | grep -q -- '--status' && STATUS_ONLY=true
echo "$ARGS" | grep -q -- '--dry-run' && DRY_RUN_FLAG="DRY_RUN=true"

if [ -z "$VERSION" ]; then
    echo "ERROR: Version required."
    echo "Usage: /create-release 0.24.0-rc0 [--status] [--dry-run]"
    exit 1
fi

# Validate semver format (matches validate_semver in scripts/lib/utils)
if ! echo "$VERSION" | grep -qP '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9a-zA-Z.-]*)?$'; then
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

# 3. Verify GITHUB_TOKEN is set (required by make release inside Dapper)
if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "ERROR: GITHUB_TOKEN not set."
    echo "Run: export GITHUB_TOKEN=\$(gh auth token)"
    exit 1
fi
echo "GITHUB_TOKEN: set"

# 4. Verify Docker is available (make release runs inside Dapper container)
if [ "$STATUS_ONLY" = false ]; then
    if ! docker info >/dev/null 2>&1; then
        echo "ERROR: Docker not available. make release requires Docker (Dapper)."
        exit 1
    fi
    echo "Docker: OK"
fi
```

## Step 3: Determine Current State

Read the release YAML to find the current stage.

```bash
if [ ! -f "$RELEASE_FILE" ]; then
    echo "STATE: not-started"
    echo "Release file $RELEASE_FILE does not exist."
else
    STATUS=$(yq -r '.status' "$RELEASE_FILE")
    BRANCH_VAL=$(yq -r '.branch // "devel"' "$RELEASE_FILE")
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
    --jq '.[] | select(.title | test("'"${VERSION}"'")) | "\(.number) \(.title) \(.url)"'

echo ""
echo "=== Recent release workflow runs ==="
gh run list --repo "${ORG}/releases" --workflow "release.yml" --limit 5 \
    --json status,conclusion,createdAt,displayTitle \
    --jq '.[] | "\(.status)/\(.conclusion // "—") \(.createdAt) \(.displayTitle)"'
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
BRANCH_TOTAL=6
for REPO in shipyard admiral submariner lighthouse cloud-prepare submariner-operator; do
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
echo ">>> All branches created. Advancing to shipyard..."
make release VERSION="${VERSION}" $DRY_RUN_FLAG
```

If branches are not all created, report waiting and exit.

### shipyard → Wait for Admiral Dependency PR, Then Advance

The `shipyard` stage: `do-release.sh` tags Shipyard and creates an Admiral dependency
update PR.

**Check Shipyard release and Admiral dependency PR:**

```bash
echo "--- Shipyard release ---"
gh release view "v${VERSION}" --repo "${ORG}/shipyard" \
    --json tagName,publishedAt \
    --jq '"\(.tagName) published \(.publishedAt)"' \
    2>/dev/null || echo "NOT YET RELEASED"

echo ""
echo "--- Admiral dependency PR ---"

# Primary: get the exact PR URL from the do-release.sh comment posted on the releases repo
# stage PR after it finishes. This avoids false positives from prior-release merged PRs.
STAGE_PR_NUM=$(gh pr list --repo "${ORG}/releases" --state merged --limit 100 \
    --json number,title \
    --jq ".[] | select(.title == \"Advancing ${VERSION} release to status: shipyard\") | .number" \
    | head -1)

ADMIRAL_PR_URL=""
if [ -n "$STAGE_PR_NUM" ]; then
    ADMIRAL_PR_URL=$(gh api "repos/${ORG}/releases/pulls/${STAGE_PR_NUM}/reviews" \
        --jq '.[] | select(.body | test("Release for status .shipyard. finished")) | .body' \
        | grep -oE 'https://github.com/[^[:space:]]+' | head -1 || true)
fi

# Fallback: filtered search scoped to the release base branch (when do-release is still
# running and hasn't posted the comment yet)
if [ -z "$ADMIRAL_PR_URL" ]; then
    ADMIRAL_PR_URL=$(gh pr list --repo "${ORG}/admiral" \
        --base "${BRANCH_VAL}" --label automated --state open \
        --json url --jq '.[0].url // empty' 2>/dev/null || true)
    if [ -z "$ADMIRAL_PR_URL" ]; then
        ADMIRAL_PR_URL=$(gh pr list --repo "${ORG}/admiral" \
            --base "${BRANCH_VAL}" --label automated --state merged \
            --limit 5 --json url --jq '.[0].url // empty' 2>/dev/null || true)
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
    else
        echo "OPEN (waiting for CI): $ADMIRAL_PR_URL"
        gh pr checks "$ADMIRAL_PR_URL" 2>/dev/null | grep -i "fail" || true
    fi
fi
```

**Advance when Admiral dependency PR is merged** and `STATUS_ONLY` is false:

```bash
if [ "$READY" = true ]; then
    echo ">>> Admiral dependency PR merged. Advancing to admiral..."
    make release VERSION="${VERSION}" $DRY_RUN_FLAG
fi
```

### admiral → Wait for 3 Project Dependency PRs, Then Advance

The `admiral` stage: `do-release.sh` tags Admiral and creates dependency update PRs in
cloud-prepare, lighthouse, and submariner.

**Check all 3 project dependency PRs:**

```bash
echo "--- Admiral release ---"
gh release view "v${VERSION}" --repo "${ORG}/admiral" \
    --json tagName,publishedAt \
    --jq '"\(.tagName) published \(.publishedAt)"' \
    2>/dev/null || echo "NOT YET RELEASED"

# Primary: get exact PR URLs from the do-release.sh comment on the releases repo stage PR
ADMIRAL_STAGE_PR_NUM=$(gh pr list --repo "${ORG}/releases" --state merged --limit 100 \
    --json number,title \
    --jq ".[] | select(.title == \"Advancing ${VERSION} release to status: admiral\") | .number" \
    | head -1)

STAGE_DEP_PRS=""
if [ -n "$ADMIRAL_STAGE_PR_NUM" ]; then
    STAGE_DEP_PRS=$(gh api "repos/${ORG}/releases/pulls/${ADMIRAL_STAGE_PR_NUM}/reviews" \
        --jq '.[] | select(.body | test("Release for status .admiral. finished")) | .body' \
        | grep -oE 'https://github.com/[^[:space:]]+' || true)
fi

PROJECTS_READY=0
PROJECTS_TOTAL=3
for REPO in cloud-prepare lighthouse submariner; do
    echo ""
    echo "--- ${REPO} dependency PR ---"

    # Try to get the exact URL from the comment first (scoped to this release/repo)
    PR_URL=$(echo "$STAGE_DEP_PRS" | grep "/${REPO}/" | head -1 || true)

    # Fallback: filtered search scoped to the release base branch
    if [ -z "$PR_URL" ]; then
        PR_URL=$(gh pr list --repo "${ORG}/${REPO}" \
            --base "${BRANCH_VAL}" --label automated --state open \
            --json url --jq '.[0].url // empty' 2>/dev/null || true)
        if [ -z "$PR_URL" ]; then
            PR_URL=$(gh pr list --repo "${ORG}/${REPO}" \
                --base "${BRANCH_VAL}" --label automated --state merged \
                --limit 5 --json url --jq '.[0].url // empty' 2>/dev/null || true)
        fi
    fi

    if [ -z "$PR_URL" ]; then
        echo "NOT YET CREATED"
    else
        PR_STATE=$(gh pr view "$PR_URL" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
        if [ "$PR_STATE" = "MERGED" ]; then
            echo "MERGED: $PR_URL"
            PROJECTS_READY=$((PROJECTS_READY + 1))
        else
            echo "OPEN: $PR_URL"
            gh pr checks "$PR_URL" 2>/dev/null | grep -i "fail" || true
        fi
    fi
done

echo ""
echo "Project dependency PRs: ${PROJECTS_READY}/${PROJECTS_TOTAL} merged"
```

**Advance when all 3 are merged:**

```bash
if [ "$PROJECTS_READY" -eq "$PROJECTS_TOTAL" ] && [ "$STATUS_ONLY" = false ]; then
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
for REPO in cloud-prepare lighthouse submariner; do
    gh release view "v${VERSION}" --repo "${ORG}/${REPO}" \
        --json tagName \
        --jq "\"${REPO}: \(.tagName)\"" \
        2>/dev/null || echo "${REPO}: NOT YET RELEASED"
done

echo ""
echo "--- Operator dependency PR ---"

# Primary: get exact PR URL from the do-release.sh comment on the releases repo stage PR
PROJECTS_STAGE_PR_NUM=$(gh pr list --repo "${ORG}/releases" --state merged --limit 100 \
    --json number,title \
    --jq ".[] | select(.title == \"Advancing ${VERSION} release to status: projects\") | .number" \
    | head -1)

OPERATOR_PR_URL=""
if [ -n "$PROJECTS_STAGE_PR_NUM" ]; then
    OPERATOR_PR_URL=$(gh api "repos/${ORG}/releases/pulls/${PROJECTS_STAGE_PR_NUM}/reviews" \
        --jq '.[] | select(.body | test("Release for status .projects. finished")) | .body' \
        | grep -oE 'https://github.com/[^[:space:]]+' | head -1 || true)
fi

# Fallback: filtered search scoped to the release base branch
if [ -z "$OPERATOR_PR_URL" ]; then
    OPERATOR_PR_URL=$(gh pr list --repo "${ORG}/submariner-operator" \
        --base "${BRANCH_VAL}" --label automated --state open \
        --json url --jq '.[0].url // empty' 2>/dev/null || true)
    if [ -z "$OPERATOR_PR_URL" ]; then
        OPERATOR_PR_URL=$(gh pr list --repo "${ORG}/submariner-operator" \
            --base "${BRANCH_VAL}" --label automated --state merged \
            --limit 5 --json url --jq '.[0].url // empty' 2>/dev/null || true)
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
    else
        echo "OPEN: $OPERATOR_PR_URL"
        gh pr checks "$OPERATOR_PR_URL" 2>/dev/null | grep -i "fail" || true
    fi
fi
```

**Advance when merged:**

```bash
if [ "$READY" = true ] && [ "$STATUS_ONLY" = false ]; then
    echo ">>> Operator dependency PR merged. Advancing to installers..."
    make release VERSION="${VERSION}" $DRY_RUN_FLAG
fi
```

### installers → Wait for Subctl + Charts Dependency PRs, Then Advance

The `installers` stage: `do-release.sh` tags submariner-operator and creates dependency
update PRs in subctl and submariner-charts.

**Check both dependency PRs:**

```bash
echo "--- Operator release ---"
gh release view "v${VERSION}" --repo "${ORG}/submariner-operator" \
    --json tagName,publishedAt \
    --jq '"\(.tagName) published \(.publishedAt)"' \
    2>/dev/null || echo "NOT YET RELEASED"

# Primary: get exact PR URLs from the do-release.sh comment on the releases repo stage PR
INST_STAGE_PR_NUM=$(gh pr list --repo "${ORG}/releases" --state merged --limit 100 \
    --json number,title \
    --jq ".[] | select(.title == \"Advancing ${VERSION} release to status: installers\") | .number" \
    | head -1)

INST_DEP_PRS=""
if [ -n "$INST_STAGE_PR_NUM" ]; then
    INST_DEP_PRS=$(gh api "repos/${ORG}/releases/pulls/${INST_STAGE_PR_NUM}/reviews" \
        --jq '.[] | select(.body | test("Release for status .installers. finished")) | .body' \
        | grep -oE 'https://github.com/[^[:space:]]+' || true)
fi

INST_READY=0
INST_TOTAL=2
for REPO in subctl submariner-charts; do
    echo ""
    echo "--- ${REPO} dependency PR ---"

    # Try to get the exact URL from the comment first (scoped to this release/repo)
    PR_URL=$(echo "$INST_DEP_PRS" | grep "/${REPO}/" | head -1 || true)

    # Fallback: filtered search scoped to the release base branch
    if [ -z "$PR_URL" ]; then
        PR_URL=$(gh pr list --repo "${ORG}/${REPO}" \
            --base "${BRANCH_VAL}" --label automated --state open \
            --json url --jq '.[0].url // empty' 2>/dev/null || true)
        if [ -z "$PR_URL" ]; then
            PR_URL=$(gh pr list --repo "${ORG}/${REPO}" \
                --base "${BRANCH_VAL}" --label automated --state merged \
                --limit 5 --json url --jq '.[0].url // empty' 2>/dev/null || true)
        fi
    fi

    if [ -z "$PR_URL" ]; then
        echo "NOT YET CREATED"
    else
        PR_STATE=$(gh pr view "$PR_URL" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
        if [ "$PR_STATE" = "MERGED" ]; then
            echo "MERGED: $PR_URL"
            INST_READY=$((INST_READY + 1))
        else
            echo "OPEN: $PR_URL"
            gh pr checks "$PR_URL" 2>/dev/null | grep -i "fail" || true
        fi
    fi
done

echo ""
echo "Installer dependency PRs: ${INST_READY}/${INST_TOTAL} merged"
```

**Advance when both merged:**

```bash
if [ "$INST_READY" -eq "$INST_TOTAL" ] && [ "$STATUS_ONLY" = false ]; then
    echo ">>> Subctl + charts dependency PRs merged. Advancing to released..."
    make release VERSION="${VERSION}" $DRY_RUN_FLAG
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
gh release view "v${VERSION}" --repo "${ORG}/releases" \
    --json tagName,publishedAt,assets \
    --jq '{tag: .tagName, published: .publishedAt, assets: [.assets[].name]}' \
    2>/dev/null || echo "NOT FOUND — do-release may still be running"

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
for IMAGE in submariner-gateway submariner-route-agent submariner-globalnet \
             lighthouse-agent lighthouse-coredns submariner-operator; do
    if skopeo inspect --raw "docker://quay.io/submariner/${IMAGE}:${IMAGE_TAG}" >/dev/null 2>&1; then
        echo "  OK  quay.io/submariner/${IMAGE}:${IMAGE_TAG}"
    else
        echo "  --  quay.io/submariner/${IMAGE}:${IMAGE_TAG} NOT FOUND"
    fi
done

# Post-release workflow (krew index update)
echo ""
echo "--- Post-Release Workflow ---"
gh run list --repo "${ORG}/releases" --workflow "post-release.yml" --limit 3 \
    --json status,conclusion,createdAt \
    --jq '.[] | "\(.status)/\(.conclusion // "—") \(.createdAt)"'
```

If all 8 tags exist and the GitHub release is published:

```
Release v${VERSION} COMPLETE.

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
    | grep -v "pass" \
    | head -10
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
