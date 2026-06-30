#!/usr/bin/env bash
# find-dep-pr.sh — Find a dependency PR URL created by do-release.sh.
#
# Two strategies:
#   1. Primary: look at the stage's merged releases-repo PR comments for the URL
#   2. Fallback: search open then merged PRs in target repo
#
# Usage: find-dep-pr.sh <org> <version> <branch_val> <stage_name> <target_repo>
#   stage_name:  the stage status that was advanced TO (e.g., "shipyard")
#   target_repo: the repo where the dep PR lives (e.g., "admiral")
#
# Outputs the PR URL to stdout (empty if not found).
set -euo pipefail

ORG="$1"
VERSION="$2"
BRANCH_VAL="$3"
STAGE_NAME="$4"
TARGET_REPO="$5"

PR_URL=""

# Primary: get the exact PR URL from the do-release.sh comment posted on the releases repo
# stage PR after it finishes. This avoids false positives from prior-release merged PRs.
STAGE_PR_NUM=$(gh pr list --repo "${ORG}/releases" --state merged \
    --search "\"Advancing ${VERSION} release to status: ${STAGE_NAME}\" in:title" \
    --json number,title \
    --jq ".[] | select(.title == \"Advancing ${VERSION} release to status: ${STAGE_NAME}\") | .number" \
    | head -1)

if [ -n "$STAGE_PR_NUM" ]; then
    STAGE_DEP_PRS=$(gh api "repos/${ORG}/releases/pulls/${STAGE_PR_NUM}/reviews" \
        --jq ".[] | select(.body | test(\"Release for status .${STAGE_NAME}. finished\")) | .body" \
        | grep -oE 'https://github.com/[^[:space:]]+' || true)

    if [ -n "$STAGE_DEP_PRS" ]; then
        PR_URL=$(echo "$STAGE_DEP_PRS" | grep "/${TARGET_REPO}/" | head -1 || true)
    else
        echo "(stage PR #${STAGE_PR_NUM} found but no dep PR comment yet — do-release may still be running)" >&2
    fi
fi

# Fallback: version-scoped search on the release base branch
if [ -z "$PR_URL" ]; then
    PR_URL=$(gh pr list --repo "${ORG}/${TARGET_REPO}" \
        --base "${BRANCH_VAL}" --label automated --state open \
        --json url,title \
        --jq ".[] | select(.title == \"Update Submariner dependencies to v${VERSION}\") | .url" \
        2>/dev/null | head -1 || true)
    if [ -z "$PR_URL" ]; then
        PR_URL=$(gh pr list --repo "${ORG}/${TARGET_REPO}" \
            --base "${BRANCH_VAL}" --label automated --state merged \
            --limit 20 --json url,title \
            --jq ".[] | select(.title == \"Update Submariner dependencies to v${VERSION}\") | .url" \
            2>/dev/null | head -1 || true)
    fi
fi

echo "$PR_URL"
