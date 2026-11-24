#!/usr/bin/env bash
# check-dep-pr.sh — Check state of a dependency PR and optionally approve it.
#
# Usage: check-dep-pr.sh <org> <repo> <version> <branch_val> <pr_url_or_empty> [--approve]
#
# If pr_url is empty or "-", does a fallback search itself.
# Outputs status lines for the user to see.
# Exit codes: 0=merged, 1=open/waiting, 2=not_found
set -euo pipefail

ORG="$1"
REPO="$2"
VERSION="$3"
BRANCH_VAL="$4"
PR_URL="${5:-}"
APPROVE=false
[[ "${6:-}" == "--approve" ]] && APPROVE=true

# Treat "-" as empty
[[ "$PR_URL" == "-" ]] && PR_URL=""

# If no URL provided, do a fallback search
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
    echo "NOT YET CREATED (do-release may still be running)"
    exit 2
fi

PR_STATE=$(gh pr view "$PR_URL" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")

if [ "$PR_STATE" = "MERGED" ]; then
    echo "MERGED: $PR_URL"
    exit 0
elif [ "$PR_STATE" = "OPEN" ]; then
    echo "OPEN: $PR_URL"

    # Approve only when requested
    if [ "$APPROVE" = true ]; then
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

    # Report failing checks regardless
    if ALL_FAILS=$(gh pr checks "$PR_URL" 2>/dev/null | grep -i "fail"); then
        REQ=$(echo "$ALL_FAILS" | grep -i "(Required)" || true)
        NON_REQ=$(echo "$ALL_FAILS" | grep -iv "(Required)" | wc -l | xargs)
        [ -n "$REQ" ] && echo "$REQ"
        [ "${NON_REQ:-0}" -gt 0 ] && echo "  (${NON_REQ} non-required failure(s) — ignored for approval)"
    fi

    exit 1
else
    echo "WARN: Unexpected PR state '${PR_STATE}' for ${PR_URL} — check manually, not approving"
    exit 1
fi
