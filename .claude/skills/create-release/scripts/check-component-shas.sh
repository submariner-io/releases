#!/usr/bin/env bash
# check-component-shas.sh — Verify release YAML component SHAs match branch HEADs
# for the components newly pinned at the current status.
#
# Usage:
#   check-component-shas.sh <release-yaml> [--org submariner-io]
#   check-component-shas.sh releases/v0.25.0-rc2.yaml
#
# Exit 0 if all stage component SHAs match branch HEAD (or no SHA gate for status).
# Exit 1 on mismatch or missing SHA.
set -euo pipefail

ORG="${ORG:-submariner-io}"
RELEASE_FILE=""

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --org)
            ORG="${2:?--org requires a value}"
            shift 2
            ;;
        -*)
            die "Unknown flag: $1"
            ;;
        *)
            [[ -z "$RELEASE_FILE" ]] || die "Unexpected argument: $1"
            RELEASE_FILE="$1"
            shift
            ;;
    esac
done

[[ -n "$RELEASE_FILE" && -f "$RELEASE_FILE" ]] || \
    die "Release YAML required. Usage: $0 <release-yaml> [--org ORG]"

# Single yq pass for release metadata (tab-separated)
IFS=$'\t' read -r STATUS BRANCH VERSION < <(
    yq -r '[.status // "", .branch // "devel", .version // .name // ""] | @tsv' "$RELEASE_FILE"
)
[[ -n "$STATUS" ]] || die "No status in $RELEASE_FILE"

echo "VERSION=${VERSION} STATUS=${STATUS} BRANCH=${BRANCH}"

# Components newly pinned when advancing TO this status (matches scripts/release.sh).
case "$STATUS" in
    shipyard)   COMPONENTS="shipyard" ;;
    admiral)    COMPONENTS="admiral" ;;
    projects)   COMPONENTS="cloud-prepare lighthouse submariner" ;;
    installers) COMPONENTS="submariner-operator" ;;
    released)   COMPONENTS="subctl submariner-charts" ;;
    *)          COMPONENTS="" ;;
esac

if [[ -z "$COMPONENTS" ]]; then
    echo "Component list is empty — no SHA gate for this stage; treating as OK"
    exit 0
fi

echo "Checking stage components: ${COMPONENTS}"
echo "---"

MISMATCHES=0
fail() { echo "FAIL  $*"; MISMATCHES=$((MISMATCHES + 1)); }

for PROJECT in $COMPONENTS; do
    YAML_SHA=$(yq -r ".components.\"${PROJECT}\" // \"\"" "$RELEASE_FILE")
    if [[ -z "$YAML_SHA" || "$YAML_SHA" == "null" ]]; then
        fail "${PROJECT}: missing in YAML"
        continue
    fi

    HEAD_SHA=$(gh api "repos/${ORG}/${PROJECT}/commits/${BRANCH}" --jq .sha 2>/dev/null || true)
    if [[ -z "$HEAD_SHA" ]]; then
        fail "${PROJECT}: could not fetch HEAD of ${BRANCH}"
        continue
    fi

    if [[ "$YAML_SHA" == "$HEAD_SHA" ]]; then
        echo "OK    ${PROJECT}: ${YAML_SHA}"
    else
        fail "${PROJECT}: yaml=${YAML_SHA} head=${HEAD_SHA}"
    fi
done

echo "---"
if [[ "$MISMATCHES" -gt 0 ]]; then
    echo "RESULT: ${MISMATCHES} mismatch(es)"
    exit 1
fi

echo "RESULT: all stage component SHAs match ${BRANCH} HEAD"
exit 0
