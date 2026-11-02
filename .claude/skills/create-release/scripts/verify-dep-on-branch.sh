#!/usr/bin/env bash
# verify-dep-on-branch.sh — After a dependency PR is MERGED, confirm its merge
# commit is on the release base branch tip (or an ancestor of tip).
#
# Prevents advancing a release stage when write_component would pin a stale
# HEAD that predates the dependency update merge.
#
# Usage: verify-dep-on-branch.sh <org> <repo> <branch> <pr_url>
# Exit 0 = merge is on branch; 1 = not yet / cannot verify
set -euo pipefail

ORG="$1"
REPO="$2"
BRANCH="$3"
PR_URL="$4"

if [ -z "$PR_URL" ] || [ "$PR_URL" = "-" ]; then
    echo "ERROR: PR URL required to verify merge is on ${BRANCH}"
    exit 1
fi

PR_JSON=$(gh pr view "$PR_URL" --json state,mergeCommit,mergedAt 2>/dev/null || true)
PR_STATE=$(echo "$PR_JSON" | jq -r '.state // "UNKNOWN"')
if [ "$PR_STATE" != "MERGED" ]; then
    echo "NOT ON BRANCH: PR state is ${PR_STATE} (need MERGED)"
    exit 1
fi

MERGE_SHA=$(echo "$PR_JSON" | jq -r '.mergeCommit.oid // empty')
if [ -z "$MERGE_SHA" ]; then
    echo "WARN: No mergeCommit on ${PR_URL} — cannot verify branch tip"
    exit 1
fi

HEAD_SHA=$(gh api "repos/${ORG}/${REPO}/commits/${BRANCH}" --jq .sha 2>/dev/null || true)
if [ -z "$HEAD_SHA" ]; then
    echo "ERROR: Could not fetch HEAD of ${ORG}/${REPO}@${BRANCH}"
    exit 1
fi

if [ "$HEAD_SHA" = "$MERGE_SHA" ]; then
    echo "OK: ${REPO}@${BRANCH} HEAD is merge commit ${MERGE_SHA}"
    exit 0
fi

# Branch may have moved forward after the merge — require merge as ancestor of HEAD.
COMPARE=$(gh api "repos/${ORG}/${REPO}/compare/${MERGE_SHA}...${HEAD_SHA}" --jq .status 2>/dev/null || true)
case "$COMPARE" in
    identical|ahead)
        echo "OK: ${REPO}@${BRANCH} HEAD ${HEAD_SHA} contains merge ${MERGE_SHA} (${COMPARE})"
        exit 0
        ;;
    behind|diverged|"")
        echo "WAITING: ${REPO}@${BRANCH} HEAD ${HEAD_SHA} does not contain merge ${MERGE_SHA} (compare=${COMPARE:-error})"
        exit 1
        ;;
    *)
        echo "WAITING: unexpected compare status '${COMPARE}' for ${MERGE_SHA}...${HEAD_SHA}"
        exit 1
        ;;
esac
