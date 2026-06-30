#!/usr/bin/env bash
# check-prereqs.sh — Verify prerequisites for running the release skill.
# Usage: check-prereqs.sh [--status-only]
set -euo pipefail

STATUS_ONLY=false
DRY_RUN=false
for arg in "$@"; do
    [[ "$arg" == "--status-only" ]] && STATUS_ONLY=true
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

ERRORS=()

# 1. Verify we are in the releases repo root
if [ ! -f releases/example.yaml ]; then
    ERRORS+=("Not in submariner-io/releases root. Run: cd ~/go/src/github.com/submariner-io/releases")
fi

# 2. Verify gh is authenticated (do NOT print the token)
if ! gh auth status 2>&1 | grep -q "Logged in"; then
    ERRORS+=("gh CLI not authenticated. Run: gh auth login")
else
    echo "gh auth: OK"
fi

# 3. Verify GITHUB_TOKEN is set (required by make release inside Dapper; not needed for --status or --dry-run)
if [ "$STATUS_ONLY" = false ] && [ "$DRY_RUN" = false ]; then
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        ERRORS+=("GITHUB_TOKEN not set. Run: export GITHUB_TOKEN=\$(gh auth token)")
    else
        echo "GITHUB_TOKEN: set"
    fi
fi

# 4. Verify Docker is available (make release runs inside Dapper container)
if [ "$STATUS_ONLY" = false ] && [ "$DRY_RUN" = false ]; then
    if ! docker info >/dev/null 2>&1; then
        ERRORS+=("Docker not available. make release requires Docker (Dapper).")
    else
        echo "Docker: OK"
    fi
fi

# 5. Verify skopeo is available (used for quay.io image verification)
if ! command -v skopeo >/dev/null 2>&1; then
    ERRORS+=("skopeo not found. Install skopeo.")
fi

# 6. Verify jq is available (used for parsing GitHub API responses)
if ! command -v jq >/dev/null 2>&1; then
    ERRORS+=("jq not found. Install jq.")
fi

# 7. Verify yq is available (used to read release YAML)
if ! command -v yq >/dev/null 2>&1; then
    ERRORS+=("yq not found. Install yq.")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    for ERR in "${ERRORS[@]}"; do
        echo "ERROR: $ERR"
    done
    exit 1
fi

echo "All prerequisites OK."
