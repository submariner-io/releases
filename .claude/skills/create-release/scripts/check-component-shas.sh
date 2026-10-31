#!/usr/bin/env bash
# check-component-shas.sh — Verify release YAML component SHAs match branch HEADs
# for the components introduced at the current status. On match, request
# CodeRabbit approval (authors cannot approve their own releases PRs).
#
# Usage:
#   check-component-shas.sh <release-yaml> [--approve <pr-number>] [--org submariner-io]
#   check-component-shas.sh releases/v0.25.0-rc2.yaml --approve 1516
#
# Exit 0 if all stage components match (and CodeRabbit approve was requested / already present).
# Exit 1 on mismatch.
set -euo pipefail

ORG="${ORG:-submariner-io}"
RELEASE_FILE=""
APPROVE_PR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --approve)
            APPROVE_PR="${2:?--approve requires a PR number}"
            shift 2
            ;;
        --org)
            ORG="${2:?--org requires a value}"
            shift 2
            ;;
        -*)
            echo "ERROR: Unknown flag: $1" >&2
            exit 1
            ;;
        *)
            if [[ -n "$RELEASE_FILE" ]]; then
                echo "ERROR: Unexpected argument: $1" >&2
                exit 1
            fi
            RELEASE_FILE="$1"
            shift
            ;;
    esac
done

if [[ -z "$RELEASE_FILE" || ! -f "$RELEASE_FILE" ]]; then
    echo "ERROR: Release YAML required. Usage: $0 <release-yaml> [--approve N]" >&2
    exit 1
fi

STATUS=$(yq -r '.status // ""' "$RELEASE_FILE")
BRANCH=$(yq -r '.branch // "devel"' "$RELEASE_FILE")
VERSION=$(yq -r '.version // .name // ""' "$RELEASE_FILE")

if [[ -z "$STATUS" ]]; then
    echo "ERROR: No status in $RELEASE_FILE" >&2
    exit 1
fi

# Components newly pinned when advancing TO this status (matches scripts/release.sh).
stage_components() {
    case "$1" in
        shipyard)   echo shipyard ;;
        admiral)    echo admiral ;;
        projects)   echo cloud-prepare lighthouse submariner ;;
        installers) echo submariner-operator ;;
        released)   echo subctl submariner-charts ;;
        branch|*)   echo "" ;;
    esac
}

request_coderabbit_approve() {
    local pr="$1"
    local me
    me=$(gh api user --jq .login)

    local cr_approved
    cr_approved=$(gh api "repos/${ORG}/releases/pulls/${pr}/reviews" \
        --jq '[.[] | select(.user.login == "coderabbitai" and .state == "APPROVED")] | length')

    if [[ "${cr_approved:-0}" -gt 0 ]]; then
        echo ">>> CodeRabbit already APPROVED PR #${pr}"
        return 0
    fi

    # Avoid spamming: skip if we already asked in the last 20 comments
    local already_asked
    already_asked=$(gh api "repos/${ORG}/releases/issues/${pr}/comments?per_page=20" \
        --jq '[.[] | select(.user.login == "'"${me}"'" and (.body | test("^@coderabbitai\\s+approve\\s*$";"i")))] | length')

    if [[ "${already_asked:-0}" -gt 0 ]]; then
        echo ">>> Already requested @coderabbitai approve on PR #${pr}; waiting for CodeRabbit"
        return 0
    fi

    # Whole comment must be exactly the command (CodeRabbit docs).
    echo ">>> Requesting CodeRabbit approve on PR #${pr} (component SHAs match)..."
    gh pr comment "$pr" --repo "${ORG}/releases" --body "@coderabbitai approve"
    echo ">>> Posted '@coderabbitai approve' — CodeRabbit needs reviews.auto_approvals.enabled"
}

COMPONENTS=$(stage_components "$STATUS")
if [[ -z "$COMPONENTS" ]]; then
    echo "STATUS=$STATUS — no component SHA gate for this stage; treating as OK"
    if [[ -n "$APPROVE_PR" ]]; then
        request_coderabbit_approve "$APPROVE_PR"
    fi
    exit 0
fi

echo "VERSION=${VERSION} STATUS=${STATUS} BRANCH=${BRANCH}"
echo "Checking stage components: ${COMPONENTS}"
echo "---"

MISMATCHES=0
for PROJECT in $COMPONENTS; do
    YAML_SHA=$(yq -r ".components.\"${PROJECT}\" // \"\"" "$RELEASE_FILE")
    if [[ -z "$YAML_SHA" || "$YAML_SHA" == "null" ]]; then
        echo "FAIL  ${PROJECT}: missing in YAML"
        MISMATCHES=$((MISMATCHES + 1))
        continue
    fi

    HEAD_SHA=$(gh api "repos/${ORG}/${PROJECT}/commits/${BRANCH}" --jq .sha 2>/dev/null || true)
    if [[ -z "$HEAD_SHA" ]]; then
        echo "FAIL  ${PROJECT}: could not fetch HEAD of ${BRANCH}"
        MISMATCHES=$((MISMATCHES + 1))
        continue
    fi

    if [[ "$YAML_SHA" == "$HEAD_SHA" ]]; then
        echo "OK    ${PROJECT}: ${YAML_SHA}"
    else
        echo "FAIL  ${PROJECT}: yaml=${YAML_SHA} head=${HEAD_SHA}"
        MISMATCHES=$((MISMATCHES + 1))
    fi
done

echo "---"
if [[ "$MISMATCHES" -gt 0 ]]; then
    echo "RESULT: ${MISMATCHES} mismatch(es) — not requesting CodeRabbit approve"
    exit 1
fi

echo "RESULT: all stage component SHAs match ${BRANCH} HEAD"
if [[ -n "$APPROVE_PR" ]]; then
    request_coderabbit_approve "$APPROVE_PR"
fi
exit 0
