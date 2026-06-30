#!/usr/bin/env bash
# check-sha-stability.sh — Gate on branch HEAD stability before recording SHAs.
#
# Usage: check-sha-stability.sh <org> <branch> <repo>...
#
# Queries the current HEAD SHA of each repo's <branch>, then compares against
# a checkpoint saved on the previous call. Exits 0 only when the SHAs match
# the checkpoint (stable across two consecutive polls), removing the checkpoint
# on success. On the first call (no checkpoint), saves a new checkpoint and
# exits 1. Callers should retry on the next poll interval.
#
# Checkpoint file: /tmp/releases-create-release-skill/sha-checkpoint-<branch>.env
#
# Exit codes: 0=stable (proceed), 1=waiting
set -euo pipefail

ORG="$1"
BRANCH="$2"
shift 2
REPOS=("$@")

CHECKPOINT_DIR="/tmp/releases-create-release-skill"
SHA_CHECKPOINT="${CHECKPOINT_DIR}/sha-checkpoint-${BRANCH}.env"
mkdir -p "$CHECKPOINT_DIR"

CURRENT_SHAS=""
for REPO in "${REPOS[@]}"; do
    SHA=$(gh api "repos/${ORG}/${REPO}/commits/${BRANCH}" --jq '.sha' 2>/dev/null || echo "unknown")
    CURRENT_SHAS="${CURRENT_SHAS}${REPO}=${SHA}\n"
done

if [ -f "$SHA_CHECKPOINT" ]; then
    PREV_SHAS=$(cat "$SHA_CHECKPOINT")
    if [ "$PREV_SHAS" = "$(printf '%b' "$CURRENT_SHAS")" ]; then
        echo "Branch SHAs stable across two polls (${BRANCH}):"
        printf '%b' "$CURRENT_SHAS" | sed 's/^/  /'
        rm -f "$SHA_CHECKPOINT"
        exit 0
    else
        echo "WAITING: Branch SHAs changed since last poll — post-merge CI still running."
        printf '%b' "$CURRENT_SHAS" | sed 's/^/  /'
        printf '%b' "$CURRENT_SHAS" > "$SHA_CHECKPOINT"
        exit 1
    fi
else
    echo "WAITING: Saving SHA checkpoint for ${BRANCH} — will advance if stable next poll."
    printf '%b' "$CURRENT_SHAS" | sed 's/^/  /'
    printf '%b' "$CURRENT_SHAS" > "$SHA_CHECKPOINT"
    exit 1
fi
